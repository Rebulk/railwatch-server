# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rake"
require "active_support/core_ext/securerandom"
require "active_support/core_ext/object/blank"
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

  # A container's entrypoint runs `bin/rails db:prepare` before `rails
  # server` provisions the fresh volume: no warning from it. A job worker
  # still says its agent is not wired.
  def test_the_database_step_before_the_first_server_does_not_warn_and_a_job_worker_does
    Dir.mktmpdir do |dir|
      with_env("RAILS_ENV" => "production", "RAILWATCH_SERVER_DATA_DIR" => File.join(dir, "railwatch"), "SECRET_KEY_BASE_DUMMY" => nil,
               "RAILWATCH_SERVER_ENABLED" => nil) do
        Railwatch::Server.instance_variable_set(:@config, nil)
        saved = Rake.application.top_level_tasks.dup
        Rake.application.top_level_tasks.replace(%w[db:prepare])
        assert_equal :building, Railwatch::Server.wire_agent!
        Rake.application.top_level_tasks.replace(%w[solid_queue:start])
        assert_equal :not_provisioned, Railwatch::Server.wire_agent!
        refute File.exist?(File.join(dir, "railwatch"))
      ensure
        Rake.application.top_level_tasks.replace(saved) if saved
        Railwatch::Server.instance_variable_set(:@config, nil)
      end
    end
  end

  # A setup that failed (or hit setup_timeout) under `bin/rails server` is
  # not run again by the Puma plugin in the same boot; the dashboard says why.
  def test_a_failed_provisioning_is_tried_once_per_process
    Dir.mktmpdir do |dir|
      binary = File.join(dir, "railwatch")
      count = File.join(dir, "runs")
      File.write(binary, "#!/bin/sh\necho x >> #{count}\necho 'setup broke' >&2\nexit 3\n")
      File.chmod(0o755, binary)
      with_env("RAILS_ENV" => "production", "RAILWATCH_SERVER_DATA_DIR" => File.join(dir, "data"), "RAILWATCH_SERVER_BINARY" => binary) do
        Railwatch::Server.instance_variable_set(:@config, nil)
        2.times { assert_raises(Railwatch::Server::Error) { Railwatch::Server.provision!(log: ->(_) {}) } }
        assert_equal 1, File.readlines(count).size
        assert_match(/setup failed \(exit 3\): setup broke/, Railwatch::Server.provision_error.message)
      ensure
        Railwatch::Server.instance_variable_set(:@config, nil)
        Railwatch::Server.instance_variable_set(:@provision_error, nil)
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
