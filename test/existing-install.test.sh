#!/bin/bash
# The installer takes down what it is replacing, which means deciding — per launchd job —
# whether that job is IN THE WAY or about to be fronted. Getting it backwards deletes a
# working site's server, so every case is asserted against a real plist + Caddyfile pair.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-existing-XXXX)
SITES="$TMP/Sites"; mkdir -p "$SITES"

# port_busy is a one-liner, so a /^}/ range for it runs on to the next function's closing
# brace. Take the multi-line helpers by range and that one by its own line.
sed -n '/^port_owner()/,/^}/p;/^ldev_launchd_jobs()/,/^}/p;/^plist_label()/,/^}/p;/^job_wants_privileged_port()/,/^}/p' "$REPO/install.sh" > "$TMP/fns.sh"
grep '^port_busy()' "$REPO/install.sh" >> "$TMP/fns.sh"
TLD=ldev
# shellcheck disable=SC1090
. "$TMP/fns.sh"

pass=0; fail=0
inway()  { if job_wants_privileged_port "$1"; then echo "  ok   $2 — in the way"; pass=$((pass+1)); else echo "  FAIL $2: should be in the way, was kept"; fail=$((fail+1)); fi; }
kept()   { if job_wants_privileged_port "$1"; then echo "  FAIL $2: should be kept, was marked for removal"; fail=$((fail+1)); else echo "  ok   $2 — kept"; pass=$((pass+1)); fi; }

# A plist naming a Caddyfile, the way a real one does.
mkjob() {
  local name="$1" cfg="$2"
  cat > "$TMP/$name.plist" <<PEOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.example.$name</string>
  <key>ProgramArguments</key><array>
    <string>/opt/homebrew/bin/caddy</string>
    <string>run</string>
    <string>--config</string>
    <string>$cfg</string>
  </array>
</dict></plist>
PEOF
}

site() { mkdir -p "$SITES/$1"; printf '%s\n' "$2" > "$SITES/$1/Caddyfile"; }

echo "a bare hostname means 443:"
site bare 'bare.ldev {
	root * /x
}'
mkjob bare "$SITES/bare/Caddyfile"
inway "$TMP/bare.plist" "bare.ldev (no port)"

echo "an explicit high port does not:"
site high 'high.ldev:8443 {
	root * /x
}'
mkjob high "$SITES/high/Caddyfile"
kept "$TMP/high.plist" "high.ldev:8443"

echo "http:// with no port means 80:"
site plain 'http://plain.ldev {
	root * /x
}'
mkjob plain "$SITES/plain/Caddyfile"
inway "$TMP/plain.plist" "http://plain.ldev"

echo "http:// with a high port does not:"
site plainport 'http://plainport.ldev:8080 {
	root * /x
}'
mkjob plainport "$SITES/plainport/Caddyfile"
kept "$TMP/plainport.plist" "http://plainport.ldev:8080"

echo "the real trap — two addresses on one line, only ONE of them ported:"
# This is the shape that motivated the check. Reading the first port on the LINE sees 8444
# and calls the whole file unprivileged, leaving the job that holds 443 in place.
site mixed 'mixed.ldev, mixed-dev.ldev:8444 {
	root * /x
}'
mkjob mixed "$SITES/mixed/Caddyfile"
inway "$TMP/mixed.plist" "mixed.ldev, mixed-dev.ldev:8444"

echo ":443 named outright:"
site explicit 'explicit.ldev:443 {
	root * /x
}'
mkjob explicit "$SITES/explicit/Caddyfile"
inway "$TMP/explicit.plist" "explicit.ldev:443"

echo "a global block is not an address:"
site globalonly '{
	admin localhost:2019
}

globalonly.ldev:8443 {
	root * /x
}'
mkjob globalonly "$SITES/globalonly/Caddyfile"
kept "$TMP/globalonly.plist" "keyless global block ignored"

echo "a plist whose Caddyfile is missing is not assumed to be in the way:"
mkjob ghost "$SITES/nosuchsite/Caddyfile"
kept "$TMP/ghost.plist" "unreadable config"

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
