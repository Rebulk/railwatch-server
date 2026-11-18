# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "tmpdir"
require "action_controller"
require "railwatch/sidecar"
require_relative "../app/controllers/railwatch/sidecar/proxy_controller"

# What the server is told about the visitor. It runs with
# RAILWATCH_TRUST_PROXY and keys its per-IP limits (sign-in, MCP) on the
# last address of X-Forwarded-For, so that header must be the app's
# request.remote_ip and nothing a browser wrote.
class ProxyControllerTest < Minitest::Test
  def forwarded_for(remote_addr, xff = nil)
    env = Rack::MockRequest.env_for("http://shop.example/railwatch/dashboard", "REMOTE_ADDR" => remote_addr)
    env["HTTP_X_FORWARDED_FOR"] = xff if xff
    controller = Railwatch::Sidecar::ProxyController.new
    controller.set_request!(ActionDispatch::Request.new(env))
    controller.send(:upstream_headers, "s" * 64)["X-Forwarded-For"]
  end

  def test_the_server_is_told_the_visitors_address
    assert_equal "203.0.113.9", forwarded_for("203.0.113.9"), "straight to Puma"
    assert_equal "203.0.113.9", forwarded_for("127.0.0.1", "203.0.113.9"), "behind Thruster or kamal-proxy"
  end

  def test_a_browser_cannot_choose_the_address_the_server_rate_limits
    assert_equal "203.0.113.9", forwarded_for("203.0.113.9", "198.51.100.7"), "an X-Forwarded-For sent straight to the app is ignored"
    assert_equal "203.0.113.9", forwarded_for("127.0.0.1", "198.51.100.7, 203.0.113.9"),
                 "behind a proxy that appends, the browser's own entry is dropped, not passed on"
  end

  def test_the_server_is_trusted_with_x_forwarded_for
    config = Railwatch::Sidecar::Configuration.new
    env = Railwatch::Sidecar::Process.new(config: config, data_dir: Railwatch::Sidecar::DataDir.new("/nonexistent"), binary: "railwatch", log: ->(_) {}).env
    assert_equal "true", env["RAILWATCH_TRUST_PROXY"]
    assert_equal "127.0.0.1:#{config.port}", env["RAILWATCH_BIND"], "only the app (and its agents) can reach it"
  end

  # With trust_proxy and an https url the server sends HSTS; the host is
  # the app's, so only the app's own policy (if any) reaches the browser.
  def test_the_servers_hsts_does_not_become_the_apps
    relay = Railwatch::Sidecar::Relay.new
    head = relay.send(:response_head, "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=31536000\r\nContent-Length: 0",
                      [ [ "strict-transport-security", "max-age=63072000; includeSubDomains" ] ])
    assert_equal "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nstrict-transport-security: max-age=63072000; includeSubDomains\r\nconnection: close\r\n\r\n", head
  end

  # What an AI agent's request (<mount>/mcp, <mount>/api/...) carries to
  # the server: the visitor's signed header only where agent access is on.
  def agent_headers(path, env: "development", remote_addr: "127.0.0.1", host: "localhost:3000", authorization: nil, setting: nil)
    config = Railwatch::Sidecar.config
    saved = [ config.agent_access, ENV["RAILS_ENV"] ]
    config.agent_access = setting
    ENV["RAILS_ENV"] = env
    rack = Rack::MockRequest.env_for("http://#{host}#{path}", "REMOTE_ADDR" => remote_addr)
    rack["HTTP_AUTHORIZATION"] = authorization if authorization
    controller = Railwatch::Sidecar::ProxyController.new
    controller.set_request!(ActionDispatch::Request.new(rack))
    controller.send(:upstream_headers, "s" * 64)
  ensure
    config.agent_access, ENV["RAILS_ENV"] = saved
  end

  def signed?(headers) = headers.key?(Railwatch::Sidecar::ProxyAuth::HEADER)

  def test_an_agent_on_this_machine_in_development_needs_no_token
    assert signed?(agent_headers("/railwatch/mcp")), "MCP from localhost in development"
    assert signed?(agent_headers("/railwatch/api/v1/me")), "the API too"
    assert signed?(agent_headers("/railwatch/mcp", host: "127.0.0.1:3000"))
    assert signed?(agent_headers("/railwatch/mcp", remote_addr: "::1", host: "[::1]:3000"))
  end

  def test_agent_access_is_off_by_default_outside_development
    %w[production staging test].each do |env|
      refute signed?(agent_headers("/railwatch/mcp", env: env)), "#{env}: MCP is not signed"
      refute signed?(agent_headers("/railwatch/api/v1/me", env: env)), "#{env}: nor the API"
      assert signed?(agent_headers("/railwatch/dashboard", env: env)), "#{env}: the dashboard still is"
    end
  end

  def test_agent_access_in_development_is_for_this_machine_only
    refute signed?(agent_headers("/railwatch/mcp", remote_addr: "192.168.1.20", host: "192.168.1.10:3000")),
           "another machine on the LAN, to a dev server bound to 0.0.0.0"
    refute signed?(agent_headers("/railwatch/mcp", host: "rebind.example:3000")),
           "a page whose own name was rebound to 127.0.0.1 (DNS rebinding) sends that name as Host"
    refute signed?(agent_headers("/railwatch/mcp", remote_addr: "10.0.0.5")), "another machine that sends Host: localhost"
  end

  def test_agent_access_can_be_turned_on_or_off_explicitly
    assert signed?(agent_headers("/railwatch/mcp", env: "production", remote_addr: "203.0.113.9", host: "shop.example", setting: true)),
           "on: every request past the gate"
    refute signed?(agent_headers("/railwatch/mcp", setting: false)), "off: not even in development"
  end

  def test_an_agents_own_token_is_sent_on_instead_of_the_visitor
    headers = agent_headers("/railwatch/mcp", env: "production", authorization: "Bearer rwp_abc")
    assert_equal "Bearer rwp_abc", headers["Authorization"]
    refute signed?(headers)
    headers = agent_headers("/railwatch/mcp", authorization: "Bearer rwp_abc")
    assert_equal "Bearer rwp_abc", headers["Authorization"], "in development too: the token decides"
    refute signed?(headers)
    refute agent_headers("/railwatch/mcp", authorization: "Basic dTpw").key?("Authorization"), "the gate's Basic credentials stay in the app"
    refute agent_headers("/railwatch/dashboard", authorization: "Bearer rwp_abc").key?("Authorization"), "pages get no Authorization"
  end

  def test_agent_access_reads_the_environment
    names = %w[RAILWATCH_SIDECAR_AGENT_ACCESS RAILWATCH_SERVER_AGENT_ACCESS]
    saved = names.to_h { [ _1, ENV[_1] ] }
    ENV.delete("RAILWATCH_SERVER_AGENT_ACCESS")
    ENV["RAILWATCH_SIDECAR_AGENT_ACCESS"] = "true"
    assert_equal true, Railwatch::Sidecar::Configuration.new.agent_access
    ENV["RAILWATCH_SIDECAR_AGENT_ACCESS"] = "0"
    assert_equal false, Railwatch::Sidecar::Configuration.new.agent_access
    ENV.delete("RAILWATCH_SIDECAR_AGENT_ACCESS")
    assert_nil Railwatch::Sidecar::Configuration.new.agent_access
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_agent_requests_are_recognised_under_a_root_mount
    config = Railwatch::Sidecar.config
    saved = config.mount_path
    config.mount_path = "/"
    assert signed?(agent_headers("/mcp")), "development, from this machine"
    refute signed?(agent_headers("/mcp", env: "production")), "a root mount does not make MCP a page"
    assert_equal "Bearer rwp_abc", agent_headers("/api/v1/me", env: "production", authorization: "Bearer rwp_abc")["Authorization"]
  ensure
    config.mount_path = saved
  end

  # The Basic gate, for a request with these headers (Basic on, configured).
  def gate_passes?(path, authorization)
    config = Railwatch.config
    saved = [ config.http_basic_auth_enabled, config.http_basic_auth_user, config.http_basic_auth_password ]
    config.http_basic_auth_enabled, config.http_basic_auth_user, config.http_basic_auth_password = true, "ops", "secret"
    rack = Rack::MockRequest.env_for("https://shop.example#{path}")
    rack["HTTP_AUTHORIZATION"] = authorization if authorization
    controller = Railwatch::Sidecar::ProxyController.new
    controller.set_request!(ActionDispatch::Request.new(rack))
    controller.set_response!(ActionDispatch::Response.new)
    controller.send(:authenticate_by_http_basic)
    controller.response.status != 401
  ensure
    config.http_basic_auth_enabled, config.http_basic_auth_user, config.http_basic_auth_password = saved
  end

  def test_an_agents_token_is_checked_by_the_server_not_the_basic_gate
    assert gate_passes?("/railwatch/mcp", "Bearer rwp_abc"), "MCP with a token: the server decides"
    assert gate_passes?("/railwatch/api/v1/me", "Bearer rwp_abc"), "the API with a token"
    refute gate_passes?("/railwatch/dashboard", "Bearer rwp_abc"), "a page with a Bearer header is still gated"
    refute gate_passes?("/railwatch/mcp", nil), "MCP without a token is gated"
    assert gate_passes?("/railwatch/mcp", "Basic #{["ops:secret"].pack("m0")}")
  end
  # Finding 1: a cookie planted on the app's domain is percent-decoded by
  # Rack, so %0D%0A in it became a real line break on the server's socket:
  # a second request, carrying the proxy's freshly signed header, smuggled
  # behind the dashboard's own (confirmed end to end on the live channel
  # against railwatch-rs v0.2.17: the smuggled comment was stored as the
  # visitor). Every path to the server refuses it before writing a byte.
  def forward_to_fake_server(cookie, websocket: false, hijack: true)
    server = TCPServer.new("127.0.0.1", 0)
    received = +""
    reader = Thread.new do
      if server.wait_readable(1)
        conn = server.accept
        received << conn.readpartial(65_536) while conn.wait_readable(0.3) rescue nil
        conn.close
      end
    end
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "proxy_secret"), "s" * 64)
      File.write(File.join(dir, "ingest_token"), "rw_test")
      config = Railwatch::Sidecar.config
      saved = [ config.port, config.data_dir ]
      config.port, config.data_dir = server.addr[1], dir
      env = Rack::MockRequest.env_for("http://shop.example/railwatch/cable", "HTTP_COOKIE" => cookie)
      env["HTTP_UPGRADE"], env["HTTP_CONNECTION"], env["HTTP_SEC_WEBSOCKET_KEY"] = "websocket", "Upgrade", "dGhlIHNhbXBsZSBub25jZQ==" if websocket
      browser, app_side = UNIXSocket.pair
      env["rack.hijack"] = -> { app_side } if hijack
      controller = Railwatch::Sidecar::ProxyController.new
      controller.set_request!(ActionDispatch::Request.new(env))
      controller.set_response!(ActionDispatch::Response.new)
      controller.forward
      env.delete(Railwatch::Sidecar::ProxyHandoff::ENV_KEY)&.upstream&.close
      reader.join
      [ controller.response.status, received ]
    ensure
      config.port, config.data_dir = saved
      [ browser, app_side ].each { _1&.close rescue nil }
    end
  ensure
    reader&.kill
    server&.close
  end

  def test_a_planted_cookie_cannot_smuggle_a_signed_request_to_the_server
    smuggled = "_railwatch_session=x%0D%0A%0D%0APOST%20/railwatch/mcp%20HTTP/1.1%0D%0AContent-Length:%200"
    { "the live channel" => { websocket: true }, "a hijacked dashboard request" => {}, "a streamed one" => { hijack: false } }.each do |path, how|
      status, received = forward_to_fake_server(smuggled, **how)
      assert_equal 400, status, "#{path}: refused"
      assert_empty received, "#{path}: nothing reaches the server"
    end
  end

  def test_a_nul_byte_in_a_forwarded_cookie_is_refused
    status, received = forward_to_fake_server("_railwatch_session=x%00y", websocket: true)
    assert_equal 400, status
    assert_empty received
  end

  def test_an_ordinary_live_channel_handshake_still_reaches_the_server
    status, received = forward_to_fake_server("_railwatch_session=abc%3D%3D", websocket: true)
    assert_equal(-1, status, "hijacked")
    assert_match %r{\AGET /railwatch/cable HTTP/1\.1\r\n}, received
    assert_includes received, "Cookie: _railwatch_session=abc==\r\n"
    assert_equal 1, received.scan("HTTP/1.1").size
  end

  # Finding 15: the app's own cookies stay in the app, whatever they are
  # called; only the server's namespaced ones (its session and its CSRF
  # token) are forwarded.
  def test_only_the_servers_own_cookies_are_forwarded
    env = Rack::MockRequest.env_for("http://shop.example/railwatch/dashboard",
                                    "HTTP_COOKIE" => "session_token=apps; account_id=7; _app_session=a; _railwatch_session=rw; XSRF-TOKEN=t")
    controller = Railwatch::Sidecar::ProxyController.new
    controller.set_request!(ActionDispatch::Request.new(env))
    assert_equal "_railwatch_session=rw; XSRF-TOKEN=t", controller.send(:upstream_headers, "s" * 64)["Cookie"]
  end

  # A forwarded value is percent-decoded: one that decodes to "x;
  # session_token=chosen" would add a pair the proxy never forwards. Such a
  # value is dropped, not passed on, so the Cookie the server reads holds
  # only the server's own names.
  def test_a_cookie_value_cannot_add_a_cookie_the_proxy_does_not_forward
    env = Rack::MockRequest.env_for("http://shop.example/railwatch/dashboard",
                                    "HTTP_COOKIE" => "_railwatch_session=x%3B%20session_token%3Dchosen%3B%20account_id%3D7; XSRF-TOKEN=t")
    controller = Railwatch::Sidecar::ProxyController.new
    controller.set_request!(ActionDispatch::Request.new(env))
    cookie = controller.send(:upstream_headers, "s" * 64)["Cookie"]
    assert_equal "XSRF-TOKEN=t", cookie
    refute_match(/session_token|account_id/, cookie.to_s)
  end

  # Finding 2: no gate (Basic off, base controller left at
  # ActionController::Base) made every visitor an admin outside
  # development. The dashboard refuses to be served then.
  def gate_refusal(env: "production", basic: false, base: "ActionController::Base")
    config = Railwatch.config
    saved = [ config.http_basic_auth_enabled, config.base_controller_class, ENV["RAILS_ENV"] ]
    config.http_basic_auth_enabled, config.base_controller_class, ENV["RAILS_ENV"] = basic, base, env
    controller = Railwatch::Sidecar::ProxyController.new
    controller.set_request!(ActionDispatch::Request.new(Rack::MockRequest.env_for("https://shop.example/railwatch/dashboard")))
    controller.set_response!(ActionDispatch::Response.new)
    controller.send(:refuse_ungated)
    controller.response.status == 503 ? controller.response.body : nil
  ensure
    config.http_basic_auth_enabled, config.base_controller_class, ENV["RAILS_ENV"] = saved
  end

  def test_an_ungated_dashboard_is_not_served_outside_development
    %w[production staging].each do |env|
      body = gate_refusal(env: env)
      refute_nil body, "#{env}: 503"
      assert_match(/no gate/, body)
      assert_match(/base_controller_class/, body)
    end
    assert_nil gate_refusal(env: "development"), "development stays open for a first run"
  end

  def test_a_dashboard_behind_basic_or_the_apps_own_controller_is_served
    assert_nil gate_refusal(basic: true), "HTTP Basic"
    assert_nil gate_refusal(base: "AdminController"), "the app's controller"
  end

  def test_the_railwatch_gems_own_gate_predicate_wins_when_it_has_one
    config = Railwatch.config
    config.define_singleton_method(:dashboard_gate_configured?) { true }
    assert_nil gate_refusal, "the gem says gated"
    config.define_singleton_method(:dashboard_gate_configured?) { false }
    refute_nil gate_refusal(basic: true), "the gem says ungated"
  ensure
    config.singleton_class.send(:remove_method, :dashboard_gate_configured?)
  end

  def test_without_a_named_user_the_visitor_is_a_member_not_an_admin
    config = Railwatch::Sidecar.config
    saved = config.user
    config.user = nil
    rack = Rack::MockRequest.env_for("https://shop.example/railwatch/dashboard")
    rack["HTTP_AUTHORIZATION"] = "Basic #{["ops:secret"].pack("m0")}"
    controller = Railwatch::Sidecar::ProxyController.new
    controller.set_request!(ActionDispatch::Request.new(rack))
    assert_equal "member", controller.send(:visitor)[:role]
    config.user = ->(_) { { email: "ada@example.com", name: "Ada", role: "admin" } }
    assert_equal "admin", controller.send(:visitor)[:role], "an app that names its admins still can"
  ensure
    config.user = saved
  end
end
