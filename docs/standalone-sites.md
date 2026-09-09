# Giving one site its own server

By default a site is a directory and nothing else: the wildcard server resolves it per
request, so there is no config file, no port and no restart. Some sites need more than that
— a different PHP version, their own certificate, a proxy to an app already running, or
restarts that leave every other site alone.

Those sites run their own Caddy on a high port, and the wildcard server puts them behind
the same front door as everything else:

    https://shop.ldev   ->   wildcard server on 443   ->   shop's own Caddy on 8443

    ldev standalone shop

## This used to be an install mode, and that was the problem

There was a `persite` mode: choosing it meant *every* site got its own server and its own
port, and nothing owned 80 or 443 at all. The four reasons above are per-site reasons, so
making them an install-wide switch charged every site for what one of them needed.

What it actually cost:

| | old `persite` mode | a standalone site today |
|---|---|---|
| the URL | `https://shop.ldev:8443` | `https://shop.ldev` |
| unknown hostname | nothing listening | the dashboard |
| `shop.localhost` origin | none | works |
| certificate | one per site, yours to manage | issued per host by the front door |
| other sites | also forced to have their own server | untouched |

The dashboard fallback is the one worth dwelling on. It needs something listening on 443
for hostnames that have no directory behind them, and `persite` deliberately left 443
empty — so an unrecognised name got a connection error rather than a page telling you what
*is* configured. That was not a missing feature, it was the mode working as designed, which
is exactly why it was hard to see.

## The two ports

Every standalone site allocates a pair:

| | example | what it is |
|---|---|---|
| site port | `8443` | where its own Caddy listens; the front door proxies here |
| admin port | `2020` | Caddy's local admin API |

Neither is a URL any more. The site port is an implementation detail — reach it directly at
`http://127.0.0.1:8443` only when you need to tell a fault of the site's from a fault of
the proxy's.

**The admin port is the one that bites.** Caddy binds its admin API at startup, and two
processes cannot share it. The second does not warn, fall back, or pick another: it exits.
So a site whose Caddyfile inherits a port already in use simply never comes up, and what
you see is a missing site rather than an error explaining why.

`ldev standalone` allocates both in step — `8443/2020`, then `8444/2021` — skipping every
port a sibling claims **and** the two the wildcard server itself holds. That last part was
a real collision: admin ports used to start at the same `2019` the front door binds, so the
first standalone site was handed a port that was already taken and lost silently.

If a site does not need the admin API, `admin off` is a valid answer and removes the
constraint entirely.

## Creating one

    ldev new shop           # a directory — already live at https://shop.ldev
    ldev standalone shop    # now it gets its own server
    cd ~/Sites/shop && caddy run
    ldev apply              # generate the proxy block, so the URL stays portless

`ldev apply` is not optional. Without it the site's own server runs perfectly and
`https://shop.ldev` still reaches the wildcard server's file handler, because nothing has
told the front door where to send that hostname.

Apply reads the address line out of each site's Caddyfile every time it runs, so a site
that changes its own port only needs another `ldev apply`. Nothing is recorded centrally,
deliberately: a second copy of the port in ldev's config is a copy that goes stale the
first time somebody edits one and not the other.

## Ports 80 and 443 are not yours to take

A site Caddyfile that puts its host on 80 or 443 is claiming the front door's own ports.
Fronting it would generate a block proxying that hostname to the very server doing the
proxying — a request loop with no site at the end of it. `ldev apply` refuses, names the
file, and serves that hostname from disk instead.

This is easier to hit than it sounds, because a Caddy address line gives **each** host on
it its own address:

    matsu.ldev, matsu-dev.ldev:8444 {

That is not one site on 8444. It is `matsu-dev.ldev` on 8444 and `matsu.ldev` on the
default 443 — which is also why a site written that way never started: an unprivileged
process cannot bind a specific address on a privileged port. Give every host an explicit
port of 1024 or above.

## Keeping one running

`caddy run` lives as long as its terminal. To make one permanent, use a LaunchAgent — and
set `WorkingDirectory` to the site directory:

```xml
<key>WorkingDirectory</key>
<string>/Users/you/Sites/shop</string>
```

That is load-bearing whenever a Caddyfile uses a relative `root * .`: without it Caddy
resolves the root against launchd's working directory (`/`) and serves the wrong tree while
looking perfectly healthy. The template `ldev standalone` writes uses an absolute root for
this reason, so it is safe either way — but a hand-written one may not be.

Set `KeepAlive` and `RunAtLoad` to start it at login and bring it back if it dies. Note
`ThrottleInterval` (default 10s, often set to 15) means a restart is not instant: a killed
server takes tens of seconds to return, which reads as "it did not restart" if you check
too early.

## The file is yours

`ldev apply` never rewrites a site's own Caddyfile. A site gets its own server precisely so
it can diverge, and regenerating it would discard whatever you changed. Apply only *reads*
the address line, to learn where to send traffic.
