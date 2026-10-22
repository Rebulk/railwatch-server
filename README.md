# railwatch-server (prototype)

The Railwatch server, bundled as a gem. Add it to a Rails app and you get
the **full** Railwatch dashboard at `/railwatch` (issues, alerts, the API
and MCP included), behind your app's own login, with no server to install.
The server runs as **its own process** next to the app, started by Puma's
master. It never runs inside a Puma worker.

> Prototype; the name is temporary. Nothing here is published.

## How it relates to the other two

| | what it is | license |
|---|---|---|
| [`railwatch`](https://github.com/Rebulk/railwatch) | the agent in your app; also has a Ruby "embedded" mode with its own dashboard | MIT |
| [`railwatch-rs`](https://github.com/Rebulk/railwatch-rs) | the server, one static binary; self-hosted on a VPS for many apps | AGPL-3.0-only |
| **`railwatch-server`** (this) | `railwatch-rs`, prebuilt per platform, run and wired for one app | AGPL-3.0-only |

This gem depends on `railwatch` and points the agent at the bundled server.
It is the same server you would self-host, at the same version, just started
for you. Moving later to a shared self-hosted install means changing
`RAILWATCH_INGEST_URL` and `RAILWATCH_TOKEN` (and copying `storage/railwatch`
if you want the history).

## Install

```ruby
# Gemfile
gem "railwatch"
gem "railwatch-server"
```

```ruby
# config/puma.rb
plugin :railwatch_server
```

```ruby
# config/initializers/railwatch.rb: the dashboard's gate (the railwatch gem's settings)
Railwatch.configure do |c|
  c.http_basic_auth_user = "admin"                       # or bin/rails railwatch:authentication:configure
  c.http_basic_auth_password = ENV["RAILWATCH_DASHBOARD_PASSWORD"]
end
```

`bin/rails s`, then open `/railwatch`. On first boot the gem runs
`railwatch setup` against `storage/railwatch/<Rails.env>`, so the account,
app, environment, ingest token and proxy secret are created once and kept
there. It then starts `railwatch serve` on `127.0.0.1:28790` and points the
agent at it.

Only a process that starts the server creates that directory: Puma with the
plugin (`bin/rails server` or `puma`) and `bin/rails railwatch_server:start`.
Anything else (`assets:precompile` in a Dockerfile, a console, a Solid Queue
worker) reads it and, until it exists, leaves the agent alone and says so.
So an image build ships no token, proxy secret or `secret_key_base`; each
volume gets its own on first start. A job worker started before the first
server reports from its next restart. A `railwatch setup` that hangs never
holds up the boot past `RAILWATCH_SERVER_SETUP_TIMEOUT` (below).

Bundler picks the platform gem with the binary for your machine:
x86_64-linux, aarch64-linux, x86_64-darwin or arm64-darwin. On anything
else the plain gem installs and tells you to set `RAILWATCH_SERVER_BINARY`
to a `railwatch` you installed yourself.

### Without Puma

Use `bin/rails railwatch_server:start` (foreground, TERM to stop), e.g. as a
Procfile line:

```
railwatch: bin/rails railwatch_server:start
```

`bin/rails railwatch_server:status` reports the binary, the data dir,
whether the server is up, and where the agent reports.

## Configuration

| env | default | |
|---|---|---|
| `RAILWATCH_SERVER_ENABLED` | on, off under `Rails.env.test` | off: no server, no route, the agent untouched |
| `RAILWATCH_SERVER_PORT` | `28790` | loopback port. Fixed, not picked at boot, so every process of the app finds the same server |
| `RAILWATCH_SERVER_DATA_DIR` | `storage/railwatch/<Rails.env>` | put it on the volume that survives deploys |
| `RAILWATCH_SERVER_MOUNT_PATH` | `/railwatch` | |
| `RAILWATCH_SERVER_URL` | the loopback URL | public URL of the app, for links in alert emails and Secure cookies |
| `RAILWATCH_SERVER_BINARY` | the platform gem's | your own `railwatch` |
| `RAILWATCH_SERVER_STOP_TIMEOUT` | `15` | seconds Puma's exit waits for the server to drain |
| `RAILWATCH_SERVER_SETUP_TIMEOUT` | `30` | seconds the first start of a data dir waits for `railwatch setup` (about a second), before Puma listens. Past it the setup is KILLed, the app boots without the server (agent not wired, the dashboard's 503 says why) and the next start retries |
| `RAILWATCH_SERVER_WIRE_AGENT` | `true` | off: you configure the agent yourself |
| `RAILWATCH_SERVER_MAX_LIVE_CONNECTIONS` | `64` | open live-update connections per app process (one per dashboard tab); past it the dashboard works without live updates |
| `RAILWATCH_SERVER_MAX_PROXIED_REQUESTS` | `64` | dashboard requests in flight per app process (waiting on the server or streaming back); past it a dashboard request gets 503 with `Retry-After: 1` at once. The app's own requests are never affected |
| `RAILWATCH_SERVER_PROXY_CONNECT_TIMEOUT` | `2` | seconds to connect to the server on loopback; past it, 503 |
| `RAILWATCH_SERVER_PROXY_FIRST_BYTE_TIMEOUT` | `25` | seconds for the server to start answering a dashboard request; past it, 504 with a message. Under 30 s on purpose: Thruster (its write timeout) and kamal-proxy drop a response that hasn't started after 30 s, and the visitor gets an empty reply instead |
| `RAILWATCH_SERVER_PROXY_IDLE_TIMEOUT` | `60` | seconds a response that has started may go without a byte moving; past it the connection is closed |
| `RAILWATCH_SERVER_NICE` | `10` | how far below the app's CPU priority the server runs (0-19; 0: the same). A busy dashboard can keep every core busy; measured in a 2-CPU container under 30 dashboard clients at the app's priority, the app's `/up` p50 went from 2 to 15 ms. Not under a CPU quota (`docker --cpus`, Kubernetes CPU limits): the kernel throttles the container's processes together whatever their priority, and in that 2-CPU container under `--cpus 2` nice 10 measured no better than nice 0 (`/up` p99 190-580 ms at either); on 2 dedicated cores (`--cpuset-cpus`) it took `/up` p99 from 207-363 ms to 18-22 ms. In a quota-limited container give it real cores (a cpuset, or a VM) or keep dashboard use light |

**Environments.** One environment per data dir, named after `Rails.env`:
development, staging and production usually run on different machines,
and each keeps its own history in `storage/railwatch/<env>`. Under
`Rails.env.test` the server is off by default (a test run would otherwise
report into the development server). The data dir records the environment
it was set up for (`environment`), and an app booted in another
environment against it refuses to wire the agent and says so, rather than
filing staging's telemetry under production. To see several environments
in one dashboard, run one shared self-hosted `railwatch-rs` and point each
environment's agent at it (`RAILWATCH_INGEST_URL`, `RAILWATCH_TOKEN`).

**The server's own settings** (alert and digest email, backups, Google
sign-in, retention, whether alerts are sent) come from the app, written on
every server start to `<data dir>/server.env` (0600) and never logged
(the log names only what was set: "settings from the app: smtp, backup"):

| server setting | from |
|---|---|
| SMTP | `config.smtp`, else Action Mailer's `smtp_settings` when `delivery_method` is `:smtp` |
| From | `config.mail_from`, else `ActionMailer::Base.default[:from]` |
| S3 backups | `config.backup`, else `credentials.railwatch_server.backup` (`endpoint bucket access_key_id secret_access_key`, optional `region prefix interval_seconds`) |
| Google sign-in | `config.google`, else `credentials.railwatch_server.google` (`client_id client_secret`) |
| retention | `config.retention = { detail_days:, core_days_max: }` |
| alert delivery | `config.alert_delivery = false` records alerts without sending |
| anything else | `config.server_env = { "RAILWATCH_NEW_ISSUES_PER_HOUR" => 50 }` |

`false` or `{}` turns one off where the app would otherwise supply it. An
incomplete backup is refused whole (logged, no backups) rather than
half-applied. `railwatch doctor` with `RAILWATCH_ENV_FILE` pointed at the
file shows what the server reads.

The agent is wired only when the app has not configured a destination:
when `RAILWATCH_TOKEN` is set, or the agent uses `transport :local`, it is
left alone and the bundled server serves only the dashboard.

**Who the server sees.** The dashboard's gate is the `railwatch` gem's:
HTTP Basic, on and closed by default; or, with Basic off,
`base_controller_class` (the proxy controller inherits from it, so your
`before_action :require_admin` runs first). Past the gate, the visitor is
named to the server by `Railwatch::Server.config.user`:

```ruby
Railwatch::Server.configure do |c|
  c.user = ->(controller) { u = controller.current_user; { email: u.email, name: u.name, role: u.admin? ? "admin" : "member" } }
end
```

Without it, the HTTP Basic user name (or "Operator") is an admin. Users are
created in the server on first sight. Nobody signs in to the server itself.

## How it works

```
browser ── /railwatch/* ──> Rails (gate) ──> ProxyController ── 127.0.0.1:28790 ──> railwatch serve
                                              + X-Railwatch-Proxy-Auth (signed, 60 s)    (RAILWATCH_BASE_PATH=/railwatch)
Puma workers, jobs ── railwatch agent ── /ingest ─────────────────────────────────────┘
```

- **Process.** `plugin :railwatch_server` spawns `railwatch serve` from
  Puma's master after boot, in its own process group: a Ctrl-C reaches
  Puma, Puma drains, and only then is the server stopped. A supervisor
  thread checks every second and restarts a dead server with backoff
  (1, 2, 4, 8, 15, 30 s), logging the death and the last lines of
  `storage/railwatch/server.log`. Each check also asks the server's `/up`
  (2 s timeout): one that is alive but stops answering (stopped, wedged)
  is logged once as NOT ANSWERING, and after 8 s more of silence is
  KILLed and restarted the same way (measured: a SIGSTOPped server was
  replaced and answering in 11 s). At boot Puma waits at most 5 s for a
  new server's `/up`, then boots without it and says so; a server that
  hasn't answered once within 60 s of starting is killed and restarted. On stop: the railwatch agent's samplers
  stop, the reporter flushes into the still-running server, then the
  server gets SIGTERM (finishes in-flight requests, commits queued writes)
  and KILL past the deadline. `server.pid` records "server parent"; a
  server orphaned by a SIGKILLed Puma is stopped by the next start.
- **Proxy.** `/railwatch/*` is a prepended route to
  `Railwatch::Server::ProxyController`. It forwards the server's cookies
  and Inertia headers, sets `Host`/`X-Forwarded-Proto`, sets
  `X-Forwarded-For` to the visitor's `request.remote_ip` (replacing any the
  browser sent; the server runs with `RAILWATCH_TRUST_PROXY`, so its per-IP
  sign-in and MCP limits count visitors, not the app), adds the signed
  header, and hands the request off: **no Puma thread waits for the
  server.** Past the gate the controller connects to the server and leaves
  the request to `ProxyHandoff`, a middleware outside every other one,
  which takes the browser's socket with Rack hijack and gives both
  sockets to the process's one `Relay` thread (the live channel's, below).
  The Relay writes the request (Puma has already read the body; a large
  one comes from Puma's tempfile) and passes the response back as it
  arrives, byte for byte except the head: `Connection: close` (the browser,
  or the proxy in front of the app, opens a new connection for the next
  request) and the app's own `Set-Cookie` (a rolling session) added. A
  response the server hasn't started within the first-byte timeout is a
  504 and one it drops before answering a 502, both written by the Relay;
  one that goes quiet mid-body is cut off after the idle timeout.
  Measured (`test/e2e/slow_dashboard.rb`, Puma 1 worker x 3 threads, pages
  taking 3 s): before, 6 slow loads made the app's `/up` wait 5.7 s;
  after, 4 ms. With 30 slow loads at once the worker kept its 13 threads,
  RSS rose 131 -> 137 MB and `/up` stayed under 12 ms. Encodings pass
  through untouched. Without Rack hijack, and under Puma's own TLS (`ssl_bind`;
  its socket wrapper holds decrypted bytes `IO.select` can't see), the
  response is streamed from the Puma thread instead, as before: headers
  as soon as the server sends them, the body as Puma writes it. Behind
  Thruster, kamal-proxy or nginx the app sees plain HTTP/1.1 and the
  handoff applies; HTTP/2 ends at that proxy. It doesn't rewrite paths:
  the server itself serves under `/railwatch` (below). CSRF is the
  server's own (Origin check plus its token), so Rails' check is off for
  this controller, and so is inertia_rails' (its `XSRF-TOKEN` at
  `Path=/` shadowed the server's, refusing every write). inertia_rails'
  middleware would also answer every dashboard click with a 409 full
  reload, since the dashboard's Inertia version is the server's, not the
  app's; the proxy removes `X-Inertia` from the request once it has been
  forwarded, so the middleware leaves the response alone.
  Commenting, resolving, saving a view and changing a setting are tested
  through the proxy (`test/e2e/browser_writes.rb`, and by hand in Chromium).
- **Live channel.** `/railwatch/cable` is a Rack hijack too; the browser's
  and the server's sockets are spliced by the same `IO.select` thread per
  app process (`Relay`), not two threads per socket: 30 open dashboards
  cost one thread. At most `max_live_connections` per process, counted
  apart from dashboard requests; past it the handshake gets 503 and the
  dashboard falls back to reloading.
- **Trust.** `storage/railwatch/proxy_secret` (0600, generated) is the
  HMAC key. The header is `v1.<claims>.<HMAC-SHA256>` with
  `email, name, role, exp`; the server refuses a bad signature, an expired
  one, one valid for more than 5 minutes, and any role but admin/member
  (401, logged). It never falls back to "signed out". The server binds
  loopback only, so nothing outside the host can reach it unproxied.

## The server side (Rebulk/railwatch-rs)

The server features this gem relies on are upstream, in Rebulk/railwatch-rs
`main` from `ef87f72` (PR #16), and the dashboard's mount handling is in the
railwatch gem from 0.9.3. Every setting is off by default, so a self-hosted
install is unchanged. Documented in railwatch-rs `docs/SELF-HOST.md`,
"Running behind an app".

- **`RAILWATCH_BASE_PATH`**: pages are served under a prefix (`/railwatch`)
  while `/ingest` and `/up` stay at the root, so the agent's URL doesn't
  change. Redirects, cookie paths, asset/icon/entry URLs, emails, MCP
  discovery and the Google callback all carry it.
- **`RAILWATCH_TRUSTED_PROXY_SECRET_FILE`**: the server accepts an
  HMAC-signed `X-Railwatch-Proxy-Auth` header (email, name, admin/member
  role, `exp` at most 300 s ahead) from this gem's proxy as the signed-in
  user. The header is stripped from every request before any route sees it,
  even with the mode off; when on, an invalid one is a 401, never a
  fall-back. The proxy can't create or demote an owner.
- **`RAILWATCH_STANDBY_RELAY`**: the server holding `serve.lock` also
  listens on `<data_dir>/serve.sock` (0600, peer uid checked); a second
  `serve` on the same data dir binds its own loopback port at once and
  relays to that socket until it gets the lock. This is what makes a
  two-container deploy overlap lose nothing (see "Deploys" below).

**Why a base path, not rewriting in the proxy:** URLs are made in four
places (Rust redirects, Inertia's 409 `X-Inertia-Location`, js-routes in
the bundle, CSS/JS asset URLs) plus cookies and the cable URL. Rewriting
means parsing HTML, JSON page props and JS chunks, and it breaks the first
time the server adds a URL the proxy doesn't know about. With a base path
the server says the right URL once and the proxy stays byte-transparent.

## Building

```sh
script/build-server /path/to/railwatch-rs   # railwatch-rs at or after ef87f72, frontend/dist built (bin/build, SKIP_CARGO=1)
rake gem:all                                # pkg/: ruby + 4 platform gems (~10 MB each)
```

Builds use the pinned `cargo-zigbuild` image from `bin/release`: static musl
for Linux, and that image's MacOSX 11.3 SDK for both darwin targets. All
four built here (2-3 min each, 4 jobs).

**macOS: built natively, signed ad hoc, run in CI.** `.github/workflows/macos.yml`
builds the frontend once on Linux, then on `macos-14` (arm64) and
`macos-15-intel` (x86_64; GitHub retired the macos-13 runners) builds the
server from the pinned railwatch-rs commit (`MACOSX_DEPLOYMENT_TARGET=11.0`, checked
with `vtool`: minos 11.0), signs it `codesign -s -`, verifies the
signature and the arch, and runs it: `--version`, `setup` in a temp dir,
`serve`, `/up` and `/ingest/ping`, then a second `serve` on the same data
dir that comes up as a standby and takes over when the first gets TERM.
Then it builds the darwin platform gem, installs it, checks the installed
binary's signature and runs it. Artifacts: the binary and the `.gem` per
arch. The zigbuild cross-build in `script/build-server` still works for
Linux; for darwin, use the workflow's artifacts (they are signed).

## Deploys and two processes

- **Same host, same data dir** (two Pumas, or `phased-restart` overlap):
  the second app process finds the port already answered, starts its own
  server anyway (it waits on `serve.lock`) and logs "standby". Its agent
  reports to the first server, which owns the data. When the first app
  process stops, its server drains and exits, the standby takes the lock
  and the port (the log says "took over"). Measured: 10 + 10 requests
  during the overlap and 10 after, 30 of 30 stored; one server writes at
  any time.
- **Two containers sharing a volume** (Kamal blue/green): each container
  has its own loopback, so the new container's agent can't reach the old
  container's server. The new container's server (`RAILWATCH_STANDBY_RELAY`,
  railwatch-rs `RAILWATCH_STANDBY_RELAY`) binds its own `127.0.0.1:28790` at once and splices
  every connection, byte for byte, to `storage/railwatch/serve.sock`, where
  the server holding `serve.lock` also listens. A Unix socket on the shared
  volume crosses network namespaces (same kernel, same inode). When the old
  container stops, its server drains and exits, the standby takes the lock
  and serves the same listener itself; connections in that gap retry the
  socket for up to 30 s. The log says "as a standby" then "took over".

  Why this mattered (measured, `test/overlap/`, 3 runs before the fix): the
  new container's first delivery was refused, the agent retained it and
  retried on its ladder, and every retained retry doubled its backpressure
  factor (1, 2, 4, 8). The sampler divides the request sample rate by that
  factor, so for the ~12 s until the old server exited the new container
  recorded 1 in 2, 1 in 4, then 1 in 8 of its requests. The dropped ones were
  never recorded at all; nothing that reached the agent's buffer was lost.
  186, 184 and 197 of ~480 requests went unrecorded, every one at a factor
  of 2, 4 or 8, none at 1. With `RAILWATCH_BACKPRESSURE=false` the same
  overlap stored 476/476: the batches themselves all arrived on retry.
  Starting the server before Puma accepts requests (under `bin/rails s`)
  also removes the one refused delivery at boot that cost 5-9 requests.

  | handover, ~800 requests | served | stored once | lost |
  |---|---|---|---|
  | before, `docker stop` | 795 | 602 | 193 (new container: 186) |
  | before, SIGKILL | 793 | 582 | 211 |
  | after, `docker stop` | 795 | 795 | 0 |
  | after, SIGKILL of the old one | 789 | 771 | 18, all the old container's last second |
  | after, fresh `rails new` app (Rails 8.1, Solid Queue), `docker stop` | 865 | 865 | 0 |
  | after, fresh `rails new` app, SIGKILL of the old one | 845 | 828 | 17, the old container's last second |

  A SIGKILLed app loses what its agent had not flushed yet (up to
  `flush_interval`, here 1 s): the records were in that process's memory.
  The new container lost nothing in either run, and no record was stored
  twice. Volumes on two different hosts are not supported (flock and Unix
  sockets don't cross hosts; each host would need its own data dir, which
  splits the history).

## Cost (same app, same 1000 requests, single-mode Puma)

| | idle RSS | RSS after 1000 req | CPU for 1000 req |
|---|---|---|---|
| this gem: `railwatch serve` | 12 MB | 51 MB | 0.15 s |
| railwatch gem embedded: writer process | 87 MB | 138 MB | 0.08 s |
| Puma itself (either way) | 126 MB | 162-166 MB | 3.2-3.8 s |

The Rust server is a third of the Ruby writer's memory. The Ruby writer
spends less CPU only because it writes rows and does no grouping,
rollups, alerts or the dashboard. Rendering the dashboard costs the
sidecar, not Puma (Puma only proxies), whereas the embedded dashboard
renders inside Puma's workers.

## Limitations and TODOs

- Dashboard connections close after each response (no keep-alive
  between the browser and the proxy for `/railwatch`). On loopback or
  behind a reverse proxy that costs nothing measurable; a browser talking
  straight to Puma over the internet opens a new TCP connection per
  dashboard request.
- The cap is per process and checked before connecting, so a burst can
  pass it by as many requests as Puma has threads.
- macOS binaries are ad-hoc signed only: fine for a gem installed with
  Bundler (RubyGems sets no quarantine flag). A notarized release needs an
  Apple Developer ID certificate in CI (`codesign -s "Developer ID
  Application: ..." --options runtime --timestamp`, then `notarytool
  submit --wait`); a bare executable can't be stapled, so Gatekeeper checks
  it online the first time it runs from a quarantined download.
- One environment per data dir (above).
- The account owner is a placeholder user with a random password nobody
  knows; the proxied users are admins/members. Transferring ownership
  works in Settings > Members.
- Releases must keep building the platform gems from a published
  railwatch-rs commit (AGPL section 6): `RAILWATCH_RS_SHA` in
  `.github/workflows/macos.yml`, and the same commit for the Linux builds.
- Name: temporary.

## License

AGPL-3.0-only (LICENSE). The platform gems contain the Railwatch server
binary; NOTICE explains what that means for your app (nothing: it runs as
a separate program) and where the corresponding source is.
