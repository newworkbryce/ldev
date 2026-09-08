#!/bin/bash
# End-to-end: `ldev new` in persite mode must write a Caddyfile that Caddy validates,
# and a second site must get a DIFFERENT admin port. That second assertion is the bug.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-e2e-XXXX)
mkdir -p "$TMP/.config/ldev" "$TMP/Sites" "$TMP/Logs"
cat > "$TMP/.config/ldev/config" <<EOF
TLD=ldev
SITES=$TMP/Sites
MODE=persite
PHP_FPM=127.0.0.1:9000
DASHBOARD=$REPO/dashboard/dist
ADMIN_PORT=2019
SITE_PORT_BASE=8443
ASK_PORT=2018
LOGDIR=$TMP/Logs
REPO_DIR=$REPO
EOF

run() { HOME="$TMP" LDEV_SKIP_PORT_PROBE=1 "$REPO/bin/ldev" "$@"; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

echo "--- ldev new shop"
run new shop 2>&1 | sed 's/^/    /'
echo "--- ldev new blog"
run new blog 2>&1 | sed 's/^/    /'
echo

for s in shop blog; do
  f="$TMP/Sites/$s.ldev/Caddyfile"
  if [ -f "$f" ]; then echo "  ok   $s Caddyfile written"; pass=$((pass+1)); else echo "  FAIL $s Caddyfile missing"; fail=$((fail+1)); continue; fi
  if caddy validate --config "$f" >/dev/null 2>&1; then echo "  ok   $s validates"; pass=$((pass+1)); else echo "  FAIL $s does not validate"; caddy validate --config "$f" 2>&1 | tail -3; fail=$((fail+1)); fi
done

a_shop=$(grep -oE 'admin localhost:[0-9]+' "$TMP/Sites/shop.ldev/Caddyfile" | grep -oE '[0-9]+$')
a_blog=$(grep -oE 'admin localhost:[0-9]+' "$TMP/Sites/blog.ldev/Caddyfile" | grep -oE '[0-9]+$')
s_shop=$(grep -oE 'shop\.ldev:[0-9]+' "$TMP/Sites/shop.ldev/Caddyfile" | head -1 | grep -oE '[0-9]+$')
s_blog=$(grep -oE 'blog\.ldev:[0-9]+' "$TMP/Sites/blog.ldev/Caddyfile" | head -1 | grep -oE '[0-9]+$')

check "shop site port"  "$s_shop" "8443"
check "shop admin port" "$a_shop" "2019"
check "blog site port"  "$s_blog" "8444"
check "blog admin port" "$a_blog" "2020"

# The regression itself, stated as its own assertion.
if [ "$a_shop" != "$a_blog" ]; then echo "  ok   admin ports differ (the bug)"; pass=$((pass+1)); else echo "  FAIL both sites got admin $a_shop — second Caddy would exit at startup"; fail=$((fail+1)); fi

# No leftover placeholders.
if grep -q '__[A-Z_]*__' "$TMP/Sites/shop.ldev/Caddyfile"; then
  echo "  FAIL unrendered placeholders:"; grep -o '__[A-Z_]*__' "$TMP/Sites/shop.ldev/Caddyfile" | sort -u | sed 's/^/       /'; fail=$((fail+1))
else echo "  ok   no unrendered placeholders"; pass=$((pass+1)); fi

# Absolute root, not "root * ."
if grep -qE '^\s*root \* /' "$TMP/Sites/shop.ldev/Caddyfile"; then echo "  ok   root is absolute"; pass=$((pass+1))
else echo "  FAIL root is not absolute"; fail=$((fail+1)); fi

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
