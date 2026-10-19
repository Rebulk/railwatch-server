# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "railwatch/server"

class ProxyHandoffTest < Minitest::Test
  Handoff = Railwatch::Server::ProxyHandoff

  def setup
    @relay = Railwatch::Server::Relay.new
    Railwatch::Server::Relay.instance_variable_set(:@current, @relay)
    Railwatch::Server::Relay.instance_variable_set(:@pid, Process.pid)
  end

  def teardown
    Railwatch::Server::Relay.instance_variable_set(:@current, nil)
  end

  def test_the_socket_goes_to_the_relay_with_the_apps_cookies_and_the_app_server_sends_nothing
    browser, client = UNIXSocket.pair
    upstream, server = UNIXSocket.pair
    env = { "rack.hijack" => -> { client } }
    app = lambda do |e|
      e[Handoff::ENV_KEY] = Handoff::Handoff.new(upstream, "GET /railwatch HTTP/1.1\r\n\r\n", nil)
      [ 200, { "set-cookie" => "_app_session=rolled; path=/; httponly", "x-request-id" => "abc", "content-type" => "text/html" }, [] ]
    end

    status, headers, body = Handoff.new(app).call(env)
    assert_equal [ 200, {}, [] ], [ status, headers, body ], "Puma writes nothing for a hijacked connection"
    assert_equal "GET /railwatch HTTP/1.1\r\n\r\n", server.readpartial(100)
    server.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    server.close
    response = browser.read
    assert_includes response, "set-cookie: _app_session=rolled; path=/; httponly\r\n", "the app's rolling session survives"
    refute_includes response, "x-request-id", "the app's other headers are not the server's response's"
  end

  def test_an_error_page_after_the_controller_is_sent_by_the_app_server_and_the_server_connection_closed
    upstream, = UNIXSocket.pair
    env = { "rack.hijack" => -> { flunk "not hijacked" } }
    app = lambda do |e|
      e[Handoff::ENV_KEY] = Handoff::Handoff.new(upstream, "GET / HTTP/1.1\r\n\r\n", nil)
      [ 500, {}, [ "error" ] ]
    end

    assert_equal [ 500, {}, [ "error" ] ], Handoff.new(app).call(env)
    assert upstream.closed?
  end

  def test_an_exception_after_the_controller_closes_the_server_connection
    upstream, = UNIXSocket.pair
    app = lambda do |e|
      e[Handoff::ENV_KEY] = Handoff::Handoff.new(upstream, "GET / HTTP/1.1\r\n\r\n", nil)
      raise "boom"
    end

    assert_raises(RuntimeError) { Handoff.new(app).call({}) }
    assert upstream.closed?
  end

  def test_other_requests_pass_through_untouched
    response = [ 200, { "content-type" => "text/plain" }, [ "hi" ] ]
    assert_equal response, Handoff.new(->(_) { response }).call({})
  end
end
