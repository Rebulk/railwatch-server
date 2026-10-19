# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require_relative "../lib/railwatch/server/relay"

class RelayTest < Minitest::Test
  def test_one_thread_moves_bytes_both_ways_for_many_connections
    relay = Railwatch::Server::Relay.new(max: 50)
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
    relay = Railwatch::Server::Relay.new(max: 1)
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
    relay = Railwatch::Server::Relay.new(max: 1)
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
    relay = Railwatch::Server::Relay.new(max: 1)
    a, b = UNIXSocket.pair
    c, d = UNIXSocket.pair
    assert relay.add(a, b)
    refute relay.add(c, d)
    refute c.closed?
  end

  private

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
