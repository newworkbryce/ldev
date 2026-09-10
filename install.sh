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
TLD_FROM_FLAG=0
SITES_FROM_FLAG=0
DO_SWITCH=0                   # --switch: take an existing, incompatible setup down first
DO_UNINSTALL=0                # --uninstall: remove what ldev installed, then stop
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
  --switch           take an existing, incompatible setup down first
  --uninstall        remove what ldev installed, then stop
  -y, --yes          answer yes to every optional step
  --defaults         take every default and imply --yes
  --plain            no menus, colour or emoji (also: NO_COLOR=1)
  -h, --help         this
EOF
}

# ---------------------------------------------------------------- arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --tld)      TLD="${2:?--tld needs a value}"; TLD_FROM_FLAG=1; shift 2 ;;
    --sites)    SITES="${2:?--sites needs a value}"; SITES_FROM_FLAG=1; shift 2 ;;
    --mode)     MODE="${2:?--mode needs a value}"; MODE_FROM_FLAG=1; shift 2 ;;
    --php-fpm)  PHP_FPM="${2:?--php-fpm needs a value}"; shift 2 ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --switch)   DO_SWITCH=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
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

# ---------------------------------------------------------------- 0. what is already here
#
# An installer that trusts MODE in its own config file cannot tidy up after itself. That
# is not hypothetical: a machine set up per-site had this script run again choosing auto.
# It rewrote MODE=auto and installed the system LaunchDaemon, and left every per-site
# Caddy running. One process then held 80 and another held 443, https://<tld>/ answered
# from neither — 000, every time, because whatever held 443 had no site for that host —
# and the install reported success.
#
# So everything below asks the machine, not the config file: which files exist, and what
# is actually listening. It survives the mode names changing, because it is written in
# terms of the two topologies that can physically collide — one root Caddy on 80/443, or
# one Caddy per site on high ports — rather than in terms of the string in MODE.
#
# Nothing here writes, starts or stops anything. It only looks.

LAUNCHDAEMONS_DIR="${LDEV_LAUNCHDAEMONS:-/Library/LaunchDaemons}"
LAUNCHAGENTS_DIR="${LDEV_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}"
DAEMON_LABEL="com.ldev.caddy"
DAEMON_PLIST="$LAUNCHDAEMONS_DIR/$DAEMON_LABEL.plist"
AUTO_CADDYFILE="$HOME/.config/ldev/Caddyfile"

EX_FOUND=0            # any evidence of a previous install at all
EX_CONFIG=0; EX_CFG_TLD=""; EX_CFG_SITES=""; EX_CFG_MODE=""
EX_AUTO_FILE=0        # ~/.config/ldev/Caddyfile
EX_DAEMON=0           # the system LaunchDaemon plist
EX_SYS_LIVE=0         # something is listening on 80 or 443
EX_PERSITE_N=0        # per-site Caddyfiles found
EX_PERSITE_LIVE=0     # at least one per-site port is answering
EX_PERSITE=()         # the first few of those Caddyfiles
EX_AGENTS=()          # per-user LaunchAgents that mention ldev
EX_PORTS=""           # human-readable "port: who has it" lines
EXISTING_ACTION="none"

# Read the config as data. Sourcing it would run whatever is in the file, and the
# question here is precisely whether this file can be trusted to describe reality.
cfg_get() { sed -n "s/^$1=//p" "$CONFIG_FILE" 2>/dev/null | tail -1; }

# Both probes are read-only, and both are skipped by LDEV_SKIP_PORT_PROBE=1 — which is
# what the tests set, because a suite that asked the machine it happens to run on what is
# listening would assert something different on every machine.
port_busy() { # port -> 0 when something is listening on it
  [ "${LDEV_SKIP_PORT_PROBE:-0}" = 1 ] && return 1
  command -v nc >/dev/null 2>&1 || return 1
  nc -z 127.0.0.1 "$1" >/dev/null 2>&1
}

# lsof only shows sockets this user owns, so a root-owned Caddy on 443 is invisible from
# here. "in use, owner needs sudo to see" is the honest answer in that case; reporting the
# port as free because we cannot see the owner is how the collision stayed hidden.
#
# "or nothing" has to include "and succeeds". lsof exits 1 when it matches no
# socket it can see, which is the ordinary case here rather than an error — a
# root-owned Caddy on 80 is invisible to this user. With `set -euo pipefail`,
# pipefail hands that 1 to the pipeline, `owner="$(port_owner 80)"` takes it as
# the status of the assignment, and set -e kills the installer where it stands:
# right after the banner, having asked nothing and said nothing. The detection
# that exists to find a busy port died on finding one.
port_owner() { # port -> "caddy pid 42 (root)" or ""
  [ "${LDEV_SKIP_PORT_PROBE:-0}" = 1 ] && return 0
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null \
    | awk 'NR > 1 { printf "%s pid %s (%s)", $1, $2, $3; exit }' || true
}

# The ports a per-site Caddyfile claims: the address on a site block, and the admin port.
# Finding none is an ordinary answer, so — as with port_owner above — the grep's exit 1
# must not become this function's, or pipefail and set -e turn "this site names no port"
# into a dead installer.
site_ports_of() {
  grep -oE '[A-Za-z0-9_.*-]+:[0-9]{2,5}[[:space:]]*\{' "$1" 2>/dev/null | grep -oE '[0-9]+' | head -2 || true
  grep -oE 'admin[[:space:]]+[A-Za-z0-9_.*-]*:[0-9]{2,5}' "$1" 2>/dev/null | grep -oE '[0-9]+$' || true
  return 0
}

detect_existing() {
  local f d p owner dirs=()

  if [ -f "$CONFIG_FILE" ]; then
    EX_CONFIG=1
    EX_CFG_TLD="$(cfg_get TLD)"
    EX_CFG_SITES="$(cfg_get SITES)"
    EX_CFG_MODE="$(cfg_get MODE)"
  fi
  [ -f "$AUTO_CADDYFILE" ] && EX_AUTO_FILE=1
  [ -f "$DAEMON_PLIST" ]   && EX_DAEMON=1

  # Both the directory this run would use and the one the old config named: a switch of
  # sites directory must not hide the sites the old topology is still serving.
  dirs=("$SITES")
  if [ -n "$EX_CFG_SITES" ] && [ "$EX_CFG_SITES" != "$SITES" ]; then dirs+=("$EX_CFG_SITES"); fi
  for d in "${dirs[@]}"; do
    for f in "$d"/*/Caddyfile; do
      [ -f "$f" ] || continue
      EX_PERSITE_N=$((EX_PERSITE_N + 1))
      if [ "${#EX_PERSITE[@]}" -lt 8 ]; then EX_PERSITE+=("$f"); fi
    done
  done

  for f in "$LAUNCHAGENTS_DIR"/*.plist; do
    [ -f "$f" ] || continue
    case "$f" in *ldev*) EX_AGENTS+=("$f"); continue ;; esac
    if grep -qs -e 'ldev' -e "$SITES" "$f"; then EX_AGENTS+=("$f"); fi
  done

  if [ "$EX_CONFIG" = 1 ] || [ "$EX_AUTO_FILE" = 1 ] || [ "$EX_DAEMON" = 1 ] \
     || [ "$EX_PERSITE_N" -gt 0 ] || [ "${#EX_AGENTS[@]}" -gt 0 ]; then
    EX_FOUND=1
  else
    return 0                       # a clean machine: ask the machine nothing further
  fi

  for p in 80 443; do
    if port_busy "$p"; then
      EX_SYS_LIVE=1
      owner="$(port_owner "$p")"
      [ -n "$owner" ] || owner="in use, owner needs sudo to see"
      EX_PORTS="$EX_PORTS$p $owner
"
    fi
  done

  if [ "${#EX_PERSITE[@]}" -gt 0 ]; then
    for f in "${EX_PERSITE[@]}"; do
      for p in $(site_ports_of "$f"); do
        if port_busy "$p"; then
          EX_PERSITE_LIVE=1
          owner="$(port_owner "$p")"
          [ -n "$owner" ] || owner="in use, owner needs sudo to see"
          EX_PORTS="$EX_PORTS$p $owner  <- $f
"
        fi
      done
    done
  fi
  # A LaunchAgent is per-site scaffolding whether or not it happens to be loaded now:
  # leaving it behind means the old topology comes back at the next login.
  if [ "${#EX_AGENTS[@]}" -gt 0 ]; then EX_PERSITE_LIVE=1; fi
  return 0
}

# What the two topologies look like when they are up. Named as "system" and "per-site"
# rather than as modes, because these are the things that fight over a port.
sys_installed()     { [ "$EX_DAEMON" = 1 ] || [ "$EX_SYS_LIVE" = 1 ]; }
persite_installed() { [ "$EX_PERSITE_N" -gt 0 ] || [ "${#EX_AGENTS[@]}" -gt 0 ]; }

# True when what this run is about to install and what is already up would fight over the
# same ports. Per-site Caddyfiles sitting on disk with nothing running are untidy but not
# a conflict; a loaded LaunchAgent or a listening port is.
topology_conflict() {
  if [ "$MODE" = "auto" ]; then
    [ "$EX_PERSITE_LIVE" = 1 ]
  else
    sys_installed
  fi
}

# The evidence, printed before any refusal: "what is running" is exactly what the failed
# install never said.
show_live() {
  if [ "$MODE" = "auto" ]; then
    local f
    [ "${#EX_AGENTS[@]}" -gt 0 ] && for f in "${EX_AGENTS[@]}"; do ui_item "LaunchAgent $f"; done
    [ "$EX_PERSITE_N" -gt 0 ] && ui_item "$EX_PERSITE_N per-site Caddyfile(s) under $SITES"
  else
    [ "$EX_DAEMON" = 1 ] && ui_item "$DAEMON_PLIST  ${C_DIM}(system LaunchDaemon)$C_R"
    [ "$EX_SYS_LIVE" = 1 ] && ui_item "port 80/443 answered while this run started"
  fi
  if [ -n "$EX_PORTS" ]; then
    printf '%s' "$EX_PORTS" | while IFS= read -r line; do [ -n "$line" ] && ui_item "port $line"; done
  fi
  return 0
}

show_existing() {
  printf '\n %s %sldev is already installed here%s\n\n' "$G_LIST" "$C_B" "$C_R"
  if [ "$EX_CONFIG" = 1 ]; then
    ui_kv "Config"  "$CONFIG_FILE"
    ui_kv "It says" "TLD .${EX_CFG_TLD:-?}  ${C_DIM}$G_DOT${C_R}  sites ${EX_CFG_SITES:-?}  ${C_DIM}$G_DOT${C_R}  mode ${EX_CFG_MODE:-?}"
  else
    ui_kv "Config"  "none at $CONFIG_FILE"
  fi
  printf '\n %s%sWhat is actually on this machine%s\n\n' "$C_B" "" "$C_R"
  if [ "$EX_DAEMON" = 1 ]; then
    ui_item "$DAEMON_PLIST  ${C_DIM}(system LaunchDaemon, root)$C_R"
  else
    ui_item "no system LaunchDaemon at $DAEMON_PLIST"
  fi
  [ "$EX_AUTO_FILE" = 1 ] && ui_item "$AUTO_CADDYFILE"
  if [ "$EX_PERSITE_N" -gt 0 ]; then
    ui_item "$EX_PERSITE_N per-site Caddyfile(s):"
    local f
    for f in "${EX_PERSITE[@]}"; do ui_hint "$f"; done
    [ "$EX_PERSITE_N" -gt "${#EX_PERSITE[@]}" ] \
      && ui_hint "… and $((EX_PERSITE_N - ${#EX_PERSITE[@]})) more"
  fi
  if [ "${#EX_AGENTS[@]}" -gt 0 ]; then
    ui_item "${#EX_AGENTS[@]} per-user LaunchAgent(s):"
    for f in "${EX_AGENTS[@]}"; do ui_hint "$f"; done
  fi
  if [ -n "$EX_PORTS" ]; then
    ui_item "listening now:"
    printf '%s' "$EX_PORTS" | while IFS= read -r f; do [ -n "$f" ] && ui_hint "$f"; done
  elif [ "${LDEV_SKIP_PORT_PROBE:-0}" = 1 ]; then
    ui_item "ports not probed (LDEV_SKIP_PORT_PROBE=1)"
  else
    ui_item "nothing listening on 80 or 443"
  fi
  # The exact state the reported defect left behind, called by name.
  if sys_installed && persite_installed; then
    printf '\n'
    ui_warn "both ways of serving are installed at once."
    ui_hint "One process holds 80 and another holds 443, so a site answers from"
    ui_hint "neither — this is the state where https://<name>.$TLD returns 000."
  fi
  printf '\n'
}

# launchd remembers, per label, that a service was disabled — in the system domain, in a
# store that outlives `launchctl bootout` AND the plist itself. The next bootstrap of that
# label then fails with "Bootstrap failed: 5: Input/output error", which names neither the
# label nor the word "disabled" and reads exactly like a broken plist; it cost two installs
# before anyone thought to run `launchctl print-disabled system`. `enable` clears the
# record, so ldev runs it before every bootstrap and again on removal — the label is left
# clean whichever way the run ends. A failure here is never fatal: it is a tidy-up, and
# the bootstrap below reports its own outcome.
launchd_enable_label() {
  sudo launchctl enable "system/$DAEMON_LABEL" >/dev/null 2>&1 \
    || ui_hint "could not clear launchd's disabled record for $DAEMON_LABEL — continuing"
  return 0
}

# Stop and remove the system Caddy service. Returns 1 if it is still there afterwards, so
# callers can refuse to install the other topology on top of a live one.
takedown_system() {
  ui_info "Taking the system Caddy service down: it owns ports 80 and 443."
  if ! confirm "Stop and remove $DAEMON_LABEL? (sudo)" "yes"; then
    ui_warn "left running. Run these, then start this installer again:"
    ui_cmd "sudo launchctl bootout system/$DAEMON_LABEL"
    ui_cmd "sudo launchctl enable system/$DAEMON_LABEL"
    ui_cmd "sudo rm -f $DAEMON_PLIST"
    return 1
  fi
  sudo launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1 || true
  launchd_enable_label
  sudo rm -f "$DAEMON_PLIST" >/dev/null 2>&1 || true
  # Ask the disk rather than the exit status. A takedown that is reported as done and did
  # not happen is the whole defect: the next step would install the other topology on top
  # of a service still holding 80 and 443.
  if [ -e "$DAEMON_PLIST" ]; then
    ui_warn "$DAEMON_PLIST is still there — the service was not taken down."
    ui_hint "run these yourself and start the installer again:"
    ui_cmd "sudo launchctl bootout system/$DAEMON_LABEL"
    ui_cmd "sudo launchctl enable system/$DAEMON_LABEL"
    ui_cmd "sudo rm -f $DAEMON_PLIST"
    return 1
  fi
  ui_ok "system service stopped and $DAEMON_PLIST removed"
  # launchd releases the socket a moment after bootout returns. ldev's own service is
  # provably gone by now — the plist is — so a port still answering belongs to something
  # else, and saying which is more use than refusing to continue over it.
  local p
  for p in 80 443; do
    port_busy "$p" || continue
    sleep 1
    port_busy "$p" || continue
    ui_warn "port $p is still answering — that is not ldev's service, it is something else."
    ui_cmd "sudo lsof -nP -iTCP:$p -sTCP:LISTEN"
  done
  EX_DAEMON=0; EX_SYS_LIVE=0
  return 0
}

# Take the per-site topology down. The Caddyfiles are the user's own files, so they are
# only removed if asked for; what must go is anything still holding a port.
takedown_persite() {
  local f label p
  if [ "${#EX_AGENTS[@]}" -gt 0 ]; then
    ui_info "Unloading ${#EX_AGENTS[@]} per-user LaunchAgent(s)."
    for f in "${EX_AGENTS[@]}"; do
      label="$(basename "$f")"; label="${label%.plist}"
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
      ui_ok "unloaded $label  ${C_DIM}(its plist is left at $f)$C_R"
    done
  fi
  if [ "$EX_PERSITE_LIVE" = 1 ] && [ "${#EX_PERSITE[@]}" -gt 0 ]; then
    for f in "${EX_PERSITE[@]}"; do
      for p in $(site_ports_of "$f"); do
        port_busy "$p" || continue
        ui_warn "something is still listening on $p (from $f)"
        ui_hint "if it is a caddy you started by hand, stop it in its own terminal:"
        ui_cmd "lsof -nP -iTCP:$p -sTCP:LISTEN"
      done
    done
  fi
  if [ "$EX_PERSITE_N" -gt 0 ]; then
    ui_info "$EX_PERSITE_N per-site Caddyfile(s) are still on disk. They are yours; ldev"
    ui_hint "will not serve them any more, and leaves them alone unless you say otherwise."
    # Deliberately not offered unattended. `--defaults` means yes to everything, and the
    # one thing a switch must never do on nobody's say-so is delete files a person wrote.
    if [ "$TUI_INTERACTIVE" = 1 ] && confirm "Delete the per-site Caddyfiles too?" "no"; then
      for f in "${EX_PERSITE[@]}"; do rm -f "$f" && ui_ok "removed $f"; done
      EX_PERSITE_N=0; EX_PERSITE=()
    else
      ui_skip "per-site Caddyfiles kept"
    fi
  fi
  EX_PERSITE_LIVE=0
  return 0
}

# --uninstall, and the "Remove it" entry on the menu below. Removes what ldev installed
# and nothing else: no site directory and no site content is touched.
do_uninstall() {
  local tld="${EX_CFG_TLD:-$TLD}" dnsd="$BREW_PREFIX/etc/dnsmasq.d"
  printf '\n %s %sRemove ldev%s\n\n' "$G_LIST" "$C_B" "$C_R"
  ui_item "$DAEMON_PLIST  ${C_DIM}(stopped, then deleted — root)$C_R"
  ui_item "$AUTO_CADDYFILE"
  ui_item "$CONFIG_FILE"
  ui_item "$dnsd/$tld.conf"
  ui_item "/etc/resolver/$tld  ${C_DIM}(root)$C_R"
  ui_hint "your sites, their content and their own Caddyfiles are left alone."
  printf '\n'
  if ! confirm "Remove these now?" "no"; then die "aborted — nothing was removed."; fi

  if [ "$EX_DAEMON" = 1 ] || [ "$EX_SYS_LIVE" = 1 ]; then
    sudo launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1 || true
    # Leave the label enabled: a disabled record here is what makes the NEXT install
    # fail with launchd's opaque "Bootstrap failed: 5: Input/output error".
    launchd_enable_label
    sudo rm -f "$DAEMON_PLIST" >/dev/null 2>&1 || ui_warn "could not remove $DAEMON_PLIST"
    ui_ok "$DAEMON_LABEL stopped, removed, and left enabled for next time"
  fi
  # Report what was actually there. `rm -f` succeeds on a file that never existed, so
  # reporting from its exit status would claim removals that never happened.
  local gone
  for gone in "$AUTO_CADDYFILE" "$CONFIG_FILE" "$dnsd/$tld.conf"; do
    [ -e "$gone" ] || continue
    rm -f "$gone" && ui_ok "removed $gone"
  done
  rmdir "$HOME/.config/ldev" 2>/dev/null || true
  if [ -f "/etc/resolver/$tld" ]; then
    if confirm "Remove /etc/resolver/$tld? (sudo)" "yes"; then
      sudo rm -f "/etc/resolver/$tld" && ui_ok "removed /etc/resolver/$tld"
    else
      ui_warn "left behind — *.${tld} will keep resolving to 127.0.0.1:"
      ui_cmd "sudo rm -f /etc/resolver/$tld"
    fi
  fi
  if [ "$EX_PERSITE_N" -gt 0 ]; then
    ui_info "$EX_PERSITE_N per-site Caddyfile(s) were left alone. Delete them yourself if"
    ui_hint "you want them gone; anything still running keeps its port until you stop it."
  fi
  printf '\n'
  ui_ok "ldev removed"
  exit 0
}

# What this run should do about what is already here. The menu is the review screen's
# style, and — like the review screen — choosing nothing writes nothing.
choose_existing_action() {
  # A flag is an answer already given, terminal or not: --uninstall must not be met with a
  # menu whose default is "update in place".
  if [ "$DO_UNINSTALL" = 1 ]; then EXISTING_ACTION="uninstall"; return 0; fi
  if [ "$TUI_INTERACTIVE" != 1 ]; then
    # Nobody is at the keyboard. Reinstalling in place is safe and is what a repeated
    # `./install.sh --defaults` means; anything that would change the serving topology
    # is refused further down unless --switch said so out loud.
    if [ "$DO_UNINSTALL" = 1 ]; then EXISTING_ACTION="uninstall"
    elif [ "$DO_SWITCH" = 1 ]; then EXISTING_ACTION="switch"
    else EXISTING_ACTION="update"; ui_info "updating the existing installation in place (no terminal to ask)."
    fi
    return 0
  fi
  # --switch on the command line preselects the switch, and still shows the menu: the
  # user asked for it, so it is the default rather than the only option.
  local d=0
  [ "$DO_SWITCH" = 1 ] && d=1
  menu_select "There is an ldev installation here already. What should this run do?" "$d" \
    "$G_ROCKET Update it in place" \
"Keep serving sites the way this machine already serves them.
Regenerates what ldev writes and restarts it." \
    "$G_BOLT Switch how sites are served" \
"Take the current setup down — the service, the LaunchAgents, the
processes holding the ports — and then install the other one.
This is the one to pick when a previous run left both live." \
    "$G_GEAR Repair it" \
"Keep every existing answer, rewrite the generated files, restart.
For an install that stopped half way." \
    "$G_NO Remove it" \
"Stop and delete what ldev installed: the service, the generated
config, the resolver entry. Your sites are not touched." \
    "$G_NO Quit" \
"Change nothing." \
    || die "aborted — nothing was written."
  case "$MENU_CHOICE" in
    0) EXISTING_ACTION="update" ;;
    1) EXISTING_ACTION="switch" ;;
    2) EXISTING_ACTION="repair" ;;
    3) EXISTING_ACTION="uninstall" ;;
    4) die "aborted — nothing was written." ;;
  esac
  return 0
}

detect_existing
if [ "$EX_FOUND" = 1 ]; then
  show_existing
  choose_existing_action
  [ "$EXISTING_ACTION" = "uninstall" ] && do_uninstall
  # Whatever the old install answered is the starting point for this one, unless a flag
  # on this command line says otherwise.
  if [ "$EX_CONFIG" = 1 ]; then
    [ "$TLD_FROM_FLAG"   = 1 ] || [ -z "$EX_CFG_TLD" ]   || TLD="$EX_CFG_TLD"
    [ "$SITES_FROM_FLAG" = 1 ] || [ -z "$EX_CFG_SITES" ] || SITES="$EX_CFG_SITES"
    if [ "$MODE_FROM_FLAG" != 1 ] && [ "$EXISTING_ACTION" != "switch" ]; then
      case "$EX_CFG_MODE" in auto|persite) MODE="$EX_CFG_MODE" ;; esac
    fi
  fi
  # What is running beats what the config claims: a config saying auto on a machine that
  # only has per-site servers up would otherwise reinstall the wrong half.
  if [ "$EXISTING_ACTION" != "switch" ] && [ "$MODE_FROM_FLAG" != 1 ]; then
    if [ "$EX_DAEMON" = 1 ] && [ "$EX_PERSITE_LIVE" != 1 ]; then MODE="auto"
    elif [ "$EX_DAEMON" != 1 ] && [ "$EX_PERSITE_LIVE" = 1 ]; then MODE="persite"
    fi
  fi
elif [ "$DO_UNINSTALL" = 1 ]; then
  die "nothing to uninstall — no ldev config, service, LaunchAgent or per-site Caddyfile found."
fi

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

if [ "$USE_DEFAULTS" != 1 ] && [ "$EXISTING_ACTION" != "repair" ]; then
  edit_tld
  edit_sites
elif [ "$EXISTING_ACTION" = "repair" ]; then
  ui_info "Repairing: keeping .$TLD, $SITES and mode ${MODE:-auto} exactly as they are."
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
  # Named explicitly rather than folded into the catch-all: a script that still passes
  # --mode apache should be told the mode is gone, not told it is a typo.
  #
  # It is gone for two reasons, found independently on two branches. It never worked —
  # the arm rendered templates/httpd-vhosts.tmpl, which exists in no revision of this
  # repo, so `set -e` killed the install there. And it was never a fit: serving the TLD
  # from httpd needs a vhost and a certificate per host, which is a different product
  # from "a folder is a site". `ldev apply` would have had nothing to render and doctor
  # nothing to check.
  apache) die "mode 'apache' is not supported — use 'auto', or 'persite' to keep an existing per-site setup." ;;
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
  [ "$EX_FOUND" = 1 ] && ui_kv "Existing"  "$EXISTING_ACTION"
  if [ "$EX_FOUND" = 1 ] && topology_conflict; then
    printf '\n %s%sWhat is in the way, and has to go down first%s\n\n' "$C_B" "" "$C_R"
    if [ "$MODE" = "auto" ]; then
      [ "${#EX_AGENTS[@]}" -gt 0 ] && ui_item "${#EX_AGENTS[@]} per-user LaunchAgent(s), to be unloaded"
      [ "$EX_PERSITE_N" -gt 0 ] && ui_item "$EX_PERSITE_N per-site Caddyfile(s) stop being served (kept unless you say otherwise)"
    else
      ui_item "$DAEMON_LABEL, to be stopped and removed  ${C_DIM}(root)$C_R"
    fi
  fi
  printf '\n %s%sWhat this will write%s\n\n' "$C_B" "" "$C_R"
  ui_item "$CONFIG_FILE"
  ui_item "$BREW_PREFIX/etc/dnsmasq.d/$TLD.conf"
  [ "$SKIP_DNS" = 1 ] || ui_item "/etc/resolver/$TLD  $C_DIM(root)$C_R"
  case "$MODE" in
    auto)    ui_item "$AUTO_CADDYFILE"
             ui_item "$DAEMON_PLIST  $C_DIM(root)$C_R" ;;
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

# ---------------------------------------------------------------- 1c. one topology at a time
#
# The user has said go, so from here things may be written — and the first of them is the
# removal of whatever this install would otherwise fight with. An install that changes how
# sites are served either takes the old way down as part of the switch, or refuses and says
# what is running; what it must never do is what the reported run did, which was to install
# a second topology beside a live one and print "Done".

topology_guard() {
  topology_conflict || return 0

  local other
  if [ "$MODE" = "auto" ]; then
    other="a per-site setup"
  else
    other="the system Caddy service ($DAEMON_LABEL)"
  fi

  if [ "$EXISTING_ACTION" != "switch" ] && [ "$DO_SWITCH" != 1 ]; then
    if [ "$TUI_INTERACTIVE" = 1 ]; then
      ui_warn "mode '$MODE' cannot share this machine with $other, which is still live:"
      show_live
      printf '\n'
      menu_select "Two ways of serving cannot both own the ports. What now?" 0 \
        "$G_BOLT Take the current one down, then install" \
"Stops and removes what is serving now, and only then installs
mode '$MODE'. This is the tidy-up a reinstall should have done." \
        "$G_NO Quit and change nothing" \
"Nothing has been written yet." \
        || die "aborted — nothing was written."
      [ "$MENU_CHOICE" = 0 ] || die "aborted — nothing was written."
      EXISTING_ACTION="switch"
    else
      # Unattended, and the answer that cannot break a working machine is no. The point
      # of failing here rather than warning is that the half-installed state this avoids
      # looks like a success and serves nothing.
      ui_warn "refusing to install mode '$MODE': $other is live. What is running now:"
      show_live
      ui_hint "re-run with --switch to take it down first, --uninstall to remove ldev,"
      ui_hint "or without --defaults to decide interactively."
      die "aborted — nothing was written: $other is still running."
    fi
  fi

  if [ "$MODE" = "auto" ]; then
    takedown_persite || die "aborted — the per-site setup is still live."
  else
    takedown_system  || die "aborted — $DAEMON_LABEL is still installed and holding ports 80 and 443."
  fi
  return 0
}
topology_guard

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
      PLIST="$DAEMON_PLIST"
      render "$REPO_DIR/templates/com.ldev.caddy.plist.tmpl" | sudo tee "$PLIST" >/dev/null
      sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
      sudo launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1 || true
      # Before every bootstrap, without exception: see launchd_enable_label above. The
      # disabled record is per label and survives both the bootout and the plist, so a
      # machine that has ever had this service disabled cannot start it again until this
      # runs — and the error it gets instead names neither the label nor the reason.
      launchd_enable_label
      boot_rc=0
      sudo launchctl bootstrap system "$PLIST" || boot_rc=$?
      if [ "$boot_rc" = 0 ]; then
        # "bootstrap succeeded" means launchd ACCEPTED the job, not that Caddy is
        # serving. Caddy can exit a moment later — an admin port already taken is the
        # usual reason — and KeepAlive then restarts it into the same failure forever.
        # Reporting success off the exit code alone is how an install finishes green
        # with nothing listening, which is the one outcome the operator cannot see.
        # So ask the socket, and give it a moment to get there first.
        if [ "${LDEV_SKIP_PORT_PROBE:-0}" = 1 ]; then
          ui_ok "service bootstrapped (ports not probed)"
        else
          serving=0
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            if port_busy 443 || port_busy 80; then serving=1; break; fi
            sleep 0.5
          done
          if [ "$serving" = 1 ]; then
            ui_ok "service started and listening"
          else
            ui_warn "$DAEMON_LABEL was accepted by launchd but nothing is listening on 80 or 443."
            ui_hint "Caddy most likely started and exited. The usual cause is its admin port"
            ui_hint "($ADMIN_PORT) already being held by another Caddy, which makes it exit at"
            ui_hint "startup rather than warn. The log says which:"
            ui_cmd "tail -20 $LOGDIR/caddy.err.log"
            ui_cmd "sudo launchctl print system/$DAEMON_LABEL | head -20"
          fi
        fi
      else
        # launchd's own words for this are "Bootstrap failed: 5: Input/output error",
        # which reads like a malformed plist and sends people to rewrite a file that was
        # fine. Say what it actually means, name the label, and hand over the command
        # that shows the truth.
        ui_warn "launchctl bootstrap failed (exit $boot_rc) — $DAEMON_LABEL is NOT running."
        ui_hint "launchd reports this as 'Bootstrap failed: 5: Input/output error' and names"
        ui_hint "neither the label nor a reason. The usual cause is a disabled record for"
        ui_hint "$DAEMON_LABEL in the system domain, which survives bootout and the plist."
        ui_hint "Check, clear it, and try again:"
        ui_cmd "sudo launchctl print-disabled system | grep $DAEMON_LABEL"
        ui_cmd "sudo launchctl enable system/$DAEMON_LABEL"
        ui_cmd "sudo launchctl bootstrap system $PLIST"
        ui_hint "If it still fails, the plist itself is next: plutil -lint $PLIST"
      fi
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
ui_kv ""           "${C_DIM}folders already named <name>.$TLD keep working too${C_R}"
ui_kv "Logs"       "$LOGDIR"
printf '\n %sNext%s\n\n' "$C_B" "$C_R"
ui_item "check every layer:  ${C_CYN}$REPO_DIR/bin/ldev doctor${C_R}"
ui_item "put ldev on PATH:   ${C_CYN}echo 'export PATH=\"$REPO_DIR/bin:\$PATH\"' >> ~/.zshrc${C_R}"
printf '\n'
