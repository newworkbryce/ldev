#!/usr/bin/env bash
#
# ldev — install a wildcard local-development TLD on macOS.
#
#   ./install.sh                 interactive
#   ./install.sh --defaults      accept every default, prompt for nothing
#   ./install.sh --tld test --sites ~/Code --mode auto --yes
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
MODE=""                       # auto | persite | apache
PHP_FPM="127.0.0.1:9000"
ADMIN_PORT="2019"           # persite: base of the admin-port run (2019, 2020, ...)
SITE_PORT_BASE="8443"       # persite: base of the site-port run (8443, 8444, ...)
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

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || return 0
  local reply=""
  read -r -p "$1 [y/N]: " reply </dev/tty || true
  [[ "$reply" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --tld)      TLD="${2:?--tld needs a value}"; shift 2 ;;
    --sites)    SITES="${2:?--sites needs a value}"; shift 2 ;;
    --mode)     MODE="${2:?--mode needs a value}"; shift 2 ;;
    --php-fpm)  PHP_FPM="${2:?--php-fpm needs a value}"; shift 2 ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --defaults) USE_DEFAULTS=1; ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

if [ -z "$MODE" ]; then
  cat <<EOF

How should sites be served?

  ${B}1) auto${R}     One Caddy owns ports 80 and 443 for *.${TLD}.
              A directory at ${SITES}/<name>.${TLD} is served at
              https://<name>.${TLD} with a certificate issued on first
              request. Unknown names fall back to the dashboard.
              ${DIM}Adding a site = creating a folder. Recommended.${R}

  ${B}2) persite${R}  One Caddy per site on its own high port (8443, 8444, ...).
              Nothing owns 443. Each site needs its own Caddyfile and
              certificate. ${DIM}Choose this to preserve an existing per-site setup.${R}

  ${B}3) apache${R}   httpd vhosts, first-vhost-per-port as the fallback.
              ${DIM}Choose this if you already run Apache and want to keep it.${R}

EOF
  case "$(ask "Mode (1/2/3)" "1")" in
    1|auto)    MODE="auto" ;;
    2|persite) MODE="persite" ;;
    3|apache)  MODE="apache" ;;
    *) die "pick 1, 2 or 3." ;;
  esac
fi

DASHBOARD="$REPO_DIR/dashboard/dist"

say ""
say "  TLD          .$TLD"
say "  Sites        $SITES"
say "  Mode         $MODE"
say "  PHP-FPM      $PHP_FPM"
say "  Dashboard    $DASHBOARD"
say ""
confirm "Proceed with these settings?" || die "aborted."

# ---------------------------------------------------------------- 2. dependencies

step "Dependencies"

command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh"

need=()
command -v dnsmasq >/dev/null 2>&1 || need+=(dnsmasq)
command -v mkcert  >/dev/null 2>&1 || need+=(mkcert)
[ "$MODE" = "apache" ] && { command -v httpd >/dev/null 2>&1 || need+=(httpd); }
[ "$MODE" != "apache" ] && { command -v caddy >/dev/null 2>&1 || need+=(caddy); }
command -v php >/dev/null 2>&1 || need+=(php)

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

# ---------------------------------------------------------------- 4. certificates

step "Certificates"

if [ "$MODE" = "auto" ]; then
  # Caddy's internal CA issues per-host certs on demand; mkcert's CA is still
  # installed so anything issued by hand is trusted too.
  say "Mode 'auto' issues a certificate per host from Caddy's own CA."
  say "Trusting Caddy's root (needs sudo, once):"
  if confirm "Install Caddy's local CA into the system trust store?"; then
    caddy trust || warn "caddy trust failed — sites will load but show a warning."
  fi
else
  say "Installing the mkcert root CA (needs sudo, once):"
  confirm "Run mkcert -install?" && mkcert -install || true
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

# ---------------------------------------------------------------- 6. server config

step "Server configuration ($MODE)"

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
    say "wrote $OUT"
    caddy validate --config "$OUT" >/dev/null 2>&1 \
      && say "config validates" \
      || warn "caddy could not validate the generated config — see: caddy validate --config $OUT"

    say ""
    say "Ports 80 and 443 are privileged, so Caddy needs to start via launchd as root."
    if confirm "Install and start the ldev launchd service?"; then
      PLIST=/Library/LaunchDaemons/com.ldev.caddy.plist
      render "$REPO_DIR/templates/com.ldev.caddy.plist.tmpl" | sudo tee "$PLIST" >/dev/null
      sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
      sudo launchctl bootout system/com.ldev.caddy 2>/dev/null || true
      sudo launchctl bootstrap system "$PLIST"
      say "service started."
    else
      say ""
      say "${YEL}Start it yourself with:${R}"
      say "  sudo caddy run --config $OUT"
    fi
    ;;
  persite)
    say "Per-site mode makes no global change."
    say "Each site gets its own Caddyfile and its own pair of ports:"
    say "  ldev new <name>   writes it, allocating site $SITE_PORT_BASE+n and admin $ADMIN_PORT+n"
    say "Both ports must be unique per site — two Caddy processes cannot share an"
    say "admin port, and the second one exits at startup instead of warning."
    say "See docs/persite.md."
    ;;
  apache)
    OUT="$BREW_PREFIX/etc/httpd/extra/httpd-vhosts-ldev.conf"
    render "$REPO_DIR/templates/httpd-vhosts.tmpl" > "$OUT"
    say "wrote $OUT"
    say "${YEL}Include it from httpd.conf and restart:${R}"
    say "  echo 'Include $OUT' >> $BREW_PREFIX/etc/httpd/httpd.conf"
    say "  sudo brew services restart httpd"
    ;;
esac

# ---------------------------------------------------------------- 7. save + report

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

step "Done"
cat <<EOF

  Config      $CONFIG_FILE
  Dashboard   http://$TLD/
  A new site  mkdir $SITES/<name>.$TLD   ->  https://<name>.$TLD

  Check it:   $REPO_DIR/bin/ldev doctor
  Add bin to your PATH:
    echo 'export PATH="$REPO_DIR/bin:\$PATH"' >> ~/.zshrc

EOF
