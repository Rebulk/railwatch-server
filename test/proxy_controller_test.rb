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
end
