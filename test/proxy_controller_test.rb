# frozen_string_literal: true

require "minitest/autorun"
require "action_controller"
require "railwatch/server"
require_relative "../app/controllers/railwatch/server/proxy_controller"

# What the server is told about the visitor. It runs with
# RAILWATCH_TRUST_PROXY and keys its per-IP limits (sign-in, MCP) on the
# last address of X-Forwarded-For, so that header must be the app's
# request.remote_ip and nothing a browser wrote.
class ProxyControllerTest < Minitest::Test
  def forwarded_for(remote_addr, xff = nil)
    env = Rack::MockRequest.env_for("http://shop.example/railwatch/dashboard", "REMOTE_ADDR" => remote_addr)
    env["HTTP_X_FORWARDED_FOR"] = xff if xff
    controller = Railwatch::Server::ProxyController.new
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
    config = Railwatch::Server::Configuration.new
    env = Railwatch::Server::Process.new(config: config, data_dir: Railwatch::Server::DataDir.new("/nonexistent"), binary: "railwatch", log: ->(_) {}).env
    assert_equal "true", env["RAILWATCH_TRUST_PROXY"]
    assert_equal "127.0.0.1:#{config.port}", env["RAILWATCH_BIND"], "only the app (and its agents) can reach it"
  end

  # With trust_proxy and an https url the server sends HSTS; the host is
  # the app's, so only the app's own policy (if any) reaches the browser.
  def test_the_servers_hsts_does_not_become_the_apps
    relay = Railwatch::Server::Relay.new
    head = relay.send(:response_head, "HTTP/1.1 200 OK\r\nStrict-Transport-Security: max-age=31536000\r\nContent-Length: 0",
                      [ [ "strict-transport-security", "max-age=63072000; includeSubDomains" ] ])
    assert_equal "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nstrict-transport-security: max-age=63072000; includeSubDomains\r\nconnection: close\r\n\r\n", head
  end

  # What an AI agent's request (<mount>/mcp, <mount>/api/...) carries to
  # the server: the visitor's signed header only where agent access is on.
  def agent_headers(path, env: "development", remote_addr: "127.0.0.1", host: "localhost:3000", authorization: nil, setting: nil)
    config = Railwatch::Server.config
    saved = [ config.agent_access, ENV["RAILS_ENV"] ]
    config.agent_access = setting
    ENV["RAILS_ENV"] = env
    rack = Rack::MockRequest.env_for("http://#{host}#{path}", "REMOTE_ADDR" => remote_addr)
    rack["HTTP_AUTHORIZATION"] = authorization if authorization
    controller = Railwatch::Server::ProxyController.new
    controller.set_request!(ActionDispatch::Request.new(rack))
    controller.send(:upstream_headers, "s" * 64)
  ensure
    config.agent_access, ENV["RAILS_ENV"] = saved
  end

  def signed?(headers) = headers.key?(Railwatch::Server::ProxyAuth::HEADER)

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
    saved = ENV["RAILWATCH_SERVER_AGENT_ACCESS"]
    ENV["RAILWATCH_SERVER_AGENT_ACCESS"] = "true"
    assert_equal true, Railwatch::Server::Configuration.new.agent_access
    ENV["RAILWATCH_SERVER_AGENT_ACCESS"] = "0"
    assert_equal false, Railwatch::Server::Configuration.new.agent_access
    ENV.delete("RAILWATCH_SERVER_AGENT_ACCESS")
    assert_nil Railwatch::Server::Configuration.new.agent_access
  ensure
    ENV["RAILWATCH_SERVER_AGENT_ACCESS"] = saved
  end

  def test_agent_requests_are_recognised_under_a_root_mount
    config = Railwatch::Server.config
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
    controller = Railwatch::Server::ProxyController.new
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
end
