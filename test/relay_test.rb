# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "tempfile"
require_relative "../lib/railwatch/server/relay"

class RelayTest < Minitest::Test
  def test_one_thread_moves_bytes_both_ways_for_many_connections
    relay = Railwatch::Server::Relay.new(max_live: 50)
    threads_before = Thread.list.size
    pairs = Array.new(40) do
      browser, proxy_side = UNIXSocket.pair
      server_side, server = UNIXSocket.pair
      assert relay.add(proxy_side, server_side)
      [ browser, server ]
    end
    assert_equal 1, Thread.list.size - threads_before, "one relay thread for every connection"
    assert_equal 40, relay.size

    pairs.each_with_index do |(browser, server), i|
      browser.write("ping #{i}")
      assert_equal "ping #{i}", read(server, "ping #{i}".bytesize)
      server.write("pong #{i}")
      assert_equal "pong #{i}", read(browser, "pong #{i}".bytesize)
    end
  end

  def test_a_large_message_arrives_whole_through_a_slow_reader
    relay = Railwatch::Server::Relay.new(max_live: 1)
    browser, proxy_side = UNIXSocket.pair
    server_side, server = UNIXSocket.pair
    relay.add(proxy_side, server_side)
    payload = Random.bytes(3 * 1024 * 1024)
    writer = Thread.new { server.write(payload) }
    sleep 0.2 # the relay fills its buffer and stops reading the server
    assert_equal payload, read(browser, payload.bytesize)
    writer.join
  end

  def test_when_one_side_closes_what_it_sent_is_delivered_and_both_close
    relay = Railwatch::Server::Relay.new(max_live: 1)
    browser, proxy_side = UNIXSocket.pair
    server_side, server = UNIXSocket.pair
    relay.add(proxy_side, server_side)
    server.write("bye")
    server.close
    assert_equal "bye", read(browser, 3)
    assert_nil browser.wait_readable(2) && browser.read_nonblock(1, exception: false), "the browser's side is closed"
    wait_until { relay.size.zero? }
  end

  def test_past_max_a_connection_is_refused_and_left_to_the_caller
    relay = Railwatch::Server::Relay.new(max_live: 1)
    a, b = UNIXSocket.pair
    c, d = UNIXSocket.pair
    assert relay.add(a, b)
    refute relay.add(c, d)
    refute c.closed?
  end

  def test_a_proxied_request_goes_to_the_server_and_its_response_comes_back_with_connection_close
    relay = Railwatch::Server::Relay.new
    browser, client = UNIXSocket.pair
    upstream, server = UNIXSocket.pair
    body = Tempfile.create("upload").tap { |f| f.write("b" * 200_000); f.rewind }
    relay.proxy(client, upstream, request: "POST /railwatch/x HTTP/1.1\r\nContent-Length: 200000\r\n\r\n",
                                  body: body, headers: [ %w[set-cookie app=1] ])
    expected = "POST /railwatch/x HTTP/1.1\r\nContent-Length: 200000\r\n\r\n#{'b' * 200_000}"
    assert_equal expected, read(server, expected.bytesize)
    assert_equal 1, relay.size(:proxied)
    server.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\nSet-Cookie: s=1\r\n\r\nhel")
    server.write("lo")
    server.close
    response = read_all(browser)
    assert_equal "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nSet-Cookie: s=1\r\nset-cookie: app=1\r\nconnection: close\r\n\r\nhello", response
    wait_until { relay.size(:proxied).zero? }
    assert body.closed?
  end

  def test_a_response_head_split_across_reads_is_rewritten_whole
    relay = Railwatch::Server::Relay.new
    browser, client = UNIXSocket.pair
    upstream, server = UNIXSocket.pair
    relay.proxy(client, upstream, request: "GET / HTTP/1.1\r\n\r\n")
    read(server, 18)
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n".each_char.each_slice(7) do |part|
      server.write(part.join)
      sleep 0.005
    end
    server.close
    assert_equal "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nconnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n", read_all(browser)
  end

  def test_a_server_that_closes_without_answering_is_a_502
    relay = Railwatch::Server::Relay.new
    browser, client = UNIXSocket.pair
    upstream, server = UNIXSocket.pair
    relay.proxy(client, upstream, request: "GET / HTTP/1.1\r\n\r\n")
    read(server, 18)
    server.close
    assert_match %r{\AHTTP/1.1 502 Bad Gateway\r\n.*Connection: close\r\n\r\nThe Railwatch server closed the connection}m, read_all(browser)
    wait_until { relay.size(:proxied).zero? }
  end

  def test_a_server_that_does_not_start_answering_in_time_is_a_504
    relay = Railwatch::Server::Relay.new(first_byte_timeout: 0.3)
    browser, client = UNIXSocket.pair
    upstream, _server = UNIXSocket.pair
    relay.proxy(client, upstream, request: "GET / HTTP/1.1\r\n\r\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_match %r{\AHTTP/1.1 504 Gateway Timeout\r\n}, read_all(browser)
    assert_in_delta 0.5, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, 0.45
    wait_until { relay.size(:proxied).zero? }
  end

  def test_a_response_that_goes_quiet_is_cut_off_after_the_idle_timeout
    relay = Railwatch::Server::Relay.new(idle_timeout: 0.3)
    browser, client = UNIXSocket.pair
    upstream, server = UNIXSocket.pair
    relay.proxy(client, upstream, request: "GET / HTTP/1.1\r\n\r\n")
    read(server, 18)
    server.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial")
    assert read_all(browser).end_with?("partial"), "the browser gets what came, then the connection closes"
    wait_until { relay.size(:proxied).zero? }
  end

  def test_live_and_proxied_connections_have_their_own_caps
    relay = Railwatch::Server::Relay.new(max_live: 1, max_proxied: 2)
    assert relay.add(*UNIXSocket.pair)
    assert relay.full?(:live)
    refute relay.full?(:proxied)
    2.times { relay.proxy(*UNIXSocket.pair, request: "GET / HTTP/1.1\r\n\r\n") }
    assert relay.full?(:proxied)
  end

  private

  def read_all(io)
    buf = +"".b
    deadline = Time.now + 5
    while Time.now < deadline
      io.wait_readable(1)
      chunk = io.read_nonblock(65_536, exception: false)
      break if chunk.nil?

      buf << chunk if chunk.is_a?(String)
    end
    buf
  end

  def read(io, n)
    buf = +"".b
    deadline = Time.now + 5
    while buf.bytesize < n && Time.now < deadline
      io.wait_readable(1)
      chunk = io.read_nonblock(n - buf.bytesize, exception: false)
      buf << chunk if chunk.is_a?(String)
    end
    buf
  end

  def wait_until
    deadline = Time.now + 2
    sleep 0.01 until yield || Time.now > deadline
    assert yield
  end
end
