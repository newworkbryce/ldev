#!/bin/bash
# The installer's menus, driven by a file of keystrokes instead of a keyboard.
#
# lib/tui.sh reads keys from LDEV_TTY on a single long-lived fd, which is exactly
# what makes this possible: point LDEV_TTY at a file of escape sequences and the
# menu cannot tell the difference. LDEV_FORCE_TUI=1 makes it draw even though
# stdout here is a pipe.
#
# Run under /bin/bash (3.2) as well as a modern bash — the installer has to work
# on a Mac where nothing has been installed yet.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_UNDER_TEST="${1:-/bin/bash}"
TMP=$(mktemp -d /tmp/ldev-tui-XXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1 -> $2"; pass=$((pass+1)); else echo "  FAIL $1: got '$2' want '$3'"; fail=$((fail+1)); fi; }

ESC=$'\033'; UP="$ESC[A"; DOWN="$ESC[B"; CR=$'\n'

# drive <keys> <snippet> -> whatever the snippet writes to fd 4
drive() {
  local keys="$1" snippet="$2"
  printf '%s' "$keys" > "$TMP/keys"
  LDEV_FORCE_TUI=1 LDEV_TTY="$TMP/keys" "$SHELL_UNDER_TEST" -c "
    set -uo pipefail
    . '$REPO/lib/tui.sh'
    tui_init
    $snippet
  " >/dev/null 2>"$TMP/err" 4>"$TMP/out"
  cat "$TMP/out"
}

three='menu_select T 0 one "" two "" three ""; printf "%s" "$MENU_CHOICE" >&4'

echo "--- menu_select ($SHELL_UNDER_TEST)"
check "enter takes the default"   "$(drive "$CR" "$three")"                  "0"
check "one down"                  "$(drive "$DOWN$CR" "$three")"             "1"
check "two down"                  "$(drive "$DOWN$DOWN$CR" "$three")"        "2"
check "down wraps to the top"     "$(drive "$DOWN$DOWN$DOWN$CR" "$three")"   "0"
check "up wraps to the bottom"    "$(drive "$UP$CR" "$three")"               "2"
check "j/k move"                  "$(drive "jjk$CR" "$three")"               "1"
check "a digit selects at once"   "$(drive "3" "$three")"                    "2"
check "a digit past the end waits" "$(drive "9$DOWN$CR" "$three")"           "1"

echo "--- cancelling"
cancel='if menu_select T 0 one "" two ""; then printf "chose:%s" "$MENU_CHOICE" >&4; else printf "cancelled" >&4; fi'
check "esc cancels"               "$(drive "$ESC" "$cancel")"                "cancelled"
check "q cancels"                 "$(drive "q" "$cancel")"                   "cancelled"
check "eof cancels"               "$(drive "" "$cancel")"                    "cancelled"

echo "--- menu_confirm"
conf='if menu_confirm "Go?" yes; then printf yes >&4; else printf no >&4; fi'
confn='if menu_confirm "Go?" no; then printf yes >&4; else printf no >&4; fi'
check "enter takes yes default"   "$(drive "$CR" "$conf")"                   "yes"
check "enter takes no default"    "$(drive "$CR" "$confn")"                  "no"
check "y is a hotkey"             "$(drive "y" "$confn")"                    "yes"
check "n is a hotkey"             "$(drive "n" "$conf")"                     "no"
check "arrow then enter"          "$(drive "$DOWN$CR" "$conf")"              "no"

echo "--- tui_input"
inp='tui_input "Name" "ldev"; printf "%s" "$TUI_VALUE" >&4'
check "typed value wins"          "$(drive "test$CR" "$inp")"                "test"
check "empty line takes default"  "$(drive "$CR" "$inp")"                    "ldev"

echo "--- plain mode never reads a key"
plain=$(LDEV_PLAIN=1 LDEV_TTY=/dev/null "$SHELL_UNDER_TEST" -c "
  set -uo pipefail
  . '$REPO/lib/tui.sh'
  tui_init
  menu_select T 1 one '' two '' three '' || true
  printf '%s ' \"\$MENU_CHOICE\"
  if menu_confirm 'Go?' yes; then printf yes; else printf no; fi
  printf ' interactive=%s unicode=%s color=%s' \"\$TUI_INTERACTIVE\" \"\$TUI_UNICODE\" \"\$TUI_COLOR\"
" 2>/dev/null | tail -1)
check "plain mode falls back to defaults" "$plain" "1 yes interactive=0 unicode=0 color=0"

echo "--- no escape codes leak into a plain run"
leak=$(LDEV_PLAIN=1 LDEV_TTY=/dev/null "$SHELL_UNDER_TEST" -c "
  . '$REPO/lib/tui.sh'; tui_init
  ui_banner hello there; ui_step X Config; ui_ok fine; ui_warn careful; ui_kv Key value
" 2>&1 | grep -c $'\033')
check "escape-code lines in plain output" "$leak" "0"

echo "--- run_task"
task=$(LDEV_PLAIN=1 "$SHELL_UNDER_TEST" -c "
  . '$REPO/lib/tui.sh'; tui_init
  works() { echo hi; }
  broken() { echo 'the reason it broke' >&2; return 3; }
  if run_task 'good' works; then echo GOOD-OK; else echo GOOD-BAD; fi
  if run_task 'bad' broken; then echo BAD-OK; else echo BAD-BAD; fi
" 2>&1)
check "a task that works"  "$(printf '%s' "$task" | grep -c 'GOOD-OK')" "1"
check "a task that fails"  "$(printf '%s' "$task" | grep -c 'BAD-BAD')" "1"

echo "--- installer still parses and answers --help"
"$SHELL_UNDER_TEST" -n "$REPO/install.sh" 2>"$TMP/err" \
  && { echo "  ok   install.sh parses"; pass=$((pass+1)); } \
  || { echo "  FAIL install.sh does not parse"; sed 's/^/       /' "$TMP/err"; fail=$((fail+1)); }
help_out="$("$SHELL_UNDER_TEST" "$REPO/install.sh" --help 2>&1)"
for flag in --defaults --plain --skip-dns --mode; do
  if printf '%s' "$help_out" | grep -q -- "$flag"; then
    echo "  ok   --help documents $flag"; pass=$((pass+1))
  else
    echo "  FAIL --help says nothing about $flag"; fail=$((fail+1))
  fi
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
