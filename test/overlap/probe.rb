# Overlap probe (test harness only): logs, per request, whether the agent
# sampled it and at what backpressure factor; per delivery, what the
# transport got back. One JSON line each in $PROBE_LOG.
if ENV["PROBE_LOG"]
  PROBE_IO = File.open(ENV["PROBE_LOG"], "a").tap { |f| f.sync = true }
  PROBE_MUTEX = Mutex.new
  def probe(**h)
    PROBE_MUTEX.synchronize { PROBE_IO.puts(JSON.generate(h.merge(t: Time.now.to_f.round(3), pid: Process.pid))) }
  end

  Railwatch::Sampler.singleton_class.prepend(Module.new do
    def decide(kind)
      decided = super
      probe(ev: "sample", kind: kind, sampled: decided, bp: Railwatch.reporter.backpressure_factor) if kind == :requests
      decided
    end
  end)

  Railwatch::Transport::Http.prepend(Module.new do
    def deliver(records, **kw)
      r = super
      probe(ev: "deliver", records: records.size, batch: kw[:batch_id], bp: kw[:backpressure_factor],
            ok: r.ok, status: r.status, accepted: r.accepted, error: r.error&.byteslice(0, 120))
      r
    end
  end)

  Railwatch::Reporter.prepend(Module.new do
    private

    def retain(batch, result)
      super
      probe(ev: "retain", records: batch.records.size, attempt: @retry_attempt, error: result.error&.byteslice(0, 120))
    end
  end)
end

# Each request names itself, so the harness can match served requests to
# stored executions.
ActiveSupport.on_load(:action_controller_base) do
  before_action { Railwatch.execution&.user_id = request.headers["X-Req-Id"] if request.headers["X-Req-Id"] }
end
