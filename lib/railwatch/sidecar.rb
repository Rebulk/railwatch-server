# frozen_string_literal: true

require "pathname"
require "railwatch"
require_relative "sidecar/version"
require_relative "sidecar/configuration"
require_relative "sidecar/binary"
require_relative "sidecar/proxy_auth"
require_relative "sidecar/data_dir"
require_relative "sidecar/settings"
require_relative "sidecar/process"
require_relative "sidecar/relay"
require_relative "sidecar/proxy_handoff"

module Railwatch
  # The Railwatch server (the Rust binary, bundled) run next to this
  # app: started by Puma's master (`plugin :railwatch_sidecar`) or
  # `bin/rails railwatch_sidecar:start`, never inside a Puma worker; the
  # dashboard proxied at /railwatch behind the app's own gate; the railwatch
  # agent pointed at it.
  module Sidecar
    class Error < StandardError; end

    class << self
      # One warning per old name per process, for what was renamed with the
      # gem (railwatch-server -> railwatch-sidecar, 0.2.0). Each old name
      # keeps working until 1.0.
      def deprecated(message)
        @deprecated ||= {}
        return if @deprecated[message]

        @deprecated[message] = true
        warn("[railwatch-sidecar] DEPRECATED: #{message} (railwatch-server was renamed railwatch-sidecar; the old name works until 1.0)")
      end

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

      # Whether the dashboard has a gate in front of it: HTTP Basic on, or
      # the app's own base controller (base_controller_class set to
      # something other than ActionController::Base). The railwatch gem's
      # own answer when it has one (dashboard_gate_configured?).
      def dashboard_gated?
        gem = Railwatch.config
        return gem.dashboard_gate_configured? if gem.respond_to?(:dashboard_gate_configured?)

        default = defined?(Railwatch::Configuration::DEFAULT_BASE_CONTROLLER) ? Railwatch::Configuration::DEFAULT_BASE_CONTROLLER : "ActionController::Base"
        gem.http_basic_auth_enabled || gem.base_controller_class.to_s.delete_prefix("::") != default
      end

      def ungated_message
        "The Railwatch dashboard at #{config.normalized_mount_path} has no gate, so it is not served in #{config.environment}: " \
          "HTTP Basic is off (RAILWATCH_HTTP_BASIC_AUTH_ENABLED=false) and Railwatch.config.base_controller_class is " \
          "ActionController::Base, which would let every visitor in as a Railwatch user, MCP included. Turn HTTP Basic back on " \
          "(Railwatch.config.http_basic_auth_user and _password), or set base_controller_class to a controller of your app " \
          "that signs people in (its before_actions run first)."
      end

      # Whether the app reports somewhere of its own choosing, in which case
      # the agent is left alone: a token set (RAILWATCH_TOKEN or the
      # initializer).
      def agent_configured_elsewhere?
        return false if Railwatch.config.ingest_url == config.local_url

        Railwatch.config.token.to_s.strip != ""
      end

      # Whether this process starts the server, the only kind that may create
      # the data dir: Puma with `plugin :railwatch_sidecar` (its master and
      # workers; under a bare `puma` the plugin is loaded before the app),
      # `bin/rails server` (which loads the app before Puma reads its config),
      # and `bin/rails railwatch_sidecar:start`. Every other process (a job
      # worker, a console, `assets:precompile` in a Dockerfile) only reads
      # what the server's process wrote: provisioning in an asset build put
      # the token and the dashboard's HMAC key in the image, shared by every
      # volume made from it.
      def serving?
        return true if defined?(::Rails::Server)
        return true if $LOADED_FEATURES.any? { _1.end_with?("/puma/plugin/railwatch_sidecar.rb", "/puma/plugin/railwatch_server.rb") }

        rake_tasks.intersect?(%w[railwatch_sidecar:start railwatch_server:start])
      end

      # An image build (`SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile`),
      # or the database step a container runs before its server (Rails'
      # docker-entrypoint: `bin/rails db:prepare`, then `rails server`, which
      # provisions), where an unprovisioned data dir is expected and not
      # worth a warning: on a fresh volume it was logged right before the
      # server's process provisioned it.
      def building?
        ENV["SECRET_KEY_BASE_DUMMY"].to_s.strip != "" || rake_tasks.any? { _1.start_with?("assets:", "db:") }
      end

      def rake_tasks
        defined?(::Rake.application) ? ::Rake.application.top_level_tasks : []
      end

      # Why this process could not provision the data dir (the dashboard
      # says so), or nil.
      attr_reader :provision_error

      # Once per data dir, before the first server starts: `railwatch setup`
      # and the proxy secret. Cheap after the first time (two files exist).
      # Only from a process that starts the server (serving?).
      #
      # Tried once per process: under `bin/rails server` the Railtie and then
      # the Puma plugin both get here before Puma listens, and a setup that
      # failed or hit setup_timeout must not hold up the boot twice. The next
      # start tries again.
      def provision!(log: ->(m) { warn("[railwatch-sidecar] #{m}") })
        dir = data_dir
        return dir if dir.provisioned?
        raise @provision_error if @provision_error

        app = defined?(Rails) && Rails.application ? Rails.application.class.module_parent_name : "App"
        env = config.environment
        # setup needs none of the app's settings (server.env is written at
        # the first start, after this).
        server_env = Process.new(config: config, data_dir: dir, binary: Binary.path, log: log).env.merge("RAILWATCH_ENV_FILE" => File::NULL)
        done = dir.provision!(binary: Binary.path, env: server_env, app_name: app, env_name: env, timeout: config.setup_timeout)
        log.call("provisioned #{dir.path}: #{done.join(', ')}") if done.any?
        dir
      rescue Error => e
        @provision_error = e
        raise
      end

      # The railwatch agent's settings for the bundled server. Called from
      # the Railtie after the app's initializers have run.
      def wire_agent!
        return :disabled unless enabled? && config.wire_agent
        return :configured_elsewhere if agent_configured_elsewhere?

        dir = serving? ? provision! : data_dir
        return building? ? :building : :not_provisioned unless dir.provisioned?

        held = dir.environment
        if held && held != config.environment
          raise Error, "#{dir.path} holds the #{held} environment, and this is #{config.environment}: the agent is not wired, " \
                       "so #{config.environment}'s telemetry does not land in #{held}'s. One data dir per environment: " \
                       "unset RAILWATCH_SIDECAR_DATA_DIR (the default is storage/railwatch/<env>) or point it elsewhere"
        end
        token = dir.token
        Railwatch.config.token = token
        Railwatch.config.ingest_url = config.local_url
        :wired
      end

      # The foreground supervisor for setups without Puma (Procfile,
      # systemd, a container's second process): runs until TERM/INT.
      def run!(log: ->(m) { $stdout.puts("[railwatch-sidecar] #{m}"); $stdout.flush })
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

# The pre-rename constant (railwatch-server): Railwatch::Server.configure in
# an existing initializer keeps working, and the railwatch gem's agents
# generator, which looks for Railwatch::Server, finds the mount path.
Railwatch::Server = Railwatch::Sidecar unless Railwatch.const_defined?(:Server, false)

require_relative "sidecar/engine" if defined?(Rails::Engine)
