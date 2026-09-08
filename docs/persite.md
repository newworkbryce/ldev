# Per-site mode

One Caddy process per site, each on its own high port. Pick this when a site needs
configuration the shared `auto` server cannot express — a different PHP version, its own
TLS certificate, a proxy to a running app — or when you want one site's restarts not to
touch the others.

The cost is that a site is no longer just a directory. It needs a config file and two
ports, and getting the second port wrong fails in a way that does not announce itself.

## The two ports

Every per-site Caddyfile allocates a pair:

| | example | what it is |
|---|---|---|
| site port | `8443` | what you browse to: `https://name.ldev:8443` |
| admin port | `2019` | Caddy's local admin API |

`ldev new <name>` allocates them in step — `8443/2019`, then `8444/2020`, and so on —
by reading the ports already claimed by sibling site Caddyfiles.

**The admin port is the one that bites.** Caddy binds its admin API at startup, and two
processes cannot share it. The second one does not warn, fall back, or pick another port:
it exits. So a site whose Caddyfile inherits the default `2019` while another site is
already running simply never comes up, and what you see is a missing site rather than an
error explaining why. If a per-site server seems not to start, check its admin port
before anything else:

    grep admin ~/Sites/<name>.ldev/Caddyfile
    lsof -nP -iTCP:2019 -sTCP:LISTEN

If this site does not need the admin API at all, `admin off` is a valid answer and
removes the constraint entirely.

## Creating a site

    ldev new shop

writes `~/Sites/shop.ldev/Caddyfile` with a free port pair, validates it, and prints the
URL and the command to start it. Ports already used by a sibling — or already bound by
anything else on the machine — are skipped, so two sites created minutes apart do not
collide.

Start it from the site directory:

    cd ~/Sites/shop.ldev && caddy run

## Keeping a site running

`caddy run` lives as long as its terminal. To make one permanent, use a LaunchAgent —
and set `WorkingDirectory` to the site directory:

```xml
<key>WorkingDirectory</key>
<string>/Users/you/Sites/shop.ldev</string>
```

That is load-bearing whenever a Caddyfile uses a relative `root * .`: without it Caddy
resolves the root against launchd's working directory (`/`) and serves the wrong tree
while looking perfectly healthy. The template `ldev new` writes uses an absolute root for
this reason, so it is safe either way — but a hand-written one may not.

Set `KeepAlive` and `RunAtLoad` to have it start at login and come back if it dies. Note
`ThrottleInterval` (default 10s, often set to 15) means a restart is not instant: a killed
server takes tens of seconds to return, which reads as "it did not restart" if you check
too early.

## Compared with auto mode

| | auto | persite |
|---|---|---|
| processes | one | one per site |
| adding a site | create a directory | `ldev new <name>` |
| ports | 80 and 443 for everything | a pair per site |
| a site's config | none | its own Caddyfile, yours to edit |
| restart blast radius | every site | that site |
| unknown hostname | falls back to the dashboard | nothing listening |

`ldev apply` only regenerates the auto-mode config and refuses to run in per-site mode:
these files are yours, and regenerating them would discard whatever you changed.
