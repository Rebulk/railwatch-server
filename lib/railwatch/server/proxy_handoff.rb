# frozen_string_literal: true

module Railwatch
  module Server
    # The last step of a proxied dashboard request. ProxyController#forward
    # checks the gate, connects to the server and leaves the request here
    # (env[ENV_KEY]); this middleware, outside every other one, takes the
    # browser's socket from Puma and gives both to the Relay, which writes the
    # request and passes the server's response back. The Puma thread returns
    # at once instead of waiting for the page.
    #
    # Outside, not in the controller, because by now the app's session and
    # cookie middleware have written their Set-Cookie (a rolling session,
    # Devise's timeoutable), which goes out with the server's response, and
    # every body proxy (the executor, the query cache) has finished.
    class ProxyHandoff
      ENV_KEY = "railwatch_server.handoff"
      # The app's own headers that still apply to a response the server
      # wrote; every other header of the app's empty 200 is dropped.
      APP_HEADERS = %w[set-cookie strict-transport-security].freeze

      Handoff = Struct.new(:upstream, :request, :body)

      def initialize(app)
        @app = app
      end

      def call(env)
        begin
          status, headers, body = @app.call(env)
        rescue Exception # rubocop:disable Lint/RescueException
          # Raised after the controller: its server connection is ours to close.
          env.delete(ENV_KEY)&.then { |h| [ h.upstream, h.body ].compact.each { |io| io.close rescue nil } }
          raise
        end
        handoff = env.delete(ENV_KEY)
        return [ status, headers, body ] unless handoff

        body.close if body.respond_to?(:close)
        unless status.to_i == 200
          # Something after the controller answered instead (an error page).
          [ handoff.upstream, handoff.body ].compact.each { |io| io.close rescue nil }
          return [ status, headers, body ]
        end

        app_headers = APP_HEADERS.flat_map do |name|
          Array(headers[name]).flat_map { _1.to_s.split("\n") }.map { [ name, _1 ] }
        end
        client = env["rack.hijack"].call
        Relay.current.proxy(client, handoff.upstream, request: handoff.request, body: handoff.body, headers: app_headers)
        [ 200, {}, [] ]
      end
    end
  end
end
