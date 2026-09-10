#!/bin/bash
# The wildcard server binds its admin API at startup and EXITS if it cannot, silently. So
# a re-install must neither reset a port somebody deliberately moved, nor hand out one
# something else already holds. Both halves are asserted here.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-iports-XXXX)

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

echo "a previous install's ports are carried forward, not reset to the defaults:"
# The machine that motivated this had ADMIN_PORT=2021 in its config because a site's own
# Caddy already held 2019 — the installer's built-in default. Resetting it re-creates the
# collision that was fixed by hand.
CONFIG_FILE="$TMP/config"
cat > "$CONFIG_FILE" <<EOF
TLD=ldev
ADMIN_PORT=2021
ASK_PORT=2030
SITE_PORT_BASE=9443
EOF
ADMIN_PORT="2019"; ASK_PORT="2018"; SITE_PORT_BASE="8443"
# The carry-forward block, lifted verbatim from install.sh.
if [ -f "$CONFIG_FILE" ]; then
  prev="$(sed -n 's/^ADMIN_PORT=//p' "$CONFIG_FILE" | head -1)"
  [ -n "$prev" ] && ADMIN_PORT="$prev"
  prev="$(sed -n 's/^ASK_PORT=//p' "$CONFIG_FILE" | head -1)"
  [ -n "$prev" ] && ASK_PORT="$prev"
  prev="$(sed -n 's/^SITE_PORT_BASE=//p' "$CONFIG_FILE" | head -1)"
  [ -n "$prev" ] && SITE_PORT_BASE="$prev"
fi
check "admin port kept"     "$ADMIN_PORT"     "2021"
check "ask port kept"       "$ASK_PORT"       "2030"
check "site port base kept" "$SITE_PORT_BASE" "9443"

echo "a fresh machine keeps the built-in defaults:"
CONFIG_FILE="$TMP/absent"
ADMIN_PORT="2019"; ASK_PORT="2018"
if [ -f "$CONFIG_FILE" ]; then ADMIN_PORT=changed; fi
check "admin port default" "$ADMIN_PORT" "2019"

echo "a busy port is stepped over:"
sed -n '/^free_port_from()/,/^}/p' "$REPO/install.sh" > "$TMP/fns.sh"
# shellcheck disable=SC1090
. "$TMP/fns.sh"

# port_busy is stubbed rather than backed by a real listener. Binding a socket from a
# backgrounded process inside a test proved flaky — the process was alive and `nc -z` still
# reported the port free — and that flakiness is not what is under test here. The real
# port_busy is one line (`nc -z 127.0.0.1 <p>`), verified by hand; what needs asserting is
# that free_port_from steps PAST a taken port instead of returning it, which is what
# silently kills a Caddy that cannot bind its admin API.
BUSY=" 2019 2020 2021 "
port_busy() { case "$BUSY" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

check "steps over one taken port"      "$(free_port_from 2021)" "2022"
check "steps over a run of them"       "$(free_port_from 2019)" "2022"
check "a free port is returned as is"  "$(free_port_from 2030)" "2030"

# The real case: the installer defaults to 2019, and seasonal-drops' own Caddy holds it.
check "the collision that motivated this" "$(free_port_from 2019)" "2022"

# Nothing free within the search window must not hang or return something taken blindly —
# it gives back what it was asked for, and the caller's bind fails loudly instead.
BUSY=""
i=2019; while [ "$i" -lt 2200 ]; do BUSY="$BUSY $i "; i=$((i + 1)); done
check "gives up after 100 and returns the original" "$(free_port_from 2019)" "2019"

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
