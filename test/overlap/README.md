# Two-container deploy overlap test

Kamal's blue/green, reproduced: two containers of the same app share one
named volume (`storage/`, so one Railwatch data dir) and have separate
network namespaces (separate loopbacks). Load runs on the old container,
then on both, then the old one is stopped (`term`, as `docker stop -t 30`)
or killed (`kill`, SIGKILL), and load continues on the new one. At the end
every request id each app answered 200 is looked up in the stored
`executions` (`user_ref`): it must be there exactly once.

`probe.rb` goes in the app as an initializer: it names each request after
its `X-Req-Id` header and logs, per request, whether the agent sampled it
and at what backpressure factor, and per delivery what the transport got
back, to `$PROBE_LOG`.

```sh
script/build-server /path/to/railwatch-rs x86_64-linux
# an app dir with Gemfile `gem "railwatch-server", path: "/gem"`, a
# /widgets action that runs one query, sqlite in storage/, force_ssl off,
# test/overlap/probe.rb as config/initializers/zz_overlap_probe.rb, and
# production's databases under storage/ (rails new's database.yml has the
# paths commented out; the Dockerfile runs db:prepare first, as Kamal does)
mkdir -p /var/tmp/rws-overlap && cp test/overlap/{Dockerfile,overlap.rb} /var/tmp/rws-overlap/
rsync -a <app>/ /var/tmp/rws-overlap/app/
rsync -a --exclude .git ./ /var/tmp/rws-overlap/gem/
cd /var/tmp/rws-overlap && docker build -t rws-overlap . && ruby overlap.rb term rws-overlap && ruby overlap.rb kill rws-overlap
```

Results are in the README ("Deploys and two processes").
