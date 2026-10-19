#!/usr/bin/env ruby
# Two app containers on one named volume (separate network namespaces, like
# Kamal's blue/green), continuous load on both through the handover, then a
# count: every request each app answered must be stored exactly once.
#
#   ruby overlap.rb [term|kill] [image]
require "net/http"
require "json"
require "securerandom"
require "open3"

MODE = ARGV[0] || "term"
IMAGE = ARGV[1] || "rws-overlap:base"
RUN = "ov#{SecureRandom.hex(3)}"
VOL = "#{RUN}-storage"
PROBES = "/var/tmp/rws-overlap/probes/#{RUN}"
Dir.mkdir(File.dirname(PROBES)) rescue nil
Dir.mkdir(PROBES)
File.chmod(0o777, PROBES)

def sh(*cmd)
  out, st = Open3.capture2e(*cmd)
  raise "#{cmd.join(' ')}: #{out}" unless st.success?
  out.strip
end

def start(name, port)
  sh("docker", "run", "-d", "--name", name, "--hostname", name, "-p", "127.0.0.1:#{port}:3000",
     "-v", "#{VOL}:/rails/storage", "-v", "#{PROBES}:/probes", "-e", "PROBE_LOG=/probes/#{name}.jsonl",
     "-e", "RAILWATCH_SERVER_URL=http://127.0.0.1:#{port}", *ENV.fetch("EXTRA_ENV", "").split.flat_map { ["-e", _1] }, "--memory", "768m", IMAGE)
end

def up?(port)
  Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/up")).code == "200"
rescue StandardError
  false
end

def wait_up(port, timeout = 90)
  t = Time.now
  sleep 0.3 until up?(port) || Time.now - t > timeout
  raise "app on #{port} never came up" unless up?(port)
end

served = Hash.new { |h, k| h[k] = [] } # container => [req ids answered 200]
lock = Mutex.new
stop = false
loaders = {}
load_on = lambda do |name, port|
  loaders[name] = Thread.new do
    i = 0
    until stop
      id = "#{name}-#{i += 1}"
      begin
        http = Net::HTTP.new("127.0.0.1", port)
        http.open_timeout = 1
        http.read_timeout = 5
        res = http.get("/widgets", "X-Req-Id" => id)
        lock.synchronize { served[name] << id } if res.code == "200"
      rescue StandardError
        nil
      end
      sleep 0.05
    end
  end
end

begin
  sh("docker", "volume", "create", VOL)
  a, b = "#{RUN}-a", "#{RUN}-b"
  start(a, 3101)
  wait_up(3101)
  load_on.call(a, 3101)
  sleep 5
  start(b, 3102) # the new release: overlaps, then the old one goes
  wait_up(3102)
  load_on.call(b, 3102)
  sleep 10
  # A's loader stops first, as kamal-proxy stops routing to the old
  # container before it is stopped.
  loaders[a].kill
  if MODE == "kill"
    sh("docker", "kill", "-s", "KILL", a)
  else
    sh("docker", "stop", "-t", "30", a) # Kamal: stop_wait_time 30
  end
  sleep 15
  stop = true
  loaders.each_value(&:join)
  sleep 4 # last flushes (flush_interval 1)
  sh("docker", "stop", "-t", "30", b)

  # Count what the server stored, from the volume, with B stopped.
  rows = sh("docker", "run", "--rm", "-v", "#{VOL}:/s", "--entrypoint", "sh", IMAGE, "-c",
            "ruby -rsqlite3 -e 'Dir[\"/s/railwatch/**/telemetry/*/core/*.sqlite3\"].each { |f| " \
            "SQLite3::Database.new(f).execute(\"select user_ref from executions where kind = ? and user_ref is not null\", [\"request\"]).each { |r| puts r[0] } }'")
  stored = rows.lines.map(&:strip).reject(&:empty?).tally
  report = {}
  served.each do |name, ids|
    missing = ids.reject { |id| stored.key?(id) }
    dup = ids.select { |id| stored[id].to_i > 1 }
    report[name] = { served: ids.size, stored: ids.size - missing.size, missing: missing.size, duplicated: dup.size,
                     missing_sample: missing.first(5) }
  end
  probes = Dir["#{PROBES}/*.jsonl"].to_h do |f|
    lines = File.readlines(f).map { JSON.parse(_1) }
    samples = lines.select { _1["ev"] == "sample" }
    [ File.basename(f, ".jsonl"), {
      sampled_out: samples.count { !_1["sampled"] },
      sampled_in: samples.count { _1["sampled"] },
      max_bp: samples.map { _1["bp"] }.max,
      refused_deliveries: lines.count { _1["ev"] == "deliver" && !_1["ok"] },
      ok_deliveries: lines.count { _1["ev"] == "deliver" && _1["ok"] },
      retains: lines.count { _1["ev"] == "retain" }
    } ]
  end
  puts JSON.pretty_generate(run: RUN, mode: MODE, image: IMAGE, apps: report, probes: probes)
ensure
  system("docker", "logs", "#{RUN}-b", out: "#{PROBES}/b.log", err: [ :child, :out ])
  system("docker", "rm", "-f", "#{RUN}-a", "#{RUN}-b", out: File::NULL, err: File::NULL)
  system("docker", "volume", "rm", VOL, out: File::NULL, err: File::NULL) unless ENV["KEEP"]
end
