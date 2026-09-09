#!/usr/bin/env bash
#
# ldev — install a wildcard local-development TLD on macOS.
#
# Interactive by default: arrow-key menus, a review screen you can go back into,
# and every root-owned change announced before it happens. Everything it writes
# is listed at the end.
#
# Run ./install.sh --help for the flags.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
CONFIG_FILE="$HOME/.config/ldev/config"

# shellcheck source=lib/tui.sh
. "$REPO_DIR/lib/tui.sh"

# Defaults. Every one of these is overridable by flag or prompt.
TLD="ldev"
SITES="$HOME/Sites"
MODE=""                       # auto | persite
MODE_FROM_FLAG=0
SKIP_DNS=0                    # --skip-dns: leave /etc/resolver and dnsmasq alone
PHP_FPM="127.0.0.1:9000"
ADMIN_PORT="2019"             # persite: base of the admin-port run (2019, 2020, ...)
SITE_PORT_BASE="8443"         # persite: base of the site-port run (8443, 8444, ...)
ASK_PORT="2018"
LOGDIR="$HOME/Library/Logs/ldev"
ASSUME_YES=0
USE_DEFAULTS=0

usage() {
  cat <<EOF
ldev installer — a wildcard local-development TLD for macOS

  ./install.sh                      interactive (arrow keys, review screen)
  ./install.sh --defaults           accept every default, prompt for nothing
  ./install.sh --tld test --sites ~/Code --mode auto --yes
  ./install.sh --mode persite --skip-dns

Options
  --tld <name>       local TLD, one label, no dot          (default: $TLD)
  --sites <dir>      directory holding your sites          (default: $SITES)
  --mode <mode>      auto | persite                        (default: asked)
  --php-fpm <addr>   PHP-FPM address                       (default: $PHP_FPM)
  --skip-dns         leave /etc/resolver and dnsmasq alone
  -y, --yes          answer yes to every optional step
  --defaults         take every default and imply --yes
  --plain            no menus, colour or emoji (also: NO_COLOR=1)
  -h, --help         this
EOF
}

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --tld)      TLD="${2:?--tld needs a value}"; shift 2 ;;
    --sites)    SITES="${2:?--sites needs a value}"; shift 2 ;;
    --mode)     MODE="${2:?--mode needs a value}"; MODE_FROM_FLAG=1; shift 2 ;;
    --php-fpm)  PHP_FPM="${2:?--php-fpm needs a value}"; shift 2 ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --skip-dns) SKIP_DNS=1; shift ;;
    --defaults) USE_DEFAULTS=1; ASSUME_YES=1; shift ;;
    --plain)    LDEV_PLAIN=1; export LDEV_PLAIN; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          printf 'error: unknown option: %s (try --help)\n' "$1" >&2; exit 1 ;;
  esac
done

# --defaults means nobody is at the keyboard, so there is nothing to draw.
[ "$USE_DEFAULTS" = 1 ] && { LDEV_PLAIN=1; export LDEV_PLAIN; }

tui_init

die() { printf '\n %s %s%s%s\n' "$G_NO" "$C_RED" "$*" "$C_R" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this installer targets macOS; it uses /etc/resolver and launchd."

# ask <prompt> <default> [hint] -> the answer in ANSWER; 1 at end of input.
#
# The answer arrives in a variable rather than on stdout, and callers must not
# wrap this in $(...). Two reasons, both of which cost a working installer once:
# the prompt itself is printed on stdout, so capturing the output captures the
# prompt as part of the answer and every validation loop then rejects the value
# the user just typed; and a command substitution is a subshell, so TUI_EOF set
# inside it would never reach the loop that has to stop when input runs out.
ANSWER=""
ask() {
  local rc=0
  ANSWER="$2"
  if [ "$USE_DEFAULTS" = 1 ]; then return 0; fi
  tui_input "$1" "$2" "${3:-}" || rc=$?
  ANSWER="$TUI_VALUE"
  return "$rc"
}

# A prompt nobody can answer means NO.
#
# This used to return 0 — yes — when stdin was not a terminal, which made every unattended run
# approve things a human was being asked about, `sudo mkdir /etc/resolver` among them. Combined
# with `set -e` above, the consequence was worse than a wrong answer: sudo has no tty to prompt
# on, fails, and the script dies at that line. The config file is written 150 lines later, so a
# headless run could only ever produce a half-configured machine — and `--defaults`, whose own
# help says "prompt for nothing", hit exactly that.
#
# Failing closed costs an unattended run the optional extras (it prints what to run instead, which
# every `else` branch here already does). `--yes` and `--defaults` still mean yes, explicitly, and
# that is the difference: a person said so, rather than nobody being there to say otherwise.
confirm() { # confirm <question> [yes|no]
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$TUI_INTERACTIVE" = 1 ] || return 1
  menu_confirm "$1" "${2:-no}"
}

ui_banner "ldev — a wildcard local-development TLD for macOS" \
          "Every root-owned change is announced before it happens, and nothing is written until you say go."

# ---------------------------------------------------------------- 1. questions

ui_step "$G_GEAR" "Configuration"

valid_tld() { [[ "$1" =~ ^[a-z0-9-]+$ ]]; }

# .dev and .app are real, HSTS-preloaded TLDs: browsers force HTTPS to the public
# internet and the local site becomes unreachable in confusing ways. .local belongs
# to mDNS/Bonjour and will fight with it.
reserved_tld() {
  case "$1" in com|net|org|dev|app|local|localhost) return 0 ;; esac
  return 1
}

edit_tld() {
  local candidate
  while :; do
    ask "Local TLD" "$TLD" "one label, no dot — sites will live at https://<name>.<tld>" \
      || die "aborted — end of input while asking for the TLD."
    candidate="$ANSWER"
    candidate="${candidate#.}"                     # tolerate ".ldev"
    if ! valid_tld "$candidate"; then
      if [ "$TUI_INTERACTIVE" = 1 ]; then
        ui_bad "'$candidate' is not one label of a-z, 0-9 and dashes."
        continue
      fi
      die "TLD must be one label of a-z, 0-9 and dashes — got '$candidate'."
    fi
    if reserved_tld "$candidate"; then
      ui_warn "'$candidate' is a real or reserved TLD and will collide with public DNS or mDNS."
      if confirm "Use '.$candidate' anyway?" "no"; then TLD="$candidate"; return 0; fi
      [ "$TUI_INTERACTIVE" = 1 ] || die "aborted — pick something like 'ldev' or 'test'."
      continue
    fi
    TLD="$candidate"
    return 0
  done
}

# The sites directory is nearly always one of a handful of places, so offer those
# and keep the free-text field for everyone else.
edit_sites() {
  if [ "$TUI_INTERACTIVE" != 1 ]; then
    ask "Directory holding your sites" "$SITES" || die "aborted — end of input."
    SITES="$ANSWER"
    SITES="${SITES/#\~/$HOME}"
    return 0
  fi
  local cands=() c seen args=()
  for c in "$SITES" "$HOME/Sites" "$HOME/Code" "$HOME/Projects" "$HOME/Developer" "$HOME/Documents/Sites"; do
    [ "$c" = "$SITES" ] || [ -d "$c" ] || continue
    seen=0
    for existing in "${cands[@]:-}"; do [ "$existing" = "$c" ] && seen=1; done
    [ "$seen" = 1 ] || cands+=("$c")
  done
  for c in "${cands[@]}"; do
    if [ -d "$c" ]; then
      args+=("$G_FOLDER ${c/#$HOME/~}" "exists $G_DOT $(ls -1 "$c" 2>/dev/null | wc -l | tr -d ' ') entries")
    else
      args+=("$G_FOLDER ${c/#$HOME/~}" "will be created")
    fi
  done
  args+=("$G_PENCIL Somewhere else…" "type a path")
  menu_select "Where do your sites live?" 0 "${args[@]}" || die "aborted."
  if [ "$MENU_CHOICE" -lt "${#cands[@]}" ]; then
    SITES="${cands[$MENU_CHOICE]}"
  else
    ask "Directory holding your sites" "$SITES" || die "aborted — end of input."
    SITES="$ANSWER"
  fi
  SITES="${SITES/#\~/$HOME}"
  return 0
}

edit_mode() {
  local d=0
  case "$MODE" in persite) d=1 ;; esac
  menu_select "How should sites be served?" "$d" \
    "$G_ROCKET auto      one Caddy owns 80 and 443    (recommended)" \
"One Caddy serves every *.$TLD name. A directory at $SITES/<name>
is served at https://<name>.$TLD, with a certificate issued on first
request; unknown names fall back to the dashboard.
Adding a site is creating a folder." \
    "$G_PKG persite   one Caddy per site, high ports" \
"One Caddy per site on its own port pair (8443, 8444 ...). Nothing
owns 443, and each site needs its own Caddyfile and certificate.
Choose this to preserve an existing per-site setup." \
    || die "aborted."
  case "$MENU_CHOICE" in
    0) MODE="auto" ;;
    1) MODE="persite" ;;
  esac
}

edit_php() {
  ask "PHP-FPM address" "$PHP_FPM" "host:port, or a unix socket path" \
    || die "aborted — end of input."
  PHP_FPM="$ANSWER"
}

if [ "$USE_DEFAULTS" != 1 ]; then
  edit_tld
  edit_sites
fi
TLD="${TLD#.}"
SITES="${SITES/#\~/$HOME}"
valid_tld "$TLD" || die "TLD must be one label of a-z, 0-9 and dashes — got '$TLD'."
if [ "$USE_DEFAULTS" = 1 ] && reserved_tld "$TLD"; then
  ui_warn "'$TLD' is a real or reserved TLD and will collide with public DNS or mDNS."
fi

if [ -z "$MODE" ]; then
  if [ "$TUI_INTERACTIVE" = 1 ]; then edit_mode; else MODE="auto"; fi
fi
case "$MODE" in
  auto|persite) ;;
  # Named explicitly rather than folded into the catch-all: a script that still
  # passes --mode apache should be told the mode is gone, not told it is a typo.
  # It was removed because it never worked — the arm rendered a template that
  # exists in no revision of this repo, so `set -e` killed the install there.
  apache) die "mode 'apache' has been removed — it rendered a template that never existed. Use auto, or persite for a site that runs its own server." ;;
  *) die "unknown mode '$MODE' — pick auto or persite." ;;
esac

DASHBOARD="$REPO_DIR/dashboard/dist"

# ---------------------------------------------------------------- 1b. review

show_summary() {
  printf '\n %s%s %sReview%s\n\n' "$G_LIST" "" "$C_B" "$C_R"
  ui_kv "TLD"       ".$TLD"
  ui_kv "Sites"     "$SITES"
  ui_kv "Mode"      "$MODE"
  ui_kv "PHP-FPM"   "$PHP_FPM"
  ui_kv "Dashboard" "$DASHBOARD"
  printf '\n %s%sWhat this will write%s\n\n' "$C_B" "" "$C_R"
  ui_item "$CONFIG_FILE"
  ui_item "$BREW_PREFIX/etc/dnsmasq.d/$TLD.conf"
  [ "$SKIP_DNS" = 1 ] || ui_item "/etc/resolver/$TLD  $C_DIM(root)$C_R"
  case "$MODE" in
    auto)    ui_item "$HOME/.config/ldev/Caddyfile"
             ui_item "/Library/LaunchDaemons/com.ldev.caddy.plist  $C_DIM(root)$C_R" ;;
    persite) ui_item "nothing global — one Caddyfile per site, written by ldev new" ;;
  esac
  printf '\n'
}

if [ "$TUI_INTERACTIVE" = 1 ]; then
  while :; do
    show_summary
    menu_select "Ready?" 0 \
      "$G_OK Install with these settings" "" \
      "$G_PENCIL Change the TLD"           "currently .$TLD" \
      "$G_PENCIL Change the sites directory" "currently $SITES" \
      "$G_PENCIL Change the mode"          "currently $MODE" \
      "$G_PENCIL Change the PHP-FPM address" "currently $PHP_FPM" \
      "$G_NO Quit without changing anything" "" \
      || die "aborted."
    case "$MENU_CHOICE" in
      0) break ;;
      1) edit_tld ;;
      2) edit_sites ;;
      3) edit_mode ;;
      4) edit_php ;;
      5) die "aborted — nothing was written." ;;
    esac
  done
else
  show_summary
  confirm "Proceed with these settings?" "yes" || die "aborted."
fi

# ---------------------------------------------------------------- 2. dependencies

ui_step "$G_PKG" "Dependencies"

command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh"

need=()
command -v dnsmasq >/dev/null 2>&1 || need+=(dnsmasq)
command -v mkcert  >/dev/null 2>&1 || need+=(mkcert)
command -v caddy >/dev/null 2>&1 || need+=(caddy)
command -v php >/dev/null 2>&1 || need+=(php)

if [ ${#need[@]} -gt 0 ]; then
  ui_info "Missing: ${C_B}${need[*]}${C_R}"
  # brew's own output is the progress bar here; a spinner would only hide it.
  if confirm "Install them with Homebrew now?" "yes"; then
    brew install "${need[@]}"
  else
    die "cannot continue without: ${need[*]}"
  fi
else
  ui_ok "everything ldev needs is already installed"
fi

mkdir -p "$SITES" "$LOGDIR" "$(dirname "$CONFIG_FILE")"

# ---------------------------------------------------------------- 3. DNS

ui_step "$G_NET" "DNS — resolving *.$TLD to 127.0.0.1"

DNSMASQ_D="$BREW_PREFIX/etc/dnsmasq.d"
mkdir -p "$DNSMASQ_D"
cat > "$DNSMASQ_D/$TLD.conf" <<EOF
# ldev — generated. Resolves *.$TLD (and $TLD itself) to 127.0.0.1, so any
# subdomain works with no /etc/hosts entry per site.
address=/$TLD/127.0.0.1
EOF
ui_wrote "$DNSMASQ_D/$TLD.conf"

# dnsmasq.conf must actually read that directory — a stock Homebrew config does not.
DNSMASQ_CONF="$BREW_PREFIX/etc/dnsmasq.conf"
if [ -f "$DNSMASQ_CONF" ] && ! grep -q "^conf-dir=$DNSMASQ_D" "$DNSMASQ_CONF" 2>/dev/null; then
  printf '\n# ldev\nconf-dir=%s,*.conf\n' "$DNSMASQ_D" >> "$DNSMASQ_CONF"
  ui_wrote "conf-dir line in $DNSMASQ_CONF"
fi

# /etc/resolver tells macOS to ask dnsmasq for this TLD specifically. Root-owned.
#
# Already done is a normal state, not a reason to ask for a password again. Detecting it lets an
# unattended run finish: --defaults answers yes to everything, and yes here means a sudo that has
# no terminal to prompt on, which under `set -e` kills the run long before the config is written.
# --skip-dns is the explicit form of the same thing.
if [ "$SKIP_DNS" = 1 ]; then
  ui_skip "resolver and dnsmasq left alone (--skip-dns)"
elif [ -f "/etc/resolver/$TLD" ] && pgrep -x dnsmasq >/dev/null 2>&1; then
  ui_ok "/etc/resolver/$TLD exists and dnsmasq is running — nothing to do"
else
  ui_info "The next step needs ${C_B}sudo${C_R}: writing /etc/resolver/$TLD and starting dnsmasq as root."
  ui_hint "dnsmasq must run as root to bind port 53."
  if confirm "Write /etc/resolver/$TLD and restart dnsmasq as root?" "yes"; then
    sudo mkdir -p /etc/resolver
    printf 'nameserver 127.0.0.1\n' | sudo tee "/etc/resolver/$TLD" >/dev/null
    sudo brew services restart dnsmasq >/dev/null
    ui_ok "resolver installed and dnsmasq restarted"
  else
    ui_warn "the TLD will not resolve until you run these yourself:"
    ui_cmd "sudo mkdir -p /etc/resolver"
    ui_cmd "echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/$TLD"
    ui_cmd "sudo brew services restart dnsmasq"
  fi
fi

# ---------------------------------------------------------------- 4. certificates

ui_step "$G_LOCK" "Certificates"

if [ "$MODE" = "auto" ]; then
  # Caddy's internal CA issues per-host certs on demand; mkcert's CA is still
  # installed so anything issued by hand is trusted too.
  ui_info "Mode 'auto' issues a certificate per host from Caddy's own CA."
  if confirm "Trust Caddy's local CA in the system store? (sudo, once)" "yes"; then
    if caddy trust; then ui_ok "Caddy's root CA is trusted"
    else ui_warn "caddy trust failed — sites will load but show a warning."; fi
  else
    ui_skip "untrusted CA — browsers will warn on every ldev site"
  fi
else
  ui_info "mkcert issues the per-site certificates in mode '$MODE'."
  if confirm "Run mkcert -install? (sudo, once)" "yes"; then
    mkcert -install || ui_warn "mkcert -install failed — certificates will not be trusted."
    ui_ok "mkcert root CA installed"
  else
    ui_skip "untrusted CA — browsers will warn on every ldev site"
  fi
fi

# ---------------------------------------------------------------- 5. dashboard

ui_step "$G_CHART" "Dashboard"

npm_install() { cd "$REPO_DIR/dashboard" && npm install --silent; }
npm_build()   { cd "$REPO_DIR/dashboard" && npm run build --silent; }

if [ -d "$REPO_DIR/dashboard" ]; then
  if [ ! -d "$REPO_DIR/dashboard/node_modules" ]; then
    run_task "Installing dashboard dependencies" npm_install \
      || ui_warn "npm install failed; the build below will probably fail too."
  fi
  run_task "Building dashboard" npm_build \
    || ui_warn "dashboard build failed; the fallback will 404."
else
  ui_warn "no dashboard/ directory in this repo — the fallback will 404."
fi

# ---------------------------------------------------------------- 6. server config

ui_step "$G_GEAR" "Server configuration ($MODE)"

CADDY_BIN="$(command -v caddy || echo "$BREW_PREFIX/bin/caddy")"
CADDYFILE="$HOME/.config/ldev/Caddyfile"

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

case "$MODE" in
  auto)
    OUT="$HOME/.config/ldev/Caddyfile"
    render "$REPO_DIR/templates/Caddyfile.auto.tmpl" > "$OUT"
    ui_wrote "$OUT"
    if caddy validate --config "$OUT" >/dev/null 2>&1; then
      ui_ok "the generated config validates"
    else
      ui_warn "caddy could not validate the generated config"
      ui_cmd "caddy validate --config $OUT"
    fi

    ui_info "Ports 80 and 443 are privileged, so Caddy starts via launchd as root."
    if confirm "Install and start the ldev launchd service? (sudo)" "yes"; then
      PLIST=/Library/LaunchDaemons/com.ldev.caddy.plist
      render "$REPO_DIR/templates/com.ldev.caddy.plist.tmpl" | sudo tee "$PLIST" >/dev/null
      sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
      sudo launchctl bootout system/com.ldev.caddy 2>/dev/null || true
      sudo launchctl bootstrap system "$PLIST"
      ui_ok "service started"
    else
      ui_skip "no service installed — start Caddy yourself with:"
      ui_cmd "sudo caddy run --config $OUT"
    fi
    ;;
  persite)
    ui_info "Per-site mode makes no global change."
    ui_hint "Each site gets its own Caddyfile and its own pair of ports:"
    ui_cmd "ldev new <name>   # site $SITE_PORT_BASE+n, admin $ADMIN_PORT+n"
    ui_hint "Both ports must be unique per site — two Caddy processes cannot share"
    ui_hint "an admin port, and the second one exits at startup instead of warning."
    ui_hint "See docs/persite.md."
    ;;
esac

# ---------------------------------------------------------------- 7. save + report

ui_step "$G_PARTY" "Done"

cat > "$CONFIG_FILE" <<EOF
# ldev — written by install.sh on $(date '+%Y-%m-%d %H:%M:%S')
TLD=$TLD
SITES=$SITES
MODE=$MODE
PHP_FPM=$PHP_FPM
DASHBOARD=$DASHBOARD
ADMIN_PORT=$ADMIN_PORT
SITE_PORT_BASE=$SITE_PORT_BASE
ASK_PORT=$ASK_PORT
LOGDIR=$LOGDIR
REPO_DIR=$REPO_DIR
EOF
ui_wrote "$CONFIG_FILE"

printf '\n'
ui_kv "Dashboard" "http://$TLD/"
ui_kv "A new site" "mkdir $SITES/<name>   ${C_DIM}->${C_R}  https://<name>.$TLD"
ui_kv "Logs"       "$LOGDIR"
printf '\n %sNext%s\n\n' "$C_B" "$C_R"
ui_item "check every layer:  ${C_CYN}$REPO_DIR/bin/ldev doctor${C_R}"
ui_item "put ldev on PATH:   ${C_CYN}echo 'export PATH=\"$REPO_DIR/bin:\$PATH\"' >> ~/.zshrc${C_R}"
printf '\n'
