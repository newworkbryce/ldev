#!/bin/bash
# Auto mode resolves a hostname to a directory, and that mapping is the whole product.
# This renders the REAL template and serves it, rather than asserting on its text:
#
#   Sites/shop        ->  https://shop.ldev      (a folder is just the site name)
#   Sites/blog.ldev   ->  https://blog.ldev      (folders named the old way still work)
#   both + both.ldev  ->  the plain folder wins
#   no folder at all  ->  the dashboard, not a 404
#
# The served config is the rendered template with TLS and the privileged addresses
# swapped for one high HTTP port — ports 80 and 443 need root, and the root-selection
# lines under test are identical either way.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-auto-XXXX)
SITES="$TMP/Sites"; DASH="$TMP/dash"; PORT=8899
mkdir -p "$SITES/shop" "$SITES/blog.ldev" "$SITES/both" "$SITES/both.ldev" "$DASH" "$TMP/logs"
echo PLAIN-SHOP  > "$SITES/shop/index.html"
echo OLD-BLOG    > "$SITES/blog.ldev/index.html"
echo PLAIN-BOTH  > "$SITES/both/index.html"
echo OLD-BOTH    > "$SITES/both.ldev/index.html"
echo DASHBOARD   > "$DASH/index.html"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

sed -e "s|__TLD__|ldev|g" -e "s|__SITES__|$SITES|g" -e "s|__DASHBOARD__|$DASH|g" \
    -e "s|__PHP_FPM__|127.0.0.1:9000|g" -e "s|__ADMIN_PORT__|2019|g" \
    -e "s|__ASK_PORT__|2018|g" -e "s|__LOGDIR__|$TMP/logs|g" \
    "$REPO/templates/Caddyfile.auto.tmpl" > "$TMP/Caddyfile"

if grep -q '__[A-Z_]*__' "$TMP/Caddyfile"; then
  echo "  FAIL unrendered placeholders:"; grep -o '__[A-Z_]*__' "$TMP/Caddyfile" | sort -u | sed 's/^/       /'; fail=$((fail+1))
else echo "  ok   no unrendered placeholders"; pass=$((pass+1)); fi

if ! command -v caddy >/dev/null 2>&1; then
  echo "  skip everything else (caddy not on PATH)"
  rm -rf "$TMP"; echo; echo "passed=$pass failed=$fail"; exit 0
fi

if caddy validate --config "$TMP/Caddyfile" >/dev/null 2>&1; then
  echo "  ok   rendered Caddyfile validates"; pass=$((pass+1))
else
  echo "  FAIL rendered Caddyfile does not validate"; caddy validate --config "$TMP/Caddyfile" 2>&1 | tail -3; fail=$((fail+1))
fi

# Same file, moved off the privileged ports and off TLS: `admin off` so it cannot collide
# with a real ldev Caddy, no automatic HTTPS, and each site address rewritten to :$PORT.
mkdir -p "$TMP/serve"
awk -v port="$PORT" '
  /^\tlocal_certs$/                 { next }
  /^\ton_demand_tls \{$/            { skip = 1; next }
  /^\t\ttls \{$/                    { skip = 1; next }
  /^\ttls \{$/                      { skip = 1; next }
  skip && /^\t*\}$/                 { skip = 0; next }
  skip                              { next }
  /^\tadmin localhost:/             { print "\tadmin off"; print "\tauto_https off"; next }
  /^\*\.ldev \{$/                   { print "http://*.ldev:" port " {"; next }
  /^ldev \{$/                       { print "http://ldev:" port " {"; next }
  /^http:\/\/\*\.localhost \{$/     { print "http://*.localhost:" port " {"; next }
  /^http:\/\/localhost \{$/         { print "http://localhost:" port " {"; next }
  { print }
' "$TMP/Caddyfile" > "$TMP/serve/Caddyfile"

if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "  skip serving checks (something already listens on $PORT)"
  rm -rf "$TMP"; echo; echo "passed=$pass failed=$fail"; exit 0
fi

if ! caddy start --config "$TMP/serve/Caddyfile" --pidfile "$TMP/caddy.pid" >"$TMP/caddy.log" 2>&1; then
  echo "  FAIL test server did not start"; tail -5 "$TMP/caddy.log" | sed 's/^/       /'; fail=$((fail+1))
  rm -rf "$TMP"; echo; echo "passed=$pass failed=$fail"; exit 1
fi
# Kill by pidfile, not `caddy stop`: this config sets `admin off`, and `caddy stop` talks
# to the admin API — so it silently fails and leaves a server holding $PORT, which the next
# run of this test then skips itself over.
trap 'kill "$(cat "$TMP/caddy.pid" 2>/dev/null)" 2>/dev/null; rm -rf "$TMP"' EXIT

get() { curl -s --max-time 5 -H "Host: $1" "http://127.0.0.1:$PORT/"; }

check "plain folder"            "$(get shop.ldev)"       "PLAIN-SHOP"
check "folder named the old way" "$(get blog.ldev)"      "OLD-BLOG"
check "plain wins over old"     "$(get both.ldev)"       "PLAIN-BOTH"
check "unknown host"            "$(get nothing.ldev)"    "DASHBOARD"
check "bare TLD is the dashboard" "$(get ldev)"          "DASHBOARD"

# The .localhost origin must agree with the TLD origin about which folder a name means.
check ".localhost plain"        "$(get shop.localhost)"  "PLAIN-SHOP"
check ".localhost old way"      "$(get blog.localhost)"  "OLD-BLOG"
check ".localhost plain wins"   "$(get both.localhost)"  "PLAIN-BOTH"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
