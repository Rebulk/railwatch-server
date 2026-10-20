# frozen_string_literal: true

module Railwatch
  module Server
    # An engine only for its app/controllers (autoloaded, so the proxy can
    # inherit from the app's own base controller) and lib/tasks (an engine
    # loads those itself); the route is the app's, prepended so no catch-all
    # of the app shadows it.
    class Engine < ::Rails::Engine
      initializer "railwatch_server.routes" do |app|
        next unless Railwatch::Server.enabled?

        mount = Railwatch::Server.config.normalized_mount_path
        app.routes.prepend do
          match "#{mount}(/*path)", to: "railwatch/server/proxy#forward", via: :all, format: false,
                                    as: :railwatch_server_dashboard
        end
      end

      # Outside every other middleware (the railwatch agent's included), so
      # the app's session and cookies are written before the browser's socket
      # is handed to the relay (ProxyHandoff).
      initializer "railwatch_server.handoff" do |app|
        next unless Railwatch::Server.enabled?

        app.middleware.insert_before 0, Railwatch::Server::ProxyHandoff
      end

      # After the app's initializers (and the railwatch gem's credentials
      # lookup), before the railwatch gem's reporter adopts its final config.
      initializer "railwatch_server.agent", after: :load_config_initializers, before: "railwatch.adopt_final_config" do
        next unless Railwatch::Server.enabled?

        # The dashboard's own requests (every page, each live refresh) are
        # not the app's traffic: recording them would also make each view a
        # new ingest, which pings the live channel, which refetches the page.
        mount = Railwatch::Server.config.normalized_mount_path
        Railwatch.config.ignored_request_paths |= [ %r{\A#{Regexp.escape(mount)}(/|\z)} ]

        case Railwatch::Server.wire_agent!
        when :wired
          Rails.logger.info("[railwatch-server] the railwatch agent reports to #{Railwatch::Server.config.local_url}")
        when :not_provisioned
          Rails.logger.warn("[railwatch-server] #{Railwatch::Server.data_dir.path} is not provisioned yet, so this process's agent is not wired: " \
                            "the server's process creates it the first time it starts (Puma with `plugin :railwatch_server`, or " \
                            "railwatch_server:start); this process reports once it restarts after that")
        when :configured_elsewhere
          Rails.logger.info("[railwatch-server] the railwatch agent is configured elsewhere (RAILWATCH_TOKEN or transport :local); " \
                            "the bundled server only serves the dashboard")
        end
      rescue Railwatch::Server::Error, Railwatch::Server::Binary::NotFound => e
        # Loud and not fatal: the app boots, the dashboard says what is wrong.
        Rails.logger.error("[railwatch-server] #{e.message}")
        warn("[railwatch-server] #{e.message}")
      end
    end
  end
end
