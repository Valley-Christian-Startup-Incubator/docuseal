# DocuSeal automatic releases on Big Mac

The verified canonical repository is
https://github.com/Valley-Christian-Startup-Incubator/docuseal, branch `master`.
The Studio's `user/501/com.incubator.docuseal.autodeploy` launchd job checks that
branch every 60 seconds. It fetches the canonical URL explicitly, revalidates
GitHub ownership, and requires a clean `master` checkout and fast-forward history.
The installed watcher is pinned and updates itself only after a successful release.

Runtime configuration, immutable release metadata, private logs, proxy configuration,
retained browser assets and the shared lock live outside the checkout at
`/Users/aimac/.local/share/docuseal/deploy`. Its `config.json` contains:

```json
{
  "full_name": "Valley-Christian-Startup-Incubator/docuseal",
  "canonical_url": "https://github.com/Valley-Christian-Startup-Incubator/docuseal",
  "source_checkout": "/Users/aimac/.local/share/docuseal/deploy/source",
  "public_health_url": "https://sign.valleychristianai.com/up",
  "docker": "/opt/homebrew/bin/docker"
}
```

The dedicated Caddy job `user/501/com.incubator.docuseal.proxy` listens only on
`127.0.0.1:3037`; its isolated admin API is `127.0.0.1:3047`. It serves append-only
`/packs/*` assets before proxying to the active release. `X-Forwarded-Proto` is set
to `https` for this HTTPS-only public service. No unrelated Caddy instance is used.
The original Compose app remains running on port 3035 for rollback.

Only the loopback Cloudflare tunnel is a trusted proxy. Caddy reads the client
address from `CF-Connecting-IP`, replaces `X-Forwarded-For` with that parsed
address, and removes `Client-IP` and `X-Client-IP`. Public forwarded-header
values cannot override the address recorded by Rails. This follows
[Caddy's trusted proxy configuration](https://caddyserver.com/docs/caddyfile/options#trusted-proxies).
Direct loopback health probes without the Cloudflare header retain the loopback
address. The proxy listener must remain loopback-only.

When a release changes proxy generation, the running watcher finishes with its
pinned code before installing the new watcher. Apply the new proxy configuration
after that release with the installed `Deployer.switch(active)` under its shared
lock. This uses Caddy's graceful `/load` route and preserves the active app.
Existing completed audit files retain their original recorded addresses.

## Operations

Run as `aimac` on `valley-big-mac`:

```sh
python3 ~/.local/share/docuseal/deploy/autodeploy.py --status
python3 ~/.local/share/docuseal/deploy/autodeploy.py --once
python3 ~/.local/share/docuseal/deploy/autodeploy.py --pause
python3 ~/.local/share/docuseal/deploy/autodeploy.py --resume
python3 ~/.local/share/docuseal/deploy/autodeploy.py --retry
python3 ~/.local/share/docuseal/deploy/autodeploy.py --rollback
```

Pause/resume only changes a marker; it does not interrupt an ongoing rollout.
Rollback restores the retained previous app and pauses subsequent automatic
rollouts. Check the public application before resuming. `--retry` explicitly
retries the same failed SHA; otherwise a new commit is required. Read private
`logs/<sha>-<timestamp>.log` for build diagnostics; logs must not be published.
`state.json` records active, previous and tracked older containers.

Manual runs and the watcher share a nonblocking `fcntl` lock. A second writer
exits quietly. `transaction.json` makes interrupted cutovers recoverable: the
next run first restores the last durable active release and proxy configuration.
Do not remove the lock file while a deployer might be running.

## Release scope and retirement

Each commit builds `deploy/Dockerfile.vcs` as a separate image and starts a new
loopback container on a free port 3040–3050 excluding admin port 3047. It reuses
the existing production PostgreSQL network, credentials and document volume.
`RUN_MIGRATIONS=false` prevents automatic schema migrations. Each release has
its own Redis persistence directory under `/data/docuseal/redis/<sha>` and its
own embedded workers. Existing workers are never restarted by a new rollout.

Readiness requires `/up`, a sign-in form at `/sign_in`, and a read-only database
query. Assets are published atomically and existing filenames cannot change
content. Caddy's graceful configuration load switches new requests; current
and previous apps stay running. Failure restores the old upstream. Assets stay
available for open browser tabs and rollback.

Older managed containers can retire only after their Redis queue, scheduled,
retry and busy work counts are zero, and no established app-port TCP connection
remains. Shutdown waits for graceful completion rather than forcing termination.
The original Compose app is never retired. A maximum of four managed runtime
containers bounds growth; a fifth rollout is refused until an older app drains.
Database schema changes, original Compose maintenance and host upgrades remain
separate operations.

## Installation and watcher updates

Prepare a clean canonical `master` clone and private `config.json` first.
Run `deploy/autodeploy_install.py --root ROOT --caddy /opt/homebrew/bin/caddy`
to prepare the dedicated proxy and original hashed assets. It records the clone's
baseline SHA as the original app's release marker. Verify `/up` and `/sign_in`
through port 3037, then transition only this service's ingress to 3037 using a
parallel connector. Keep the original app and ingress connector through that
verified transition. The installer does not change the tunnel.

Only after the public route works through the dedicated proxy, rerun the
installer with `--enable-watcher`. It takes the deployment lock before replacing
an installed watcher and preserves an already-running dedicated proxy process.
To install a critical deployer fix before the next successful app rollout, use
this same locked installer from the reviewed fixed checkout. A failed ownership
check leaves the existing jobs untouched.

Run the isolated fixture suite with:

```sh
CADDY_BIN=/opt/homebrew/bin/caddy python3 deploy/autodeploy_test.py
```

It checks a real in-flight request across Caddy's upstream switch, retained old
assets, forwarded HTTPS protocol, failed builds, failed-public-check rollback,
interrupted-switch recovery, locking and container retention. Test fixtures use
random loopback ports and never connect to production containers or databases.
