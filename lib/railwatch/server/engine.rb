# frozen_string_literal: true

module Railwatch
  module Server
    # An engine only for its app/controllers (autoloaded, so the proxy can
    # inherit from the app's own base controller) and its rake tasks; the
    # route is the app's, prepended so no catch-all of the app shadows it.
    class Engine < ::Rails::Engine
      rake_tasks { load File.expand_path("../../tasks/railwatch_server.rake", __dir__) }

      initializer "railwatch_server.routes" do |app|
        next unless Railwatch::Server.enabled?

        mount = Railwatch::Server.config.normalized_mount_path
        app.routes.prepend do
          match "#{mount}(/*path)", to: "railwatch/server/proxy#forward", via: :all, format: false,
                                    as: :railwatch_server_dashboard
        end
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
