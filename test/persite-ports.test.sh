#!/bin/bash
# Exercise the persite port allocator against a fake sites tree, including the exact
# collision that motivated it (a sibling already holding 8443/2019).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LDEV="$REPO/bin/ldev"
TMP=$(mktemp -d /tmp/ldev-test-XXXX)
SITES="$TMP/Sites"; mkdir -p "$SITES"

# Pull just the two functions out of bin/ldev, so the test does not need an install.
sed -n '/^persite_used_ports()/,/^}/p;/^persite_next_ports()/,/^}/p' "$LDEV" > "$TMP/fns.sh"
TLD=ldev; ADMIN_PORT=2019; SITE_PORT_BASE=8443
export LDEV_SKIP_PORT_PROBE=1   # deterministic: ignore what this machine happens to be serving
# shellcheck disable=SC1090
. "$TMP/fns.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

echo "empty tree:"
check "first pair" "$(persite_next_ports)" "8443 2019"

echo "one sibling on 8443/2019 (the real collision):"
mkdir -p "$SITES/a.ldev"
printf '{\n\tadmin localhost:2019\n}\n\na.ldev:8443 {\n\troot * /x\n}\n' > "$SITES/a.ldev/Caddyfile"
check "skips both" "$(persite_next_ports)" "8444 2020"

echo "two siblings:"
mkdir -p "$SITES/b.ldev"
printf '{\n\tadmin localhost:2020\n}\n\nb.ldev:8444 {\n\troot * /x\n}\n' > "$SITES/b.ldev/Caddyfile"
check "next pair" "$(persite_next_ports)" "8445 2021"

echo "a gap is reused only when BOTH ports are free:"
rm -rf "$SITES/a.ldev"
check "reuses 8443/2019" "$(persite_next_ports)" "8443 2019"

echo "a plain-named sibling counts too (folders no longer carry the TLD):"
mkdir -p "$SITES/d"
printf '{\n\tadmin localhost:2019\n}\n\nd.ldev:8443 {\n\troot * /x\n}\n' > "$SITES/d/Caddyfile"
check "skips the plain sibling's pair" "$(persite_next_ports)" "8445 2021"
rm -rf "$SITES/d"

echo "admin port taken alone still blocks the pair:"
mkdir -p "$SITES/c.ldev"
printf '{\n\tadmin localhost:2019\n}\n\nc.ldev:9999 {\n\troot * /x\n}\n' > "$SITES/c.ldev/Caddyfile"
check "site free, admin taken" "$(persite_next_ports)" "8445 2021"

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
