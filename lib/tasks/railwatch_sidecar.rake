# frozen_string_literal: true

namespace :railwatch_sidecar do
  desc "Run the bundled Railwatch server in the foreground (for a Procfile or a supervisor; Puma users add `plugin :railwatch_sidecar`)"
  task start: :environment do
    Railwatch::Sidecar.run!
  end

  desc "Whether the bundled Railwatch server is running and the agent reports to it"
  task status: :environment do
    config = Railwatch::Sidecar.config
    dir = Railwatch::Sidecar.data_dir
    up = begin
      Net::HTTP.get_response(URI("#{config.local_url}/up")).is_a?(Net::HTTPSuccess)
    rescue SystemCallError, IOError
      false
    end
    pid = dir.path.join("server.pid")
    binary = begin
      Railwatch::Sidecar::Binary.path
    rescue Railwatch::Sidecar::Binary::NotFound => e
      "MISSING: #{e.message.lines.first.strip}"
    end
    puts "binary       #{binary}"
    puts "data dir     #{dir.path}#{' (not provisioned)' unless dir.provisioned?}"
    puts "server       #{up ? 'UP' : 'DOWN'} on #{config.local_url}#{" (pid #{pid.read.split.first})" if pid.exist?}"
    puts "dashboard    #{config.normalized_mount_path}"
    puts "agent        " + (Railwatch::Sidecar.agent_configured_elsewhere? ? "configured elsewhere (#{Railwatch.config.ingest_url})" :
                             "reports to #{Railwatch.config.ingest_url}")
    puts "log          #{dir.log_file}"
    exit(up ? 0 : 1)
  end
end

# The task names before the rename (railwatch-server); they work until 1.0.
namespace :railwatch_server do
  %w[start status].each do |name|
    task name => :environment do
      Railwatch::Sidecar.deprecated("railwatch_server:#{name} is now railwatch_sidecar:#{name}")
      Rake::Task["railwatch_sidecar:#{name}"].invoke
    end
  end
end
