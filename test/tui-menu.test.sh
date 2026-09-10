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

# The installer looks at what is already installed before it writes anything, and the Mac
# running this suite very likely has an ldev of its own: a real
# /Library/LaunchDaemons/com.ldev.caddy.plist, real LaunchAgents, a real Caddy holding 443.
# Every install.sh run below is pointed at empty stand-ins for the launchd directories and
# told not to probe ports, so "what is already installed" is answered by this temporary
# directory rather than by whoever's machine this is.
LD_DIR="$TMP/LaunchDaemons"; LA_DIR="$TMP/LaunchAgents"
export LDEV_LAUNCHDAEMONS="$LD_DIR" LDEV_LAUNCHAGENTS="$LA_DIR" LDEV_SKIP_PORT_PROBE=1
export HOME="$TMP/neutral-home"
mkdir -p "$LD_DIR" "$LA_DIR" "$HOME"

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

echo "--- the cursor always comes back"
# A menu hides the cursor while it draws. Whatever happens next — a choice, a
# cancel, or a signal — the terminal must not be left without one, because that
# outlives the process that did it.
SHOW=$'\033[?25h'
printf '%s' "$DOWN$CR" > "$TMP/keys"
LDEV_FORCE_TUI=1 LDEV_TTY="$TMP/keys" "$SHELL_UNDER_TEST" -c "
  . '$REPO/lib/tui.sh'; tui_init; menu_select T 0 one '' two '' || true
" >"$TMP/cur" 2>/dev/null
check "a finished menu leaves the cursor shown" \
  "$(tail -c 6 "$TMP/cur" | grep -cF "$SHOW" || true)" "1"

# Killed in the middle of a menu. The keys come from a fifo that never delivers,
# so the menu is parked in its read when the signal lands.
#
# The signal is TERM rather than INT only because of how this test has to run: a
# job started in the background by a non-interactive shell inherits SIGINT as
# ignored, and a shell that inherits an ignored signal cannot trap it at all. So
# Ctrl-C itself is untestable from here; TERM exercises the same handler.
signal_run() { # signal_run <signal> <expected rc> <label>
  rm -f "$TMP/fifo"; mkfifo "$TMP/fifo"
  ( exec 3>"$TMP/fifo"; sleep 8 ) &
  local holder=$! victim rc
  LDEV_FORCE_TUI=1 LDEV_TTY="$TMP/fifo" "$SHELL_UNDER_TEST" -c "
    . '$REPO/lib/tui.sh'; tui_init; menu_select T 0 one '' two '' || true
  " >"$TMP/sig" 2>/dev/null &
  victim=$!
  sleep 1
  kill -"$1" "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null; rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  check "SIG$1 restores the cursor" "$(tail -c 8 "$TMP/sig" | grep -cF "$SHOW" || true)" "1"
  check "SIG$1 exits $2"            "$rc"                                                "$2"
}
signal_run TERM 143
signal_run HUP 129

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

echo "--- the port probe survives a port it cannot see into"
# Everything else in this file sets LDEV_SKIP_PORT_PROBE=1, so the probe itself is
# the one thing the suite would never run — and that is exactly where the installer
# crashed: lsof exits 1 on a root-owned socket it cannot see, pipefail promotes it,
# and `owner="$(port_owner 80)"` under set -e killed the run right after the banner.
# So probe for real here, against whatever this machine happens to be running.
probe_out="$(env -u LDEV_SKIP_PORT_PROBE HOME="$TMP/neutral-home" \
  LDEV_LAUNCHDAEMONS="$LD_DIR" LDEV_LAUNCHAGENTS="$LA_DIR" LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --tld probe --skip-dns 2>&1 || true)"
check "a real probe gets past the banner" "$(printf '%s' "$probe_out" | grep -c 'Configuration')" "1"
check "a real probe still fails closed"   "$(printf '%s' "$probe_out" | grep -c 'aborted')"       "1"

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
check "--help no longer offers apache" "$(printf '%s' "$help_out" | grep -ci apache)" "0"

# apache was removed because it never worked: its arm rendered
# templates/httpd-vhosts.tmpl, which exists in no revision of this repo, so the
# install died there under set -e. A script still passing the flag should be
# told the mode is gone by name, rather than getting "unknown mode" as if it
# were a typo — and it must stop rather than quietly installing something else.
apache_out="$("$SHELL_UNDER_TEST" "$REPO/install.sh" --mode apache --defaults --skip-dns 2>&1 || true)"
check "--mode apache is refused by name" "$(printf '%s' "$apache_out" | grep -ci "mode 'apache' is not supported")" "1"
check "--mode apache stops the install"  "$(printf '%s' "$apache_out" | grep -c 'Dependencies')"     "0"

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
# The installer now looks at what is already installed before it writes anything, and the
# machine running this suite is very likely to have an ldev of its own — a real
# /Library/LaunchDaemons/com.ldev.caddy.plist, real LaunchAgents, a real Caddy on 443.
# Every run below is pointed at empty stand-ins for those and told not to probe ports, so
# the answer to "what is already installed" is this directory's, not this Mac's.
mkdir -p "$STUB" "$LD_DIR" "$LA_DIR"
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
  # INST_KEEP=1 keeps whatever a test has just planted in HOME and in the fake launchd
  # directories, which is how "the installer found an existing install" is set up.
  if [ "${INST_KEEP:-0}" != 1 ]; then
    rm -rf "$INST_HOME" "$TRIPWIRE" "$BREW_STUB_PREFIX" "$LD_DIR" "$LA_DIR"
    mkdir -p "$INST_HOME/Sites" "$INST_HOME/Code" "$LD_DIR" "$LA_DIR"
  else
    rm -f "$TRIPWIRE"
  fi
  printf '%s' "$1" > "$TMP/keys"
  HOME="$INST_HOME" PATH="$STUB:$PATH" TERM=xterm-256color \
  LDEV_LAUNCHDAEMONS="$LD_DIR" LDEV_LAUNCHAGENTS="$LA_DIR" LDEV_SKIP_PORT_PROBE=1 \
  LDEV_FORCE_TUI=1 LDEV_TTY="$TMP/keys" \
    "$SHELL_UNDER_TEST" "$REPO/install.sh" ${INST_ARGS:-} >"$TMP/inst.out" 2>&1 &
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

# Every question is now a menu, so these are digits rather than typed words: "2" on the
# TLD menu is .test, and a digit selects immediately. The sites menu offers ~/Sites then
# ~/Code, so DOWN+enter picks ~/Code; the mode menu offers auto/persite, so DOWN+enter
# picks persite; "6" on the review screen is "Quit without changing anything".
echo "--- installer: quitting at the review screen writes nothing"
install_drive "2$DOWN$CR$DOWN${CR}6"
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
# "2" picks .test on the TLD menu, enter takes ~/Sites and auto, "2" on the review is
# "Change the TLD", "3" on the TLD menu is "Type a different one…", then "demo", then quit.
install_drive "2$CR${CR}23demo${CR}6"
check "finished (did not spin)"   "$INST_TIMEDOUT"                                      "0"
check "two review screens"        "$(inst_text | grep -c 'Review')"                     "2"
check "the first review had .test" "$(inst_text | grep -cE '^ +TLD +\.test$')"          "1"
check "the second review has .demo" "$(inst_text | grep -cE '^ +TLD +\.demo$')"         "1"
check "the new TLD is the last word" "$(inst_text | grep -E '^ +TLD +\.' | tail -1 | tr -s ' ')" " TLD .demo"
check "the mode survived the edit" "$(inst_text | grep -cE '^ +Mode +auto$')"           "2"
check "still wrote nothing"       "$([ -e "$INST_HOME/.config/ldev" ] && echo yes || echo no)" "no"
check "still no sudo"             "$([ -e "$TRIPWIRE" ] && cat "$TRIPWIRE" || echo none)"      "none"

echo "--- installer: input running out mid-question gives up instead of looping"
# A rejected TLD with nothing left to type — "3" opens the free-text branch first.
# The bug this covers printed the rejection ~28,000 times in 25 seconds and never stopped.
install_drive "3not a tld!$CR"
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

# ------------------------------------------------ what is already installed
#
# The installer used to trust MODE in its own config file, so a per-site machine that ran
# it again and chose auto ended up serving both ways at once: the new daemon on 80, an old
# per-site Caddy on 443, and every site answering 000 because whatever held 443 had no
# block for that host. Nothing warned. These tests plant an installation — a config, the
# system LaunchDaemon plist, per-site Caddyfiles, a per-user LaunchAgent — and assert that
# the installer finds it by looking, says so, and refuses to lay a second topology on top.

# "did it say this at all", for text that legitimately appears more than once: counting
# lines would make the assertion depend on how often a message is repeated.
saw_inst() { if inst_text | grep -q -F -- "$1"; then echo yes; else echo no; fi; }
saw_text() { if printf '%s' "$1" | grep -q -F -- "$2"; then echo yes; else echo no; fi; }

# plant_existing <mode> <daemon:0|1> <persite:0|1> <agent:0|1>
plant_existing() {
  rm -rf "$INST_HOME" "$TRIPWIRE" "$BREW_STUB_PREFIX" "$LD_DIR" "$LA_DIR"
  mkdir -p "$INST_HOME/Sites" "$INST_HOME/Code" "$INST_HOME/.config/ldev" "$LD_DIR" "$LA_DIR"
  cat > "$INST_HOME/.config/ldev/config" <<EOF
TLD=test
SITES=$INST_HOME/Sites
MODE=$1
PHP_FPM=127.0.0.1:9000
EOF
  [ "$2" = 1 ] && printf '<plist>fake</plist>\n' > "$LD_DIR/com.ldev.caddy.plist"
  if [ "$3" = 1 ]; then
    mkdir -p "$INST_HOME/Sites/shop.test" "$INST_HOME/Sites/blog.test"
    printf '{\n\tadmin localhost:2019\n}\n\nshop.test:8443 {\n\troot * /x\n}\n' > "$INST_HOME/Sites/shop.test/Caddyfile"
    printf '{\n\tadmin localhost:2020\n}\n\nblog.test:8444 {\n\troot * /x\n}\n' > "$INST_HOME/Sites/blog.test/Caddyfile"
  fi
  [ "$4" = 1 ] && printf '<plist>ldev shop</plist>\n' > "$LA_DIR/com.example.shop-ldev.plist"
  return 0
}

echo "--- installer: a root Caddy that is not ours is seen and not claimed"
# Looking only for com.ldev.caddy is how detection missed the daemons that actually held
# 80 and 443 on a real Mac — sh.brew.caddy from `sudo brew services start caddy`, and a
# hand-written one. It reported "no system LaunchDaemon" while root plainly held both
# ports, then offered to take down com.ldev.caddy, which was not installed. Accepting
# that would have removed nothing and added a second root Caddy fighting for the ports.
plant_existing persite 0 1 0
printf '<plist><string>/opt/homebrew/bin/caddy</string></plist>\n' > "$LD_DIR/sh.brew.caddy.plist"
printf '<plist><string>/usr/bin/true</string></plist>\n'           > "$LD_DIR/com.other.thing.plist"
foreign="$(HOME="$INST_HOME" PATH="$STUB:$PATH" LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --skip-dns 2>&1 || true)"
check "the foreign caddy daemon is listed" "$(saw_text "$foreign" 'sh.brew.caddy.plist')"      "yes"
check "it is named as not ours"            "$(saw_text "$foreign" 'not installed by ldev')"    "yes"
check "a non-caddy daemon is ignored"      "$(saw_text "$foreign" 'com.other.thing')"          "no"
check "it does not offer to remove a daemon that is absent" \
  "$(printf '%s' "$foreign" | grep -c 'com.ldev.caddy, to be stopped')" "0"
rm -f "$LD_DIR/sh.brew.caddy.plist" "$LD_DIR/com.other.thing.plist"

echo "--- installer: the real port probe runs only when there is an install to explain"
# The rest of this section sets LDEV_SKIP_PORT_PROBE=1, so the probe never runs — and the
# probe only runs at all once something has been found, which is why a probe-free run
# proves nothing about it. Plant an installation and let the probe loose on whatever this
# machine is really doing: lsof exits 1 on a socket it cannot see into, and under
# `set -o pipefail` that used to end the install a few lines after the banner.
plant_existing auto 1 1 1
probe2="$(env -u LDEV_SKIP_PORT_PROBE HOME="$INST_HOME" PATH="$STUB:$PATH" LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --skip-dns 2>&1 || true)"
check "the probe did not kill the run" "$(saw_text "$probe2" 'already installed here')"   "yes"
check "it got as far as the questions" "$(saw_text "$probe2" 'Configuration')"            "yes"
check "and still fails closed"         "$(saw_text "$probe2" 'aborted')"                  "yes"
check "the probe wrote nothing"        "$(grep -c '^MODE=auto$' "$INST_HOME/.config/ldev/config")" "1"

echo "--- installer: it finds the installation it is about to replace"
plant_existing auto 1 1 1
INST_KEEP=1 install_drive "5"          # "5" on the existing-install menu is Quit
INST_KEEP=0
check "finished (did not spin)"     "$INST_TIMEDOUT"                                       "0"
check "said ldev is already here"   "$(inst_text | grep -c 'already installed here')"      "1"
check "named the LaunchDaemon"      "$(inst_text | grep -c "$LD_DIR/com.ldev.caddy.plist")" "1"
check "counted the per-site files"  "$(inst_text | grep -c '2 per-site Caddyfile')"        "1"
check "named the LaunchAgent"       "$(inst_text | grep -c 'com.example.shop-ldev.plist')" "1"
# The state the reported machine was left in, named as such rather than left to be guessed.
check "warned that both are live"   "$(inst_text | grep -c 'both ways of serving')"        "1"
check "quitting wrote nothing"      "$(inst_text | grep -c 'nothing was written')"         "1"
check "quitting exits non-zero"     "$([ "$INST_RC" -ne 0 ] && echo yes || echo no)"       "yes"
# Detection must be able to run before the user has agreed to anything, so it may not need
# a password: every look it takes is a file test, a glob or a read.
check "detection needed no sudo"    "$([ -e "$TRIPWIRE" ] && cat "$TRIPWIRE" || echo none)" "none"
check "detection changed nothing"   "$([ -e "$LD_DIR/com.ldev.caddy.plist" ] && echo kept || echo gone)" "kept"

echo "--- installer: Remove it, from the menu, removes ldev and not the sites"
plant_existing persite 0 1 0
#   4 = "Remove it"; y = yes to the list it prints first.
INST_KEEP=1 install_drive "4y"
INST_KEEP=0
check "finished (did not spin)"     "$INST_TIMEDOUT"                                       "0"
check "it listed what it would remove" "$(saw_inst 'Remove ldev')"                         "yes"
check "the config is gone"          "$([ -e "$INST_HOME/.config/ldev/config" ] && echo yes || echo no)" "no"
check "it said so"                  "$(saw_inst 'ldev removed')"                           "yes"
# The sites are the user's work. An uninstaller that took them with it would be worse than
# the untidiness it exists to fix.
check "the sites survived"          "$([ -e "$INST_HOME/Sites/shop.test/Caddyfile" ] && echo yes || echo no)" "yes"

echo "--- installer: a run that would change the topology is not allowed to just proceed"
# Interactive: the existing menu's "Update it in place", then the review screen switched to
# per-site by hand. The old daemon still owns 80 and 443, so the install stops and says so.
plant_existing auto 1 0 0
#   1 = update in place; enter = TLD (the mode comes from the config, so it is not asked);
#   enter = sites; 4 = change the mode on the review screen; DOWN+enter = persite;
#   enter = install with these settings; then the conflict menu, where DOWN+enter is
#   "quit and change nothing".
INST_KEEP=1 install_drive "1$CR${CR}4$DOWN$CR${CR}$DOWN$CR"
INST_KEEP=0
check "finished (did not spin)"      "$INST_TIMEDOUT"                                      "0"
check "said the two cannot share"    "$(saw_inst 'cannot share this machine')"             "yes"
check "named the service"            "$(saw_inst 'com.ldev.caddy')"                        "yes"
check "quitting the conflict writes nothing" "$(saw_inst 'nothing was written')"           "yes"
check "the config was not rewritten" "$(grep -c '^MODE=auto$' "$INST_HOME/.config/ldev/config")" "1"
check "the daemon was left alone"    "$([ -e "$LD_DIR/com.ldev.caddy.plist" ] && echo kept || echo gone)" "kept"

echo "--- installer: unattended, a topology change is refused rather than half-done"
plant_existing auto 1 0 0
unatt="$(HOME="$INST_HOME" PATH="$STUB:$PATH" LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --defaults --skip-dns --mode persite 2>&1)"
unatt_rc=$?
check "--defaults refused"           "$([ "$unatt_rc" -ne 0 ] && echo yes || echo no)"     "yes"
check "it said what is running"      "$(saw_text "$unatt" 'com.ldev.caddy')"               "yes"
check "it said what to do instead"   "$(saw_text "$unatt" '--switch')"                     "yes"
check "it wrote nothing"             "$(grep -c '^MODE=auto$' "$INST_HOME/.config/ldev/config")" "1"
check "it needed no sudo"            "$(priv_attempts)"                                    "0"
check "no emoji in the refusal"      "$(printf '%s' "$unatt" | emoji_lines)"               "0"
check "no escapes in the refusal"    "$(printf '%s' "$unatt" | grep -c "$ESC")"            "0"

echo "--- installer: a switch that cannot take the old service down installs nothing"
# --switch says take it down, but every sudo here fails, so the plist is still on disk
# afterwards. Reporting the takedown from the exit status rather than from the disk is how
# the second topology got installed beside a live one.
plant_existing auto 1 0 0
sw="$(HOME="$INST_HOME" PATH="$STUB:$PATH" LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --defaults --skip-dns --mode persite --switch 2>&1)"
sw_rc=$?
check "the switch failed"            "$([ "$sw_rc" -ne 0 ] && echo yes || echo no)"        "yes"
check "it said the plist is still there" "$(printf '%s' "$sw" | grep -c 'still there')"    "1"
check "it did not claim success"     "$(printf '%s' "$sw" | grep -c 'stopped and .* removed')" "0"
check "the config was not rewritten" "$(grep -c '^MODE=auto$' "$INST_HOME/.config/ldev/config")" "1"

echo "--- installer: nothing to uninstall says so instead of pretending"
rm -rf "$INST_HOME" "$LD_DIR" "$LA_DIR"; rm -f "$TRIPWIRE"
mkdir -p "$INST_HOME/Sites" "$LD_DIR" "$LA_DIR"
un_out="$(HOME="$INST_HOME" PATH="$STUB:$PATH" LDEV_TTY=/dev/null \
  "$SHELL_UNDER_TEST" "$REPO/install.sh" --uninstall --yes 2>&1)"
un_rc=$?
check "--uninstall on a clean machine fails" "$([ "$un_rc" -ne 0 ] && echo yes || echo no)" "yes"
check "and says there is nothing to remove"  "$(printf '%s' "$un_out" | grep -c 'nothing to uninstall')" "1"
check "and needed no sudo"                   "$(priv_attempts)"                            "0"

# ------------------------------------------------ launchd's disabled record
#
# launchd keeps a per-label "disabled" record in the system domain that survives both
# `launchctl bootout` and deleting the plist. The next bootstrap of that label then fails
# with "Bootstrap failed: 5: Input/output error" — which names neither the label nor the
# word disabled, and reads like a broken plist. It cost two failed installs. So ldev runs
# `launchctl enable system/com.ldev.caddy` before every bootstrap and again on removal.
#
# These runs need a root that succeeds, so they use a second set of stubs: a sudo that
# performs a tiny allowlist (tee, rm inside this temp directory, chown, chmod, launchctl)
# and writes every call to a log. Nothing real is invoked, and the log is the assertion.

ROOTSTUB="$TMP/rootstub"; ROOTLOG="$TMP/rootlog"; ROOT_HOME="$TMP/root-home"
BREW2="$TMP/brew2"
mkdir -p "$ROOTSTUB" "$BREW2"
cat > "$ROOTSTUB/sudo" <<STUBEOF
#!/bin/sh
echo "sudo \$*" >> "$ROOTLOG"
case "\$1" in
  tee) shift; cat > "\$1"; exit 0 ;;
  rm)  shift
       for a in "\$@"; do
         case "\$a" in
           -*) ;;
           "$TMP"/*) ;;
           *) echo "REFUSED rm \$a" >> "$ROOTLOG"; exit 1 ;;
         esac
       done
       rm "\$@"; exit 0 ;;
  launchctl) shift; exec "$ROOTSTUB/launchctl" "\$@" ;;
  chown|chmod|mkdir) exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
cat > "$ROOTSTUB/launchctl" <<STUBEOF
#!/bin/sh
echo "launchctl \$*" >> "$ROOTLOG"
case "\$1" in
  bootstrap) exit \${LDEV_TEST_BOOTSTRAP_RC:-0} ;;
  *) exit 0 ;;
esac
STUBEOF
cat > "$ROOTSTUB/brew" <<STUBEOF
#!/bin/sh
if [ "\$1" = "--prefix" ]; then echo "$BREW2"; exit 0; fi
echo "brew \$*" >> "$ROOTLOG"
exit 0
STUBEOF
for c in caddy mkcert npm dnsmasq; do
  cat > "$ROOTSTUB/$c" <<STUBEOF
#!/bin/sh
echo "$c \$*" >> "$ROOTLOG"
exit 0
STUBEOF
done
chmod +x "$ROOTSTUB"/*

# The output goes to a file rather than back through $(...): a command substitution is a
# subshell, and the return code set inside one never reaches the assertions.
ROOT_RC=0
root_install() { # root_install <args...> -> rc in ROOT_RC, output via root_text
  rm -f "$ROOTLOG"
  HOME="$ROOT_HOME" PATH="$ROOTSTUB:$PATH" LDEV_TTY=/dev/null \
    "$SHELL_UNDER_TEST" "$REPO/install.sh" "$@" >"$TMP/root.out" 2>&1
  ROOT_RC=$?
  return 0
}
root_text() { cat "$TMP/root.out"; }
saw_root() { if grep -q -F -- "$1" "$TMP/root.out"; then echo yes; else echo no; fi; }
# The order the two launchctl calls happen in is the whole fix, so it is asserted as an
# order and not as two independent greps.
log_order() { # log_order <first> <second> -> yes when both appear, first before second
  local a b
  a="$(grep -n -F "$1" "$ROOTLOG" 2>/dev/null | head -1 | cut -d: -f1)"
  b="$(grep -n -F "$2" "$ROOTLOG" 2>/dev/null | head -1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo yes; else echo "no($a,$b)"; fi
}

echo "--- installer: launchctl enable runs before every bootstrap"
rm -rf "$ROOT_HOME" "$LD_DIR" "$BREW2"; mkdir -p "$ROOT_HOME/Sites" "$LD_DIR" "$BREW2"
root_install --defaults --skip-dns --mode auto
check "the auto install finished"    "$ROOT_RC"                                            "0"
check "the plist was installed"      "$([ -e "$LD_DIR/com.ldev.caddy.plist" ] && echo yes || echo no)" "yes"
check "enable ran before bootstrap"  "$(log_order 'launchctl enable system/com.ldev.caddy' 'launchctl bootstrap system')" "yes"
check "bootout still ran first"      "$(log_order 'launchctl bootout system/com.ldev.caddy' 'launchctl enable system/com.ldev.caddy')" "yes"
# Only bootstrap-level success is assertable here: these runs set LDEV_SKIP_PORT_PROBE=1,
# so the installer cannot ask the socket whether Caddy actually came up, and says so
# rather than claiming it did. A green "service started and listening" is reserved for a
# run that really looked.
check "the service was reported bootstrapped" "$(saw_root 'service bootstrapped')" "yes"
check "it did not claim to be listening"      "$(saw_root 'and listening')"         "no"

echo "--- installer: a failed bootstrap is diagnosed, not passed through"
LDEV_TEST_BOOTSTRAP_RC=5
export LDEV_TEST_BOOTSTRAP_RC
root_install --defaults --skip-dns --mode auto
unset LDEV_TEST_BOOTSTRAP_RC
check "the run did not abort"        "$ROOT_RC"                                            "0"
check "it named the label"           "$(saw_root 'com.ldev.caddy is NOT running')" "yes"
check "it named the real cause"      "$(saw_root 'disabled record')" "yes"
check "it pointed at print-disabled" "$(saw_root 'print-disabled system')" "yes"
# The config is the last thing written. A bootstrap failure must not cost the user that,
# or the machine is left in the half-configured state the whole installer is built to avoid.
check "the config was still written" "$(grep -c '^MODE=auto$' "$ROOT_HOME/.config/ldev/config")" "1"

echo "--- installer: running it again over its own installation updates in place"
root_install --defaults --skip-dns --mode auto
check "the second run finished"      "$ROOT_RC"                                            "0"
check "it saw the existing install"  "$(saw_root 'already installed here')" "yes"
check "it said it would update"      "$(saw_root 'updating the existing installation in place')" "yes"
check "enable ran before bootstrap again" "$(log_order 'launchctl enable system/com.ldev.caddy' 'launchctl bootstrap system')" "yes"

echo "--- installer: --uninstall leaves the label enabled, not just booted out"
root_install --uninstall --yes
check "the uninstall finished"       "$ROOT_RC"                                            "0"
check "the plist is gone"            "$([ -e "$LD_DIR/com.ldev.caddy.plist" ] && echo yes || echo no)" "no"
check "the config is gone"           "$([ -e "$ROOT_HOME/.config/ldev/config" ] && echo yes || echo no)" "no"
check "bootout then enable on removal" "$(log_order 'launchctl bootout system/com.ldev.caddy' 'launchctl enable system/com.ldev.caddy')" "yes"
check "it said the label was left enabled" "$(saw_root 'left enabled')" "yes"
# A switch is the other half of the same promise: the old topology goes down as part of it.
echo "--- installer: switching the other way unloads the agents and keeps the files"
rm -rf "$ROOT_HOME" "$LD_DIR" "$LA_DIR"
mkdir -p "$ROOT_HOME/Sites/shop.ldev" "$ROOT_HOME/.config/ldev" "$LD_DIR" "$LA_DIR"
printf 'TLD=ldev\nSITES=%s/Sites\nMODE=persite\n' "$ROOT_HOME" > "$ROOT_HOME/.config/ldev/config"
printf '{\n\tadmin localhost:2019\n}\n\nshop.ldev:8443 {\n\troot * /x\n}\n' > "$ROOT_HOME/Sites/shop.ldev/Caddyfile"
printf '<plist>ldev shop</plist>\n' > "$LA_DIR/com.example.shop-ldev.plist"
root_install --defaults --skip-dns --mode auto --switch
check "the switch to auto finished"  "$ROOT_RC"                                            "0"
check "it unloaded the LaunchAgent"  "$(grep -qF 'launchctl bootout gui/' "$ROOTLOG" && echo yes || echo no)" "yes"
# --defaults answers yes to every question, so the only protection for files a person
# wrote by hand is that the question is never asked when nobody is there to answer it.
check "it kept the per-site Caddyfile" "$([ -e "$ROOT_HOME/Sites/shop.ldev/Caddyfile" ] && echo yes || echo no)" "yes"
check "it said they were kept"       "$(saw_root 'still on disk')"                         "yes"
check "the new mode was written"     "$(grep -c '^MODE=auto$' "$ROOT_HOME/.config/ldev/config")" "1"

echo "--- installer: switching away takes the system service down first"
rm -rf "$ROOT_HOME" "$LA_DIR"; mkdir -p "$ROOT_HOME/Sites" "$LA_DIR"
root_install --defaults --skip-dns --mode auto
root_install --defaults --skip-dns --mode persite --switch
check "the switch finished"          "$ROOT_RC"                                            "0"
check "the daemon plist is gone"     "$([ -e "$LD_DIR/com.ldev.caddy.plist" ] && echo yes || echo no)" "no"
check "it booted the service out"    "$(grep -qF 'launchctl bootout system/com.ldev.caddy' "$ROOTLOG" && echo yes || echo no)" "yes"
check "it left the label enabled"    "$(grep -qF 'launchctl enable system/com.ldev.caddy' "$ROOTLOG" && echo yes || echo no)" "yes"
check "the new mode was written"     "$(grep -c '^MODE=persite$' "$ROOT_HOME/.config/ldev/config")" "1"
rm -rf "$INST_HOME" "$TRIPWIRE" "$BREW_STUB_PREFIX" "$ROOT_HOME"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
