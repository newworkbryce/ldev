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

# End of input is not an empty line. A caller that re-asks after rejecting a
# value has to be able to tell the two apart, or it re-asks forever: that is
# exactly how the installer's TLD loop once spun at 100% CPU with its output
# going nowhere anybody could see.
eofin='if tui_input "Name" "ldev"; then printf "ok:%s" "$TUI_VALUE" >&4; else printf "eof:%s:%s" "$TUI_EOF" "$TUI_VALUE" >&4; fi'
check "EOF is reported, not silently defaulted" "$(drive "" "$eofin")"       "eof:1:ldev"
check "a last line with no newline still counts" "$(drive "test" "$eofin")"  "ok:test"
check "an empty line is not EOF"  "$(drive "$CR" "$eofin")"                  "ok:ldev"

# tui_input answers in TUI_VALUE and prompts on stdout, so capturing it with
# $(...) would return the prompt glued to the answer. Prove the prompt is there
# to be captured, so nobody "tidies up" the contract by accident.
promptleak='tui_input "Local TLD" "ldev" >"'"$TMP"'/prompt"; grep -c "Local TLD" "'"$TMP"'/prompt" >&4'
check "the prompt goes to stdout, the answer does not" "$(drive "test$CR" "$promptleak" | tr -d ' \n')" "1"

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

# ------------------------------------------------ the configuration phase, end to end
#
# The whole of install.sh up to the review screen, driven by scripted keys under
# a throwaway HOME. Nothing here may touch the real machine, so every command
# that could — sudo, brew install, launchctl, caddy, mkcert, npm — is shadowed by
# a stub on PATH that records the attempt in a tripwire file and fails. Each test
# then asserts the tripwire was never written: "no sudo was attempted" is checked
# rather than assumed.
#
# Every run is under a watchdog. A test suite for an installer that once spun
# forever must not be able to hang the machine that runs it.

STUB="$TMP/stub"; TRIPWIRE="$TMP/tripwire"; INST_HOME="$TMP/home"
BREW_STUB_PREFIX="$TMP/brew-prefix"          # deliberately never created
mkdir -p "$STUB"
for c in sudo launchctl caddy mkcert npm httpd dnsmasq; do
  cat > "$STUB/$c" <<STUBEOF
#!/bin/sh
echo "$c \$*" >> "$TRIPWIRE"
exit 1
STUBEOF
  chmod +x "$STUB/$c"
done
# `brew --prefix` runs at the top of install.sh before anything is decided, and
# it only reads. Answering it keeps the review screen's paths deterministic;
# anything else brew is asked to do trips the wire.
cat > "$STUB/brew" <<STUBEOF
#!/bin/sh
if [ "\$1" = "--prefix" ]; then echo "$BREW_STUB_PREFIX"; exit 0; fi
echo "brew \$*" >> "$TRIPWIRE"
exit 1
STUBEOF
chmod +x "$STUB/brew"

# install_drive <keys> -> INST_RC, output in $TMP/inst.out, INST_TIMEDOUT
INST_RC=0; INST_TIMEDOUT=0
install_drive() {
  rm -rf "$INST_HOME" "$TRIPWIRE" "$BREW_STUB_PREFIX"
  mkdir -p "$INST_HOME/Sites" "$INST_HOME/Code"
  printf '%s' "$1" > "$TMP/keys"
  HOME="$INST_HOME" PATH="$STUB:$PATH" TERM=xterm-256color \
  LDEV_FORCE_TUI=1 LDEV_TTY="$TMP/keys" \
    "$SHELL_UNDER_TEST" "$REPO/install.sh" >"$TMP/inst.out" 2>&1 &
  local p=$! i=0
  INST_TIMEDOUT=0
  while [ "$i" -lt 100 ] && kill -0 "$p" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$p" 2>/dev/null; then
    INST_TIMEDOUT=1; kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; INST_RC=137
  else
    wait "$p"; INST_RC=$?
  fi
  return 0
}

# The menus paint with escape codes; assertions read the text underneath.
strip_esc() { sed "s/${ESC}\[[0-9;?]*[a-zA-Z]//g"; }
inst_text() { strip_esc < "$TMP/inst.out"; }

# A grep bracket expression matches bytes, not characters, so [✅❌] also matches
# the em dash that shares a lead byte with them. Fixed strings are the only
# honest way to ask whether a supposedly plain run printed an emoji.
emoji_lines() { grep -c -F -e '✅' -e '❌' -e '⚙' -e '🚀' -e '📦' -e '📁' -e '⚡' -e '🎉' -e '❯' || true; }

# Anything privileged the stubs caught. Never written is the passing state.
priv_attempts() {
  if [ -e "$TRIPWIRE" ]; then grep -cE '^(sudo|launchctl|brew) ' "$TRIPWIRE" || true; else echo 0; fi
}

# The sites menu offers ~/Sites then ~/Code, so DOWN+enter picks ~/Code; the
# mode menu offers auto/persite/apache, so DOWN+enter picks persite; "6" on the
# review screen is "Quit without changing anything".
echo "--- installer: quitting at the review screen writes nothing"
install_drive "test$CR$DOWN$CR$DOWN${CR}6"
check "finished (did not spin)"        "$INST_TIMEDOUT"                          "0"
check "quitting exits non-zero"        "$([ "$INST_RC" -ne 0 ] && echo yes || echo no)" "yes"
check "said nothing was written"       "$(inst_text | grep -c 'nothing was written')"   "1"
check "no config file"                 "$([ -e "$INST_HOME/.config/ldev/config" ] && echo yes || echo no)" "no"
check "no ~/.config/ldev at all"       "$([ -e "$INST_HOME/.config/ldev" ] && echo yes || echo no)"        "no"
check "no dnsmasq conf"                "$([ -e "$BREW_STUB_PREFIX" ] && echo yes || echo no)"              "no"
check "no sites dir created"           "$([ -e "$INST_HOME/Projects" ] && echo yes || echo no)"            "no"
check "no sudo, brew install, launchctl" "$([ -e "$TRIPWIRE" ] && cat "$TRIPWIRE" || echo none)"           "none"

echo "--- installer: the review screen reflects what was chosen"
# The same run: a TLD typed at the prompt and a mode picked from the menu.
check "typed TLD was accepted"    "$(inst_text | grep -c 'is not one label')"           "0"
check "review shows the TLD"      "$(inst_text | grep -cE '^ +TLD +\.test$')"           "1"
check "review shows the mode"     "$(inst_text | grep -cE '^ +Mode +persite$')"         "1"
check "review shows the sites dir" "$(inst_text | grep -cE "^ +Sites +$INST_HOME/Code$")" "1"

echo "--- installer: going back from the review to change the TLD"
# enter takes ~/Sites and auto, "2" is "Change the TLD", then "demo", then quit.
install_drive "test$CR$CR${CR}2demo${CR}6"
check "finished (did not spin)"   "$INST_TIMEDOUT"                                      "0"
check "two review screens"        "$(inst_text | grep -c 'Review')"                     "2"
check "the first review had .test" "$(inst_text | grep -cE '^ +TLD +\.test$')"          "1"
check "the second review has .demo" "$(inst_text | grep -cE '^ +TLD +\.demo$')"         "1"
check "the new TLD is the last word" "$(inst_text | grep -E '^ +TLD +\.' | tail -1 | tr -s ' ')" " TLD .demo"
check "the mode survived the edit" "$(inst_text | grep -cE '^ +Mode +auto$')"           "2"
check "still wrote nothing"       "$([ -e "$INST_HOME/.config/ldev" ] && echo yes || echo no)" "no"
check "still no sudo"             "$([ -e "$TRIPWIRE" ] && cat "$TRIPWIRE" || echo none)"      "none"

echo "--- installer: input running out mid-question gives up instead of looping"
# A rejected TLD with nothing left to type. The bug this covers printed the
# rejection ~28,000 times in 25 seconds and never stopped.
install_drive "not a tld!$CR"
check "finished (did not spin)"   "$INST_TIMEDOUT"                                      "0"
check "gave up non-zero"          "$([ "$INST_RC" -ne 0 ] && echo yes || echo no)"      "yes"
check "rejected the value once"   "$(inst_text | grep -c 'is not one label')"           "1"
check "said why it stopped"       "$(inst_text | grep -c 'end of input')"               "1"
check "wrote nothing"             "$([ -e "$INST_HOME/.config/ldev" ] && echo yes || echo no)" "no"

echo "--- installer: --defaults prompts for nothing and runs to the end"
# persite mode is the one that makes no global change, so a whole run finishes
# inside the throwaway HOME without a single privileged step to stub out.
rm -rf "$INST_HOME" "$TRIPWIRE" "$BREW_STUB_PREFIX"; mkdir -p "$INST_HOME/Sites"
def_out="$(HOME="$INST_HOME" PATH="$STUB:$PATH" TERM=xterm-256color LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --defaults --skip-dns --mode persite 2>&1)"
def_rc=$?
check "--defaults succeeded"      "$def_rc"                                             "0"
check "--defaults asked nothing"  "$(printf '%s' "$def_out" | grep -c 'Local TLD')"     "0"
check "--defaults drew no menu"   "$(printf '%s' "$def_out" | grep -c 'enter select')"  "0"
check "--defaults printed no escapes" "$(printf '%s' "$def_out" | grep -c "$ESC")"      "0"
check "--defaults printed no emoji"   "$(printf '%s' "$def_out" | emoji_lines)"          "0"
check "--defaults wrote the config"   "$(grep -c '^TLD=ldev$' "$INST_HOME/.config/ldev/config" 2>/dev/null)" "1"
check "--defaults needed no sudo"     "$(priv_attempts)"                                 "0"

echo "--- installer: a piped, non-tty run stays plain and fails closed"
rm -rf "$INST_HOME" "$TRIPWIRE" "$BREW_STUB_PREFIX"; mkdir -p "$INST_HOME/Sites"
pipe_out="$(HOME="$INST_HOME" PATH="$STUB:$PATH" LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --tld piped --skip-dns 2>&1 | cat)"
check "piped run printed no escapes" "$(printf '%s' "$pipe_out" | grep -c "$ESC")"      "0"
check "piped run printed no emoji"   "$(printf '%s' "$pipe_out" | emoji_lines)"         "0"
# No terminal and no --yes: confirm() answers NO, so the run stops at the review
# rather than proceeding to a sudo that has nowhere to prompt.
check "piped run fails closed"       "$(printf '%s' "$pipe_out" | grep -c 'aborted')"   "1"
check "piped run wrote nothing"      "$([ -e "$INST_HOME/.config/ldev/config" ] && echo yes || echo no)" "no"

echo "--- installer: NO_COLOR"
rm -rf "$INST_HOME" "$TRIPWIRE" "$BREW_STUB_PREFIX"; mkdir -p "$INST_HOME/Sites"
nc_out="$(HOME="$INST_HOME" PATH="$STUB:$PATH" TERM=xterm-256color NO_COLOR=1 LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --defaults --skip-dns --mode persite 2>&1)"
check "NO_COLOR printed no escapes" "$(printf '%s' "$nc_out" | grep -c "$ESC")"         "0"
# NO_COLOR is a preference, not a missing capability: it drops colour without
# costing the user the menus.
nc_tui=$(LDEV_FORCE_TUI=1 NO_COLOR=1 LDEV_TTY=/dev/null "$SHELL_UNDER_TEST" -c "
  . '$REPO/lib/tui.sh'; tui_init
  printf 'interactive=%s color=%s' \"\$TUI_INTERACTIVE\" \"\$TUI_COLOR\"
" 2>/dev/null | strip_esc)
check "NO_COLOR keeps the menus"    "$nc_tui"    "interactive=1 color=0"
rm -rf "$INST_HOME" "$TRIPWIRE" "$BREW_STUB_PREFIX"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
