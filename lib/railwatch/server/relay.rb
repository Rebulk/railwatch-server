# frozen_string_literal: true

module Railwatch
  module Server
    # Sockets the proxy has taken from Puma, moved by one thread per app
    # process with IO.select instead of a Puma thread (or two threads) per
    # connection. Two kinds:
    #
    # - live: the live channel (the dashboard's websocket, one per open tab),
    #   spliced both ways until either side closes (#add).
    # - proxied: every other dashboard request (#proxy). The request, which
    #   Puma has read in full, is written to the server; the response is
    #   written back to the browser as it arrives, byte for byte except its
    #   head (Connection: close, the app's own Set-Cookie added: ProxyHandoff), and then
    #   both sockets close. A slow page waits here, not on a Puma thread.
    #
    # Each kind has its own cap (Configuration#max_live_connections,
    # #max_proxied_requests). Each direction buffers at most MAX_BUFFER bytes
    # for a slow reader before its source stops being read.
    #
    # A proxied request the server has not started answering within
    # first_byte_timeout gets a 504, one it stops answering before sending a
    # byte a 502, both written here; one that goes quiet for idle_timeout
    # after its first byte is cut off.
    class Relay
      CHUNK = 16 * 1024
      MAX_BUFFER = 1024 * 1024
      MAX_HEAD = 64 * 1024
      HOP_BY_HOP = %w[connection keep-alive proxy-connection].freeze
      REASONS = { 502 => "Bad Gateway", 504 => "Gateway Timeout" }.freeze

      # input: what this side's peer is sent instead of what is read from io
      # (a proxied request's body, from Puma's tempfile).
      Side = Struct.new(:io, :peer, :pending, :eof, :input, :pair)
      # head: the proxied response's head while it arrives; nil once it has
      # been passed on (or the relay answered instead).
      Pair = Struct.new(:kind, :left, :right, :started_at, :active_at, :head, :extra_headers)

      class << self
        # One per process: a forked Puma worker starts its own.
        def current
          @mutex ||= Mutex.new
          @mutex.synchronize do
            @current = nil unless @pid == ::Process.pid
            @pid = ::Process.pid
            config = Railwatch::Server.config
            @current ||= new(max_live: config.max_live_connections, max_proxied: config.max_proxied_requests,
                             first_byte_timeout: config.proxy_first_byte_timeout, idle_timeout: config.proxy_idle_timeout)
          end
        end
      end

      def initialize(max_live: 64, max_proxied: 64, first_byte_timeout: 120, idle_timeout: 60)
        @max = { live: max_live, proxied: max_proxied }
        @first_byte_timeout = first_byte_timeout
        @idle_timeout = idle_timeout
        @sides = {}
        @pairs = []
        @mutex = Mutex.new
        @wake_r, @wake_w = IO.pipe
        @thread = nil
      end

      def max(kind = :live) = @max.fetch(kind)

      def size(kind = :live) = @mutex.synchronize { @pairs.count { _1.kind == kind } }

      def full?(kind) = size(kind) >= @max.fetch(kind)

      # Splices `a` and `b` until either closes. False when the live cap is
      # reached; the caller still owns both sockets then.
      def add(a, b)
        @mutex.synchronize do
          return false if @pairs.count { _1.kind == :live } >= @max[:live]

          register(:live, a, b)
        end
        wake
        true
      end

      # One proxied request: `request` (its head, and its body when small) and
      # then `body` (an IO, read to its end) go to the server on `upstream`;
      # the server's response goes to `client` with `headers` ([name, value]
      # pairs: the app's Set-Cookie) added to its head; then all three close. The relay owns them
      # from here. Never refuses: the proxy checks #full? first, so the cap
      # can be passed by as many requests as are checked at the same moment.
      def proxy(client, upstream, request:, body: nil, headers: [])
        @mutex.synchronize do
          pair = register(:proxied, client, upstream)
          pair.head = +"".b
          pair.extra_headers = headers
          pair.right.pending << request.b
          pair.left.eof = body.nil?
          if body
            pair.left.input = body
            @sides[body] = pair.left
          end
        end
        wake
        true
      end

      private

      def register(kind, a, b)
        left = Side.new(a, nil, +"".b, false)
        right = Side.new(b, left, +"".b, false)
        left.peer = right
        now = monotonic
        pair = Pair.new(kind, left, right, now, now)
        left.pair = right.pair = pair
        @sides[a] = left
        @sides[b] = right
        @pairs << pair
        start_thread
        pair
      end

      def start_thread
        return if @thread&.alive?

        @thread = Thread.new { run }
        @thread.name = "railwatch-server-relay"
        @thread.report_on_exception = false
      end

      def wake
        @wake_w.write_nonblock(".", exception: false)
      end

      def run
        loop do
          readers, writers, timed = @mutex.synchronize do
            sides = @pairs.flat_map { [ _1.left, _1.right ] }
            [ sides.select { |s| !s.eof && s.peer.pending.bytesize < MAX_BUFFER }.map { |s| s.input || s.io },
              sides.reject { |s| s.pending.empty? }.map(&:io),
              @pairs.any? { _1.kind == :proxied } ]
          end
          readable, writable, = IO.select(readers + [ @wake_r ], writers, nil, timed ? 0.5 : 30)
          if readable
            @wake_r.read_nonblock(1024, exception: false) if readable.delete(@wake_r)
            writable.each { |io| flush(io) }
            readable.each { |io| pull(io) }
          end
          expire if timed
        end
      rescue StandardError => e
        warn("[railwatch-server] relay stopped: #{e.class}: #{e.message}")
        @mutex.synchronize do
          @sides.each_key { |io| io.close rescue nil }.clear
          @pairs.clear
        end
      end

      def pull(io)
        side = @mutex.synchronize { @sides[io] }
        return unless side

        pair = side.pair
        data = io.read_nonblock(CHUNK, exception: false)
        case data
        when :wait_readable, :wait_writable then nil
        when nil
          side.eof = true
          if side.input
            @mutex.synchronize { @sides.delete(io) }
            io.close
            side.input = nil
          end
          return fail_pair(pair, 502, "closed the connection without answering") if side.equal?(pair.right) && pair.head

          close_if_done(side)
        else
          pair.active_at = monotonic
          if side.equal?(pair.right) && pair.head
            pair.head << data
            split = pair.head.index("\r\n\r\n")
            unless split
              fail_pair(pair, 502, "sent a response head over #{MAX_HEAD} bytes") if pair.head.bytesize > MAX_HEAD
              return
            end
            data = response_head(pair.head.byteslice(0, split), pair.extra_headers) + pair.head.byteslice((split + 4)..)
            pair.head = nil
          end
          side.peer.pending << data
          flush(side.peer.io)
        end
      rescue IOError, SystemCallError => e
        side.equal?(pair.right) ? fail_pair(pair, 502, "dropped the connection (#{e.class})") : close_pair(pair)
      end

      def flush(io)
        side = @mutex.synchronize { @sides[io] }
        return unless side
        return if side.pending.empty?

        written = io.write_nonblock(side.pending, exception: false)
        if written.is_a?(Integer)
          side.pending = side.pending.byteslice(written..)
          side.pair.active_at = monotonic
        end
        close_if_done(side)
      rescue IOError, SystemCallError => e
        side.equal?(side.pair.right) ? fail_pair(side.pair, 502, "dropped the connection (#{e.class})") : close_pair(side.pair)
      end

      # Live: one side closed, what it sent is delivered to the other, then
      # both go (a websocket's close frame is data, so nothing is cut short).
      # Proxied: the server has finished its response and the browser has all
      # of it.
      def close_if_done(side)
        pair = side.pair
        done = if pair.kind == :live
                 (side.eof && side.peer.pending.empty?) || (side.peer.eof && side.pending.empty?)
               else
                 pair.right.eof && pair.left.pending.empty?
               end
        close_pair(pair) if done
      end

      # The server's response head, for a connection that closes after it:
      # the body is passed on as sent (its Content-Length or chunked framing
      # included), so only the connection headers change.
      def response_head(head, extra)
        status, *fields = head.split("\r\n")
        fields.reject! { |field| HOP_BY_HOP.include?(field[/\A[^:]*/].strip.downcase) }
        fields.concat(extra.map { |name, value| "#{name}: #{value}" })
        "#{status}\r\n#{fields.map { "#{_1}\r\n" }.join}connection: close\r\n\r\n".b
      end

      # A proxied request the server failed: before the response started, the
      # browser gets `status` with why, then the connection closes; after, it
      # is cut short (a browser sees a truncated body as a failed load).
      def fail_pair(pair, status, why)
        return close_pair(pair) unless pair.kind == :proxied && pair.head && @mutex.synchronize { @pairs.include?(pair) }

        message = "The Railwatch server #{why}. Its log is in the app's storage/railwatch/<env>/server.log.\n"
        warn("[railwatch-server] dashboard request: #{status}: the server #{why}")
        pair.head = nil
        pair.active_at = monotonic
        pair.right.eof = true
        pair.right.pending.clear
        pair.left.eof = true
        if (input = pair.left.input)
          @mutex.synchronize { @sides.delete(input) }
          input.close rescue nil
          pair.left.input = nil
        end
        pair.left.pending << "HTTP/1.1 #{status} #{REASONS[status]}\r\nContent-Type: text/plain; charset=utf-8\r\n" \
                             "Content-Length: #{message.bytesize}\r\nConnection: close\r\n\r\n#{message}"
        flush(pair.left.io)
      end

      def expire
        now = monotonic
        @mutex.synchronize { @pairs.select { _1.kind == :proxied } }.each do |pair|
          if pair.head && now - pair.started_at > @first_byte_timeout
            fail_pair(pair, 504, "did not answer within #{@first_byte_timeout} s (proxy_first_byte_timeout)")
          elsif !pair.head && now - pair.active_at > @idle_timeout
            warn("[railwatch-server] dashboard request: nothing moved for #{@idle_timeout} s (proxy_idle_timeout); closing it")
            close_pair(pair)
          end
        end
      end

      def close_pair(pair)
        @mutex.synchronize do
          @pairs.delete(pair)
          [ pair.left, pair.right ].each do |side|
            [ side.io, side.input ].compact.each do |io|
              @sides.delete(io)
              io.close rescue nil
            end
          end
        end
      end

      def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
