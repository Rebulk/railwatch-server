# Slow dashboard pages must not take the app's Puma threads.
#
# Boots the app (default /var/tmp/rws-fresh, any app with railwatch-server in
# its Gemfile) under Puma, 1 worker x 3 threads, without the plugin, in front
# of a fake Railwatch server on loopback whose /railwatch/slow pages take
# DELAY seconds. Then opens SLOW concurrent slow dashboard loads and times
# the app's own /up while they wait. Before the hijacking proxy, /up waited
# for a slow page to finish (every thread was holding one); after, it is
# answered at once.
#
#   ruby test/e2e/slow_dashboard.rb [/path/to/app]
#
# Also checks, through the proxy, what the fake server makes easy to check:
# a trickled chunked response streams, an upload arrives whole, the app's
# own session cookie is still set next to the server's, the server down is a
# 503, and past max_proxied_requests the visitor gets a 503 at once.
require "net/http"
require "socket"
require "tmpdir"
require "fileutils"
require "securerandom"

APP = File.expand_path(ARGV[0] || "/var/tmp/rws-fresh")
PUMA_PORT = 3311
SIDECAR_PORT = 28797
DELAY = Float(ENV.fetch("DELAY", "3"))
SLOW = Integer(ENV.fetch("SLOW", "6"))
AUTH = %w[admin s3cret-dashboard].freeze

# --- the fake server -------------------------------------------------------
class FakeServer
  attr_reader :uploads

  def initialize(port)
    @server = TCPServer.new("127.0.0.1", port)
    @uploads = []
    @thread = Thread.new { loop { Thread.new(@server.accept) { |c| serve(c) } } }
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve(client)
    head = +""
    head << client.readpartial(16_384) until head.include?("\r\n\r\n")
    head, body = head.split("\r\n\r\n", 2)
    path = head[/\A\S+ (\S+)/, 1]
    length = head[/^content-length: *(\d+)/i, 1].to_i
    body << client.readpartial(65_536) while body.bytesize < length
    case path
    when %r{/slow}
      sleep DELAY
      respond(client, "slow page")
    when %r{/upload}
      @uploads << body
      respond(client, "got #{body.bytesize}")
    when %r{/trickle}
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n")
      5.times do |i|
        chunk = "part #{i}\n"
        client.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
        sleep 0.4
      end
      client.write("0\r\n\r\n")
    else
      respond(client, "page #{path}", "Set-Cookie: _railwatch_session=server; Path=/railwatch; HttpOnly\r\n")
    end
  rescue IOError, SystemCallError
    nil
  ensure
    client.close rescue nil
  end

  def respond(client, text, extra = "")
    client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{text.bytesize}\r\n#{extra}\r\n#{text}")
  end
end

# --- helpers ---------------------------------------------------------------
def http(method, path, body: nil, auth: true, timeout: 30)
  Net::HTTP.start("127.0.0.1", PUMA_PORT, read_timeout: timeout, open_timeout: 5) do |h|
    req = Net::HTTP.const_get(method).new(path)
    req.basic_auth(*AUTH) if auth
    req["Content-Type"] = "application/octet-stream" if body
    req.body = body if body
    h.request(req)
  end
end

def timed
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  [ result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t ]
end

def check(name, ok, detail = nil)
  puts "#{ok ? 'ok  ' : 'FAIL'} #{name}#{" (#{detail})" if detail}"
  $failed = true unless ok
end

def ms(seconds) = "#{(seconds * 1000).round} ms"

# --- boot ------------------------------------------------------------------
data = Dir.mktmpdir("rws-slow-", "/var/tmp")
File.write(File.join(data, "proxy_secret"), SecureRandom.hex(32))
File.write(File.join(data, "ingest_token"), "rw_test")
File.write(File.join(data, "environment"), "development\n")
puma_config = File.join(data, "puma.rb")
File.write(puma_config, <<~RUBY)
  workers 1
  threads 3, 3
  port #{PUMA_PORT}
  environment "development"
RUBY
log = File.join(data, "puma.log")
env = {
  "RAILWATCH_SERVER_ENABLED" => "true", "RAILWATCH_SERVER_PORT" => SIDECAR_PORT.to_s, "RAILWATCH_SERVER_DATA_DIR" => data,
  "RAILWATCH_SERVER_WIRE_AGENT" => "false", "RAILWATCH_ENABLED" => "false", "WEB_CONCURRENCY" => nil, "RAILS_MAX_THREADS" => nil,
  "RAILWATCH_SERVER_MAX_PROXIED_REQUESTS" => ENV.fetch("RAILWATCH_SERVER_MAX_PROXIED_REQUESTS", "16")
}
fake = FakeServer.new(SIDECAR_PORT)
puma = spawn(env, "bundle", "exec", "puma", "-C", puma_config, chdir: APP, out: log, err: log, pgroup: true)
begin
  deadline = Time.now + 60
  until (http(:Get, "/up").is_a?(Net::HTTPSuccess) rescue false)
    raise "Puma did not boot; #{log}:\n#{File.read(log).lines.last(20).join}" if Time.now > deadline

    sleep 0.2
  end
  http(:Get, "/railwatch/warm") # load the controller

  # --- the reproduction ----------------------------------------------------
  _, idle = timed { http(:Get, "/up") }
  slow = Array.new(SLOW) { Thread.new { timed { http(:Get, "/railwatch/slow") } } }
  sleep 0.3 # every slow load is waiting on the server
  during = Array.new(5) { timed { http(:Get, "/up") }.then { |r, t| [ r.code, t ] } }
  results = slow.map(&:value)
  worst = during.map(&:last).max
  puts "/up idle #{ms(idle)}; during #{SLOW} slow loads (#{DELAY} s each, 3 threads): " \
       "#{during.map { |_, t| ms(t) }.join(', ')}; slow loads #{results.map { |r, t| "#{r.code}/#{t.round(1)}s" }.join(' ')}"
  check("the app answers while #{SLOW} slow dashboard pages wait (worst /up #{ms(worst)})", worst < 0.5 && during.all? { |c, _| c == "200" })
  check("every slow page arrives", results.all? { |r, _| r.code == "200" && r.body == "slow page" })

  # --- the rest of the proxy -----------------------------------------------
  first = nil
  r, total = timed do
    Net::HTTP.start("127.0.0.1", PUMA_PORT) do |h|
      req = Net::HTTP::Get.new("/railwatch/trickle")
      req.basic_auth(*AUTH)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      h.request(req) { |res| res.read_body { first ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - t } }
    end
  end
  check("a chunked response streams (first part after #{ms(first)}, all after #{ms(total)})", r.code == "200" && first < 0.3 && total > 1.5)

  upload = Random.bytes(3 * 1024 * 1024)
  r = http(:Post, "/railwatch/upload", body: upload)
  check("a 3 MB upload arrives whole", r.code == "200" && fake.uploads.last == upload, r.body)

  r = http(:Get, "/railwatch/page")
  check("401 without credentials", http(:Get, "/railwatch/page", auth: false).code == "401")
  check("the server's cookie comes back", r.get_fields("set-cookie").to_a.any? { _1.start_with?("_railwatch_session=server") })
  check("the response says Connection: close", r["connection"].to_s.casecmp?("close"), r["connection"])

  cap = Integer(env["RAILWATCH_SERVER_MAX_PROXIED_REQUESTS"])
  slow = Array.new(cap) { Thread.new { http(:Get, "/railwatch/slow") } }
  sleep 0.5
  r, t = timed { http(:Get, "/railwatch/page") }
  check("past max_proxied_requests (#{cap}): 503 at once (#{ms(t)})", r.code == "503" && t < 0.5 && r["retry-after"], r.code)
  check("the app still answers then", http(:Get, "/up").code == "200")
  check("the #{cap} in flight all arrive", slow.map(&:value).all? { _1.code == "200" })

  fake.stop
  r = http(:Get, "/railwatch/page")
  check("the server down: 503 that says so", r.code == "503" && r.body.include?("not answering"), r.code)
ensure
  Process.kill(:TERM, -puma) rescue nil
  Process.wait(puma) rescue nil
  fake&.stop rescue nil
  if $failed
    puts "Puma log: #{log}"
  else
    FileUtils.rm_rf(data)
  end
end
exit($failed ? 1 : 0)
