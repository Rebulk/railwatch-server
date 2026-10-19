# frozen_string_literal: true

require "fileutils"

module Railwatch
  module Server
    # The server's own settings that come from the app: SMTP for alert and
    # digest email, S3 backups, Google sign-in, retention, whether alerts are
    # sent. Written to `<data dir>/server.env` (0600, replaced atomically on
    # every start) and handed to the server as RAILWATCH_ENV_FILE, so secrets
    # are neither on the server's command line nor in its environment, and
    # never in a log: only the names of what was set are logged.
    #
    # Each comes from Railwatch::Server.config first, then from the app:
    #
    #   smtp      config.action_mailer.smtp_settings, when delivery_method is :smtp
    #   mail_from ActionMailer::Base.default[:from]
    #   backup    credentials.railwatch_server.backup
    #   google    credentials.railwatch_server.google
    #
    # Anything the server reads that has no setting here goes in
    # config.server_env ("RAILWATCH_..." => value). The server's own process
    # environment still wins over this file (its rule for env files).
    class Settings
      Invalid = Class.new(StandardError)

      def initialize(config, rails: (defined?(::Rails) && ::Rails.respond_to?(:application) ? ::Rails.application : nil))
        @config = config
        @rails = rails
      end

      # { "RAILWATCH_SMTP_ADDRESS" => "smtp.example.com", ... }, and which
      # groups were set, for the log.
      def env
        out = {}
        if (smtp = smtp_settings)
          out.merge!(smtp_env(smtp))
        end
        if (from = mail_from)
          out["RAILWATCH_SMTP_FROM"] = from
        end
        if (backup = backup_settings)
          out.merge!(backup_env(backup))
        end
        if (google = google_settings)
          out.merge!(google_env(google))
        end
        if (r = given(@config.retention))
          out["RAILWATCH_DETAIL_RETENTION_DAYS"] = r[:detail_days] if r[:detail_days]
          out["RAILWATCH_CORE_RETENTION_DAYS_MAX"] = r[:core_days_max] if r[:core_days_max]
        end
        out["RAILWATCH_ALERT_DELIVERY"] = @config.alert_delivery ? "on" : "off" unless @config.alert_delivery.nil?
        out.merge!(@config.server_env.to_h.transform_keys(&:to_s))
        out.transform_values { |v| v.to_s }.reject { |_, v| v.empty? }
      end

      def groups(env = self.env)
        {
          "smtp" => env.key?("RAILWATCH_SMTP_ADDRESS"),
          "backup" => env.key?("RAILWATCH_BACKUP_S3_BUCKET"),
          "google" => env.key?("RAILWATCH_GOOGLE_CLIENT_ID"),
          "retention" => env.keys.any? { _1.include?("RETENTION") },
          "alert_delivery" => env.key?("RAILWATCH_ALERT_DELIVERY")
        }.select { |_, v| v }.keys + (@config.server_env.to_h.keys.map(&:to_s) - KNOWN)
      end

      # Writes the file the server reads; returns its path.
      def write!(path)
        body = +"# Written by railwatch-server on every start from the app's settings. Do not edit.\n"
        env.each do |key, value|
          raise Invalid, "#{key}: not a variable name" unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          raise Invalid, "#{key}: a value cannot contain a line break" if value.match?(/[\r\n]/)

          # The server strips one pair of matching quotes and keeps the rest
          # verbatim (no escapes), so quoting keeps edge spaces and '#'.
          body << "#{key}=\"#{value}\"\n"
        end
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        tmp = "#{path}.tmp"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(body) }
        File.chmod(0o600, tmp)
        File.rename(tmp, path)
        path
      end

      private

      KNOWN = %w[
        RAILWATCH_SMTP_ADDRESS RAILWATCH_SMTP_PORT RAILWATCH_SMTP_SECURITY RAILWATCH_SMTP_USERNAME RAILWATCH_SMTP_PASSWORD
        RAILWATCH_SMTP_FROM RAILWATCH_BACKUP_S3_ENDPOINT RAILWATCH_BACKUP_S3_BUCKET RAILWATCH_BACKUP_S3_ACCESS_KEY_ID
        RAILWATCH_BACKUP_S3_SECRET_ACCESS_KEY RAILWATCH_BACKUP_S3_REGION RAILWATCH_BACKUP_S3_PREFIX
        RAILWATCH_BACKUP_INTERVAL_SECONDS RAILWATCH_GOOGLE_CLIENT_ID RAILWATCH_GOOGLE_CLIENT_SECRET
        RAILWATCH_DETAIL_RETENTION_DAYS RAILWATCH_CORE_RETENTION_DAYS_MAX RAILWATCH_ALERT_DELIVERY
      ].freeze

      # nil: from the app. false or {}: off. A hash: that.
      def given(value) = value.nil? ? nil : (value.respond_to?(:to_h) && value.to_h.any? ? symbolize(value) : false)

      def smtp_settings
        return given(@config.smtp) || nil unless @config.smtp.nil?
        return unless @rails && defined?(::ActionMailer::Base)
        return unless ::ActionMailer::Base.delivery_method == :smtp

        settings = symbolize(::ActionMailer::Base.smtp_settings)
        settings[:address] ? settings : nil
      end

      def mail_from
        return @config.mail_from if @config.mail_from
        return unless @rails && defined?(::ActionMailer::Base)

        from = ::ActionMailer::Base.default[:from]
        from.is_a?(String) ? from : nil
      end

      def backup_settings
        @config.backup.nil? ? credential(:backup) : given(@config.backup) || nil
      end

      def google_settings
        @config.google.nil? ? credential(:google) : given(@config.google) || nil
      end

      def credential(name)
        value = @rails&.credentials&.dig(:railwatch_server, name)
        value ? symbolize(value) : nil
      rescue StandardError
        # Unreadable credentials (no master key on this machine) are the app's
        # problem to report; the server runs without these settings.
        nil
      end

      # Action Mailer's names, as the mail gem reads them.
      def smtp_env(s)
        security = if s[:tls] || s[:ssl]
          "tls"
        elsif s[:enable_starttls] == false && s[:enable_starttls_auto] == false
          "none"
        else
          "starttls"
        end
        {
          "RAILWATCH_SMTP_ADDRESS" => s[:address],
          "RAILWATCH_SMTP_PORT" => s[:port] || 25,
          "RAILWATCH_SMTP_SECURITY" => security,
          "RAILWATCH_SMTP_USERNAME" => s[:user_name],
          "RAILWATCH_SMTP_PASSWORD" => s[:password]
        }.compact
      end

      def backup_env(b)
        missing = %i[endpoint bucket access_key_id secret_access_key].reject { b[_1] }
        raise Invalid, "backup needs #{missing.join(', ')} (Railwatch::Server.config.backup or credentials.railwatch_server.backup)" if missing.any?

        {
          "RAILWATCH_BACKUP_S3_ENDPOINT" => b[:endpoint],
          "RAILWATCH_BACKUP_S3_BUCKET" => b[:bucket],
          "RAILWATCH_BACKUP_S3_ACCESS_KEY_ID" => b[:access_key_id],
          "RAILWATCH_BACKUP_S3_SECRET_ACCESS_KEY" => b[:secret_access_key],
          "RAILWATCH_BACKUP_S3_REGION" => b[:region],
          "RAILWATCH_BACKUP_S3_PREFIX" => b[:prefix],
          "RAILWATCH_BACKUP_INTERVAL_SECONDS" => b[:interval_seconds]
        }.compact
      end

      def google_env(g)
        raise Invalid, "google needs client_id and client_secret" unless g[:client_id] && g[:client_secret]

        { "RAILWATCH_GOOGLE_CLIENT_ID" => g[:client_id], "RAILWATCH_GOOGLE_CLIENT_SECRET" => g[:client_secret] }
      end

      def symbolize(hash) = hash.to_h.transform_keys(&:to_sym)
    end
  end
end
