# frozen_string_literal: true

require "net/http"
require "socket"

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
    # `server.pid` in the data dir holds "<child pid> <parent pid> <host>". A
    # Puma that was SIGKILLed cannot stop its child, which would then hold
    # serve.lock forever and make every later server wait; the next start
    # finds the record, sees the parent gone, and stops the orphan first.
    # Only on the same host name: the data dir may be a volume shared with
    # another container, whose pids mean other processes here.
    #
    # Alive is not enough: a stopped or wedged server records nothing and
    # holds every dashboard request until the proxy gives up. Each poll asks
    # its /up (PROBE_TIMEOUT); one that has not answered for HANG_TIMEOUT
    # is KILLed and restarted with the backoff. One that never answered
    # since it was started gets STARTUP_TIMEOUT (it may be migrating).
    class Process
      BACKOFF = [ 1, 2, 4, 8, 15, 30 ].freeze
      # How long a start waits for /up. Under `bin/rails server` that is
      # before Puma listens, so it is boot time: a healthy server answers in
      # ~100 ms, and one that doesn't is left to the supervisor.
      READY_TIMEOUT = 5
      PROBE_TIMEOUT = 2
      HANG_TIMEOUT = 8
      STARTUP_TIMEOUT = 60

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
          # Every dashboard request comes from the app's ProxyController,
          # which sets X-Forwarded-For to the visitor's request.remote_ip
          # (and never passes the browser's on), so the server's per-IP
          # limits (sign-in, MCP) see visitors, not the app. The agents post
          # /ingest on loopback without one and are keyed on 127.0.0.1.
          "RAILWATCH_TRUST_PROXY" => "true",
          # A second server on this data dir (the new container of a deploy,
          # which has its own loopback) answers on its own port at once and
          # relays to the one holding serve.lock through serve.sock in the
          # data dir, until it takes over (railwatch-rs RAILWATCH_STANDBY_RELAY).
          "RAILWATCH_STANDBY_RELAY" => "true",
          # The server's settings from the app (Settings), and nothing else
          # of the machine's: no installed /etc/railwatch/railwatch.env, no
          # railwatch.toml from the app's directory, no systemd sockets
          # meant for Puma.
          "RAILWATCH_ENV_FILE" => @data_dir.settings_file.to_s,
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
        if alive?
          @standby ? took_over : check_health
          return
        end

        failed("DIED") if @pid
        return if monotonic < @next_start_at

        start
      end

      def start
        stop_orphan
        write_settings
        # Another server already answers on the port: another app process
        # on this host and loopback (a second Puma) whose server owns the
        # data dir. Ours waits on serve.lock and takes over when that one
        # exits; meanwhile every agent here reports to it.
        @standby = up?
        log = File.open(@data_dir.log_file, "a")
        @log_offset_at_spawn = log.size
        @relay_log_offset = nil
        @answered = false
        @unanswered_since = nil
        @pid = ::Process.spawn(env, @binary, "serve", chdir: @data_dir.path.to_s, in: File::NULL, out: log, err: log, pgroup: true)
        log.close
        renice
        if @standby
          @log.call("Railwatch server (pid #{@pid}) on standby: another server already answers on 127.0.0.1:#{@config.port} " \
                    "and owns #{@data_dir.path}; this one waits for its serve.lock and takes over when it exits. " \
                    "Until then this process's agent reports to that server.")
          return
        end
        write_pid_file
        started = monotonic
        @log.call("Railwatch server starting (pid #{@pid}, 127.0.0.1:#{@config.port}, data #{@data_dir.path}, log #{@data_dir.log_file})")
        if wait_until_ready(started)
          relaying = relaying?
          @standby = relaying
          @log.call(relaying ? "Railwatch server (pid #{@pid}) answering on 127.0.0.1:#{@config.port} in #{((monotonic - started) * 1000).round} ms " \
                               "as a standby: another app process (the old container of a deploy) holds #{@data_dir.path}/serve.lock; " \
                               "this one relays to it through serve.sock and takes over when it exits" :
                               "Railwatch server ready in #{((monotonic - started) * 1000).round} ms; dashboard at #{@config.normalized_mount_path}")
          answered
        elsif alive?
          if waiting_for_lock?
            @log.call("Railwatch server (pid #{@pid}) is waiting for #{@data_dir.path}/serve.lock: another server owns this " \
                      "data dir and keeps serving; this one takes over when it exits")
          else
            @unanswered_since = started
            @log.call("Railwatch server (pid #{@pid}) not answering /up after #{READY_TIMEOUT}s; not waiting longer for it. " \
                      "Killed and restarted if it has not answered #{STARTUP_TIMEOUT}s after starting; see #{@data_dir.log_file}")
          end
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
        pid_file.delete if @pid && pid_file.exist? && pid_file.read.split.values_at(0, 2) == [ @pid.to_s, Socket.gethostname ]
        @pid = nil
      end

      private

      def up?(timeout: PROBE_TIMEOUT)
        Net::HTTP.start("127.0.0.1", @config.port, open_timeout: timeout, read_timeout: timeout) do |http|
          http.get("/up").is_a?(Net::HTTPSuccess)
        end
      rescue SystemCallError, IOError, Timeout::Error, Net::ProtocolError, Net::HTTPBadResponse
        # A wedged server (or something else on the port) may answer garbage:
        # not answering, not a reason for the supervisor to stop.
        false
      end

      # Logged when it stops answering and when it answers again, once each.
      def check_health
        asked_at = monotonic
        if up?
          @log.call("Railwatch server (pid #{@pid}) answering /up again after #{(monotonic - @unanswered_since).round}s") if @unanswered_since && @answered
          answered unless @answered
          @unanswered_since = nil
          return
        end
        return if !@answered && waiting_for_lock?

        limit = @answered ? HANG_TIMEOUT : STARTUP_TIMEOUT
        unless @unanswered_since
          @unanswered_since = asked_at
          @log.call("Railwatch server (pid #{@pid}) is running but NOT ANSWERING /up within #{PROBE_TIMEOUT}s; " \
                    "telemetry is not being recorded. Killed and restarted if it stays silent for #{limit}s")
        end
        silent = monotonic - @unanswered_since
        return if silent < limit

        ::Process.kill(:KILL, @pid)
        reaped_within?(1)
        failed("HUNG (alive, no answer on /up for #{silent.round}s); KILLED it")
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def failed(what)
        @failures += 1
        delay = BACKOFF[[ @failures - 1, BACKOFF.size - 1 ].min]
        @log.call("Railwatch server (pid #{@pid}) #{what}; restarting in #{delay}s (failure #{@failures}). " \
                  "Last lines of #{@data_dir.log_file}:\n#{tail_log}")
        @pid = nil
        @next_start_at = monotonic + delay
      end

      def answered
        @answered = true
        @failures = 0
        renice
      end

      # Below the app's own priority (RAILWATCH_SERVER_NICE), so a busy
      # dashboard, which can keep every core busy, takes CPU from the app's
      # requests last. Linux keeps a priority per thread: set on the child's
      # process group (every thread in it) right after the spawn, and again
      # once it answers, for any thread started in between; later threads
      # inherit it.
      def renice
        return if @config.nice.zero?

        ::Process.setpriority(::Process::PRIO_PGRP, @pid, [ ::Process.getpriority(::Process::PRIO_PROCESS, 0) + @config.nice, 19 ].min)
      rescue SystemCallError => e
        @log.call("Railwatch server (pid #{@pid}) runs at the app's priority: nice +#{@config.nice} failed (#{e.message})")
      end

      def waiting_for_lock?
        lines = File.open(@data_dir.log_file) { |f| f.seek(@log_offset_at_spawn || 0); f.read(64 * 1024) }.to_s.lines
        lines.grep(/waiting for .*serve\.lock/).any? && lines.grep(/serve\.lock acquired after/).none?
      rescue SystemCallError
        false
      end

      # Re-read on every start, so a restart picks up changed credentials.
      # Names only in the log, never values.
      def write_settings
        settings = Settings.new(@config)
        env = settings.env
        settings.write!(@data_dir.settings_file.to_s)
        groups = settings.groups(env)
        @log.call("Railwatch server settings from the app: #{groups.join(', ')}") if groups.any? && groups != @logged_groups
        @logged_groups = groups
      rescue Settings::Invalid => e
        @log.call("Railwatch server settings NOT applied: #{e.message}")
        Settings.new(Configuration.new, rails: nil).write!(@data_dir.settings_file.to_s)
      end

      def write_pid_file
        File.write(@data_dir.path.join("server.pid"), "#{@pid} #{::Process.pid} #{Socket.gethostname}\n")
      end

      # The other server exited and ours holds serve.lock now. Same
      # loopback: the other deleted server.pid on a clean stop and ours
      # answers on the port. Relaying (another container): ours said in its
      # log that it acquired the lock.
      def took_over
        if @relay_log_offset
          return if relaying?
        else
          return if @data_dir.path.join("server.pid").exist? || !up?
        end

        @standby = false
        @relay_log_offset = nil
        write_pid_file
        @log.call("Railwatch server (pid #{@pid}) took over #{@data_dir.path}: the previous server exited")
      end

      # Whether our server is relaying to another one (railwatch-rs RAILWATCH_STANDBY_RELAY):
      # its log says "standby: ... relaying" and not yet "acquired after".
      # Read from where this server's lines start.
      def relaying?
        @relay_log_offset ||= relay_log_start
        lines = File.open(@data_dir.log_file) { |f| f.seek(@relay_log_offset); f.read }.lines
        started = lines.rindex { |l| l.include?("railwatch: standby:") && l.include?("relaying") }
        return false unless started

        lines[started..].none? { |l| l.include?("serve.lock acquired after") }
      rescue SystemCallError
        false
      end

      def relay_log_start
        @log_offset_at_spawn || 0
      end

      def wait_until_ready(started)
        while (left = READY_TIMEOUT - (monotonic - started)) > 0
          return false unless alive?
          return true if up?(timeout: [ left, PROBE_TIMEOUT ].min)

          sleep 0.1
        end
        false
      end

      def stop_orphan
        file = @data_dir.path.join("server.pid")
        return unless file.exist?

        child, parent, host = file.read.split
        child, parent = child.to_i, parent.to_i
        return if host != Socket.gethostname
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
