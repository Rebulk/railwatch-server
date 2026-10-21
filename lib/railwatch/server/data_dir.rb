# frozen_string_literal: true

require "fileutils"
require "open3"
require "securerandom"

module Railwatch
  module Server
    # The server's data directory under the app (storage/railwatch by
    # default) and what this gem keeps in it next to the server's own files:
    #
    #   control.sqlite3, telemetry/, serve.lock, secret_key_base   the server's
    #   proxy_secret     the HMAC key the /railwatch proxy signs with (0600)
    #   ingest_token     the first environment's rw_ token (0600), so every
    #                    process of the app can report without asking
    #   server.log       the server's stdout and stderr
    #   server.env       the server's settings from the app (Settings, 0600)
    #   environment      the Rails environment it holds (one per data dir)
    #
    # Provisioning runs `railwatch setup` once, before the first `serve`:
    # setup refuses a data dir that already has users, so it is idempotent by
    # construction, and the token it prints is written down here because the
    # server keeps only its digest.
    #
    # It runs before Puma listens, so it has a deadline (setup_timeout): past
    # it the setup's process group is KILLed and provisioning fails, and the
    # app boots without the server. A setup that fails, by deadline or exit
    # status, leaves no ingest_token (so the dir is not provisioned?), and
    # what it had created is removed: users it had committed would make every
    # later setup refuse the dir ("already has users").
    class DataDir
      SETUP_LOCK = "provision.lock"

      attr_reader :path

      def initialize(path)
        @path = Pathname.new(path)
      end

      def proxy_secret_file = path.join("proxy_secret")
      def token_file = path.join("ingest_token")
      def log_file = path.join("server.log")
      def settings_file = path.join("server.env")
      def environment_file = path.join("environment")

      # The Rails environment this data dir was provisioned for. Data dirs
      # provisioned before the file existed say nothing.
      def environment
        environment_file.read.strip if environment_file.exist?
      end

      def token
        token_file.read.strip if token_file.exist?
      end

      def proxy_secret
        proxy_secret_file.read.strip if proxy_secret_file.exist?
      end

      def provisioned?
        token_file.exist? && proxy_secret_file.exist?
      end

      # Creates the directory, the proxy secret and (through `railwatch
      # setup`) the admin, account, app and environment, once. Two processes
      # booting together take turns on an flock, so only one runs setup; the
      # wait for it counts against the same timeout, so workers that each
      # provision (a bare `puma` in cluster mode) are not held up one after
      # another. Returns what it did, for the log.
      def provision!(binary:, env:, app_name:, env_name:, timeout:)
        FileUtils.mkdir_p(path, mode: 0o700)
        deadline = monotonic + timeout
        done = []
        File.open(path.join(SETUP_LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
          until lock.flock(File::LOCK_EX | File::LOCK_NB)
            if monotonic >= deadline
              raise Error, "another process has been provisioning #{path} for #{timeout}s (RAILWATCH_SERVER_SETUP_TIMEOUT); " \
                           "this one boots without the Railwatch server and tries again at its next start"
            end
            sleep 0.05
          end
          unless proxy_secret_file.exist?
            write_secret(proxy_secret_file, SecureRandom.hex(32))
            done << "proxy secret"
          end
          unless token_file.exist?
            write_secret(token_file, setup!(binary, env, app_name, env_name, timeout, [ deadline - monotonic, 0.1 ].max))
            done << "admin, account, #{app_name}/#{env_name} and its ingest token"
          end
          File.write(environment_file, "#{env_name}\n") unless environment_file.exist?
        end
        done
      end

      private

      def write_secret(file, value)
        tmp = file.sub_ext(".tmp")
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write("#{value}\n") }
        File.rename(tmp, file)
      end

      # The admin's password is random and thrown away: nobody signs in with
      # it. People reach the dashboard through the app's own gate, and the
      # proxy names them (ProxyAuth); the admin is only the account's owner.
      def setup!(binary, env, app_name, env_name, timeout, left)
        password = SecureRandom.base58(32)
        before = path.children
        out, err, status = run_setup(left, env, binary, "setup", "--email", "railwatch-owner@localhost.invalid", "--name", "Railwatch",
                                     "--account", app_name, "--app", app_name, "--env", env_name, "--password-stdin",
                                     stdin_data: "#{password}\n")
        token = out[/RAILWATCH_TOKEN=(rw_\S+)/, 1]
        return token if status&.success? && token

        (path.children - before).each { FileUtils.rm_rf(_1) }
        unless status
          raise Error, "railwatch setup did not finish within #{timeout}s (RAILWATCH_SERVER_SETUP_TIMEOUT); KILLED it. " \
                       "The app boots without the Railwatch server: the agent is not wired and the dashboard is unavailable. " \
                       "The next start runs setup again#{"; it printed: #{err.strip.lines.last(5).join.strip}" if err.strip != ""}"
        end
        if err.include?("already has users")
          raise Error, "#{path} already has a Railwatch server with users but no #{token_file.basename}: " \
                       "create a token with `#{binary} env create <slug>` (RAILWATCH_DATA_DIR=#{path}) and write it to #{token_file}"
        end
        raise Error, "railwatch setup failed (exit #{status.exitstatus}): #{err.strip.presence || out.strip}"
      end

      # Open3.capture3 with a deadline: [stdout, stderr, status], status nil
      # when the deadline passed and the setup's process group was KILLed.
      def run_setup(timeout, *command, stdin_data:)
        Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait|
          out = Thread.new { stdout.read }
          err = Thread.new { stderr.read }
          begin
            stdin.write(stdin_data)
          rescue Errno::EPIPE
            nil
          end
          stdin.close
          return [ out.value, err.value, wait.value ] if wait.join(timeout)

          begin
            ::Process.kill(:KILL, -wait.pid)
          rescue Errno::ESRCH
            nil
          end
          wait.join
          [ out.join(1)&.value.to_s, err.join(1)&.value.to_s, nil ]
        end
      end

      def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
