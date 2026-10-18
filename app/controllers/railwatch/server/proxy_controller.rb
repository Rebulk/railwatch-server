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
        name = basic_user.presence || "Operator"
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

      def relay(secret)
        config = Railwatch::Server.config
        upstream = Net::HTTPGenericRequest.new(request.request_method, request.body_stream.present? || request.raw_post.present?,
                                               !request.head?, request.fullpath, upstream_headers(secret))
        upstream.body = request.raw_post if upstream.request_body_permitted?
        response = Net::HTTP.start("127.0.0.1", config.port, open_timeout: 2, read_timeout: 120) { |http| http.request(upstream) }

        response.each_header do |name, _|
          next if HOP_BY_HOP.include?(name)

          values = response.get_fields(name)
          self.response.headers[name] = name == "set-cookie" ? values : values.join(", ")
        end
        self.status = response.code.to_i
        self.response_body = request.head? ? [] : [ response.body.to_s ]
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, EOFError => e
        unavailable("#{e.class}: #{e.message}")
      end

      def websocket?
        request.get? && request.headers["Upgrade"].to_s.casecmp?("websocket")
      end

      # The live channel: the handshake is sent on with the signed header and
      # the connection is spliced to the server's. Needs a server with full
      # Rack hijack (Puma).
      def tunnel(secret)
        hijack = request.env["rack.hijack"]
        return head(:not_implemented) unless hijack

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
        splice(client, upstream)
        self.status = -1
        self.response_body = []
      rescue Errno::ECONNREFUSED => e
        unavailable("#{e.class}: #{e.message}")
      end

      def splice(a, b)
        [ [ a, b ], [ b, a ] ].each do |from, to|
          Thread.new do
            IO.copy_stream(from, to)
          rescue IOError, SystemCallError
            nil
          ensure
            [ from, to ].each { |io| io.close rescue nil }
          end
        end
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
