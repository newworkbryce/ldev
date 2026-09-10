#!/bin/bash
# A proxied site points at a dev server somebody starts and stops all day, so the case that
# matters is the one where it is NOT running. These assertions run a real Caddy against a
# real upstream, then kill the upstream and check what the site does next.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-proxy-XXXX)
mkdir -p "$TMP/.config/ldev" "$TMP/Sites" "$TMP/Logs" "$TMP/build"
echo "STALE-BUILD" > "$TMP/build/index.html"

cfg() {
  cat > "$TMP/.config/ldev/config" <<EOF
TLD=ldev
SITES=$TMP/Sites
PHP_FPM=127.0.0.1:9000
DASHBOARD=$REPO/dashboard/dist
ADMIN_PORT=2019
SITE_PORT_BASE=8443
ASK_PORT=2018
PROXY_FALLBACK=$1
LOGDIR=$TMP/Logs
REPO_DIR=$REPO
EOF
}

run() { HOME="$TMP" LDEV_SKIP_PORT_PROBE=1 "$REPO/bin/ldev" "$@"; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }
has()   { if grep -q "$2" "$3"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
hasnt() { if grep -q "$2" "$3"; then echo "  FAIL $1"; fail=$((fail+1)); else echo "  ok   $1"; pass=$((pass+1)); fi; }

UP=21771   # the "dev server" port
C="$TMP/.config/ldev/Caddyfile"

echo "ldev proxy records the port:"
cfg no
run proxy app "$UP" --fallback "$TMP/build" >/dev/null 2>&1
check "marker written" "$([ -f "$TMP/Sites/app/.ldev-proxy" ] && echo yes || echo no)" "yes"
check "port recorded"  "$(sed -n 's/^PORT=//p' "$TMP/Sites/app/.ldev-proxy")" "$UP"
check "listed as a proxy" "$(run list 2>/dev/null | grep -c "proxy :$UP")" "1"

echo "with the fallback turned OFF:"
run render >/dev/null 2>&1
has   "the site is proxied"        "reverse_proxy 127.0.0.1:$UP" "$C"
hasnt "no handle_errors block"     "handle_errors"               "$C"

echo "with the fallback turned ON:"
cfg yes
run render >/dev/null 2>&1
has "handle_errors is emitted"     "handle_errors"    "$C"
has "it roots at the build"        "root \* $TMP/build" "$C"

if ! command -v caddy >/dev/null 2>&1; then
  echo "  skip live cases (caddy not on PATH)"
else
  # Serve the generated config on a spare port so the assertions run against real Caddy
  # behaviour rather than against the text of a config file.
  SERVE=21772
  sed -e "s|^app\.ldev {|http://app.ldev:$SERVE {|" -e '/tls {/,/}/d' "$C" > "$TMP/serve.Caddyfile"
  # Only the proxy block is wanted here; drop everything else so nothing fights for a port.
  awk '/^http:\/\/app\.ldev:'"$SERVE"' \{/{f=1} f{print} f&&/^}/{exit}' "$TMP/serve.Caddyfile" > "$TMP/only.Caddyfile"
  printf '{\n\tadmin off\n\tauto_https off\n}\n\n' | cat - "$TMP/only.Caddyfile" > "$TMP/live.Caddyfile"

  if caddy validate --config "$TMP/live.Caddyfile" >/dev/null 2>&1; then
    echo "  ok   the generated proxy block validates"; pass=$((pass+1))

    python3 -c "
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'LIVE-UPSTREAM')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', $UP), H).serve_forever()" >/dev/null 2>&1 &
    UPPID=$!
    caddy start --config "$TMP/live.Caddyfile" >/dev/null 2>&1
    sleep 2

    echo "upstream running:"
    check "serves the dev server" "$(curl -s --max-time 5 http://app.ldev:$SERVE/ 2>/dev/null)" "LIVE-UPSTREAM"

    echo "upstream stopped, fallback ON:"
    # `wait` inside the same redirect, or bash prints its own "Terminated" job notice.
    { kill "$UPPID"; wait "$UPPID"; } >/dev/null 2>&1 || true
    sleep 1
    check "serves the last build" "$(curl -s --max-time 5 http://app.ldev:$SERVE/ 2>/dev/null)" "STALE-BUILD"

    caddy stop --config "$TMP/live.Caddyfile" >/dev/null 2>&1
    pkill -f "$TMP/live.Caddyfile" 2>/dev/null || true
  else
    echo "  FAIL the generated proxy block does not validate"
    caddy validate --config "$TMP/live.Caddyfile" 2>&1 | tail -4
    fail=$((fail+1))
  fi
fi

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
