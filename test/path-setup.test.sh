#!/bin/bash
# The installer offers to put bin/ldev on the PATH, which means picking a startup file and
# a syntax per shell. Both are easy to get subtly wrong in ways that fail silently — the
# line lands somewhere real, the installer says it worked, and the shell still cannot find
# ldev — so each shell is asserted rather than assumed.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/ldev-path-XXXX)

# Pull the two functions out of install.sh, so the test needs no install and no sudo.
sed -n '/^shell_rc()/,/^}/p;/^path_line()/,/^}/p' "$REPO/install.sh" > "$TMP/fns.sh"
REPO_DIR="$REPO"
HOME="$TMP"
# shellcheck disable=SC1090
. "$TMP/fns.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

echo "startup file per shell:"
check "zsh"  "$(SHELL=/bin/zsh shell_rc)"  "$TMP/.zshrc"
check "fish" "$(SHELL=/usr/local/bin/fish shell_rc)" "$TMP/.config/fish/config.fish"
check "ksh"  "$(SHELL=/bin/ksh shell_rc)"  "$TMP/.kshrc"
# An unknown shell must return EMPTY so the installer prints the line instead of writing to
# a file it guessed at. Returning a plausible-looking default would be the harmful answer.
check "unknown shell is empty" "$(SHELL=/bin/nonesuch shell_rc)" ""

echo "bash on macOS reads .bash_profile for a login shell, never .bashrc:"
# Both exist: .bash_profile must still win, because Terminal opens login shells.
: > "$TMP/.bash_profile"
: > "$TMP/.bashrc"
check "prefers .bash_profile" "$(SHELL=/bin/bash shell_rc)" "$TMP/.bash_profile"
rm -f "$TMP/.bash_profile"
# Without it, .profile — which a login bash also reads — not .bashrc, which it does not.
check "falls back to .profile" "$(SHELL=/bin/bash shell_rc)" "$TMP/.profile"

echo "syntax per shell:"
# `export PATH="...:$PATH"` is a syntax error in fish, so this is not cosmetic.
check "posix export" "$(SHELL=/bin/zsh path_line)" "export PATH=\"$REPO/bin:\$PATH\""
check "fish"         "$(SHELL=/usr/local/bin/fish path_line)" "fish_add_path $REPO/bin"

echo "the line the installer would write:"
# Re-running the installer must not stack duplicates; it greps for the bin path first, so
# assert the written line actually contains what that grep looks for.
line="$(SHELL=/bin/zsh path_line)"
printf '\n# ldev\n%s\n' "$line" > "$TMP/.zshrc"
if grep -qF "$REPO/bin" "$TMP/.zshrc"; then echo "  ok   a second run would detect it"; pass=$((pass+1))
else echo "  FAIL the idempotence grep would not match what was written"; fail=$((fail+1)); fi

rm -rf "$TMP"
echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
