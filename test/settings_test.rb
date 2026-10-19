# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "railwatch/server"

class SettingsTest < Minitest::Test
  FakeCredentials = Struct.new(:data) do
    def dig(*keys) = data.dig(*keys)
  end
  FakeRails = Struct.new(:credentials)

  def setup
    @config = Railwatch::Server::Configuration.new
  end

  def settings(credentials = {}) = Railwatch::Server::Settings.new(@config, rails: FakeRails.new(FakeCredentials.new(credentials)))

  def test_the_apps_smtp_settings_become_the_servers
    @config.smtp = { address: "smtp.example.com", port: 465, user_name: "u", password: "p w#1", tls: true }
    @config.mail_from = "Ops <ops@example.com>"
    env = settings.env
    assert_equal "smtp.example.com", env["RAILWATCH_SMTP_ADDRESS"]
    assert_equal "465", env["RAILWATCH_SMTP_PORT"]
    assert_equal "tls", env["RAILWATCH_SMTP_SECURITY"]
    assert_equal "p w#1", env["RAILWATCH_SMTP_PASSWORD"]
    assert_equal "Ops <ops@example.com>", env["RAILWATCH_SMTP_FROM"]
  end

  def test_backup_and_google_come_from_credentials
    env = settings(railwatch_server: {
      backup: { endpoint: "https://s3.example.com", bucket: "b", access_key_id: "AK", secret_access_key: "SK" },
      google: { client_id: "cid", client_secret: "cs" }
    }).env
    assert_equal "b", env["RAILWATCH_BACKUP_S3_BUCKET"]
    assert_equal "SK", env["RAILWATCH_BACKUP_S3_SECRET_ACCESS_KEY"]
    assert_equal "cid", env["RAILWATCH_GOOGLE_CLIENT_ID"]
  end

  def test_an_incomplete_backup_is_refused_rather_than_half_applied
    error = assert_raises(Railwatch::Server::Settings::Invalid) { settings(railwatch_server: { backup: { bucket: "b" } }).env }
    assert_match(/endpoint, access_key_id, secret_access_key/, error.message)
  end

  def test_an_explicit_empty_setting_turns_the_credential_off
    @config.backup = {}
    @config.google = false
    env = settings(railwatch_server: { google: { client_id: "cid", client_secret: "cs" } }).env
    refute env.key?("RAILWATCH_GOOGLE_CLIENT_ID")
    refute env.key?("RAILWATCH_BACKUP_S3_BUCKET")
  end

  def test_retention_alerts_and_extra_settings
    @config.retention = { detail_days: 7, core_days_max: 90 }
    @config.alert_delivery = false
    @config.server_env = { "RAILWATCH_NEW_ISSUES_PER_HOUR" => 50 }
    env = settings.env
    assert_equal "7", env["RAILWATCH_DETAIL_RETENTION_DAYS"]
    assert_equal "off", env["RAILWATCH_ALERT_DELIVERY"]
    assert_equal "50", env["RAILWATCH_NEW_ISSUES_PER_HOUR"]
    assert_equal %w[retention alert_delivery RAILWATCH_NEW_ISSUES_PER_HOUR], settings.groups
  end

  def test_the_file_is_owner_only_and_refuses_line_breaks
    Dir.mktmpdir do |dir|
      path = File.join(dir, "server.env")
      @config.smtp = { address: "smtp.example.com", password: "secret" }
      settings.write!(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_includes File.read(path), %(RAILWATCH_SMTP_PASSWORD="secret")

      @config.smtp = { address: "smtp.example.com", password: "a\nRAILWATCH_URL=evil" }
      assert_raises(Railwatch::Server::Settings::Invalid) { settings.write!(path) }
    end
  end

  def test_unreadable_credentials_mean_no_settings
    broken = Object.new
    def broken.dig(*) = raise("ActiveSupport::MessageEncryptor::InvalidMessage")
    assert_empty Railwatch::Server::Settings.new(@config, rails: FakeRails.new(broken)).env
  end
end
