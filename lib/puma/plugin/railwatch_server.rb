# frozen_string_literal: true

require "puma/plugin"

# `plugin :railwatch_server` in config/puma.rb: runs the bundled Railwatch
# server as a child of Puma's master (single or cluster mode; never in a
# worker), restarts it with backoff when it dies, and stops it after Puma
# has drained its requests and flushed its reporter.
#
# The shape is the railwatch gem's own writer plugin
# (lib/puma/plugin/railwatch.rb). A bare `puma` fires plugin starts before
# it loads the Rack app, so there a background supervisor waits for
# after_booted. Under `bin/rails server` the app is loaded first, and the
# server is started in `start` itself, before Puma accepts a request: an
# agent whose first delivery is refused counts it as backpressure and
# samples fewer requests for the next second or two. Stopping is in at_exit,
# not after_stopped: Puma fires after_stopped from its TERM trap BEFORE it
# drains in-flight requests, and those requests' records still have to
# reach this server.
Puma::Plugin.create do
  POLL = 1

  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $$
    @booted = false
    @shutting_down = false

    start_server_now if app_loaded?
    in_background { supervise }
    launcher.events.after_booted { @booted = true }
    # A hot restart (USR2) re-execs this process: the server is stopped
    # first and the new master starts its own.
    launcher.events.before_restart { stop_server if Process.pid == @puma_pid }
    launcher.events.after_stopped { @shutting_down = true }
    at_exit { shutdown if Process.pid == @puma_pid }
  end

  private

  def active?
    defined?(::Railwatch::Server) && ::Railwatch::Server.enabled?
  end

  def app_loaded?
    defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application&.initialized?
  end

  def start_server_now
    return unless active?

    build_server
    @server.ensure_running
  rescue StandardError => e
    log "Railwatch server NOT started: #{e.class}: #{e.message}"
    @server = nil
  end

  def build_server
    ::Railwatch::Server.provision!(log: method(:log))
    @server = ::Railwatch::Server::Process.new(
      config: ::Railwatch::Server.config, data_dir: ::Railwatch::Server.data_dir,
      binary: ::Railwatch::Server::Binary.path, log: method(:log)
    )
  end

  def supervise
    sleep 0.05 until @server || @booted || @shutting_down
    return unless active?

    build_server unless @server
    until @shutting_down
      @server.ensure_running
      sleep POLL
    end
  rescue StandardError => e
    log "Railwatch server NOT started: #{e.class}: #{e.message}"
  end

  # The app's own reporter first, while the server still listens: the last
  # requests' records (and in single mode, every request's) go out now.
  #
  # Under `bin/rails server` the app loads before Puma starts this plugin,
  # so this at_exit was registered after the railwatch gem's and runs
  # BEFORE them (at_exit is LIFO). Those stop the health sampler and flush
  # the session tracker, which emits records; run them here first, so their
  # records are in the final flush rather than produced after the server is
  # gone. Each stop! is idempotent; the gem's own at_exit then does nothing.
  def shutdown
    @shutting_down = true
    if defined?(::Railwatch) && ::Railwatch.respond_to?(:enabled?) && ::Railwatch.enabled? && !::Railwatch.config.local?
      [ "Health", "Sessions", "Maintenance", "Export::Sender" ].each do |name|
        mod = ::Railwatch.const_get(name) if ::Railwatch.const_defined?(name)
        mod.stop! if mod.respond_to?(:stop!)
      end
      ::Railwatch.reporter.shutdown
    end
    stop_server
  rescue StandardError => e
    log "Railwatch server shutdown failed (#{e.class}: #{e.message})"
  end

  def stop_server
    @server&.stop
  end

  def log(message)
    @log_writer.log("[railwatch-server] #{message}")
  end
end
