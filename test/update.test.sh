#!/bin/bash
# `ldev update` migrates a config written by an older ldev without reinstalling. What has to
# hold: keys this version expects get added, keys it no longer understands get removed,
# values somebody already set are never touched, the previous file is recoverable, and
# running it twice changes nothing the second time.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-update-XXXX)
mkdir -p "$TMP/.config/ldev" "$TMP/Sites" "$TMP/Logs"

run() { HOME="$TMP" "$REPO/bin/ldev" "$@"; }
C="$TMP/.config/ldev/config"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
val() { sed -n "s/^$1=//p" "$C" | head -1; }

# A config as an older ldev wrote it: MODE still present, and none of the keys added since.
old_config() {
  cat > "$C" <<EOF
# ldev — written by install.sh on 2026-01-01 00:00:00
TLD=ldev
SITES=$TMP/Sites
MODE=persite
PHP_FPM=127.0.0.1:9000
DASHBOARD=$REPO/dashboard/dist
ADMIN_PORT=2021
SITE_PORT_BASE=8443
ASK_PORT=2018
LOGDIR=$TMP/Logs
REPO_DIR=$REPO
EOF
}

echo "an older config is migrated:"
old_config
out="$(run update 2>&1)"
check "PROXY_FALLBACK added"   "$(val PROXY_FALLBACK)" "no"
check "MODE removed"           "$(grep -c '^MODE=' "$C")" "0"

# The whole point of a migration rather than a reinstall: a value somebody deliberately set
# survives. ADMIN_PORT=2021 exists precisely because 2019 was taken.
check "a hand-set port is untouched" "$(val ADMIN_PORT)" "2021"
check "sites directory untouched"    "$(val SITES)"      "$TMP/Sites"

echo "the previous config is recoverable:"
bak="$(ls "$TMP/.config/ldev"/config.bak-* 2>/dev/null | head -1)"
if [ -n "$bak" ]; then echo "  ok   a backup was written"; pass=$((pass+1))
else echo "  FAIL no backup"; fail=$((fail+1)); fi
if [ -n "$bak" ] && grep -q '^MODE=persite' "$bak"; then echo "  ok   the backup still has the old keys"; pass=$((pass+1))
else echo "  FAIL the backup does not hold the pre-migration content"; fail=$((fail+1)); fi

echo "running it again is a no-op:"
before="$(cat "$C")"
out="$(run update 2>&1)"
if [ "$before" = "$(cat "$C")" ]; then echo "  ok   the config is unchanged"; pass=$((pass+1))
else echo "  FAIL a second run rewrote the config"; fail=$((fail+1)); fi
if printf '%s' "$out" | grep -q "up to date"; then echo "  ok   it says so"; pass=$((pass+1))
else echo "  FAIL no 'up to date' message"; fail=$((fail+1)); fi
check "no second backup" "$(ls "$TMP/.config/ldev"/config.bak-* 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "doctor reports the drift before it is fixed:"
old_config
out="$(run doctor 2>&1)"
if printf '%s' "$out" | grep -q "config is from an older ldev"; then echo "  ok   drift is reported"; pass=$((pass+1))
else echo "  FAIL doctor did not mention the drift"; fail=$((fail+1)); fi
if printf '%s' "$out" | grep -q "ldev update"; then echo "  ok   it names the fix"; pass=$((pass+1))
else echo "  FAIL doctor did not name 'ldev update'"; fail=$((fail+1)); fi

echo "an unusable value is not silently accepted as present:"
# A key that exists but is empty still counts as present — update fills MISSING keys, it does
# not police values. Asserted so the boundary is deliberate rather than accidental.
old_config
printf 'PROXY_FALLBACK=\n' >> "$C"
run update >/dev/null 2>&1
check "an empty value is left alone" "$(val PROXY_FALLBACK)" ""

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
