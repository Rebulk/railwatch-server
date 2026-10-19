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
`railwatch setup` against `storage/railwatch`, so the account, app,
environment, ingest token and proxy secret are created once and kept
there. It then starts `railwatch serve` on `127.0.0.1:28790` and points the
agent at it.

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
| `RAILWATCH_SERVER_ENABLED` | `true` | off: no server, no route, the agent untouched |
| `RAILWATCH_SERVER_PORT` | `28790` | loopback port. Fixed, not picked at boot, so every process of the app finds the same server |
| `RAILWATCH_SERVER_DATA_DIR` | `storage/railwatch` | put it on the volume that survives deploys |
| `RAILWATCH_SERVER_MOUNT_PATH` | `/railwatch` | |
| `RAILWATCH_SERVER_URL` | the loopback URL | public URL of the app, for links in alert emails and Secure cookies |
| `RAILWATCH_SERVER_BINARY` | the platform gem's | your own `railwatch` |
| `RAILWATCH_SERVER_STOP_TIMEOUT` | `15` | seconds Puma's exit waits for the server to drain |
| `RAILWATCH_SERVER_WIRE_AGENT` | `true` | off: you configure the agent yourself |

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
  `storage/railwatch/server.log`. On stop: the railwatch agent's samplers
  stop, the reporter flushes into the still-running server, then the
  server gets SIGTERM (finishes in-flight requests, commits queued writes)
  and KILL past the deadline. `server.pid` records "server parent"; a
  server orphaned by a SIGKILLed Puma is stopped by the next start.
- **Proxy.** `/railwatch/*` is a prepended route to
  `Railwatch::Server::ProxyController`. It forwards the server's cookies
  and Inertia headers, sets `Host`/`X-Forwarded-Proto`, adds the signed
  header, and copies the response back. It doesn't rewrite paths: the
  server itself serves under `/railwatch` (below). The live channel
  (`/railwatch/cable`) is a Rack hijack spliced to the server's socket.
  CSRF is the server's own (Origin check plus its token), so Rails' check
  is skipped for this controller.
- **Trust.** `storage/railwatch/proxy_secret` (0600, generated) is the
  HMAC key. The header is `v1.<claims>.<HMAC-SHA256>` with
  `email, name, role, exp`; the server refuses a bad signature, an expired
  one, one valid for more than 5 minutes, and any role but admin/member
  (401, logged). It never falls back to "signed out". The server binds
  loopback only, so nothing outside the host can reach it unproxied.

## The Rust patches (`rust-patches/`)

Three commits on railwatch-rs `fc318ed`. **Not pushed upstream** (0001 and
0002 are being upstreamed separately). Every setting is off by default, so
a self-hosted install is unchanged.

1. `0001`: **`RAILWATCH_BASE_PATH`** and **`RAILWATCH_TRUSTED_PROXY_SECRET_FILE`**.
   - Base path: pages are nested under the prefix while `/ingest` and `/up`
     stay at the root, so the agent's URL doesn't change. Prefixed in turn:
     redirects (`Ctx::redirect`; `back_or` strips the prefix and refuses
     Referers outside it), cookie `Path`, the HTML document's asset, icon
     and entry-script URLs, saved-view URLs, and the beacon. It also emits
     `<meta name="railwatch-mount">` (the gem engine's convention) and
     `<meta name="action-cable-url">`. Vite's base becomes `./`, so CSS
     fonts and lazy chunks resolve relative to their own file; the same
     build works at `/` and under a prefix.
   - Trusted proxy: `web/proxy_auth.rs` (sign/verify/resolve), checked in
     the session middleware and the cable handshake. The resolved user gets
     one session row, reused; the proxy may set admin/member but never
     demote the owner.
   - Tests: `tests/trusted_proxy.rs` (real router over HTTP: root ingest,
     prefixed redirects, cookies, assets, cable 101, forged/expired/too-long
     headers 401, no provisioning on forgery, CSRF still enforced) and unit
     tests in `proxy_auth.rs`, `config.rs`, `inertia.rs`. Full `--lib`
     suite plus `security_poc` and `ingest_http` pass (145 + 3).
2. `0002`: the frontend's entrypoint reads `railwatch-mount` into the
   js-routes `script_name`, as the gem's own entrypoint does. Without it
   every sidebar link pointed at `/apps/...`.
3. `0003`: **`RAILWATCH_STANDBY_RELAY`** (`standby.rs`). The lock holder
   also listens on `<data_dir>/serve.sock`; a second `serve` that finds the
   lock held and can bind its own address relays to that socket until it
   gets the lock, then serves the same listener. Falls back to waiting as
   before when it can't bind (same loopback: the holder has the port), with
   TLS or socket activation, or when the path is over 103 bytes. Tests:
   `standby::tests` and `tests/standby_relay.rs` (45 ingest batches through
   the standby across a TERM of the holder: all 200, all stored once);
   `serve_lock` unchanged and passing.

**Why a base path, not rewriting in the proxy:** URLs are made in four
places (Rust redirects, Inertia's 409 `X-Inertia-Location`, js-routes in
the bundle, CSS/JS asset URLs) plus cookies and the cable URL. Rewriting
means parsing HTML, JSON page props and JS chunks, and it breaks the first
time the server adds a URL the proxy doesn't know about. With a base path
the server says the right URL once and the proxy stays byte-transparent.

## Building

```sh
script/build-server /path/to/railwatch-rs   # rust-patches applied, frontend/dist built (bin/build, SKIP_CARGO=1)
rake gem:all                                # pkg/: ruby + 4 platform gems (~10 MB each)
```

Builds use the pinned `cargo-zigbuild` image from `bin/release`: static musl
for Linux, and that image's MacOSX 11.3 SDK for both darwin targets. All
four built here (2-3 min each, 4 jobs).

**macOS: built, not run.** The darwin binaries cross-link (Mach-O,
x86_64/arm64) but were never executed, and they're unsigned. Apple Silicon
runs ad-hoc-signed binaries only, so expect `Killed: 9` until signed
(`codesign -s -` in the gem build would do for a local gem). A Gatekeeper
quarantine flag doesn't apply to files RubyGems extracts. Before shipping:
a macOS GitHub runner job that runs `railwatch version` and the
`trusted_proxy` test on each arch, ad-hoc or Developer ID signing, and a
check that the 11.3 SDK floor is fine.

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
  rust-patches/0003) binds its own `127.0.0.1:28790` at once and splices
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

- macOS binaries unverified (above).
- The proxy buffers whole responses (no streaming) and holds a Puma thread
  per live-channel connection's handshake, then two Ruby threads per open
  websocket. Fine for a few dashboard users; Thruster/nginx in front won't
  help with the threads.
- Uploads (source maps through `/railwatch/...`) are buffered in memory.
- Not exercised end to end: writes through the proxy from a browser
  (saving a view, changing an issue). The Rust test shows CSRF is still
  enforced with the proxy header, and the proxy forwards the XSRF cookie
  and header, but nobody clicked a form.
- One environment per app (the one `setup` created, named after
  `Rails.env`). Staging and production on one data dir would need
  `railwatch env create`.
- The account owner is a placeholder user with a random password nobody
  knows; the proxied users are admins/members. Transferring ownership
  works in Settings > Members.
- Alerts, SMTP, Google sign-in, backups: configure them the self-hosted
  way (`RAILWATCH_*` in the server's environment); this gem does not pass
  them through yet.
- The rust patch needs upstreaming (or a fork) before this gem can ship;
  the platform gems must be built from published source (AGPL section 6).
- Name: temporary.

## License

AGPL-3.0-only (LICENSE). The platform gems contain the Railwatch server
binary; NOTICE explains what that means for your app (nothing: it runs as
a separate program) and where the corresponding source is.
