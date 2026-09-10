#!/bin/bash
# End-to-end for the single-mode flow:
#   ldev new         creates a directory and NOTHING else — the wildcard server serves it
#   ldev standalone  gives one site its own server, on a pair of ports nobody else holds
#   ldev render      writes a wildcard config that proxies to each of those servers
#
# Two assertions here are regressions rather than features: a second site must get a
# DIFFERENT admin port, and neither may be handed the wildcard server's own.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-e2e-XXXX)
mkdir -p "$TMP/.config/ldev" "$TMP/Sites" "$TMP/Logs"
cat > "$TMP/.config/ldev/config" <<EOF
TLD=ldev
SITES=$TMP/Sites
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
yes() { if [ "$2" = "0" ]; then echo "  FAIL $1"; fail=$((fail+1)); else echo "  ok   $1"; pass=$((pass+1)); fi; }

echo "--- ldev new shop / blog"
run new shop 2>&1 | sed 's/^/    /'
run new blog 2>&1 | sed 's/^/    /'
echo

# A plain new site is a directory, full stop. Anything else here would mean the suffix or a
# config file had crept back into the cheapest path.
check "new makes a bare directory" "$([ -d "$TMP/Sites/shop" ] && echo yes)" "yes"
check "new writes no Caddyfile"    "$([ -f "$TMP/Sites/shop/Caddyfile" ] && echo yes || echo no)" "no"

echo
echo "--- ldev standalone shop / blog"
run standalone shop 2>&1 | sed 's/^/    /'
run standalone blog 2>&1 | sed 's/^/    /'
echo

for s in shop blog; do
  f="$TMP/Sites/$s/Caddyfile"
  if [ -f "$f" ]; then echo "  ok   $s Caddyfile written"; pass=$((pass+1)); else echo "  FAIL $s Caddyfile missing"; fail=$((fail+1)); continue; fi
  # No caddy means nothing to validate against, which is not the same as invalid — reporting
  # it as a failure would blame the config for the machine.
  if ! command -v caddy >/dev/null 2>&1; then echo "  skip $s validates (caddy not on PATH)"; continue; fi
  if caddy validate --config "$f" >/dev/null 2>&1; then echo "  ok   $s validates"; pass=$((pass+1)); else echo "  FAIL $s does not validate"; caddy validate --config "$f" 2>&1 | tail -3; fail=$((fail+1)); fi
done

a_shop=$(grep -oE 'admin localhost:[0-9]+' "$TMP/Sites/shop/Caddyfile" | grep -oE '[0-9]+$')
a_blog=$(grep -oE 'admin localhost:[0-9]+' "$TMP/Sites/blog/Caddyfile" | grep -oE '[0-9]+$')
s_shop=$(grep -oE 'shop\.ldev:[0-9]+' "$TMP/Sites/shop/Caddyfile" | head -1 | grep -oE '[0-9]+$')
s_blog=$(grep -oE 'blog\.ldev:[0-9]+' "$TMP/Sites/blog/Caddyfile" | head -1 | grep -oE '[0-9]+$')

check "shop site port"  "$s_shop" "8443"
check "shop admin port" "$a_shop" "2020"
check "blog site port"  "$s_blog" "8444"
check "blog admin port" "$a_blog" "2021"

# The two regressions, each stated as its own assertion.
if [ "$a_shop" != "$a_blog" ]; then echo "  ok   admin ports differ"; pass=$((pass+1)); else echo "  FAIL both sites got admin $a_shop — the second Caddy would exit at startup"; fail=$((fail+1)); fi
if [ "$a_shop" != "2019" ] && [ "$a_blog" != "2019" ]; then echo "  ok   neither took the wildcard server's admin port"; pass=$((pass+1)); else echo "  FAIL a site was handed 2019, which the wildcard server holds"; fail=$((fail+1)); fi

# No leftover placeholders.
if grep -q '__[A-Z_]*__' "$TMP/Sites/shop/Caddyfile"; then
  echo "  FAIL unrendered placeholders:"; grep -o '__[A-Z_]*__' "$TMP/Sites/shop/Caddyfile" | sort -u | sed 's/^/       /'; fail=$((fail+1))
else echo "  ok   no unrendered placeholders"; pass=$((pass+1)); fi

# Absolute root, not "root * ."
if grep -qE '^\s*root \* /' "$TMP/Sites/shop/Caddyfile"; then echo "  ok   root is absolute"; pass=$((pass+1))
else echo "  FAIL root is not absolute"; fail=$((fail+1)); fi

echo
echo "--- ldev render"
run render 2>&1 | sed 's/^/    /'
echo
C="$TMP/.config/ldev/Caddyfile"

# The proxy block is the join between the two halves. Without it a standalone site's own
# server runs perfectly and the portless URL still reaches nothing.
yes "wildcard config written"                  "$([ -f "$C" ] && echo 1 || echo 0)"
yes "shop is proxied by name"                  "$(grep -c '^shop\.ldev {' "$C")"
yes "blog is proxied by name"                  "$(grep -c '^blog\.ldev {' "$C")"
yes "shop proxies to its own port over http"   "$(grep -c 'reverse_proxy http://127\.0\.0\.1:8443' "$C")"
yes "blog proxies to its own port over http"   "$(grep -c 'reverse_proxy http://127\.0\.0\.1:8444' "$C")"
if grep -q '__[A-Z_]*__' "$C"; then
  echo "  FAIL unrendered placeholders in the wildcard config:"; grep -o '__[A-Z_]*__' "$C" | sort -u | sed 's/^/       /'; fail=$((fail+1))
else echo "  ok   no unrendered placeholders in the wildcard config"; pass=$((pass+1)); fi
yes "the wildcard block survives"              "$(grep -c '^\*\.ldev {' "$C")"
yes "the dashboard fallback survives"          "$(grep -c "$REPO/dashboard/dist" "$C")"

if command -v caddy >/dev/null 2>&1; then
  if caddy validate --config "$C" >/dev/null 2>&1; then echo "  ok   wildcard config validates"; pass=$((pass+1))
  else echo "  FAIL wildcard config does not validate"; caddy validate --config "$C" 2>&1 | tail -5; fail=$((fail+1)); fi
else
  echo "  skip wildcard config validates (caddy not on PATH)"
fi

echo
echo "--- a site claiming the wildcard server's own port"

# Hand-written Caddyfiles exist, and a Caddy address line gives each host on it its OWN
# address — so `x.ldev, y.ldev:8444 {` silently puts x.ldev on the default 443. Fronting
# that would emit a block proxying x.ldev to this very server: a loop with no site at the
# end of it. It must be skipped, and it must say so.
mkdir -p "$TMP/Sites/legacy"
printf '{\n\tadmin localhost:2099\n}\n\nlegacy.ldev, other.ldev:8444 {\n\troot * /x\n}\n' > "$TMP/Sites/legacy/Caddyfile"

warn="$(run render 2>&1 >/dev/null)"
run render >/dev/null 2>&1

if printf '%s' "$warn" | grep -q 'legacy.ldev on port 443'; then echo "  ok   the clash is reported"; pass=$((pass+1))
else echo "  FAIL nothing warned about legacy.ldev on 443"; fail=$((fail+1)); fi

if grep -q '^legacy\.ldev {' "$C"; then echo "  FAIL legacy.ldev was fronted anyway — that config proxies to itself"; fail=$((fail+1))
else echo "  ok   legacy.ldev is not fronted"; pass=$((pass+1)); fi

if grep -q 'reverse_proxy https://127\.0\.0\.1:443' "$C"; then echo "  FAIL a block proxies to port 443 — the loop"; fail=$((fail+1))
else echo "  ok   nothing proxies to 443"; pass=$((pass+1)); fi

if command -v caddy >/dev/null 2>&1; then
  if caddy validate --config "$C" >/dev/null 2>&1; then echo "  ok   config still validates"; pass=$((pass+1))
  else echo "  FAIL config no longer validates"; fail=$((fail+1)); fi
fi

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
