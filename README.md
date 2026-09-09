# 🌐 ldev

**A wildcard local-development TLD for macOS. Create a folder, get an HTTPS site.**

```sh
mkdir ~/Sites/shop        # →  https://shop.ldev
```

That is the whole workflow. The folder is named after the site and **nothing else** — no
`.ldev` on the end, no `/etc/hosts` entry, no vhost, no certificate, no port number, no
restart. A hostname with no folder behind it lands on a dashboard listing what you *do*
have, rather than a connection error.

The TLD is a setting. `.ldev` is only the default — install it as `.test`, `.wip`,
`.local-dev` or anything else.

---

## 📑 Contents

- [✨ What you get](#-what-you-get)
- [📋 Requirements](#-requirements)
- [⚡ Install](#-install)
- [🚀 Making a site](#-making-a-site)
- [🧭 Commands](#-commands)
- [🔀 Serving modes](#-serving-modes)
- [🤖 Headless and automated browsers](#-headless-and-automated-browsers)
- [🧩 How it works](#-how-it-works)
- [📊 The dashboard](#-the-dashboard)
- [🔧 Configuration](#-configuration)
- [🩺 Troubleshooting](#-troubleshooting)
- [📦 What it changes on your machine](#-what-it-changes-on-your-machine)
- [🧪 Tests](#-tests)
- [🧹 Uninstall](#-uninstall)
- [📄 License](#-license)

---

## ✨ What you get

| | |
|---|---|
| 📁 **A folder is a site** | `~/Sites/shop` → `https://shop.ldev`. No config file, no restart. |
| 🔒 **HTTPS that browsers trust** | A certificate per hostname, issued on first request from a local CA. |
| 🌍 **No DNS admin** | `*.ldev` resolves to `127.0.0.1`, including names that do not exist yet. |
| 🧭 **A dashboard, not a dead end** | An unknown hostname lists your real sites instead of failing blankly. |
| 🐘 **PHP, static, WordPress** | PHP via FastCGI when there is an `index.php`, files when there is not. |
| 🩺 **A diagnostic that names the broken layer** | `ldev doctor` checks DNS, listeners, PHP, config and a real fetch separately. |

---

## 📋 Requirements

- **macOS** — the installer uses `/etc/resolver` and `launchd`, both macOS-specific.
- **[Homebrew](https://brew.sh)**.
- `dnsmasq`, `mkcert`, `php`, and `node` (for the dashboard build) — **installed for
  you** if they are missing, after asking.
- `caddy`, or `httpd` in apache mode — likewise.
- `sudo` for three things, each announced before it happens: the resolver file, the local
  CA, and the launchd service. Every one of them can be declined and run by hand.

---

## ⚡ Install

```sh
git clone https://github.com/newworkbryce/ldev.git
cd ldev
./install.sh
```

The installer asks four things — **TLD**, **sites directory**, **serving mode**, and
whether to make the root-owned changes for you — then does the rest.

Non-interactive:

```sh
./install.sh --tld test --sites ~/Code --mode auto --yes
./install.sh --defaults
```

| Flag | Effect |
|---|---|
| `--tld <name>` | The TLD, one label, no dot. Default `ldev`. |
| `--sites <dir>` | Where your site folders live. Default `~/Sites`. |
| `--mode auto\|apache\|persite` | Serving mode; see below. Default `auto`. |
| `--php-fpm <host:port>` | PHP-FPM address. Default `127.0.0.1:9000`. |
| `--skip-dns` | Leave `/etc/resolver` and dnsmasq alone. |
| `--yes`, `-y` | Answer yes to every confirmation. |
| `--defaults` | Accept every default and prompt for nothing. |

Then put the CLI on your `PATH`:

```sh
# the installer prints this line with your real checkout path already filled in
echo 'export PATH="/path/to/ldev/bin:$PATH"' >> ~/.zshrc
```

Finally, confirm the whole stack:

```sh
ldev doctor
```

---

## 🚀 Making a site

**The folder name is the site name.** No suffix:

```sh
mkdir ~/Sites/shop        # →  https://shop.ldev
mkdir ~/Sites/client-api  # →  https://client-api.ldev
ldev new blog             # same thing, plus a starter index.html
```

In `auto` mode the site is live immediately — the server resolves the folder per request,
so there is nothing to apply and nothing to restart.

What lands where:

| The folder contains | What is served |
|---|---|
| `index.php` | PHP via FastCGI |
| `index.html` (and no `index.php`) | Static files, with directory browsing |
| `wp-config.php` | WordPress — the dashboard reads `WP_HOME` to show its real URL |
| neither index | The dashboard fallback, so the name is not simply broken |

### 📛 Folders do not need `.ldev` in the name

Earlier versions required the folder to repeat the TLD (`~/Sites/shop.ldev`). They no
longer do, and that matters for a practical reason: the suffix was never load-bearing —
the hostname supplies it — but requiring it meant an existing project folder had to be
*renamed* before it could be served.

**Folders named the old way keep working.** Both layouts resolve to the same hostname:

| Folder | Served at |
|---|---|
| `~/Sites/shop` | `https://shop.ldev` ✅ preferred |
| `~/Sites/shop.ldev` | `https://shop.ldev` ✅ still works, nothing to rename |

If **both** folders exist they are one hostname, and the plain one wins. That is a
confusing thing to hit silently, so `ldev list` marks the shadowed folder and `ldev
doctor` reports it:

```
both.ldev    static    https://both.ldev/  (shadowed by both/)
```

---

## 🧭 Commands

```sh
ldev doctor      # check each layer separately and say which one is broken
ldev list        # sites found under the sites directory, and their type
ldev new <name>  # create a site directory, live immediately
ldev apply       # re-render the server config and restart (auto + apache modes)
ldev restart     # restart the server
ldev status      # is the service running
ldev config      # print the saved configuration
ldev help        # the above, from the tool itself
```

`ldev doctor` exists because these layers fail independently, and a working layer above a
broken one is genuinely misleading. The failure that motivated this repo was DNS resolving
perfectly while nothing listened on 443: every name resolved, port 80 answered with a
redirect to HTTPS, and HTTPS refused the connection. It reads as "DNS is broken" and it is
not. `doctor` reports DNS, listeners, PHP, config and an end-to-end fetch as separate
results, each with the command that fixes it.

---

## 🔀 Serving modes

Chosen during install, because the right answer depends on what the machine already runs.

| Mode | What it does | Choose it when |
|---|---|---|
| ⚡ **auto** | One Caddy owns 80 and 443 for the whole TLD. Sites resolve by directory name; certificates are issued per host on first request; unknown hosts fall back to the dashboard. | **Default.** Nothing else needs those ports. |
| 🐘 **apache** | httpd vhosts generated from your folders: a wildcard vhost on port 80, plus one HTTPS vhost and certificate per site, written by `ldev apply`. See [docs/apache.md](docs/apache.md). | Apache already owns 80/443 and you want to keep it. |
| 🧱 **persite** | One Caddy per site on its own high port (8443, 8444, …), each with its own Caddyfile and certificate. See [docs/persite.md](docs/persite.md). | You already have per-site servers and want to keep them. |

Only **auto** makes a new site work over HTTPS with no configuration at all. The other
two exist so that installing this does not tear down a setup that already works.

### 🐘 Apache mode, and where it differs

Apache has no on-demand certificate issuance, and a wildcard `*.ldev` certificate does not
work either — browsers reject it for `shop.ldev`, because `.ldev` is a single label. So
the two protocols are served by different machinery:

| | How | When a new folder works |
|---|---|---|
| **HTTP** | One wildcard vhost. `mod_vhost_alias` derives the document root from the hostname. | Immediately |
| **HTTPS** | One vhost per host, each naming its own mkcert certificate. | After `ldev apply` |

```sh
mkdir ~/Sites/shop     # http://shop.ldev works now
ldev apply             # writes shop's vhost + certificate, reloads httpd
                       # https://shop.ldev works now
```

`ldev apply` regenerates `~/.config/ldev/httpd-vhosts.conf` from whatever folders exist,
issues any certificate it is missing into `~/.config/ldev/certs/`, **syntax-checks the
result with `httpd -t` before replacing the live file**, and reloads httpd gracefully. A
generated vhost file that does not parse would stop httpd starting at all — and in this
mode httpd is the machine's web server, not just ldev's — so the check is not optional.

The installer enables the modules this needs (`vhost_alias`, `rewrite`, `proxy`,
`proxy_fcgi`, `ssl`, `socache_shmcb`), which a stock Homebrew `httpd.conf` ships
commented out, after asking and after backing the file up. httpd must also listen on 80
and 443 — Homebrew's default is 8080 — and run as root to bind them. `ldev doctor` checks
every one of those separately.

---

## 🤖 Headless and automated browsers

Every auto-mode site also answers over plain HTTP at **`http://<name>.localhost`**.

Browsers resolve `*.localhost` to loopback themselves — no DNS entry, no certificate,
nothing to trust. That matters because automated and preview browsers (Claude, Playwright
sandboxes, some CI images) refuse custom local TLDs: the document loads but every
subresource is blocked, so a JS app mounts nothing and the failure looks like an
application bug. Those tools can always reach `<name>.localhost`.

```sh
open https://shop.ldev          # you, in a normal browser
curl http://shop.localhost/     # a headless tool, no certificate involved
```

Both origins resolve the same folder, in both layouts.

---

## 🧩 How it works

Four layers, each replaceable:

1. **🌍 DNS** — dnsmasq answers `*.<tld>` with `127.0.0.1`, and `/etc/resolver/<tld>` tells
   macOS to ask dnsmasq for that TLD. This is why no `/etc/hosts` entry is ever needed,
   including for hostnames that do not exist yet.
2. **🚦 Routing** — one Caddy site block serves the whole TLD, deriving the document root
   from the hostname (`{labels.1}`). It looks for `<sites>/<name>` first and
   `<sites>/<name>.<tld>` second, then a `file` matcher decides PHP, static, or fallback.
3. **🔒 TLS** — Caddy's own CA issues a certificate per host on first request. It is
   deliberately *not* a wildcard certificate: a `*.<tld>` certificate is rejected by
   browsers for `<name>.<tld>` with `ERR_CERT_COMMON_NAME_INVALID`, which is a confusing
   failure to debug. Per-host issuance avoids it.
4. **🧭 Fallback** — anything with no directory goes to the dashboard, so a typo or a
   half-set-up project tells you what exists instead of failing blankly.

The generated config is `~/.config/ldev/Caddyfile`, rendered from
[`templates/Caddyfile.auto.tmpl`](templates/Caddyfile.auto.tmpl) — which is commented at
length, and is the authoritative description of the routing.

Apache mode keeps the same four layers and swaps the middle two: `mod_vhost_alias` and
`mod_rewrite` for routing, per-host mkcert certificates for TLS. See
[docs/apache.md](docs/apache.md).

---

## 📊 The dashboard

`dashboard/` is a React + PHP app listing local projects with their name, URL, port and
platform, and detecting WordPress installs by reading `WP_HOME` from `wp-config.php`. It
is what an unknown hostname falls back to, and it lives at:

```
https://ldev/            # the bare TLD
http://localhost/        # and here, no certificate needed
```

Its Sites directory and TLD are configurable in **Settings**, and its config lives outside
the repo so a rebuild never overwrites it. To rebuild it after a change:

```sh
cd dashboard && npm run build
```

---

## 🔧 Configuration

Everything the installer decided is saved in `~/.config/ldev/config`, a plain shell file
that `ldev` sources on every run:

| Key | Meaning |
|---|---|
| `TLD` | The local TLD, without the dot |
| `SITES` | Directory holding your site folders |
| `MODE` | `auto` or `persite` |
| `PHP_FPM` | PHP-FPM address, e.g. `127.0.0.1:9000` |
| `DASHBOARD` | Path to the built dashboard |
| `ADMIN_PORT`, `SITE_PORT_BASE`, `ASK_PORT` | Ports; the first two are the per-site allocation bases |
| `LOGDIR` | Where access logs are written |
| `REPO_DIR` | This checkout, so `ldev` can find its templates |

Edit it, then apply:

```sh
ldev config      # print it
ldev apply       # re-render the Caddyfile and restart (auto mode)
```

Changing `TLD` also needs the DNS side redone — the simplest route is to re-run
`./install.sh` with the new value.

---

## 🩺 Troubleshooting

**Start with `ldev doctor`.** It checks each layer on its own and prints the command that
fixes whatever failed. The common ones:

| Symptom | Likely cause | Fix |
|---|---|---|
| 🌍 Name does not resolve at all | Resolver file or dnsmasq | `echo 'nameserver 127.0.0.1' \| sudo tee /etc/resolver/ldev` then `sudo brew services restart dnsmasq` |
| 🔌 Resolves, then "connection refused" | Nothing on 443 — the service is not running | `sudo launchctl bootstrap system /Library/LaunchDaemons/com.ldev.caddy.plist` |
| 🔒 Certificate warning in the browser | The local CA is not trusted | `caddy trust` |
| 📄 Blank page on a PHP site | PHP-FPM is not listening | `brew services start php` |
| 🧭 You get the dashboard instead of your site | The folder has no `index.php` or `index.html` — or a plain folder is shadowing a `.ldev` one | `ldev list` |
| 🤖 A headless browser loads nothing | It refuses custom TLDs | Use `http://<name>.localhost/` |
| 🐘 HTTP works but HTTPS does not (apache mode) | The site has no vhost or certificate yet | `ldev apply` |
| 🐘 httpd will not start after `ldev apply` (apache mode) | A required module is not loaded — the error names a *directive*, not the module | `ldev doctor` names the module |
| 🧱 A per-site server "does not start" | Two sites sharing an admin port — the second exits silently | [docs/persite.md](docs/persite.md) |

Logs are in `~/Library/Logs/ldev/`.

---

## 📦 What it changes on your machine

Everything root-owned is announced before it happens, and can be declined and run by hand
instead.

| Path | Owner | Purpose |
|---|---|---|
| `$(brew --prefix)/etc/dnsmasq.d/<tld>.conf` | you | wildcard DNS for the TLD |
| `$(brew --prefix)/etc/dnsmasq.conf` | you | one `conf-dir` line, if not already present |
| `/etc/resolver/<tld>` | root | routes that TLD to dnsmasq |
| `~/.config/ldev/config` | you | saved settings |
| `~/.config/ldev/Caddyfile` | you | generated server config (auto mode) |
| `~/.config/ldev/httpd-vhosts.conf` | you | generated vhosts (apache mode) |
| `~/.config/ldev/certs/` | you | one mkcert pair per host (apache mode) |
| `$(brew --prefix)/etc/httpd/httpd.conf` | you | apache mode: an `Include` line, and `LoadModule` lines uncommented — backed up first |
| `~/Library/Logs/ldev/` | you | access logs |
| `/Library/LaunchDaemons/com.ldev.caddy.plist` | root | starts Caddy on 80/443 at boot |
| system trust store | root | trusts the local CA, once |

Nothing is written anywhere else.

---

## 🧪 Tests

Plain bash, no framework. Each script sets up a throwaway tree, asserts, and cleans up:

```sh
bash test/auto-root.test.sh      # hostname → folder, both layouts, on a real Caddy
bash test/apache-vhosts.test.sh  # ldev apply's vhosts, checked and served by a real httpd
bash test/persite-new.test.sh    # ldev new writes a valid, non-colliding site config
bash test/persite-ports.test.sh  # the site/admin port allocator
```

They skip gracefully when `caddy` is not on the `PATH`, or when a port they need is busy.

---

## 🧹 Uninstall

The reverse of the table above, in order:

```sh
sudo launchctl bootout system/com.ldev.caddy
sudo rm -f /Library/LaunchDaemons/com.ldev.caddy.plist
sudo rm -f /etc/resolver/ldev
rm -f "$(brew --prefix)/etc/dnsmasq.d/ldev.conf"
sudo brew services restart dnsmasq
rm -rf ~/.config/ldev ~/Library/Logs/ldev   # config, generated Caddyfile/vhosts, certs
caddy untrust                    # optional: remove the local CA from the trust store
```

Then remove the `conf-dir` line `install.sh` appended to
`$(brew --prefix)/etc/dnsmasq.conf`, and drop `bin/` from your `PATH`.

Apache mode also edited `httpd.conf`. Remove the `Include` line it added, and — if you
want the modules off again — restore the backup it made first:

```sh
ls "$(brew --prefix)"/etc/httpd/httpd.conf.ldev-backup.*   # newest is the one before install
sudo brew services restart httpd
```

**Your site folders are never touched** — uninstalling stops them being served, and
nothing more.

---

## 📄 License

No licence file yet. Add one before publishing this repo.
