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
    #
    # Provisioning runs `railwatch setup` once, before the first `serve`:
    # setup refuses a data dir that already has users, so it is idempotent by
    # construction, and the token it prints is written down here because the
    # server keeps only its digest.
    class DataDir
      SETUP_LOCK = "provision.lock"

      attr_reader :path

      def initialize(path)
        @path = Pathname.new(path)
      end

      def proxy_secret_file = path.join("proxy_secret")
      def token_file = path.join("ingest_token")
      def log_file = path.join("server.log")

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
      # booting together take turns on an flock, so only one runs setup.
      # Returns what it did, for the log.
      def provision!(binary:, env:, app_name:, env_name:)
        FileUtils.mkdir_p(path, mode: 0o700)
        done = []
        File.open(path.join(SETUP_LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          unless proxy_secret_file.exist?
            write_secret(proxy_secret_file, SecureRandom.hex(32))
            done << "proxy secret"
          end
          unless token_file.exist?
            write_secret(token_file, setup!(binary, env, app_name, env_name))
            done << "admin, account, #{app_name}/#{env_name} and its ingest token"
          end
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
      def setup!(binary, env, app_name, env_name)
        password = SecureRandom.base58(32)
        out, err, status = Open3.capture3(
          env, binary, "setup", "--email", "railwatch-owner@localhost.invalid", "--name", "Railwatch",
          "--account", app_name, "--app", app_name, "--env", env_name, "--password-stdin",
          stdin_data: "#{password}\n"
        )
        token = out[/RAILWATCH_TOKEN=(rw_\S+)/, 1]
        return token if status.success? && token

        if err.include?("already has users")
          raise Error, "#{path} already has a Railwatch server with users but no #{token_file.basename}: " \
                       "create a token with `#{binary} env create <slug>` (RAILWATCH_DATA_DIR=#{path}) and write it to #{token_file}"
        end
        raise Error, "railwatch setup failed (exit #{status.exitstatus}): #{err.strip.presence || out.strip}"
      end
    end
  end
end
