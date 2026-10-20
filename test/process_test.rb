# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "socket"
require "railwatch/server"

# The supervisor against a fake `railwatch serve` that answers /up: a server
# that stops answering is noticed, KILLed and restarted, once per state
# change in the log; and it runs below the app's CPU priority.
class ProcessTest < Minitest::Test
  FAKE = <<~RUBY
    #!#{RbConfig.ruby}
    require "socket"
    server = TCPServer.new("127.0.0.1", Integer(ENV["RAILWATCH_BIND"].split(":").last))
    loop do
      c = server.accept
      c.readpartial(4096)
      c.write("HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok")
      c.close
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("rws-process-")
    @binary = File.join(@dir, "railwatch")
    File.write(@binary, FAKE)
    File.chmod(0o755, @binary)
    @config = Railwatch::Server::Configuration.new
    @config.port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
    @config.data_dir = File.join(@dir, "data")
    FileUtils.mkdir_p(@config.data_dir)
    @lines = []
    @server = Railwatch::Server::Process.new(config: @config, data_dir: Railwatch::Server::DataDir.new(@config.data_dir), binary: @binary,
                                             log: ->(m) { @lines << m })
    @timeouts = %i[HANG_TIMEOUT PROBE_TIMEOUT].to_h { [ _1, Railwatch::Server::Process.const_get(_1) ] }
    set_timeouts(HANG_TIMEOUT: 1, PROBE_TIMEOUT: 0.3)
  end

  def teardown
    @server.stop(timeout: 1)
    set_timeouts(**@timeouts)
    FileUtils.rm_rf(@dir)
  end

  def set_timeouts(**values)
    verbose, $VERBOSE = $VERBOSE, nil
    values.each { |k, v| Railwatch::Server::Process.const_set(k, v) }
  ensure
    $VERBOSE = verbose
  end

  def test_a_server_that_stops_answering_is_killed_and_restarted
    @server.ensure_running
    first = @server.pid
    assert_match(/ready in/, @lines.last)

    ::Process.kill(:STOP, first)
    started = monotonic
    @server.ensure_running until @server.pid != first || monotonic - started > 5
    refute_equal first, @server.pid
    assert_operator monotonic - started, :<, 3
    assert_equal 1, @lines.grep(/NOT ANSWERING/).size
    assert_equal 1, @lines.grep(/HUNG .*KILLED it; restarting in 1s/).size

    sleep 1
    @server.ensure_running
    refute_nil @server.pid
    assert_match(/ready in/, @lines.last)
    refute process?(first)
  end

  def test_a_server_that_answers_again_in_time_is_left_running
    @server.ensure_running
    pid = @server.pid
    ::Process.kill(:STOP, pid)
    @server.ensure_running
    ::Process.kill(:CONT, pid)
    3.times { @server.ensure_running }
    assert_equal pid, @server.pid
    assert_equal 1, @lines.grep(/NOT ANSWERING/).size
    assert_equal 1, @lines.grep(/answering \/up again/).size
  end

  def test_the_server_runs_below_the_apps_priority
    skip "no /proc" unless File.exist?("/proc/self/stat")

    @server.ensure_running
    own = ::Process.getpriority(::Process::PRIO_PROCESS, 0)
    assert_equal [ own + 10, 19 ].min, File.read("/proc/#{@server.pid}/stat").split(") ").last.split[16].to_i
  end

  private

  def process?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
end
