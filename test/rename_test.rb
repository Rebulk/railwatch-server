# frozen_string_literal: true

require "minitest/autorun"
require "rake"
require "active_support/core_ext/securerandom"
require "active_support/core_ext/object/blank"
require "railwatch/sidecar"

# railwatch-server became railwatch-sidecar in 0.2.0. An app that upgrades
# without touching its config (rebulk-crm: plugin :railwatch_server,
# RAILWATCH_SERVER_* in deploy.yml, Railwatch::Server.configure) must run
# exactly as before, with one warning per old name.
class RenameTest < Minitest::Test
  def setup
    Railwatch::Sidecar.instance_variable_set(:@deprecated, nil)
  end

  def with_env(vars)
    saved = vars.keys.to_h { [ _1, ENV[_1] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_an_old_railwatch_server_variable_still_configures_the_sidecar_and_says_so
    with_env("RAILWATCH_SIDECAR_MOUNT_PATH" => nil, "RAILWATCH_SERVER_MOUNT_PATH" => "/monitoring",
             "RAILWATCH_SIDECAR_ENABLED" => nil, "RAILWATCH_SERVER_ENABLED" => "false") do
      config = nil
      _, err = capture_io { config = Railwatch::Sidecar::Configuration.new }
      assert_equal "/monitoring", config.mount_path
      refute config.enabled
      assert_includes err, "RAILWATCH_SERVER_MOUNT_PATH is now RAILWATCH_SIDECAR_MOUNT_PATH"
      assert_includes err, "RAILWATCH_SERVER_ENABLED is now RAILWATCH_SIDECAR_ENABLED"
    end
  end

  def test_the_new_variable_wins_over_the_old_one_without_a_warning
    with_env("RAILWATCH_SIDECAR_PORT" => "30001", "RAILWATCH_SERVER_PORT" => "30002") do
      config = nil
      _, err = capture_io { config = Railwatch::Sidecar::Configuration.new }
      assert_equal 30001, config.port
      refute_includes err, "RAILWATCH_SERVER_PORT"
    end
  end

  def test_each_old_name_warns_once_per_process
    with_env("RAILWATCH_SIDECAR_NICE" => nil, "RAILWATCH_SERVER_NICE" => "5") do
      _, err = capture_io { 3.times { Railwatch::Sidecar::Configuration.new } }
      assert_equal 1, err.scan("RAILWATCH_SERVER_NICE").size
    end
  end

  def test_railwatch_server_configure_in_an_existing_initializer_configures_the_sidecar
    assert_same Railwatch::Sidecar, Railwatch::Server
    Railwatch::Server.configure { |c| c.port = 31337 }
    assert_equal 31337, Railwatch::Sidecar.config.port
  ensure
    Railwatch::Sidecar.instance_variable_set(:@config, nil)
  end

  # In a child process: loading a Puma plugin file marks this process as the
  # one that starts the server (Sidecar.serving?), for every later test.
  def test_plugin_railwatch_server_in_config_puma_rb_is_the_sidecar_plugin
    lib = File.expand_path("../lib", __dir__)
    out = IO.popen([ RbConfig.ruby, "-I", lib, "-e", <<~RUBY, err: %i[child out] ], &:read)
      require "puma"
      require "puma/plugin/railwatch_server"
      print Puma::Plugins.find("railwatch_server").equal?(Puma::Plugins.find("railwatch_sidecar")) ? "SAME" : "DIFFERENT"
    RUBY
    assert_includes out, "SAME"
    assert_includes out, "plugin :railwatch_sidecar"
  end

  def test_the_old_credentials_key_still_supplies_backup_settings
    creds = { railwatch_server: { backup: { bucket: "b" } } }
    rails = Struct.new(:credentials).new(Struct.new(:h) { def dig(*k) = h.dig(*k) }.new(creds))
    value = nil
    _, err = capture_io { value = Railwatch::Sidecar::Settings.new(Railwatch::Sidecar::Configuration.new, rails: rails).send(:credential, :backup) }
    assert_equal({ bucket: "b" }, value)
    assert_includes err, "credentials.railwatch_sidecar.backup"
  end
end
