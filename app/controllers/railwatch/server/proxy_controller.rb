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
    # trusts (railwatch-rs trusted proxy auth); nobody signs in twice.
    #
    # The server is served under the same path (RAILWATCH_BASE_PATH), so
    # paths, redirects, cookies, asset URLs and the live channel pass through
    # unrewritten. CSRF is the server's: it checks Origin and its own token
    # on every write, so Rails' check is skipped here.
    #
    # No Puma thread waits for the server. Past the gate, the request (which
    # Puma has read in full) is left to ProxyHandoff, which takes the socket
    # from Puma and gives it to the process's one Relay thread; the Relay
    # writes the request to the server and the response back, then closes
    # the connection (Connection: close: the browser, or the proxy in front
    # of the app, opens a new one for the next request). Where the socket
    # can't be taken (a server without Rack hijack, Puma's own TLS) the
    # response is streamed from this thread instead (#stream).
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
          @http.open_timeout = Railwatch::Server.config.proxy_connect_timeout
          @http.read_timeout = Railwatch::Server.config.proxy_first_byte_timeout
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
      # Host names that only reach this machine (agent_access?).
      LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

      skip_forgery_protection if respond_to?(:skip_forgery_protection)
      before_action :authenticate_by_http_basic

      # An app on inertia_rails has its controller module in every
      # ActionController::Base, this one included, and two of its behaviours
      # break the dashboard, whose Inertia protocol is the server's end to
      # end. Its middleware compares the dashboard's X-Inertia-Version with
      # the app's and answers 409 to every Inertia visit, so each click was
      # a full page load. Once this controller has answered (forwarded, or
      # refused at the gate), the request's X-Inertia is removed, so the
      # middleware, on its way out, sees no Inertia visit (every
      # inertia_rails version checks that header first). Its after_action
      # wrote the app's own XSRF-TOKEN (Path=/) on every response, so the
      # browser held two and sent the app's to the server, which refused
      # every write; forgery protection is off here (the server checks its
      # own token), and that after_action skips a controller without it.
      def process_action(...)
        super
      ensure
        request.delete_header("HTTP_X_INERTIA")
      end

      def protect_against_forgery? = false

      def forward
        if (error = Railwatch::Server.provision_error) && !Railwatch::Server.data_dir.provisioned?
          return unavailable("not provisioned: #{error.message}")
        end

        secret = Railwatch::Server.data_dir.proxy_secret
        return unavailable("not provisioned yet (no #{Railwatch::Server.data_dir.proxy_secret_file})") unless secret

        if websocket?
          tunnel(secret)
        elsif hijackable?
          hand_off(secret)
        else
          stream(secret)
        end
      end

      private

      # An agent's Bearer token takes the one Authorization header Basic would
      # need, so a request to MCP or the API with one is left to the server,
      # which checks the token (401 without a valid one) as a standalone
      # railwatch-rs does. The app's own before_actions (base_controller_class)
      # still run.
      def authenticate_by_http_basic
        config = Railwatch.config
        return unless config.http_basic_auth_enabled
        return if agent_bearer
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

      # The server's MCP endpoint and JSON API: what an AI agent calls.
      def agent_request?
        mount = Railwatch::Server.config.normalized_mount_path
        rest = mount == "/" ? request.path : request.path.delete_prefix(mount)
        rest == "/mcp" || rest.start_with?("/api/")
      end

      # Whether an agent request is signed for the visitor (config.agent_access).
      # By default only in development, and only for a request from this
      # machine (request.local?: a dev server bound to 0.0.0.0 still refuses
      # the LAN) to a local host name (a page on another site that rebinds
      # its own name to 127.0.0.1 arrives with that name as Host).
      def agent_access?
        setting = Railwatch::Server.config.agent_access
        return setting unless setting.nil?

        Railwatch::Server.config.environment == "development" && request.local? && LOCAL_HOSTS.include?(request.host)
      end

      # An agent's own token, which the server checks: sent on as it came,
      # and the visitor is not signed (the server would ignore them anyway).
      def agent_bearer
        value = request.authorization.to_s
        value if agent_request? && value.start_with?("Bearer ")
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
        # The visitor, as the app sees it (RemoteIp: the proxies in front of
        # the app are trusted, the browser's own X-Forwarded-For is not),
        # and only that: the server (RAILWATCH_TRUST_PROXY) keys its per-IP
        # limits on the last address here.
        headers["X-Forwarded-For"] = request.remote_ip
        # An agent request without access goes on unsigned: the server's 401
        # tells the agent to send a token.
        if (bearer = agent_bearer)
          headers["Authorization"] = bearer
        elsif !agent_request? || agent_access?
          headers[ProxyAuth::HEADER] = signed_header(secret)
        end
        headers
      end

      # The browser's socket can be taken from the app server and moved with
      # IO.select: Rack hijack, and a plain socket (not Puma's own TLS, whose
      # socket wrapper keeps decrypted bytes the relay could not see).
      def hijackable?
        return false unless request.env["rack.hijack"]

        socket = request.env["puma.socket"]
        socket.nil? || socket.is_a?(::BasicSocket)
      end

      # Connects to the server and leaves the request to ProxyHandoff; the
      # empty 200 here is never sent. Past max_proxied_requests the visitor
      # gets a 503 at once.
      def hand_off(secret)
        relay = Relay.current
        if relay.full?(:proxied)
          Rails.logger.warn("[railwatch-server] #{relay.max(:proxied)} dashboard requests in flight (max_proxied_requests); refusing another")
          response.headers["Retry-After"] = "1"
          return render(plain: "The dashboard is busy (#{relay.max(:proxied)} requests in flight in this process). Try again in a moment.",
                        status: :service_unavailable)
        end

        upstream = connect
        request_head, body = upstream_request(secret)
        request.env[ProxyHandoff::ENV_KEY] = ProxyHandoff::Handoff.new(upstream, request_head, body)
        head :ok
      rescue SystemCallError, IOError => e
        upstream&.close rescue nil
        unavailable("#{e.class}: #{e.message}")
      end

      def connect
        TCPSocket.new("127.0.0.1", Railwatch::Server.config.port, connect_timeout: Railwatch::Server.config.proxy_connect_timeout)
      rescue IO::TimeoutError => e
        raise Errno::ETIMEDOUT, e.message
      end

      # The request as the server gets it: its head (and its body, when Puma
      # kept that in memory), and the body Puma spooled to a tempfile, as a
      # second descriptor of it (Puma closes its own when this thread
      # returns). Puma has read the body in full and decoded a chunked one,
      # so it always has a length.
      def upstream_request(secret)
        input = request.body
        input.rewind if input.respond_to?(:rewind)
        length = request.content_length.to_i
        body = input.is_a?(::File) ? input.dup : nil
        # The browser's HTTP version: an HTTP/1.0 client (nginx's default
        # upstream protocol) can't read a chunked response, and the server
        # doesn't send one to an HTTP/1.0 request.
        version = request.get_header("SERVER_PROTOCOL") == "HTTP/1.0" ? "HTTP/1.0" : "HTTP/1.1"
        headers = upstream_headers(secret)
        headers["Accept-Encoding"] = request.headers["Accept-Encoding"].presence || "identity"
        headers["Content-Length"] = length.to_s if length.positive? || request.content_length
        headers["Connection"] = "close"
        head = "#{request.request_method} #{request.fullpath} #{version}\r\n" \
               "#{headers.map { |k, v| "#{k}: #{v.to_s.delete("\r\n")}\r\n" }.join}\r\n".b
        head << input.read.to_s.b if body.nil? && length.positive?
        [ head, body ]
      end

      # Without hijack: the response is streamed from this thread, status and
      # headers as soon as the server sends them, then the body as the app
      # server writes it (Upstream#each), so a large export never sits whole
      # in this process. The request body is streamed too, from rack.input.
      def stream(secret)
        upstream = Upstream.new(request, upstream_headers(secret), port: Railwatch::Server.config.port)
        response = upstream.start
        response.each_header do |name, _|
          next if HOP_BY_HOP.include?(name) || Relay::APP_OWNED.include?(name)

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
        if relay.full?(:live)
          Rails.logger.warn("[railwatch-server] #{relay.max(:live)} live-channel connections open (max_live_connections); refusing another")
          return head(:service_unavailable)
        end
        upstream = connect
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
      rescue SystemCallError => e
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
