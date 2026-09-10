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
- [🔀 One server, and sites that need their own](#-one-server-and-sites-that-need-their-own)
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
- `dnsmasq`, `caddy`, `mkcert`, `php`, and `node` (for the dashboard build) —
  **installed for you** if they are missing, after asking.
- `sudo` for three things, each announced before it happens: the resolver file, the local
  CA, and the launchd service. Every one of them can be declined and run by hand.

---

## ⚡ Install

```sh
git clone https://github.com/newworkbryce/ldev.git
cd ldev
./install.sh
```

The installer asks three things — **TLD**, **sites directory**, and whether to make the
root-owned changes for you — then does the rest. There is no serving mode to choose.

Non-interactive:

```sh
./install.sh --tld test --sites ~/Code --yes
./install.sh --defaults
```

| Flag | Effect |
|---|---|
| `--tld <name>` | The TLD, one label, no dot. Default `ldev`. |
| `--sites <dir>` | Where your site folders live. Default `~/Sites`. |
| `--php-fpm <host:port>` | PHP-FPM address. Default `127.0.0.1:9000`. |
| `--skip-dns` | Leave `/etc/resolver` and dnsmasq alone. |
| `--yes`, `-y` | Answer yes to every confirmation. |
| `--defaults` | Accept every default and prompt for nothing. |

### Replacing an existing setup

Before installing its own daemon, the installer looks for whatever already serves the TLD
and offers to take it down, because leaving it up is what produced the worst failure this
tool has had: two servers live at once, one holding 80 and the other 443, and the bare
`https://<tld>/` URL answering from neither — while the install reported success.

It matches launchd jobs by **content**, not by filename: a job is found because its
`ProgramArguments` run `caddy` against a Caddyfile under your sites or config directory,
not because it is called something ldev-ish. The one that motivated this was named
`com.bryce.caddy-matsu`.

Only jobs wanting **port 80 or 443** are offered for removal. A per-site server on a high
port is not in the way — the wildcard server proxies to it — so it is listed as kept and
left running. That distinction is per *address*, not per line: in

```
matsu.ldev, matsu-dev.ldev:8444 {
```

each host has its own address, so `matsu-dev.ldev` is on 8444 and `matsu.ldev` is on the
default 443. Reading the first port on that line would call the job harmless and leave it
holding the port ldev needs.

Site folders are never touched, and a busy port with no launchd job behind it is named
rather than guessed at — that is somebody's `caddy run` in a terminal, and not the
installer's to kill.

The installer then offers to put the CLI on your `PATH`, and says exactly what it would
append and to which file before it does:

```
ldev lives in /path/to/ldev/bin, which is not on your PATH.
This would append to /Users/you/.zshrc:

  export PATH="/path/to/ldev/bin:$PATH"

Add it? [y/N]:
```

It picks the file and the syntax from your **login shell**, not from a guess: `.zshrc` for
zsh, `.bash_profile` for bash (macOS Terminal opens login shells, which read that and
pointedly not `.bashrc`), `config.fish` for fish — where the line is `fish_add_path`,
because `export PATH="…:$PATH"` is a syntax error in fish. A shell it does not recognise
gets the line printed rather than written to a file it guessed at.

Decline, and it prints the command to run yourself. Re-running the installer will not
stack duplicates, and if `ldev` already resolves to a *different* checkout it says which
one wins instead of appearing to fix it.

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

**A folder name has to be able to *be* a hostname.** Caddy matches on the `Host:` header,
which is lowercase and cannot contain a space:

| Folder | Reachable at |
|---|---|
| `~/Sites/ClothingStore` | `https://clothingstore.ldev` — macOS is case-insensitive, so this works |
| `~/Sites/Scope Canvas` | ❌ nothing — no URL can carry that space |

`ldev list` counts the unreachable ones and says to rename them, rather than printing a
URL that cannot work.

---

## 🧭 Commands

```sh
ldev doctor      # check each layer separately and say which one is broken
ldev list        # sites found under the sites directory, and their type
ldev new <name>  # create a site directory, live immediately
ldev standalone <name>  # give one site its own server, fronted by the wildcard one
ldev rehome <name>      # move a WordPress site onto its portless URL
ldev render      # re-render the server config, without restarting
ldev apply       # re-render the server config and restart
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

## 🔀 One server, and sites that need their own

One Caddy owns 80 and 443 for the whole TLD. Sites resolve by directory name, certificates
are issued per host on first request, and an unknown host falls back to the dashboard.
There is nothing to choose at install time.

A site sometimes needs what that shared server cannot express — its own PHP version, its
own certificate, a proxy to an app already running, or restarts that leave its neighbours
alone. That site runs its own Caddy on a high port and is **fronted** by the wildcard one:

```sh
ldev standalone shop     # writes shop its own Caddyfile on a free port pair
cd ~/Sites/shop && caddy run
ldev apply               # generate the proxy block, so the URL stays portless
```

It keeps everything the shared server gives everything else — `https://shop.ldev` with no
port, a certificate, the `.localhost` origin, and the dashboard fallback for names that do
not exist. See [docs/standalone-sites.md](docs/standalone-sites.md).

> ℹ️ **`persite` and `apache` modes are gone.** Both were install-wide answers to per-site
> questions. `persite` gave up ports 80 and 443 for *every* site so that *one* could have
> its own server — and with those ports went the dashboard fallback (which needs something
> listening on 443 for hostnames with no folder behind them), the portless URLs and the
> `.localhost` origins. Those four capabilities are now a per-site escalation that costs
> none of that. `apache` never worked: the template it rendered was never committed, so
> choosing it killed the installer. The installer refuses both by name rather than
> accepting a mode nothing downstream implements.
>
> The trade this makes is real and worth stating: ldev now requires ports 80 and 443, and
> on macOS that means a root-owned launchd daemon. A machine where something else must keep
> those ports cannot run it.

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
| `PHP_FPM` | PHP-FPM address, e.g. `127.0.0.1:9000` |
| `DASHBOARD` | Path to the built dashboard |
| `ADMIN_PORT`, `ASK_PORT` | The wildcard server's own admin API and on-demand-TLS ask endpoint |
| `SITE_PORT_BASE` | First port handed to a site that runs its own server; admin ports start one above `ADMIN_PORT` |
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
| 🔐 `ERR_SSL_PROTOCOL_ERROR` on every site but one | Something other than ldev holds 443 and knows only that one host | `ldev doctor` names it; re-run `./install.sh` to take it down |
| 🔒 Certificate warning in the browser | The local CA is not trusted | `caddy trust` |
| 📄 Blank page on a PHP site | PHP-FPM is not listening | `brew services start php` |
| 🧭 You get the dashboard instead of your site | The folder has no `index.php` or `index.html` — or a plain folder is shadowing a `.ldev` one | `ldev list` |
| 🤖 A headless browser loads nothing | It refuses custom TLDs | Use `http://<name>.localhost/` |
| 🔤 A folder never appears | Its name cannot be a hostname — a space, or another character a `Host:` header cannot carry | `ldev list` counts these; rename them |
| 🧱 A site's own server "does not start" | Two sites sharing an admin port — the second exits silently | [docs/standalone-sites.md](docs/standalone-sites.md) |
| 🔁 A site's own server runs, but its URL still hits the dashboard | No proxy block for it yet | `ldev apply` |
| ↩️ A WordPress site redirects to `:8443` | `WP_HOME`/`WP_SITEURL` still name the old ported URL | `ldev rehome <name>` |

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
| `~/.config/ldev/Caddyfile` | you | generated server config |
| `~/Library/Logs/ldev/` | you | access logs |
| `/Library/LaunchDaemons/com.ldev.caddy.plist` | root | starts Caddy on 80/443 at boot |
| another launchd job holding 80/443 | root or you | **removed**, only if you accept the prompt — see [Replacing an existing setup](#replacing-an-existing-setup) |
| system trust store | root | trusts the local CA, once |
| your shell's startup file | you | one `PATH` line — only if you accept the prompt |

Nothing is written anywhere else.

---

## 🧪 Tests

Plain bash, no framework. Each script sets up a throwaway tree, asserts, and cleans up:

```sh
bash test/auto-root.test.sh      # hostname → folder, both layouts, on a real Caddy
bash test/standalone.test.sh     # new, standalone and render: config, ports, proxy blocks
bash test/site-ports.test.sh     # the site/admin port allocator
bash test/rehome.test.sh         # what rehome refuses to do to your site data
bash test/path-setup.test.sh     # the right startup file and syntax per shell
bash test/existing-install.test.sh  # which launchd job is in the way, and which is fronted
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
rm -rf ~/.config/ldev ~/Library/Logs/ldev   # config and the generated Caddyfile
caddy untrust                    # optional: remove the local CA from the trust store
```

Then remove the two lines `install.sh` appended: the `conf-dir` line in
`$(brew --prefix)/etc/dnsmasq.conf`, and — if you accepted the PATH prompt — the `# ldev`
line and the one after it in your shell's startup file (`~/.zshrc`, `~/.bash_profile`,
`~/.profile` or `~/.config/fish/config.fish`, whichever it named at the time).

**Your site folders are never touched** — uninstalling stops them being served, and
nothing more.

---

## 📄 License

No licence file yet. Add one before publishing this repo.
