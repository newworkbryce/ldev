# Apache mode

httpd vhosts generated from your site folders. Pick this when Apache is already the local
web server and you are not willing to hand ports 80 and 443 to Caddy for a dev TLD —
which is a reasonable thing not to be willing to do.

## What is generated

`ldev apply` writes one file, `~/.config/ldev/httpd-vhosts.conf`, containing:

| Block | What it serves |
|---|---|
| `<VirtualHost *:443>` for the bare TLD | The dashboard. **First**, so it is also what an unknown https host reaches. |
| `<VirtualHost *:80>` with `ServerAlias *.<tld>` | Every site, over HTTP. `VirtualDocumentRoot` derives the root from the hostname. |
| one `<VirtualHost *:443>` per site | That site over HTTPS, naming its own certificate. |

Certificates live in `~/.config/ldev/certs/`, one pair per host, issued by `mkcert` and
reused on later runs.

## Why HTTP and HTTPS are not symmetric

Apache has no equivalent of Caddy's on-demand issuance: a vhost names its certificate in
the config, so a host with no vhost has no certificate. A wildcard is not a way out —
browsers reject a `*.ldev` certificate for `shop.ldev`, because `.ldev` is a single label,
with `ERR_CERT_COMMON_NAME_INVALID`.

So:

    mkdir ~/Sites/shop     # http://shop.ldev  works now
    ldev apply             # https://shop.ldev works now

That one command is the whole difference from auto mode. `ldev new <name>` says so on the
way out rather than leaving you to discover it.

## Folder layouts

Both layouts work, and the plain folder wins — the same precedence as auto mode, so a
site does not change meaning when the serving mode does:

| Folder | Host |
|---|---|
| `~/Sites/shop` | `shop.ldev` |
| `~/Sites/shop.ldev` | `shop.ldev` |

If both exist, only one vhost is written, for `~/Sites/shop`. Writing two vhosts with the
same `ServerName` would not be an error Apache reports — it takes the first and ignores
the rest, so the symptom would be a site serving the wrong directory in silence.

Over HTTP the same precedence is done with `mod_rewrite`, in the wildcard vhost. The site
name is stashed in an env var (`LDEV_SITE`) rather than used as a `%1` backreference,
because `%N` refers to the *last* `RewriteCond` that matched — and the directory tests
that follow would quietly redefine it.

## Requirements this mode adds

Modules, all of which a stock Homebrew `httpd.conf` ships commented out:

    mod_vhost_alias  mod_rewrite  mod_proxy  mod_proxy_fcgi  mod_ssl  mod_socache_shmcb

A missing one does not announce itself as missing. httpd refuses to start with
`Invalid command 'VirtualDocumentRoot'`, which reads as a typo in a config file you did
not write. `install.sh` offers to uncomment them (backing up `httpd.conf` first), and
`ldev doctor` names any that are still not loaded.

httpd must also **listen on 80 and 443** — Homebrew's default is 8080 — and run as root
to bind them:

    sudo brew services start httpd

The generated file deliberately contains no `Listen` directive. A duplicate `Listen` for
a port `httpd.conf` already has is a fatal startup error, and taking down the machine's
web server to add a dev TLD is not a trade worth making.

## Applying changes safely

`ldev apply` renders to a temporary file, runs `httpd -t` against it in isolation, and
only then replaces the live one. The isolation matters in both directions: checking the
machine's whole `httpd.conf` would fail for reasons unrelated to this file, and cannot be
run at all before the `Include` line exists.

If the check fails, the previous file is left in place and the error is printed. A vhost
file that does not parse does not break one site — it stops httpd starting at all.

Then it reloads gracefully (`apachectl -k graceful`), falling back to a full
`brew services restart httpd`. Graceful is the default because in this mode httpd is
serving more than ldev.

## Compared with auto mode

| | auto | apache |
|---|---|---|
| processes | one Caddy | your existing httpd |
| new folder over HTTP | immediate | immediate |
| new folder over HTTPS | immediate | after `ldev apply` |
| certificates | issued per host on first request | issued per host by `ldev apply` |
| unknown hostname | the dashboard | the dashboard (with a certificate warning over HTTPS) |
| config it owns | `~/.config/ldev/Caddyfile` | `~/.config/ldev/httpd-vhosts.conf` |
