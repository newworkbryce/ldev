#!/bin/bash
# Exercise the standalone-site port allocator against a fake sites tree, including both
# collisions that motivated it: a sibling already holding a pair, and the wildcard server's
# own admin port being handed to the first site.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LDEV="$REPO/bin/ldev"
TMP=$(mktemp -d /tmp/ldev-test-XXXX)
SITES="$TMP/Sites"; mkdir -p "$SITES"

# Pull just the two functions out of bin/ldev, so the test does not need an install.
sed -n '/^site_used_ports()/,/^}/p;/^site_next_ports()/,/^}/p' "$LDEV" > "$TMP/fns.sh"
TLD=ldev; ADMIN_PORT=2019; ASK_PORT=2018; SITE_PORT_BASE=8443
export LDEV_SKIP_PORT_PROBE=1   # deterministic: ignore what this machine happens to be serving
# shellcheck disable=SC1090
. "$TMP/fns.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

# The admin run starts ABOVE the wildcard server's own admin port, not at it. When these
# shared ADMIN_PORT, the first standalone site was handed 2019 — the port the front door
# already held — and its Caddy exited at startup rather than warning, so the site was
# simply never up. 2020, not 2019, is the whole point of this first assertion.
echo "empty tree:"
check "first pair skips the wildcard server's admin port" "$(site_next_ports)" "8443 2020"

echo "the wildcard server's own ports are never handed out:"
check "2019 (admin) is claimed" "$(site_used_ports | grep -cx 2019)" "1"
check "2018 (ask) is claimed"   "$(site_used_ports | grep -cx 2018)" "1"

echo "one sibling on 8443/2020 (the sibling collision):"
mkdir -p "$SITES/a.ldev"
printf '{\n\tadmin localhost:2020\n}\n\nhttp://a.ldev:8443 {\n\troot * /x\n}\n' > "$SITES/a.ldev/Caddyfile"
check "skips both" "$(site_next_ports)" "8444 2021"

echo "a bare directory name counts as a sibling too:"
mkdir -p "$SITES/b"
printf '{\n\tadmin localhost:2021\n}\n\nhttp://b.ldev:8444 {\n\troot * /x\n}\n' > "$SITES/b/Caddyfile"
check "next pair" "$(site_next_ports)" "8445 2022"

echo "a gap is reused only when BOTH ports are free:"
rm -rf "$SITES/a.ldev"
check "reuses 8443/2020" "$(site_next_ports)" "8443 2020"

echo "admin port taken alone still blocks the pair:"
mkdir -p "$SITES/c.ldev"
printf '{\n\tadmin localhost:2020\n}\n\nhttp://c.ldev:9999 {\n\troot * /x\n}\n' > "$SITES/c.ldev/Caddyfile"
check "site free, admin taken" "$(site_next_ports)" "8445 2022"

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
