# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "active_support/core_ext/securerandom"
require "active_support/core_ext/object/blank"
require "railwatch/server"

# Provisioning against fake `railwatch setup`s: one that hangs is KILLed at
# setup_timeout with everything it started, the app is told why, and the
# data dir is left as it was so the next start runs setup again.
class ProvisionTest < Minitest::Test
  # setup: sleeps when FAKE_SETUP=hang (in a child too, so the KILL has to
  # reach the whole group), creates control.sqlite3 and then hangs when
  # FAKE_SETUP=half (the users are in, the token never printed), else
  # prints a token.
  FAKE = <<~SH
    #!/bin/sh
    [ "$1" = setup ] || exit 2
    echo "$$" > "$PIDS/setup.pid"
    case "$FAKE_SETUP" in
      hang) sleep 600 & echo "$!" > "$PIDS/child.pid"; wait ;;
      half) touch "$RAILWATCH_DATA_DIR/control.sqlite3"; echo "creating the account" >&2; exec sleep 600 ;;
      *) cat > /dev/null; echo "  RAILWATCH_TOKEN=rw_test_token" ;;
    esac
  SH

  def setup
    @dir = Dir.mktmpdir("rws-provision-")
    @binary = File.join(@dir, "railwatch")
    File.write(@binary, FAKE)
    File.chmod(0o755, @binary)
    @pids = File.join(@dir, "pids")
    FileUtils.mkdir_p(@pids)
    @data = Railwatch::Server::DataDir.new(File.join(@dir, "data"))
  end

  def teardown
    %w[setup child].each do |name|
      file = File.join(@pids, "#{name}.pid")
      ::Process.kill(:KILL, File.read(file).to_i) if File.exist?(file)
    rescue Errno::ESRCH
      nil
    end
    FileUtils.rm_rf(@dir)
  end

  def provision(mode, timeout: 0.5)
    @data.provision!(binary: @binary, env: { "FAKE_SETUP" => mode, "PIDS" => @pids, "RAILWATCH_DATA_DIR" => @data.path.to_s },
                     app_name: "Shop", env_name: "production", timeout: timeout)
  end

  def test_a_setup_that_hangs_is_killed_with_its_children_and_the_boot_goes_on
    started = monotonic
    error = assert_raises(Railwatch::Server::Error) { provision("hang") }
    assert_operator monotonic - started, :<, 3, "the boot waits setup_timeout, not for the setup"
    assert_match(/did not finish within 0.5s \(RAILWATCH_SERVER_SETUP_TIMEOUT\); KILLED it/, error.message)
    assert_match(/boots without the Railwatch server/, error.message)
    refute process?(File.read(File.join(@pids, "setup.pid")).to_i), "the setup is gone"
    refute process?(File.read(File.join(@pids, "child.pid")).to_i), "so is anything it started (its process group)"
    refute @data.provisioned?
  end

  def test_a_setup_killed_halfway_leaves_nothing_that_blocks_the_next_start
    error = assert_raises(Railwatch::Server::Error) { provision("half") }
    assert_match(/it printed: creating the account/, error.message)
    refute @data.provisioned?
    refute @data.path.join("control.sqlite3").exist?, "its users would make every later setup refuse the dir"
    assert @data.proxy_secret_file.exist?, "the gem's own files stay"

    assert_equal [ "admin, account, Shop/production and its ingest token" ], provision("ok")
    assert @data.provisioned?
    assert_equal "rw_test_token", @data.token
  end

  def test_a_setup_in_time_provisions_the_data_dir
    assert_equal [ "proxy secret", "admin, account, Shop/production and its ingest token" ], provision("ok", timeout: 10)
    assert @data.provisioned?
    assert_equal "production", @data.environment
  end

  def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

  def process?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
