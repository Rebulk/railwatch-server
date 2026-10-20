# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "railwatch/server"

class EnvironmentTest < Minitest::Test
  def with_env(vars)
    saved = vars.keys.to_h { [ _1, ENV[_1] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_each_environment_gets_its_own_data_dir
    %w[development staging production].each do |env|
      with_env("RAILS_ENV" => env, "RAILWATCH_SERVER_DATA_DIR" => nil) do
        assert_equal File.expand_path("storage/railwatch/#{env}"), Railwatch::Server::Configuration.new.data_path.to_s
      end
    end
  end

  def test_off_in_the_test_environment_unless_asked_for
    with_env("RAILS_ENV" => "test", "RAILWATCH_SERVER_ENABLED" => nil) do
      refute Railwatch::Server::Configuration.new.enabled
    end
    with_env("RAILS_ENV" => "test", "RAILWATCH_SERVER_ENABLED" => "true") do
      assert Railwatch::Server::Configuration.new.enabled
    end
    with_env("RAILS_ENV" => "production", "RAILWATCH_SERVER_ENABLED" => nil) do
      assert Railwatch::Server::Configuration.new.enabled
    end
  end

  # The image build (`SECRET_KEY_BASE_DUMMY=1 assets:precompile`) and any
  # process that doesn't start the server: nothing is created, so no token
  # or HMAC key ends up in an image layer.
  def test_a_process_that_does_not_start_the_server_writes_no_data_dir
    Dir.mktmpdir do |dir|
      data = File.join(dir, "storage/railwatch/production")
      with_env("RAILS_ENV" => "production", "RAILWATCH_SERVER_DATA_DIR" => data, "SECRET_KEY_BASE_DUMMY" => "1", "RAILWATCH_SERVER_ENABLED" => nil) do
        Railwatch::Server.instance_variable_set(:@config, nil)
        refute Railwatch::Server.serving?
        assert_equal :building, Railwatch::Server.wire_agent!
        with_env("SECRET_KEY_BASE_DUMMY" => nil) { assert_equal :not_provisioned, Railwatch::Server.wire_agent! }
        refute File.exist?(File.join(dir, "storage"))
      ensure
        Railwatch::Server.instance_variable_set(:@config, nil)
      end
    end
  end

  # Thruster and kamal-proxy drop a response that hasn't started after 30 s;
  # the proxy's own 504 must come first to reach the visitor.
  def test_the_proxy_gives_up_before_the_front_proxies_do
    with_env("RAILWATCH_SERVER_PROXY_FIRST_BYTE_TIMEOUT" => nil) do
      assert_operator Railwatch::Server::Configuration.new.proxy_first_byte_timeout, :<, 30
    end
  end

  def test_a_data_dir_remembers_its_environment
    Dir.mktmpdir do |dir|
      data = Railwatch::Server::DataDir.new(dir)
      assert_nil data.environment
      File.write(File.join(dir, "environment"), "staging\n")
      assert_equal "staging", data.environment
    end
  end
end
