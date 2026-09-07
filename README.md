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

The installer asks four things — TLD, sites directory, serving mode, and whether
to make the root-owned changes for you — then does the rest. Non-interactive:

```sh
./install.sh --tld test --sites ~/Code --mode auto --yes
./install.sh --defaults
```

## Serving modes

Chosen during install, because the right answer depends on what the machine
already runs.

| Mode | What it does | Choose it when |
|---|---|---|
| **auto** | One Caddy owns 80 and 443 for the whole TLD. Sites resolve by directory name; certificates are issued per host on first request; unknown hosts fall back to the dashboard. | Default. Nothing else needs those ports. |
| **persite** | One Caddy per site on its own high port, each with its own Caddyfile and certificate. | You already have per-site servers and want to keep them. |
| **apache** | httpd vhosts, with the first vhost per port acting as the fallback. | Apache is already the local web server. |

Only **auto** makes a new site work with no configuration. The other two are
there so installing this does not tear down a setup that already works.

## Commands

```sh
ldev doctor      # check each layer separately and say which one is broken
ldev list        # sites found under the sites directory, and their type
ldev new <name>  # create a site directory, live immediately
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
   root from the hostname (`{labels.1}`). A `file` matcher decides PHP, static, or
   fallback.
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
`mkcert`, `php`, plus `node` to build the dashboard.

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
