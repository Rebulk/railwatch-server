# frozen_string_literal: true

namespace :railwatch_server do
  desc "Run the bundled Railwatch server in the foreground (for a Procfile or a supervisor; Puma users add `plugin :railwatch_server`)"
  task start: :environment do
    Railwatch::Server.run!
  end

  desc "Whether the bundled Railwatch server is running and the agent reports to it"
  task status: :environment do
    config = Railwatch::Server.config
    dir = Railwatch::Server.data_dir
    up = begin
      Net::HTTP.get_response(URI("#{config.local_url}/up")).is_a?(Net::HTTPSuccess)
    rescue SystemCallError, IOError
      false
    end
    pid = dir.path.join("server.pid")
    binary = begin
      Railwatch::Server::Binary.path
    rescue Railwatch::Server::Binary::NotFound => e
      "MISSING: #{e.message.lines.first.strip}"
    end
    puts "binary       #{binary}"
    puts "data dir     #{dir.path}#{' (not provisioned)' unless dir.provisioned?}"
    puts "server       #{up ? 'UP' : 'DOWN'} on #{config.local_url}#{" (pid #{pid.read.split.first})" if pid.exist?}"
    puts "dashboard    #{config.normalized_mount_path}"
    puts "agent        " + (Railwatch::Server.agent_configured_elsewhere? ? "configured elsewhere (#{Railwatch.config.local? ? 'transport :local' : Railwatch.config.ingest_url})" :
                             "reports to #{Railwatch.config.ingest_url}")
    puts "log          #{dir.log_file}"
    exit(up ? 0 : 1)
  end
end
