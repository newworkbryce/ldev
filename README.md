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

The installer is a small terminal UI: **↑↓** to move, **enter** to choose, **1-9** to jump
straight to an option, **esc** to back out. Each choice explains itself as you highlight it.

It runs in seven steps, and writes nothing until you say go:

1. **What is already here** — before asking anything, it looks at what is actually
   installed and running: an existing config, the system LaunchDaemon, per-site
   Caddyfiles, LaunchAgents, and what holds ports 80 and 443. If it finds a previous
   install, it says so and offers to update it in place, switch, repair, or remove it.
2. **Configuration** — TLD, sites directory, and serving mode, each as a menu or a
   validated prompt, ending in a **review screen** listing every setting and every path
   about to be written, root-owned ones marked. You can go back into any answer from
   there, or quit without a byte being written.
3. **Dependencies** — offers to `brew install` whatever is missing.
4. **DNS**, 5. **Certificates**, 6. **Server configuration**, 7. **Done** — each
   announcing any root-owned change before making it, and printing the commands to run
   by hand if you decline.

Non-interactive:

```sh
./install.sh --tld test --sites ~/Code --mode auto --yes
./install.sh --defaults
```

With no terminal — a pipe, a script, `--plain`, or `NO_COLOR` — the menus, colour and
emoji fall away and every question takes the same answer it would have shown you. Optional
root-owned steps then **fail closed**: they are skipped, with the commands printed, unless
you passed `--yes` or `--defaults`.

| Flag | Effect |
|---|---|
| `--tld <name>` | The TLD, one label, no dot. Default `ldev`. |
| `--sites <dir>` | Where your site folders live. Default `~/Sites`. |
| `--mode auto\|persite` | Serving mode; see below. Default `auto`. |
| `--php-fpm <host:port>` | PHP-FPM address. Default `127.0.0.1:9000`. |
| `--skip-dns` | Leave `/etc/resolver` and dnsmasq alone. |
| `--switch` | Take an existing, incompatible setup down first. |
| `--uninstall` | Remove what ldev installed, then stop. |
| `--plain` | No menus, colour or emoji. Same as `NO_COLOR=1`. |
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
ldev apply       # re-render the server config and restart (auto mode)
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
| 🧱 **persite** | One Caddy per site on its own high port (8443, 8444, …), each with its own Caddyfile and certificate. See [docs/persite.md](docs/persite.md). | You already have per-site servers and want to keep them. |

Only **auto** makes a new site work with no configuration at all. `persite` is there so
that installing this does not tear down a setup that already works.

> ℹ️ An `apache` mode was named in an earlier config format and is **not supported**.
> Serving the TLD from httpd needs a vhost and a certificate per host — httpd has no
> on-demand issuance, and a `*.ldev` certificate is rejected by browsers for `shop.ldev` —
> which is a different product from "a folder is a site". The installer refuses it by
> name rather than accepting a mode nothing downstream implements.

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
| 🔤 A folder never appears | Its name cannot be a hostname — a space, or another character a `Host:` header cannot carry | `ldev list` counts these; rename them |
| 🧱 A per-site server "does not start" | Two sites sharing an admin port — the second exits silently | [docs/persite.md](docs/persite.md) |
| 🕳️ Every URL returns `000`, nothing in any log | Two topologies live at once: a mode was switched without the old one being taken down, so one process holds 80 and another holds 443, and whatever holds 443 has no site for that host | `./install.sh --switch`, or `./install.sh` and pick "switch" |

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
| system trust store | root | trusts the local CA, once |

Nothing is written anywhere else.

---

## 🧪 Tests

Plain bash, no framework. Each script sets up a throwaway tree, asserts, and cleans up:

```sh
bash test/auto-root.test.sh      # hostname → folder, both layouts, on a real Caddy
bash test/persite-new.test.sh    # ldev new writes a valid, non-colliding site config
bash test/persite-ports.test.sh  # the site/admin port allocator
bash test/tui-menu.test.sh       # the installer's menus and its whole question phase
```

They skip gracefully when `caddy` is not on the `PATH`, or when a port they need is busy.

`tui-menu.test.sh` drives the installer with a file of keystrokes in place of a keyboard,
so the arrow keys, the review screen and the abort paths are all exercised without a
terminal. Every run of `install.sh` inside it is pointed at a throwaway `HOME` and empty
stand-ins for the launchd directories, and `sudo`, `brew`, `launchctl`, `caddy`, `mkcert`
and `npm` are shadowed by stubs that record any attempt to a tripwire file — so "it needed
no sudo" is asserted rather than assumed. It runs under `/bin/bash`, which on macOS is
3.2, because the installer has to work before you have installed anything else.

---

## 🧹 Uninstall

```sh
./install.sh --uninstall
```

That removes what ldev installed — booting out the LaunchDaemon and any per-site
LaunchAgents, deleting the plist, the resolver file, the dnsmasq conf and
`~/.config/ldev` — and stops, without installing anything. It leaves the launchd label
*enabled*, because launchd keeps a per-label disabled record that survives both `bootout`
and deleting the plist, and a later reinstall would then fail with
`Bootstrap failed: 5: Input/output error`, which mentions neither the label nor the word
"disabled".

By hand, the reverse of the table above, in order:

```sh
sudo launchctl bootout system/com.ldev.caddy
sudo launchctl enable system/com.ldev.caddy   # or the next install fails, opaquely
sudo rm -f /Library/LaunchDaemons/com.ldev.caddy.plist
sudo rm -f /etc/resolver/ldev
rm -f "$(brew --prefix)/etc/dnsmasq.d/ldev.conf"
sudo brew services restart dnsmasq
rm -rf ~/.config/ldev ~/Library/Logs/ldev   # config and the generated Caddyfile
caddy untrust                    # optional: remove the local CA from the trust store
```

Then remove the `conf-dir` line `install.sh` appended to
`$(brew --prefix)/etc/dnsmasq.conf`, and drop `bin/` from your `PATH`.

**Your site folders are never touched** — uninstalling stops them being served, and
nothing more.

---

## 📄 License

No licence file yet. Add one before publishing this repo.
