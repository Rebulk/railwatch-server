# frozen_string_literal: true

module Railwatch
  module Server
    # The live channel's open connections (the dashboard's websocket, one per
    # open tab), spliced to the server's by one thread per app process
    # instead of two threads per connection. The proxy hijacks the browser's
    # socket from Puma and hands it over with the server's; this thread moves
    # bytes both ways with IO.select until either side closes, then closes
    # both.
    #
    # At most `max` connections at a time (Configuration#max_live_connections);
    # past that #add refuses and the proxy answers 503, and the dashboard
    # works without live updates. Each direction buffers at most MAX_BUFFER
    # bytes for a slow reader before its source stops being read.
    class Relay
      CHUNK = 16 * 1024
      MAX_BUFFER = 1024 * 1024

      Side = Struct.new(:io, :peer, :pending, :eof)

      class << self
        # One per process: a forked Puma worker starts its own.
        def current
          @mutex ||= Mutex.new
          @mutex.synchronize do
            @current = nil unless @pid == ::Process.pid
            @pid = ::Process.pid
            @current ||= new(max: Railwatch::Server.config.max_live_connections)
          end
        end
      end

      attr_reader :max

      def initialize(max:)
        @max = max
        @sides = {}
        @mutex = Mutex.new
        @wake_r, @wake_w = IO.pipe
        @thread = nil
      end

      def size = @mutex.synchronize { @sides.size / 2 }

      # Splices `a` and `b` until either closes. False when `max` are open
      # already; the caller still owns both sockets then.
      def add(a, b)
        @mutex.synchronize do
          return false if @sides.size / 2 >= @max

          left = Side.new(a, nil, +"".b, false)
          right = Side.new(b, left, +"".b, false)
          left.peer = right
          @sides[a] = left
          @sides[b] = right
          start_thread
        end
        wake
        true
      end

      private

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
          readers, writers = @mutex.synchronize do
            [ @sides.values.select { |s| !s.eof && s.peer.pending.bytesize < MAX_BUFFER }.map(&:io),
              @sides.values.reject { |s| s.pending.empty? }.map(&:io) ]
          end
          readable, writable, = IO.select(readers + [ @wake_r ], writers, nil, 30)
          next unless readable

          @wake_r.read_nonblock(1024, exception: false) if readable.delete(@wake_r)
          writable.each { |io| flush(io) }
          readable.each { |io| pull(io) }
        end
      rescue StandardError => e
        warn("[railwatch-server] live-channel relay stopped: #{e.class}: #{e.message}")
        @mutex.synchronize { @sides.each_key { |io| io.close rescue nil }.clear }
      end

      def pull(io)
        side = @mutex.synchronize { @sides[io] }
        return unless side

        data = io.read_nonblock(CHUNK, exception: false)
        case data
        when :wait_readable, :wait_writable then nil
        when nil
          side.eof = true
          close_if_done(side)
        else
          side.peer.pending << data
          flush(side.peer.io)
        end
      rescue IOError, SystemCallError
        close_pair(side)
      end

      def flush(io)
        side = @mutex.synchronize { @sides[io] }
        return unless side
        return if side.pending.empty?

        written = io.write_nonblock(side.pending, exception: false)
        side.pending = side.pending.byteslice(written..) if written.is_a?(Integer)
        close_if_done(side)
      rescue IOError, SystemCallError
        close_pair(side)
      end

      # One side closed: what it sent is delivered to the other, then both
      # go. A websocket's close frame is data, so nothing is cut short.
      def close_if_done(side)
        peer = side.peer
        done = (side.eof && peer.pending.empty?) || (peer.eof && side.pending.empty?)
        close_pair(side) if done
      end

      def close_pair(side)
        @mutex.synchronize do
          [ side.io, side.peer.io ].each do |io|
            @sides.delete(io)
            io.close rescue nil
          end
        end
      end
    end
  end
end
