#!/usr/bin/env bash
#
# ldev — install a wildcard local-development TLD on macOS.
#
#   ./install.sh                 interactive
#   ./install.sh --defaults      accept every default, prompt for nothing
#   ./install.sh --tld test --sites ~/Code --yes
#   ./install.sh --skip-dns      leave /etc/resolver and dnsmasq alone
#
# Everything it writes is listed at the end, and every root-owned change is
# announced before it happens.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
CONFIG_FILE="$HOME/.config/ldev/config"

# Defaults. Every one of these is overridable by flag or prompt.
TLD="ldev"
SITES="$HOME/Sites"
SKIP_DNS=0                    # --skip-dns: leave /etc/resolver and dnsmasq alone
PHP_FPM="127.0.0.1:9000"
ADMIN_PORT="2019"           # the wildcard server's own admin API
SITE_PORT_BASE="8443"       # base of the run a standalone site's port is taken from
ASK_PORT="2018"
LOGDIR="$HOME/Library/Logs/ldev"
ASSUME_YES=0
USE_DEFAULTS=0

# ---------------------------------------------------------------- output helpers

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'
else
  B=""; DIM=""; R=""; GRN=""; YEL=""; RED=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$GRN" "$R" "$B" "$*" "$R"; }
warn() { printf '%s warning:%s %s\n' "$YEL" "$R" "$*" >&2; }
die()  { printf '%s error:%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

ask() {
  # ask <prompt> <default> -> echoes the answer
  local prompt="$1" default="$2" reply=""
  if [ "$USE_DEFAULTS" = 1 ] || [ ! -t 0 ]; then printf '%s' "$default"; return; fi
  read -r -p "$prompt [$default]: " reply </dev/tty || true
  printf '%s' "${reply:-$default}"
}

# A prompt nobody can answer means NO.
#
# This used to return 0 — yes — when stdin was not a terminal, which made every unattended run
# approve things a human was being asked about, `sudo mkdir /etc/resolver` among them. Combined
# with `set -e` two lines up, the consequence was worse than a wrong answer: sudo has no tty to
# prompt on, fails, and the script dies at that line. The config file is written 110 lines later,
# so a headless run could only ever produce a half-configured machine — and `--defaults`, whose
# own help says "prompt for nothing", hit exactly that.
#
# Failing closed costs an unattended run the optional extras (it prints what to run instead, which
# every `else` branch here already does). `--yes` and `--defaults` still mean yes, explicitly, and
# that is the difference: a person said so, rather than nobody being there to say otherwise.
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || return 1
  local reply=""
  read -r -p "$1 [y/N]: " reply </dev/tty || true
  [[ "$reply" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --tld)      TLD="${2:?--tld needs a value}"; shift 2 ;;
    --sites)    SITES="${2:?--sites needs a value}"; shift 2 ;;
    # There is one serving mode now, so this flag has no answer to accept. Failing loudly
    # beats ignoring it: a script passing `--mode persite` was asking for an install with
    # nothing on 80/443, and silently giving it the opposite is worse than stopping.
    --mode)     die "--mode is gone: ldev now has a single serving mode. A site that needs its own server gets one with 'ldev standalone <name>', fronted by the wildcard server." ;;
    --php-fpm)  PHP_FPM="${2:?--php-fpm needs a value}"; shift 2 ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --skip-dns) SKIP_DNS=1; shift ;;
    --defaults) USE_DEFAULTS=1; ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '3,$p' "$0" | sed -n '/^#/!q; s/^# \{0,1\}//p'; exit 0 ;;
    *)          die "unknown option: $1 (try --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this installer targets macOS; it uses /etc/resolver and launchd."

# ---------------------------------------------------------------- 1. questions

step "Configuration"

if [ "$USE_DEFAULTS" != 1 ]; then
  TLD="$(ask "Local TLD (no dot)" "$TLD")"
  SITES="$(ask "Directory holding your sites" "$SITES")"
fi

TLD="${TLD#.}"                                  # tolerate ".ldev"
SITES="${SITES/#\~/$HOME}"                      # expand a typed ~

[[ "$TLD" =~ ^[a-z0-9-]+$ ]] || die "TLD must be one label of a-z, 0-9 and dashes — got '$TLD'."
case "$TLD" in
  com|net|org|dev|app|local|localhost)
    # .dev and .app are real, HSTS-preloaded TLDs: browsers force HTTPS to the
    # public internet and your local site becomes unreachable in confusing ways.
    # .local belongs to mDNS/Bonjour and will fight with it.
    warn "'$TLD' is a real or reserved TLD and will collide with public DNS or mDNS."
    confirm "Use '$TLD' anyway?" || die "aborted — pick something like 'ldev' or 'test'."
    ;;
esac

DASHBOARD="$REPO_DIR/dashboard/dist"

say ""
say "  TLD          .$TLD"
say "  Sites        $SITES"
say "  PHP-FPM      $PHP_FPM"
say "  Dashboard    $DASHBOARD"
say ""
confirm "Proceed with these settings?" || die "aborted."

# A previous install's ports are a DECISION, not a default. Somebody moves the admin port
# off 2019 precisely because something else already holds it, and a re-install that resets
# it to the built-in default re-creates the collision they fixed — silently, because a Caddy
# that cannot bind its admin API exits at startup rather than warning.
if [ -f "$CONFIG_FILE" ]; then
  prev="$(sed -n 's/^ADMIN_PORT=//p' "$CONFIG_FILE" | head -1)"
  [ -n "$prev" ] && ADMIN_PORT="$prev"
  prev="$(sed -n 's/^ASK_PORT=//p' "$CONFIG_FILE" | head -1)"
  [ -n "$prev" ] && ASK_PORT="$prev"
  prev="$(sed -n 's/^SITE_PORT_BASE=//p' "$CONFIG_FILE" | head -1)"
  [ -n "$prev" ] && SITE_PORT_BASE="$prev"
fi

# ---------------------------------------------------------------- 2. dependencies

step "Dependencies"

command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh"

# mkcert is no longer among these. It was here for the per-site mode, where every site
# needed a certificate of its own; the wildcard server issues one per host from Caddy's
# internal CA on first request, so nothing in a default install calls mkcert at all.
need=()
command -v dnsmasq >/dev/null 2>&1 || need+=(dnsmasq)
command -v caddy   >/dev/null 2>&1 || need+=(caddy)
command -v php     >/dev/null 2>&1 || need+=(php)

if [ ${#need[@]} -gt 0 ]; then
  say "Missing: ${need[*]}"
  if confirm "Install them with Homebrew now?"; then
    brew install "${need[@]}"
  else
    die "cannot continue without: ${need[*]}"
  fi
else
  say "All present."
fi

mkdir -p "$SITES" "$LOGDIR" "$(dirname "$CONFIG_FILE")"

# ---------------------------------------------------------------- 3. DNS

step "DNS — resolving *.$TLD to 127.0.0.1"

DNSMASQ_D="$BREW_PREFIX/etc/dnsmasq.d"
mkdir -p "$DNSMASQ_D"
cat > "$DNSMASQ_D/$TLD.conf" <<EOF
# ldev — generated. Resolves *.$TLD (and $TLD itself) to 127.0.0.1, so any
# subdomain works with no /etc/hosts entry per site.
address=/$TLD/127.0.0.1
EOF
say "wrote $DNSMASQ_D/$TLD.conf"

# dnsmasq.conf must actually read that directory — a stock Homebrew config does not.
DNSMASQ_CONF="$BREW_PREFIX/etc/dnsmasq.conf"
if [ -f "$DNSMASQ_CONF" ] && ! grep -q "^conf-dir=$DNSMASQ_D" "$DNSMASQ_CONF" 2>/dev/null; then
  printf '\n# ldev\nconf-dir=%s,*.conf\n' "$DNSMASQ_D" >> "$DNSMASQ_CONF"
  say "added conf-dir to $DNSMASQ_CONF"
fi

# /etc/resolver tells macOS to ask dnsmasq for this TLD specifically. Root-owned.
say ""
# Already done is a normal state, not a reason to ask for a password again. Detecting it lets an
# unattended run finish: --defaults answers yes to everything, and yes here means a sudo that has
# no terminal to prompt on, which under `set -e` kills the run 110 lines before the config is
# written. --skip-dns is the explicit form of the same thing.
if [ "$SKIP_DNS" = 1 ]; then
  say "Skipping the resolver and dnsmasq step (--skip-dns)."
elif [ -f "/etc/resolver/$TLD" ] && pgrep -x dnsmasq >/dev/null 2>&1; then
  say "/etc/resolver/$TLD already exists and dnsmasq is running — nothing to do here."
else
  say "Next step needs sudo: writing /etc/resolver/$TLD and starting dnsmasq as root."
  say "  (dnsmasq must run as root to bind port 53.)"
  if confirm "Run these now?"; then
    sudo mkdir -p /etc/resolver
    printf 'nameserver 127.0.0.1\n' | sudo tee "/etc/resolver/$TLD" >/dev/null
    sudo brew services restart dnsmasq >/dev/null
    say "done."
  else
    cat <<EOF

${YEL}Run these yourself before the TLD will resolve:${R}
  sudo mkdir -p /etc/resolver
  echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/$TLD
  sudo brew services restart dnsmasq
EOF
  fi
fi

# ---------------------------------------------------------------- 4. certificates

step "Certificates"

# One certificate per host, issued from Caddy's own CA the first time that host is asked
# for. Trusting the CA once is what makes every future site work with no certificate step.
say "Each host gets its own certificate from Caddy's local CA, issued on first request."
say "Trusting that CA (needs sudo, once):"
if confirm "Install Caddy's local CA into the system trust store?"; then
  caddy trust || warn "caddy trust failed — sites will load but show a warning."
fi

# ---------------------------------------------------------------- 5. dashboard

step "Dashboard"

if [ -d "$REPO_DIR/dashboard" ]; then
  if [ ! -d "$REPO_DIR/dashboard/node_modules" ]; then
    say "Installing dashboard dependencies..."
    ( cd "$REPO_DIR/dashboard" && npm install --silent )
  fi
  say "Building dashboard..."
  ( cd "$REPO_DIR/dashboard" && npm run build --silent ) || warn "dashboard build failed; the fallback will 404."
else
  warn "no dashboard/ directory in this repo — the fallback will 404."
fi

# ---------------------------------------------------------------- 6. paths

CADDY_BIN="$(command -v caddy || echo "$BREW_PREFIX/bin/caddy")"
CADDYFILE="$HOME/.config/ldev/Caddyfile"

# ---------------------------------------------------------------- 7. server config

# ------------------------------------------------- 7a. the installation being replaced

step "Existing installation"

# Whatever already answers for this TLD has to come down before ldev's own daemon goes up,
# and finding it is the installer's job. It used not to be: an install that changed the
# topology wrote its config, installed its daemon, and left the previous one running — so
# both were live, one held 80, the other held 443, and the bare https://<tld>/ URL answered
# from neither while the install reported success.
#
# Per-site servers on high ports are deliberately NOT touched. They are fronted by the
# wildcard server now rather than replaced by it, so stopping them would take down the
# sites this install is meant to make reachable.

# A port's listener, or empty. lsof exits non-zero when it can see nothing — INCLUDING a
# root-owned socket an unprivileged user cannot inspect, which is exactly the case here —
# and this script runs under `set -e` with pipefail, so the failure is swallowed on
# purpose. An earlier version of this check ended in an unguarded lsof|awk pipeline and
# killed the installer on any machine with something already on port 80.
port_owner() {
  local out=""
  out="$(lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1; exit}')" || true
  printf '%s' "$out"
}

port_busy() { nc -z 127.0.0.1 "$1" 2>/dev/null; }

# launchd jobs that serve this TLD, one plist path per line.
#
# Matched by CONTENT, never by filename. The job doing this on the machine that motivated
# the check was called com.bryce.caddy-matsu — nothing in that name says ldev, or caddy's
# role, or which TLD it serves, and a filename convention is not something an installer
# gets to assume about a file somebody else wrote.
ldev_launchd_jobs() {
  local f
  for f in /Library/LaunchDaemons/*.plist "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$f" ] || continue
    grep -qi "caddy" "$f" 2>/dev/null || continue
    if grep -qF "$HOME/.config/ldev" "$f" 2>/dev/null \
    || grep -qF "$SITES" "$f" 2>/dev/null \
    || grep -qF ".$TLD" "$f" 2>/dev/null; then
      printf '%s\n' "$f"
    fi
  done
}

plist_label() {
  /usr/libexec/PlistBuddy -c 'Print :Label' "$1" 2>/dev/null || basename "$1" .plist
}

# Does this launchd job want port 80 or 443?
#
# This is the difference between the job ldev is REPLACING and the ones it is about to
# start fronting. A per-site server on 8443 is not in the way — the wildcard server proxies
# to it — and removing it would take down the very site this install is meant to make
# reachable portlessly. Only a job holding a privileged port has to go.
#
# The answer is in the Caddyfile the job runs, not in the plist: a Caddy site address with
# no port means 443, `http://` means 80, and anything else names its port outright.
job_wants_privileged_port() {
  local plist="$1" cfg="" line addr
  # The config path is whichever ProgramArguments entry looks like a Caddyfile.
  cfg="$(grep -oE '<string>[^<]*Caddyfile[^<]*</string>' "$plist" 2>/dev/null \
        | sed -E 's|</?string>||g' | head -1)" || true
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 1   # cannot tell — treat as not in the way

  # Real address lines only: not comments, and ending in the `{` that opens a site block.
  # The keyless global block `{` is excluded, or every file would look like an address.
  while IFS= read -r line; do
    # Per ADDRESS, not per line. A Caddy address line can carry several, and each is
    # INDEPENDENT: in `matsu.ldev, matsu-dev.ldev:8444 {` the neighbour is on 8444 and
    # matsu.ldev is on the default 443. Reading the first port on the LINE would call that
    # file unprivileged and leave the job holding 443 in place — which is the entire
    # failure this check exists to prevent.
    line="${line%\{}"
    for addr in ${line//,/ }; do
      case "$addr" in
        "") continue ;;
        *:80|*:443)  return 0 ;;                 # names a privileged port outright
        http://*:*)  continue ;;                 # http:// with an explicit port
        http://*)    return 0 ;;                 # http:// with none means 80
        https://*:*) continue ;;
        https://*)   return 0 ;;                 # https:// with none means 443
        *:[0-9]*)    continue ;;                 # some other port
        *)           return 0 ;;                 # bare host, no port: https on 443
      esac
    done
  done <<EOF
$(grep -vE '^[[:space:]]*#' "$cfg" 2>/dev/null | grep -E '\{[[:space:]]*$' | grep -vE '^[[:space:]]*\{[[:space:]]*$' || true)
EOF
  return 1
}

ALL_JOBS="$(ldev_launchd_jobs || true)"

# Only the jobs holding 80 or 443 are in the way. The rest are per-site servers this
# install is about to put BEHIND the wildcard one, and they keep running.
EXISTING=""
KEPT=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if job_wants_privileged_port "$f"; then
    EXISTING="$EXISTING$f"$'\n'
  else
    KEPT="$KEPT$f"$'\n'
  fi
done <<EOF
$ALL_JOBS
EOF
EXISTING="${EXISTING%$'\n'}"
KEPT="${KEPT%$'\n'}"
OWNER_80="$(port_owner 80)"
OWNER_443="$(port_owner 443)"

if [ -n "$KEPT" ]; then
  n=0
  while IFS= read -r f; do [ -n "$f" ] && n=$((n + 1)); done <<EOF
$KEPT
EOF
  say "$n per-site server(s) on high ports — left running, the wildcard server will proxy to them."
fi

if [ -z "$EXISTING" ] && ! port_busy 80 && ! port_busy 443; then
  say "Nothing else holds ports 80 or 443."
else
  say "Found something already serving, or already holding the ports ldev needs:"
  say ""
  if [ -n "$EXISTING" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      say "  launchd  $(plist_label "$f")"
      say "           $f"
    done <<EOF
$EXISTING
EOF
  fi
  # A busy port with no plist behind it is somebody's `caddy run` in a terminal, or a
  # server this installer has no business removing. Name it and stop, rather than guess.
  for prt in 80 443; do
    if port_busy "$prt"; then
      owner="$(port_owner "$prt")"
      say "  port $prt  ${owner:-held by a process this user cannot see (root-owned)}"
    fi
  done
  say ""

  if [ -n "$EXISTING" ]; then
    say "Removing these stops them serving and deletes their plist. Site FOLDERS are"
    say "never touched, and per-site servers on high ports keep running — the new"
    say "wildcard server proxies to them rather than replacing them."
    if confirm "Take them down?"; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        label="$(plist_label "$f")"
        case "$f" in
          /Library/LaunchDaemons/*)
            sudo launchctl bootout "system/$label" 2>/dev/null || true
            # launchd keeps a per-label DISABLED record that outlives both bootout and
            # deleting the plist, and a later bootstrap of that label then fails with
            # "Bootstrap failed: 5: Input/output error" — a message naming neither the
            # label nor the word disabled. Leave the label clean on the way out.
            sudo launchctl enable "system/$label" 2>/dev/null || true
            sudo rm -f "$f"
            ;;
          *)
            launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
            launchctl enable "gui/$(id -u)/$label" 2>/dev/null || true
            rm -f "$f"
            ;;
        esac
        say "  removed $label"
      done <<EOF
$EXISTING
EOF
      # launchd unloads asynchronously; bootstrapping into a port the old job has not let
      # go of yet fails in a way that reads as a port conflict with nothing visible on it.
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        port_busy 80 || port_busy 443 || break
        sleep 1
      done
      if port_busy 80 || port_busy 443; then
        warn "ports 80/443 are still busy after removing those jobs — something else holds them."
      else
        say "  ports 80 and 443 are free."
      fi
    else
      warn "Left in place. The ldev daemon will fail to bind whichever port they hold."
    fi
  else
    warn "No launchd job explains this, so there is nothing here safe to remove."
    say  "Stop whatever holds the port yourself, then re-run this installer."
  fi
fi

# The wildcard server's own two ports, chosen AFTER the takedown — before it, a port held
# by the job about to be removed looks taken and would be skipped for no reason.
#
# Caddy binds its admin API at startup and EXITS if it cannot, without warning, so a
# collision here is a server that never comes up and never says why. The site that hit this
# was seasonal-drops, whose own Caddy holds 2019: the installer's default.
free_port_from() {
  local p="$1" n=0
  while [ "$n" -lt 100 ]; do
    port_busy "$p" || { printf '%s' "$p"; return 0; }
    p=$((p + 1)); n=$((n + 1))
  done
  printf '%s' "$1"
}

new_admin="$(free_port_from "$ADMIN_PORT")"
if [ "$new_admin" != "$ADMIN_PORT" ]; then
  warn "admin port $ADMIN_PORT is already in use — using $new_admin instead."
  ADMIN_PORT="$new_admin"
fi
new_ask="$(free_port_from "$ASK_PORT")"
if [ "$new_ask" != "$ASK_PORT" ]; then
  warn "ask port $ASK_PORT is already in use — using $new_ask instead."
  ASK_PORT="$new_ask"
fi

# Written here rather than earlier because the ports above are only knowable now, and
# `ldev render` two steps down reads this file for them.
cat > "$CONFIG_FILE" <<EOF
# ldev — written by install.sh on $(date '+%Y-%m-%d %H:%M:%S')
TLD=$TLD
SITES=$SITES
PHP_FPM=$PHP_FPM
DASHBOARD=$DASHBOARD
ADMIN_PORT=$ADMIN_PORT
SITE_PORT_BASE=$SITE_PORT_BASE
ASK_PORT=$ASK_PORT
LOGDIR=$LOGDIR
REPO_DIR=$REPO_DIR
EOF
say "wrote $CONFIG_FILE (admin $ADMIN_PORT, ask $ASK_PORT)"

# ---------------------------------------------------------------- 7b. server configuration

step "Server configuration"

render() {
  sed -e "s|__TLD__|$TLD|g" \
      -e "s|__SITES__|$SITES|g" \
      -e "s|__DASHBOARD__|$DASHBOARD|g" \
      -e "s|__PHP_FPM__|$PHP_FPM|g" \
      -e "s|__ADMIN_PORT__|$ADMIN_PORT|g" \
      -e "s|__ASK_PORT__|$ASK_PORT|g" \
      -e "s|__LOGDIR__|$LOGDIR|g" \
      -e "s|__CADDY_BIN__|$CADDY_BIN|g" \
      -e "s|__CADDYFILE__|$CADDYFILE|g" \
      -e "s|__HOME__|$HOME|g" \
      "$1"
}

# `ldev render` rather than a render() call here, because the wildcard Caddyfile is not a
# straight substitution any more: it carries a generated proxy block for every site that
# runs its own server, and that generator lives in bin/ldev. Rendering it twice, in two
# languages, is how the two would drift.
"$REPO_DIR/bin/ldev" render || die "could not render $CADDYFILE"

say ""
say "Ports 80 and 443 are privileged, so Caddy needs to start via launchd as root."
if confirm "Install and start the ldev launchd service?"; then
  PLIST=/Library/LaunchDaemons/com.ldev.caddy.plist
  render "$REPO_DIR/templates/com.ldev.caddy.plist.tmpl" | sudo tee "$PLIST" >/dev/null
  sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
  sudo launchctl bootout system/com.ldev.caddy 2>/dev/null || true
  # If this label was ever booted out and its plist deleted, launchd still holds a disabled
  # record for it and bootstrap fails with "Bootstrap failed: 5: Input/output error" — which
  # names neither the label nor the word disabled, so it reads as a broken plist. Enabling
  # first is a no-op when there is no such record, and the fix when there is.
  sudo launchctl enable system/com.ldev.caddy 2>/dev/null || true
  sudo launchctl bootstrap system "$PLIST"
  say "service started."
else
  say ""
  say "${YEL}Nothing will answer on 80 or 443 until it runs. Start it yourself with:${R}"
  say "  sudo caddy run --config $CADDYFILE"
fi

# ---------------------------------------------------------------- 8. PATH

step "PATH"

# Which file, and which SYNTAX, depends on the shell, and guessing is worse than not
# offering: a line appended to ~/.zshrc does nothing for a bash or fish user, who is then
# told their PATH is set while their shell still cannot find ldev. Only shells whose
# startup file and export syntax are known get an offer; anything else is printed for the
# reader to place, because they know where their own config lives and this script does not.
#
# $SHELL is the LOGIN shell — what a new terminal window starts — which is the right
# question here. The shell currently running this script is bash either way.
shell_rc() {
  case "${SHELL##*/}" in
    zsh)  printf '%s' "$HOME/.zshrc" ;;
    # macOS Terminal opens LOGIN shells, and a login bash reads .bash_profile and pointedly
    # does NOT read .bashrc. Writing to .bashrc is the classic way to make this silently
    # not work on a Mac.
    bash) if [ -f "$HOME/.bash_profile" ]; then printf '%s' "$HOME/.bash_profile"
          else printf '%s' "$HOME/.profile"; fi ;;
    fish) printf '%s' "$HOME/.config/fish/config.fish" ;;
    ksh)  printf '%s' "$HOME/.kshrc" ;;
    *)    printf '' ;;
  esac
}

# fish is not POSIX and `export PATH="...:$PATH"` is a syntax error in it. fish_add_path is
# also idempotent, so re-running the installer cannot stack duplicates the way the export
# line would.
path_line() {
  case "${SHELL##*/}" in
    fish) printf 'fish_add_path %s' "$REPO_DIR/bin" ;;
    *)    printf 'export PATH="%s:$PATH"' "$REPO_DIR/bin" ;;
  esac
}

RC="$(shell_rc)"
LINE="$(path_line)"
FOUND="$(command -v ldev 2>/dev/null || true)"

if [ "$FOUND" = "$REPO_DIR/bin/ldev" ]; then
  say "Already on your PATH — ldev resolves to $FOUND."
elif [ -n "$FOUND" ]; then
  # A different checkout wins the name. Adding ours would not change that, since the
  # existing entry comes first, so say which one answers rather than appearing to fix it.
  warn "'ldev' already resolves to $FOUND, which is not this checkout."
  say  "This one is $REPO_DIR/bin/ldev — call it by full path, or reorder your PATH."
elif [ -z "$RC" ]; then
  say "Shell '${SHELL##*/}' is not one this script knows how to edit."
  say "Add $REPO_DIR/bin to your PATH in its startup file:"
  say "  $LINE"
elif [ -f "$RC" ] && grep -qF "$REPO_DIR/bin" "$RC"; then
  say "$RC already adds it. Open a new terminal, or: source $RC"
else
  say "ldev lives in $REPO_DIR/bin, which is not on your PATH."
  say "This would append to $RC:"
  say ""
  say "  $LINE"
  say ""
  if confirm "Add it?"; then
    mkdir -p "$(dirname "$RC")"        # fish's config directory may not exist yet
    printf '\n# ldev\n%s\n' "$LINE" >> "$RC"
    say "added to $RC — run 'source $RC', or open a new terminal."
  else
    say "${YEL}Add it yourself:${R}"
    say "  echo '$LINE' >> $RC"
  fi
fi

# ---------------------------------------------------------------- 9. report

step "Done"
cat <<EOF

  Config      $CONFIG_FILE
  Dashboard   https://$TLD/          (and any name with no directory behind it)
  A new site  mkdir $SITES/<name>    ->  https://<name>.$TLD
              the .$TLD suffix on the directory is optional; both are served

  Its own server, for a site that needs one — a different PHP version, its own
  certificate, a proxy to a running app, restarts that leave the others alone:
              $REPO_DIR/bin/ldev standalone <name>

  Check it:   $REPO_DIR/bin/ldev doctor
              (or just 'ldev doctor', if the PATH step above added it)

EOF
