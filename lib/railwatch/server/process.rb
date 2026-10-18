# frozen_string_literal: true

require "net/http"

module Railwatch
  module Server
    # One `railwatch serve` child: started, watched, restarted with backoff
    # when it dies, stopped with TERM and a deadline. The Puma plugin drives
    # it from Puma's master; nothing here runs in a worker.
    #
    # The child runs in its own process group, so a Ctrl-C in the terminal
    # reaches Puma only: Puma drains its requests, its reporter flushes the
    # last batches into this server, and only then is the server stopped.
    #
    # `server.pid` in the data dir holds "<child pid> <parent pid>". A Puma
    # that was SIGKILLed cannot stop its child, which would then hold
    # serve.lock forever and make every later server wait; the next start
    # finds the record, sees the parent gone, and stops the orphan first.
    class Process
      BACKOFF = [ 1, 2, 4, 8, 15, 30 ].freeze
      READY_TIMEOUT = 15

      attr_reader :pid

      def initialize(config:, data_dir:, binary:, log:)
        @config = config
        @data_dir = data_dir
        @binary = binary
        @log = log
        @pid = nil
        @failures = 0
        @next_start_at = 0.0
      end

      def env
        {
          "RAILWATCH_DATA_DIR" => @data_dir.path.to_s,
          "RAILWATCH_BIND" => "127.0.0.1:#{@config.port}",
          "RAILWATCH_URL" => @config.url || @config.local_url,
          "RAILWATCH_BASE_PATH" => @config.normalized_mount_path,
          "RAILWATCH_TRUSTED_PROXY_SECRET_FILE" => @data_dir.proxy_secret_file.to_s,
          # The app's own environment must not configure the server: no
          # installed /etc/railwatch/railwatch.env, no railwatch.toml from
          # the app's directory, no systemd sockets meant for Puma.
          "RAILWATCH_ENV_FILE" => File::NULL,
          "RAILWATCH_CONFIG" => nil,
          "LISTEN_FDS" => nil, "LISTEN_PID" => nil, "LISTEN_FDNAMES" => nil
        }
      end

      def alive?
        return false unless @pid

        ::Process.kill(0, @pid)
        # A zombie nobody has reaped yet still answers signal 0.
        !::Process.waitpid(@pid, ::Process::WNOHANG)
      rescue Errno::ESRCH
        false
      rescue Errno::ECHILD
        # Puma's cluster reaps every child with wait2(-1), this one too.
        begin
          ::Process.kill(0, @pid)
          true
        rescue Errno::ESRCH
          false
        end
      end

      # Called every poll: starts the server when it is not running and its
      # backoff has passed. Loud when it had died.
      def ensure_running
        return if alive?

        if @pid
          @failures += 1
          delay = BACKOFF[[ @failures - 1, BACKOFF.size - 1 ].min]
          @log.call("Railwatch server (pid #{@pid}) DIED; restarting in #{delay}s (failure #{@failures}). " \
                    "Last lines of #{@data_dir.log_file}:\n#{tail_log}")
          @pid = nil
          @next_start_at = monotonic + delay
        end
        return if monotonic < @next_start_at

        start
      end

      def start
        stop_orphan
        log = File.open(@data_dir.log_file, "a")
        @pid = ::Process.spawn(env, @binary, "serve", chdir: @data_dir.path.to_s, in: File::NULL, out: log, err: log, pgroup: true)
        log.close
        File.write(@data_dir.path.join("server.pid"), "#{@pid} #{::Process.pid}\n")
        started = monotonic
        @log.call("Railwatch server starting (pid #{@pid}, 127.0.0.1:#{@config.port}, data #{@data_dir.path}, log #{@data_dir.log_file})")
        if wait_until_ready(started)
          @log.call("Railwatch server ready in #{((monotonic - started) * 1000).round} ms; dashboard at #{@config.normalized_mount_path}")
          @failures = 0
        elsif alive?
          waiting = File.read(@data_dir.log_file).lines.last(5).grep(/waiting for .*serve\.lock/).any?
          @log.call(waiting ? "Railwatch server (pid #{@pid}) is waiting for #{@data_dir.path}/serve.lock: another server owns this " \
                              "data dir and keeps serving; this one takes over when it exits" :
                              "Railwatch server (pid #{@pid}) not answering /up after #{READY_TIMEOUT}s; see #{@data_dir.log_file}")
        end
      rescue SystemCallError => e
        @pid = nil
        @failures += 1
        @next_start_at = monotonic + BACKOFF[[ @failures - 1, BACKOFF.size - 1 ].min]
        @log.call("Railwatch server could not be started (#{e.class}: #{e.message}); retrying")
      end

      # TERM: the server stops accepting, finishes in-flight requests and
      # commits what its writers hold, then exits. KILL past the deadline.
      def stop(timeout: @config.stop_timeout)
        return unless @pid

        started = monotonic
        ::Process.kill(:TERM, @pid)
        if reaped_within?(timeout)
          @log.call("Railwatch server (pid #{@pid}) stopped in #{((monotonic - started) * 1000).round} ms")
        else
          @log.call("Railwatch server (pid #{@pid}) did not exit within #{timeout}s of TERM; killing it")
          ::Process.kill(:KILL, @pid)
          reaped_within?(1)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      ensure
        pid_file = @data_dir.path.join("server.pid")
        pid_file.delete if @pid && pid_file.exist? && pid_file.read.split.first.to_i == @pid
        @pid = nil
      end

      private

      def wait_until_ready(started)
        uri = URI("#{@config.local_url}/up")
        while monotonic - started < READY_TIMEOUT
          return false unless alive?
          begin
            return true if Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
          rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout
            nil
          end
          sleep 0.1
        end
        false
      end

      def stop_orphan
        file = @data_dir.path.join("server.pid")
        return unless file.exist?

        child, parent = file.read.split.map(&:to_i)
        return if child <= 0 || parent == ::Process.pid || process?(parent) || !process?(child)

        @log.call("Railwatch server pid #{child} was left behind by pid #{parent}, which is gone; stopping it")
        ::Process.kill(:TERM, child)
        deadline = monotonic + @config.stop_timeout
        sleep 0.1 while process?(child) && monotonic < deadline
        ::Process.kill(:KILL, child) if process?(child)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def process?(pid)
        ::Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def reaped_within?(seconds)
        deadline = monotonic + seconds
        loop do
          return true if ::Process.waitpid(@pid, ::Process::WNOHANG)
          return false if monotonic >= deadline

          sleep 0.05
        end
      rescue Errno::ECHILD
        # Reaped by Puma's cluster: gone iff signal 0 says so.
        loop do
          return true unless process?(@pid)
          return false if monotonic >= deadline

          sleep 0.05
        end
      end

      def tail_log
        File.exist?(@data_dir.log_file) ? File.read(@data_dir.log_file).lines.last(10).join : "(no log)"
      end

      def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
