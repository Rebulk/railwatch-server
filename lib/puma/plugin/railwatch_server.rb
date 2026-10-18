# frozen_string_literal: true

require "puma/plugin"

# `plugin :railwatch_server` in config/puma.rb: runs the bundled Railwatch
# server as a child of Puma's master (single or cluster mode; never in a
# worker), restarts it with backoff when it dies, and stops it after Puma
# has drained its requests and flushed its reporter.
#
# The shape is the railwatch gem's own writer plugin
# (lib/puma/plugin/railwatch.rb): `start` touches nothing of the app,
# because a bare `puma` fires plugin starts before it loads the Rack app;
# a background supervisor waits for after_booted. Stopping is in at_exit,
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

  def supervise
    sleep POLL until @booted || @shutting_down
    return unless active?

    ::Railwatch::Server.provision!(log: method(:log))
    @server = ::Railwatch::Server::Process.new(
      config: ::Railwatch::Server.config, data_dir: ::Railwatch::Server.data_dir,
      binary: ::Railwatch::Server::Binary.path, log: method(:log)
    )
    until @shutting_down
      @server.ensure_running
      sleep POLL
    end
  rescue StandardError => e
    log "Railwatch server NOT started: #{e.class}: #{e.message}"
  end

  # The app's own reporter first, while the server still listens: the last
  # requests' records (and in single mode, every request's) go out now.
  def shutdown
    @shutting_down = true
    if defined?(::Railwatch) && ::Railwatch.respond_to?(:enabled?) && ::Railwatch.enabled? && !::Railwatch.config.local?
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
