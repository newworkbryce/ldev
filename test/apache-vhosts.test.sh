#!/bin/bash
# `ldev apply` in apache mode must produce a vhost file that httpd itself accepts, with
# one vhost per HOST — not per folder. A plain folder and a suffixed one are the same
# hostname, and two vhosts sharing a ServerName is the failure this guards: Apache takes
# the first and ignores the second without saying so, serving the wrong directory.
#
# Certificates are generated with openssl, not mkcert: `httpd -t` reads the cert files,
# so they have to be real, but a test has no business creating a CA on the machine that
# runs it. `ldev apply` reuses any pair that is already there, so this exercises the same
# path without issuing anything.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-apache-XXXX)
mkdir -p "$TMP/.config/ldev/certs" "$TMP/Sites" "$TMP/Logs" "$TMP/dash"
cat > "$TMP/.config/ldev/config" <<EOF
TLD=ldev
SITES=$TMP/Sites
MODE=apache
PHP_FPM=127.0.0.1:9000
DASHBOARD=$TMP/dash
ADMIN_PORT=2019
SITE_PORT_BASE=8443
ASK_PORT=2018
LOGDIR=$TMP/Logs
REPO_DIR=$REPO
EOF

# shop is plain, blog is named the old way, both/ and both.ldev are one host.
mkdir -p "$TMP/Sites/shop" "$TMP/Sites/blog.ldev" "$TMP/Sites/both" "$TMP/Sites/both.ldev"
echo PLAIN-SHOP > "$TMP/Sites/shop/index.html"
echo OLD-BLOG   > "$TMP/Sites/blog.ldev/index.html"
echo PLAIN-BOTH > "$TMP/Sites/both/index.html"
echo OLD-BOTH   > "$TMP/Sites/both.ldev/index.html"
echo DASHBOARD  > "$TMP/dash/index.html"

for h in ldev shop.ldev blog.ldev both.ldev; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$h" \
    -keyout "$TMP/.config/ldev/certs/$h-key.pem" -out "$TMP/.config/ldev/certs/$h.pem" >/dev/null 2>&1
done

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

# `apply` ends by reloading httpd, which needs sudo and is not this test's business.
# Stub sudo (and apachectl) on the PATH so the render and the syntax check run alone.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sudo";      chmod +x "$TMP/bin/sudo"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/apachectl"; chmod +x "$TMP/bin/apachectl"

out="$(HOME="$TMP" PATH="$TMP/bin:$PATH" "$REPO/bin/ldev" apply 2>&1)"
echo "$out" | sed 's/^/    /'
V="$TMP/.config/ldev/httpd-vhosts.conf"

if [ -f "$V" ]; then echo "  ok   vhost file written"; pass=$((pass+1))
else echo "  FAIL no vhost file at $V"; fail=$((fail+1)); echo; echo "passed=$pass failed=$fail"; rm -rf "$TMP"; exit 1; fi

if grep -q '__[A-Z_]*__' "$V"; then
  echo "  FAIL unrendered placeholders:"; grep -o '__[A-Z_]*__' "$V" | sort -u | sed 's/^/       /'; fail=$((fail+1))
else echo "  ok   no unrendered placeholders"; pass=$((pass+1)); fi

check "https vhosts"        "$(grep -c 'ServerName .*\.ldev$' "$V")" "3"
check "shop has one vhost"  "$(grep -c 'ServerName shop\.ldev$' "$V")" "1"
check "old-style blog too"  "$(grep -c 'ServerName blog\.ldev$' "$V")" "1"
check "one vhost per host"  "$(grep -c 'ServerName both\.ldev$' "$V")" "1"

# ...and the surviving one is the plain folder, the same precedence as auto mode.
if grep -A2 'ServerName both\.ldev$' "$V" | grep -q "DocumentRoot \"$TMP/Sites/both\""; then
  echo "  ok   both.ldev serves the plain folder"; pass=$((pass+1))
else echo "  FAIL both.ldev does not serve $TMP/Sites/both"; fail=$((fail+1)); fi

# The wildcard HTTP vhost is what makes a new folder work with no config at all.
grep -q 'VirtualDocumentRoot' "$V" \
  && { echo "  ok   wildcard http vhost present"; pass=$((pass+1)); } \
  || { echo "  FAIL no VirtualDocumentRoot"; fail=$((fail+1)); }

# The real check: httpd's own parser. `ldev apply` already ran it — this asserts that it
# did, and that the file it kept is the one that passed.
if ! command -v httpd >/dev/null 2>&1; then
  echo "  skip httpd -t (httpd not on PATH)"
else
  if echo "$out" | grep -q 'not syntax-checked'; then
    echo "  FAIL apply skipped the syntax check while httpd is installed"; fail=$((fail+1))
  else echo "  ok   apply syntax-checked the file"; pass=$((pass+1)); fi

  # And an independent run of the same check, so a bug in apply's plumbing cannot hide a
  # broken template by reporting success.
  ROOT="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/opt/httpd"
  [ -d "$ROOT/lib/httpd/modules" ] || ROOT="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  {
    printf 'ServerRoot "%s"\nServerName t\nPidFile "%s/httpd.pid"\nErrorLog "%s/main-error.log"\n' "$ROOT" "$TMP" "$TMP"
    for m in mpm_event authz_core authz_host unixd mime dir log_config vhost_alias rewrite proxy proxy_fcgi ssl socache_shmcb; do
      printf 'LoadModule %s_module lib/httpd/modules/mod_%s.so\n' "$m" "$m"
    done
    printf 'Include "%s"\n' "$V"
  } > "$TMP/wrapper.conf"
  if httpd -t -f "$TMP/wrapper.conf" >"$TMP/httpd-t.log" 2>&1; then
    echo "  ok   httpd -t accepts the vhost file"; pass=$((pass+1))
  else
    echo "  FAIL httpd -t rejected it"; tail -4 "$TMP/httpd-t.log" | sed 's/^/       /'; fail=$((fail+1))
  fi

  # Syntax is not behaviour. The hostname -> folder mapping is three RewriteCond pairs
  # deep, and every one of them is the kind of thing that parses fine and resolves wrong,
  # so serve the file and ask it. Port 80 needs root; the wildcard vhost is identical on
  # any port, so it is moved to a high one for this.
  PORT=8898
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    echo "  skip serving checks (something already listens on $PORT)"
  else
    sed -e "s|^Include |Listen $PORT\nInclude |" "$TMP/wrapper.conf" > "$TMP/serve.conf"
    sed -e "s|<VirtualHost \*:80>|<VirtualHost *:$PORT>|" "$V" > "$TMP/serve-vhosts.conf"
    sed -i '' -e "s|Include \"$V\"|Include \"$TMP/serve-vhosts.conf\"|" "$TMP/serve.conf"

    httpd -f "$TMP/serve.conf" -D FOREGROUND >"$TMP/httpd-run.log" 2>&1 &
    HTTPD_PID=$!
    trap 'kill "$HTTPD_PID" 2>/dev/null' EXIT
    for _ in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 "$PORT" 2>/dev/null && break; sleep 0.3; done

    if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
      echo "  FAIL test httpd did not start"; tail -4 "$TMP/httpd-run.log" | sed 's/^/       /'; fail=$((fail+1))
    else
      get() { curl -s --max-time 5 -H "Host: $1" "http://127.0.0.1:$PORT/"; }
      check "plain folder"             "$(get shop.ldev)"    "PLAIN-SHOP"
      check "folder named the old way" "$(get blog.ldev)"    "OLD-BLOG"
      check "plain wins over old"      "$(get both.ldev)"    "PLAIN-BOTH"
      check "unknown host"             "$(get nope.ldev)"    "DASHBOARD"
      check "bare TLD"                 "$(get ldev)"         "DASHBOARD"
    fi
    kill "$HTTPD_PID" 2>/dev/null
    wait "$HTTPD_PID" 2>/dev/null
    trap - EXIT
  fi
fi

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
