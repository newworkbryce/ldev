#!/bin/bash
# `ldev rehome` rewrites real site data, so what is tested here is mostly what it REFUSES
# to do. The happy path needs a live WordPress database and is exercised by hand; every
# guard in front of it can be checked without one.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-rehome-XXXX)
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

run() { HOME="$TMP" "$REPO/bin/ldev" "$@"; }
pass=0; fail=0
says() { if printf '%s' "$2" | grep -q "$3"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; echo "       got: $2"; fail=$((fail+1)); fi; }

echo "a site that does not exist:"
out="$(run rehome nosuchsite 2>&1)"
says "is refused" "$out" "no directory for"

echo "a directory that is not WordPress:"
mkdir -p "$TMP/Sites/plain"
echo hi > "$TMP/Sites/plain/index.html"
out="$(run rehome plain 2>&1)"
says "is refused by name" "$out" "not a WordPress site"

echo "a name that cannot be a hostname:"
out="$(run rehome 'bad name' 2>&1)"
says "is refused" "$out" "is not a site name"

if ! command -v wp >/dev/null 2>&1; then
  echo "  skip  already-portless case (wp-cli not on PATH)"
else
  echo "a site already on its portless URL:"
  mkdir -p "$TMP/Sites/done"
  cat > "$TMP/Sites/done/wp-config.php" <<'WPEOF'
<?php
define( 'WP_HOME', 'https://done.ldev' );
define( 'WP_SITEURL', 'https://done.ldev' );
WPEOF
  before="$(cat "$TMP/Sites/done/wp-config.php")"
  out="$(run rehome done 2>&1)"
  says "is a no-op" "$out" "already at https://done.ldev"
  # The point of the no-op is that it touches nothing, so assert that rather than the text.
  if [ "$before" = "$(cat "$TMP/Sites/done/wp-config.php")" ]; then echo "  ok   wp-config.php untouched"; pass=$((pass+1))
  else echo "  FAIL wp-config.php was modified by a no-op"; fail=$((fail+1)); fi
  if ls "$TMP/Sites/done"/.ldev-rehome-*.sql >/dev/null 2>&1; then echo "  FAIL a no-op still exported a backup"; fail=$((fail+1))
  else echo "  ok   no backup written for a no-op"; pass=$((pass+1)); fi

  echo "a real move, with no way to confirm it:"
  mkdir -p "$TMP/Sites/ported"
  cat > "$TMP/Sites/ported/wp-config.php" <<'WPEOF'
<?php
define( 'WP_HOME', 'https://ported.ldev:8443' );
define( 'WP_SITEURL', 'https://ported.ldev:8443' );
WPEOF
  before="$(cat "$TMP/Sites/ported/wp-config.php")"
  # No tty here, and no --yes: it must stop rather than assume consent for a data rewrite.
  out="$(run rehome ported </dev/null 2>&1)"
  says "stops without a terminal" "$out" "refusing to rewrite site data"
  if [ "$before" = "$(cat "$TMP/Sites/ported/wp-config.php")" ]; then echo "  ok   wp-config.php untouched"; pass=$((pass+1))
  else echo "  FAIL wp-config.php was modified without confirmation"; fail=$((fail+1)); fi
fi

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
