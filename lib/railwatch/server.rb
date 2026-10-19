# frozen_string_literal: true

require "pathname"
require "railwatch"
require_relative "server/version"
require_relative "server/configuration"
require_relative "server/binary"
require_relative "server/proxy_auth"
require_relative "server/data_dir"
require_relative "server/settings"
require_relative "server/process"
require_relative "server/relay"

module Railwatch
  # The Railwatch server (the AGPL Rust binary, bundled) run next to this
  # app: started by Puma's master (`plugin :railwatch_server`) or
  # `bin/rails railwatch_server:start`, never inside a Puma worker; the
  # dashboard proxied at /railwatch behind the app's own gate; the railwatch
  # agent pointed at it.
  module Server
    class Error < StandardError; end

    class << self
      def config
        @config ||= Configuration.new
      end

      def configure
        yield config
        config
      end

      def data_dir
        DataDir.new(config.data_path)
      end

      def enabled?
        config.enabled
      end

      # Whether the app reports somewhere of its own choosing, in which case
      # the agent is left alone: a token set (RAILWATCH_TOKEN or the
      # initializer), or the embedded store (`transport = :local`).
      def agent_configured_elsewhere?
        return true if Railwatch.config.local?
        return false if Railwatch.config.ingest_url == config.local_url

        Railwatch.config.token.to_s.strip != ""
      end

      # Once per data dir, before anything needs the token: `railwatch setup`
      # and the proxy secret. Cheap after the first time (two files exist).
      def provision!(log: ->(m) { warn("[railwatch-server] #{m}") })
        dir = data_dir
        return dir if dir.provisioned?

        app = defined?(Rails) && Rails.application ? Rails.application.class.module_parent_name : "App"
        env = config.environment
        # setup needs none of the app's settings (server.env is written at
        # the first start, after this).
        server_env = Process.new(config: config, data_dir: dir, binary: Binary.path, log: log).env.merge("RAILWATCH_ENV_FILE" => File::NULL)
        done = dir.provision!(binary: Binary.path, env: server_env, app_name: app, env_name: env)
        log.call("provisioned #{dir.path}: #{done.join(', ')}") if done.any?
        dir
      end

      # The railwatch agent's settings for the bundled server. Called from
      # the Railtie after the app's initializers have run.
      def wire_agent!
        return :disabled unless enabled? && config.wire_agent
        return :configured_elsewhere if agent_configured_elsewhere?

        dir = provision!
        held = dir.environment
        if held && held != config.environment
          raise Error, "#{dir.path} holds the #{held} environment, and this is #{config.environment}: the agent is not wired, " \
                       "so #{config.environment}'s telemetry does not land in #{held}'s. One data dir per environment: " \
                       "unset RAILWATCH_SERVER_DATA_DIR (the default is storage/railwatch/<env>) or point it elsewhere"
        end
        token = dir.token
        Railwatch.config.token = token
        Railwatch.config.ingest_url = config.local_url
        :wired
      end

      # The foreground supervisor for setups without Puma (Procfile,
      # systemd, a container's second process): runs until TERM/INT.
      def run!(log: ->(m) { $stdout.puts("[railwatch-server] #{m}"); $stdout.flush })
        provision!(log: log)
        server = Process.new(config: config, data_dir: data_dir, binary: Binary.path, log: log)
        stopping = false
        %w[TERM INT].each { |sig| trap(sig) { stopping = true } }
        begin
          loop do
            sleep 0.5
            # Checked after the sleep: a TERM during it must not start a
            # server on the way out.
            break if stopping

            server.ensure_running
          end
        ensure
          server.stop
        end
      end
    end
  end
end

require_relative "server/engine" if defined?(Rails::Engine)
