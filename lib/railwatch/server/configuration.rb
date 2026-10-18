# frozen_string_literal: true

module Railwatch
  module Server
    # Everything is an env var first (RAILWATCH_SERVER_*), then assignment in
    # an initializer:
    #
    #   Railwatch::Server.configure do |c|
    #     c.port = 28790
    #     c.user = ->(controller) { { email: controller.current_user.email, name: controller.current_user.name, role: "admin" } }
    #   end
    #
    # The dashboard's gate is the railwatch gem's (Railwatch.config): HTTP
    # Basic on and closed by default, or `base_controller_class` with Basic
    # off. One set of credentials for /railwatch whichever gem serves it.
    class Configuration
      attr_accessor :enabled, :port, :data_dir, :mount_path, :binary, :url, :stop_timeout, :user, :wire_agent

      def initialize
        @enabled = env_bool("RAILWATCH_SERVER_ENABLED", true)
        # One fixed port per app, not a free one picked at boot: every process
        # of the app (Puma workers, Solid Queue, a rake task) must find the
        # server without asking, and a second Puma on the same host and data
        # dir must hit the same server (docs: two processes, one data dir).
        @port = Integer(ENV.fetch("RAILWATCH_SERVER_PORT", "28790"))
        @data_dir = ENV.fetch("RAILWATCH_SERVER_DATA_DIR", "storage/railwatch")
        @mount_path = ENV.fetch("RAILWATCH_SERVER_MOUNT_PATH", "/railwatch")
        # A railwatch binary of your own (another version, a platform this
        # gem has no build for). Default: the one in this platform's gem.
        @binary = ENV["RAILWATCH_SERVER_BINARY"]
        # The public URL of the dashboard's host, for links in alert emails
        # and the Secure cookie flag. Default: the loopback address.
        @url = ENV["RAILWATCH_SERVER_URL"]
        # How long Puma's exit waits for the server to drain after TERM. The
        # server answers SIGTERM by finishing in-flight requests and committing
        # queued writes; an idle one is gone in well under a second.
        @stop_timeout = Float(ENV.fetch("RAILWATCH_SERVER_STOP_TIMEOUT", "15"))
        # Who the dashboard's visitor is, as the server should see them:
        # ->(controller) { { email:, name:, role: "admin" | "member" } }.
        @user = nil
        # Point the railwatch agent at the bundled server when the app has not
        # configured one (no RAILWATCH_TOKEN). Off: the app wires it itself.
        @wire_agent = env_bool("RAILWATCH_SERVER_WIRE_AGENT", true)
      end

      def data_path
        path = Pathname.new(data_dir)
        path.relative? && defined?(Rails) && Rails.root ? Rails.root.join(path) : path.expand_path
      end

      def local_url = "http://127.0.0.1:#{port}"

      def normalized_mount_path
        "/#{mount_path.to_s.delete_prefix('/').delete_suffix('/')}"
      end

      private

      def env_bool(name, default)
        value = ENV[name]
        return default if value.nil? || value.strip.empty?

        %w[1 true yes on].include?(value.strip.downcase)
      end
    end
  end
end
