# frozen_string_literal: true

require "net/http"
require "socket"

module Railwatch
  module Server
    # /railwatch/* in the app, forwarded to the bundled server on loopback.
    #
    # The gate is the railwatch gem's, so one setting covers the dashboard
    # whichever gem serves it: HTTP Basic, on and closed by default
    # (Railwatch.config.http_basic_auth_*), or the app's own controller
    # (Railwatch.config.base_controller_class, with Basic off), whose
    # before_actions run first. Past the gate, each request carries a signed,
    # 60-second X-Railwatch-Proxy-Auth naming the visitor, which the server
    # trusts (rust-patches/: trusted proxy auth); nobody signs in twice.
    #
    # The server is served under the same path (RAILWATCH_BASE_PATH), so
    # paths, redirects, cookies, asset URLs and the live channel pass through
    # unrewritten. CSRF is the server's: it checks Origin and its own token
    # on every write, so Rails' check is skipped here.
    class ProxyController < Railwatch.config.base_controller_class.constantize
      # One upstream request whose response body is read as Puma writes it.
      # Net::HTTP reads a body only inside the block of #request; a Fiber
      # runs that block, handing back the response first and then each
      # chunk, so headers can be returned before the body is read. Puma
      # iterates the body on the thread that called the controller, which
      # is the thread the Fiber was made on.
      class Upstream
        def initialize(request, headers, port:)
          @http = Net::HTTP.new("127.0.0.1", port)
          @http.open_timeout = 2
          @http.read_timeout = 120
          @http.max_retries = 0
          # Byte-transparent: the browser's Accept-Encoding, or identity. A
          # request built without one gets Net::HTTP's gzip default and its
          # body decoded under the server's Content-Length.
          headers = headers.merge("Accept-Encoding" => request.headers["Accept-Encoding"].presence || "identity")
          @upstream = Net::HTTPGenericRequest.new(request.request_method, !request.content_length.to_i.zero? || chunked_input?(request),
                                                  !request.head?, request.fullpath, headers)
          return unless @upstream.request_body_permitted?

          input = request.body
          input.rewind if input.respond_to?(:rewind)
          @upstream.body_stream = input
          if request.content_length
            @upstream["Content-Length"] = request.content_length.to_s
          else
            @upstream["Transfer-Encoding"] = "chunked"
          end
        end

        def start
          @fiber = Fiber.new do
            @http.start
            @http.request(@upstream) do |response|
              Fiber.yield response
              response.read_body { |chunk| Fiber.yield chunk }
            end
            nil
          ensure
            @http.finish if @http.started?
          end
          @fiber.resume
        end

        def each
          while (chunk = @fiber.resume)
            yield chunk
          end
        end

        # Called by Rack when Puma is done with the body, read to the end or
        # not (the browser went away): the connection is closed either way.
        def close
          @http.finish if @http.started?
        rescue IOError
          nil
        end

        private

        def chunked_input?(request)
          request.get_header("HTTP_TRANSFER_ENCODING").to_s.include?("chunked")
        end
      end

      # The server's cookies only; the app's own (its session) stay here.
      FORWARDED_COOKIES = %w[_railwatch_session session_token account_id XSRF-TOKEN].freeze
      FORWARDED_HEADERS = %w[
        Accept Accept-Encoding Accept-Language Content-Type Origin Referer User-Agent
        X-Inertia X-Inertia-Version X-Inertia-Partial-Component X-Inertia-Partial-Data X-Inertia-Partial-Except
        X-Inertia-Reset X-Inertia-Error-Bag X-Inertia-Except-Once-Props X-Requested-With X-XSRF-TOKEN X-CSRF-Token
        Purpose Sec-Purpose Sec-Fetch-Site Sec-Fetch-Mode Sec-Fetch-Dest If-None-Match If-Modified-Since
      ].freeze
      HOP_BY_HOP = %w[connection keep-alive transfer-encoding content-length te trailer upgrade proxy-connection].freeze

      skip_forgery_protection if respond_to?(:skip_forgery_protection)
      before_action :authenticate_by_http_basic

      # An app on inertia_rails has its controller module in every
      # ActionController::Base, this one included, and two of its behaviours
      # break the dashboard, whose Inertia protocol is the server's end to
      # end. Its middleware compared the dashboard's X-Inertia-Version with
      # the app's and answered 409 to every Inertia visit, so each click was
      # a full page load; hiding inertia_configuration makes the middleware
      # leave this controller's requests alone. Its after_action wrote the
      # app's own XSRF-TOKEN (Path=/) on every response, so the browser held
      # two and sent the app's to the server, which refused every write;
      # forgery protection is off here (the server checks its own token),
      # and that after_action skips a controller without it.
      def respond_to?(name, include_all = false)
        name.to_sym == :inertia_configuration ? false : super
      end

      def protect_against_forgery? = false

      def forward
        secret = Railwatch::Server.data_dir.proxy_secret
        return unavailable("not provisioned yet (no #{Railwatch::Server.data_dir.proxy_secret_file})") unless secret

        if websocket?
          tunnel(secret)
        else
          relay(secret)
        end
      end

      private

      def authenticate_by_http_basic
        config = Railwatch.config
        return unless config.http_basic_auth_enabled
        return if config.http_basic_auth_ok?(request)

        request_http_basic_authentication("Railwatch")
      end

      # Who the server should see: Railwatch::Server.config.user when the app
      # names its user, else the HTTP Basic user, else one operator.
      def visitor
        given = Railwatch::Server.config.user&.call(self)
        return given.to_h.transform_keys(&:to_sym).reverse_merge(role: "admin") if given

        basic_user = ActionController::HttpAuthentication::Basic.user_name_and_password(request).first if request.authorization.to_s.start_with?("Basic ")
        # Decoded base64 comes back binary; parameterize needs a real encoding.
        name = basic_user.to_s.dup.force_encoding(Encoding::UTF_8).scrub.presence || "Operator"
        { email: "#{name.parameterize.presence || 'operator'}@railwatch.invalid", name: name, role: "admin" }
      end

      def signed_header(secret)
        v = visitor
        ProxyAuth.sign(secret, email: v[:email], name: v[:name], role: v[:role])
      end

      def upstream_headers(secret)
        headers = FORWARDED_HEADERS.each_with_object({}) do |name, h|
          value = request.headers[name]
          h[name] = value if value
        end
        cookies = request.cookies.slice(*FORWARDED_COOKIES)
        headers["Cookie"] = cookies.map { |k, v| "#{k}=#{v}" }.join("; ") if cookies.any?
        # The server compares Origin with Host, and builds absolute URLs (an
        # Inertia version-mismatch reload) from Host and X-Forwarded-Proto.
        headers["Host"] = request.host_with_port
        headers["X-Forwarded-Proto"] = request.scheme
        headers[ProxyAuth::HEADER] = signed_header(secret)
        headers
      end

      # The response is streamed: status and headers as soon as the server
      # sends them, then the body as Puma writes it (Upstream#each), so a
      # large export or a slow page never sits whole in this process. The
      # request body is streamed too, from rack.input (Puma spools a large
      # one to a tempfile), instead of being read into a string.
      def relay(secret)
        upstream = Upstream.new(request, upstream_headers(secret), port: Railwatch::Server.config.port)
        response = upstream.start
        response.each_header do |name, _|
          next if HOP_BY_HOP.include?(name)

          values = response.get_fields(name)
          self.response.headers[name] = name == "set-cookie" ? values : values.join(", ")
        end
        # The server's length is the body's: Upstream asks for it unencoded
        # unless the browser accepts an encoding, and never decodes it.
        self.response.headers["content-length"] = response["content-length"] if response["content-length"] && !response.chunked?
        self.status = response.code.to_i
        self.response_body = request.head? || !response.class.body_permitted? ? (upstream.close; []) : upstream
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, EOFError => e
        unavailable("#{e.class}: #{e.message}")
      end

      def websocket?
        request.get? && request.headers["Upgrade"].to_s.casecmp?("websocket")
      end

      # The live channel: the handshake is sent on with the signed header and
      # the connection is spliced to the server's by the process's one relay
      # thread (Relay), at most config.max_live_connections at a time. Needs
      # a server with full Rack hijack (Puma).
      def tunnel(secret)
        hijack = request.env["rack.hijack"]
        return head(:not_implemented) unless hijack

        relay = Relay.current
        if relay.size >= relay.max
          Rails.logger.warn("[railwatch-server] #{relay.max} live-channel connections open (max_live_connections); refusing another")
          return head(:service_unavailable)
        end
        upstream = TCPSocket.new("127.0.0.1", Railwatch::Server.config.port)
        handshake = upstream_headers(secret).merge(
          "Connection" => "Upgrade", "Upgrade" => "websocket",
          "Sec-WebSocket-Key" => request.headers["Sec-WebSocket-Key"],
          "Sec-WebSocket-Version" => request.headers["Sec-WebSocket-Version"],
          "Sec-WebSocket-Protocol" => request.headers["Sec-WebSocket-Protocol"],
          "Sec-WebSocket-Extensions" => request.headers["Sec-WebSocket-Extensions"]
        ).compact
        upstream.write("GET #{request.fullpath} HTTP/1.1\r\n#{handshake.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n")
        client = hijack.call
        unless relay.add(client, upstream)
          [ client, upstream ].each { |io| io.close rescue nil }
        end
        self.status = -1
        self.response_body = []
      rescue Errno::ECONNREFUSED => e
        unavailable("#{e.class}: #{e.message}")
      end

      def unavailable(why)
        message = "The Railwatch server is not answering on 127.0.0.1:#{Railwatch::Server.config.port} (#{why}). " \
                  "It is started by `plugin :railwatch_server` in config/puma.rb or `bin/rails railwatch_server:start`; " \
                  "its log is #{Railwatch::Server.data_dir.log_file}."
        Rails.logger.error("[railwatch-server] #{message}")
        render plain: message, status: :service_unavailable
      end
    end
  end
end
