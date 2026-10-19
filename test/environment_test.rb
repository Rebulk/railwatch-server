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

  def test_a_data_dir_remembers_its_environment
    Dir.mktmpdir do |dir|
      data = Railwatch::Server::DataDir.new(dir)
      assert_nil data.environment
      File.write(File.join(dir, "environment"), "staging\n")
      assert_equal "staging", data.environment
    end
  end
end
