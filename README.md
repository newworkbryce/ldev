# ldev

A wildcard local-development TLD for macOS. Create a folder, get an HTTPS site.

```
mkdir ~/Sites/shop.ldev        ->  https://shop.ldev
```

No `/etc/hosts` entry, no vhost, no certificate, no port number, no restart. A
hostname with no folder behind it lands on a dashboard listing what you do have,
rather than a connection error.

The TLD is a setting. `.ldev` is only the default — install it as `.test`,
`.wip`, `.local-dev` or anything else.

## Install

```sh
git clone https://github.com/newworkbryce/ldev.git
cd ldev
./install.sh
```

The installer asks three things — TLD, sites directory, and whether to make the
root-owned changes for you — then does the rest. Non-interactive:

```sh
./install.sh --tld test --sites ~/Code --yes
./install.sh --defaults
```

It needs ports 80 and 443, which on macOS means a root-owned launchd daemon.
That is the one requirement: a machine where something else must keep those
ports cannot run this.

## How a request is served

One Caddy owns 80 and 443 for the whole TLD, and resolves every hostname under
it from a single wildcard block:

| `https://shop.ldev` finds | it is served |
|---|---|
| `~/Sites/shop.ldev/` or `~/Sites/shop/` | from disk — PHP via FastCGI if there is an `index.php`, static files if there is an `index.html` |
| a site running its own server | proxied to it, with the URL still portless |
| nothing at all | by the dashboard, listing what you *do* have |

The directory name may carry the TLD or not; both are served, so a repo cloned
as `~/Sites/shop` needs no renaming. Certificates are issued per host from
Caddy's own CA on first request, so a new site needs no certificate step.

### When one site needs more

A site needing what the shared server cannot express — a different PHP version,
its own certificate, a proxy to an app already running, or restarts that leave
its neighbours alone — runs its own Caddy on a high port and is fronted by the
wildcard one:

```sh
ldev standalone shop
```

It keeps the portless URL, the certificate, and the dashboard fallback. This
used to be an install-wide mode (`persite`) that gave up ports 80 and 443 — and
with them the fallback and the clean URLs — for every site, to satisfy one.
See [docs/standalone-sites.md](docs/standalone-sites.md).

## Commands

```sh
ldev doctor      # check each layer separately and say which one is broken
ldev list        # sites found under the sites directory, and their type
ldev new <name>  # create a site directory, live immediately
ldev standalone <name>  # give one site its own server, fronted by the wildcard one
ldev render      # re-render the server config, without restarting
ldev apply       # re-render the server config and restart
ldev status      # is the service running
ldev config      # print the saved configuration
```

`ldev doctor` exists because these layers fail independently and a working layer
above a broken one is genuinely misleading. The failure that motivated this repo
was DNS resolving perfectly while nothing listened on 443: every name resolved,
port 80 answered with a redirect to HTTPS, and HTTPS refused the connection. It
reads as "DNS is broken" and it is not. `doctor` reports DNS, listeners, PHP,
config and an end-to-end fetch as separate results.

## How it works

Four layers, each replaceable:

1. **DNS** — dnsmasq answers `*.<tld>` with `127.0.0.1`, and
   `/etc/resolver/<tld>` tells macOS to ask dnsmasq for that TLD. This is why no
   `/etc/hosts` entry is ever needed, including for hostnames that do not exist
   yet.
2. **Routing** — one Caddy site block serves the whole TLD, deriving the document
   root from the hostname (`{labels.1}`). `file` matchers decide PHP, static, or
   fallback, and try both directory layouts — `<name>.<tld>` and bare `<name>` — so
   the suffix is optional. A site running its own server gets a generated
   `reverse_proxy` block ahead of the wildcard, which Caddy prefers because it
   matches more specifically.
3. **TLS** — Caddy's own CA issues a certificate per host on first request. It is
   deliberately *not* a wildcard certificate: a `*.<tld>` certificate is rejected
   by browsers for `<name>.<tld>` with `ERR_CERT_COMMON_NAME_INVALID`, which is a
   confusing failure to debug. Per-host issuance avoids it.
4. **Fallback** — anything with no directory goes to the dashboard, so a typo or
   a half-set-up project tells you what exists instead of failing blankly.

## The dashboard

`dashboard/` is a React + PHP app listing local projects with their name, URL,
port and platform, and detecting WordPress installs by reading `WP_HOME` from
`wp-config.php`. Its Sites directory and TLD are configurable in Settings, and
its config lives outside the repo so a rebuild never overwrites it.

## Requirements

macOS, Homebrew, and — installed for you if missing — `dnsmasq`, `caddy`,
`php`, plus `node` to build the dashboard. Ports 80 and 443 must be free.

## What it changes on your machine

Everything root-owned is announced before it happens, and can be declined and run
by hand instead.

| Path | Owner | Purpose |
|---|---|---|
| `$(brew --prefix)/etc/dnsmasq.d/<tld>.conf` | you | wildcard DNS for the TLD |
| `/etc/resolver/<tld>` | root | routes that TLD to dnsmasq |
| `~/.config/ldev/config` | you | saved settings |
| `~/.config/ldev/Caddyfile` | you | generated server config |
| `/Library/LaunchDaemons/com.ldev.caddy.plist` | root | starts Caddy on 80/443 at boot |
| system trust store | root | trusts the local CA, once |

Uninstalling is the reverse of that table; nothing is written anywhere else.
