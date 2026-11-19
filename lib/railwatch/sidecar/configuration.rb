# frozen_string_literal: true

module Railwatch
  module Sidecar
    # Everything is an env var first (RAILWATCH_SIDECAR_*), then assignment in
    # an initializer:
    #
    #   Railwatch::Sidecar.configure do |c|
    #     c.port = 28790
    #     c.user = ->(controller) { { email: controller.current_user.email, name: controller.current_user.name, role: "admin" } }
    #   end
    #
    # The dashboard's gate is the railwatch gem's (Railwatch.config): HTTP
    # Basic on and closed by default, or `base_controller_class` with Basic
    # off. One set of credentials for /railwatch whichever gem serves it.
    class Configuration
      attr_accessor :enabled, :port, :data_dir, :mount_path, :binary, :url, :stop_timeout, :setup_timeout, :user, :wire_agent,
                    :max_live_connections, :max_proxied_requests, :proxy_connect_timeout, :proxy_first_byte_timeout,
                    :proxy_idle_timeout, :nice, :smtp, :mail_from, :backup, :google, :retention, :alert_delivery, :server_env,
                    :agent_access

      def initialize
        # nil: on, except under Rails.env.test (a test run on a machine with
        # a development server running would report into it). See #enabled.
        @enabled = env_bool("RAILWATCH_SIDECAR_ENABLED", nil)
        # One fixed port per app, not a free one picked at boot: every process
        # of the app (Puma workers, Solid Queue, a rake task) must find the
        # server without asking, and a second Puma on the same host and data
        # dir must hit the same server (docs: two processes, one data dir).
        @port = Integer(setting("RAILWATCH_SIDECAR_PORT", "28790"))
        # nil: storage/railwatch/<Rails.env>, one per environment, as Rails
        # keeps storage/<env>.sqlite3. See #data_path.
        @data_dir = setting("RAILWATCH_SIDECAR_DATA_DIR")
        @mount_path = setting("RAILWATCH_SIDECAR_MOUNT_PATH", "/railwatch")
        # A railwatch binary of your own (another version, a platform this
        # gem has no build for). Default: the one in this platform's gem.
        @binary = setting("RAILWATCH_SIDECAR_BINARY")
        # The public URL of the dashboard's host, for links in alert emails
        # and the Secure cookie flag. Default: the loopback address.
        @url = setting("RAILWATCH_SIDECAR_URL")
        # How long Puma's exit waits for the server to drain after TERM. The
        # server answers SIGTERM by finishing in-flight requests and committing
        # queued writes; an idle one is gone in well under a second.
        @stop_timeout = Float(setting("RAILWATCH_SIDECAR_STOP_TIMEOUT", "15"))
        # How long the first start of a data dir waits for `railwatch setup`
        # (it takes about a second), before Puma listens. Past it the setup is
        # KILLed and the app boots without the server; the next start retries.
        @setup_timeout = Float(setting("RAILWATCH_SIDECAR_SETUP_TIMEOUT", "30"))
        # Who the dashboard's visitor is, as the server should see them:
        # ->(controller) { { email:, name:, role: "admin" | "member" } }. A
        # role left out is Railwatch::Sidecar.default_role (member).
        @user = nil
        # Whether <mount>/mcp and <mount>/api/ (what an AI agent calls) are
        # signed for the visitor like the dashboard, so the agent needs no
        # token. nil: only in development, for a request from this machine
        # to a local host name (ProxyController#agent_access?). true: for
        # every request that passes the gate, in any environment. false:
        # never; an agent sends a token (Authorization: Bearer rwp_...).
        @agent_access = env_bool("RAILWATCH_SIDECAR_AGENT_ACCESS", nil)
        # Point the railwatch agent at the bundled server when the app has not
        # configured one (no RAILWATCH_TOKEN). Off: the app wires it itself.
        @wire_agent = env_bool("RAILWATCH_SIDECAR_WIRE_AGENT", true)
        # Open live-channel connections (one per dashboard tab) per app
        # process, all spliced by one relay thread. Past it the dashboard
        # still works, without live updates.
        @max_live_connections = Integer(setting("RAILWATCH_SIDECAR_MAX_LIVE_CONNECTIONS", "64"))
        # Dashboard requests waiting on the server or streaming back, per app
        # process, all moved by that same relay thread instead of a Puma
        # thread each. Past it a dashboard request gets 503 and Retry-After
        # at once; the app's own requests are never affected.
        @max_proxied_requests = Integer(setting("RAILWATCH_SIDECAR_MAX_PROXIED_REQUESTS", "64"))
        # Seconds: to connect to the server (on loopback: it is down, or past
        # its own connection cap), for it to start answering a dashboard
        # request (504 past it; the slowest page at 30 days takes seconds),
        # and for a response that has started to move again (cut off past it).
        # The first-byte timeout is under the 30 s after which Thruster and
        # kamal-proxy drop a response that has not started: past theirs the
        # visitor gets an empty reply, under it this proxy's 504 that says why.
        @proxy_connect_timeout = Float(setting("RAILWATCH_SIDECAR_PROXY_CONNECT_TIMEOUT", "2"))
        @proxy_first_byte_timeout = Float(setting("RAILWATCH_SIDECAR_PROXY_FIRST_BYTE_TIMEOUT", "25"))
        @proxy_idle_timeout = Float(setting("RAILWATCH_SIDECAR_PROXY_IDLE_TIMEOUT", "60"))
        # How much lower than the app's the server's CPU priority is (nice
        # increment, 0-19; 0 keeps the app's). The server can keep every core
        # busy rendering dashboards; at 10 the app's requests come first. Not
        # under a CPU quota (docker --cpus, Kubernetes limits), which stalls
        # the app with the server whatever the priority.
        @nice = Integer(setting("RAILWATCH_SIDECAR_NICE", "10"))
        # The server's own settings (Settings): nil means "from the app"
        # (Action Mailer's SMTP and From, credentials.railwatch_sidecar's
        # backup and google), false/{} turns one off.
        #   smtp:      { address:, port:, user_name:, password:, enable_starttls:, tls: }
        #   backup:    { endpoint:, bucket:, access_key_id:, secret_access_key:, region:, prefix:, interval_seconds: }
        #   google:    { client_id:, client_secret: }
        #   retention: { detail_days:, core_days_max: }
        @smtp = nil
        @mail_from = nil
        @backup = nil
        @google = nil
        @retention = nil
        # true/false: send alerts or only record them. nil: the server's default (on).
        @alert_delivery = nil
        # Any other RAILWATCH_* setting of the server, by name.
        @server_env = {}
      end

      def enabled
        @enabled.nil? ? environment != "test" : @enabled
      end

      # The environment the server's data dir holds: Rails.env, else
      # RAILS_ENV/RACK_ENV, else production. One per data dir.
      def environment
        (defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env : ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "production").to_s
      end

      def data_path
        path = Pathname.new(data_dir || File.join("storage", "railwatch", environment))
        path.relative? && defined?(Rails) && Rails.root ? Rails.root.join(path) : path.expand_path
      end

      def local_url = "http://127.0.0.1:#{port}"

      def normalized_mount_path
        "/#{mount_path.to_s.delete_prefix('/').delete_suffix('/')}"
      end

      private

      # RAILWATCH_SIDECAR_<NAME>, else the pre-rename RAILWATCH_SERVER_<NAME>
      # (railwatch-server, before 0.2), which still works and warns once.
      def setting(name, default = nil)
        value = ENV[name]
        return value unless value.nil?

        old = name.sub("RAILWATCH_SIDECAR_", "RAILWATCH_SERVER_")
        value = ENV[old]
        return default if value.nil?

        Railwatch::Sidecar.deprecated("#{old} is now #{name}")
        value
      end

      def env_bool(name, default)
        value = setting(name)
        return default if value.nil? || value.strip.empty?

        %w[1 true yes on].include?(value.strip.downcase)
      end
    end
  end
end
