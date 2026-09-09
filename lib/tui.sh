#!/usr/bin/env bash
#
# tui.sh — the terminal UI the ldev installer runs on: arrow-key menus, colour,
# glyphs and a spinner.
#
# Everything here degrades in one direction. When stdout is not a terminal, or
# the caller passed --plain, or TERM is dumb, every function still returns the
# same answer it would have returned interactively — it prints a plain line and
# takes the default instead of drawing a menu. Callers never branch on which of
# the two they got, which is the point: there is one path through the installer,
# not an interactive one and a headless one that drift apart.
#
# Keys are read from LDEV_TTY (default /dev/tty) on fd 3, opened once so the
# read offset is shared, which lets a test feed a file of escape sequences in
# place of a keyboard. LDEV_FORCE_TUI=1 draws menus even when stdout is a pipe.
#
# Bash 3.2 is the floor — that is what macOS ships, and the installer has to run
# before the user has installed anything else. So: no associative arrays, no
# fractional `read -t`, no ${x^^}.

[ -n "${LDEV_TUI_SOURCED:-}" ] && return 0
LDEV_TUI_SOURCED=1

TUI_INTERACTIVE=0
TUI_COLOR=0
TUI_UNICODE=1
TUI_KEY=""
TUI_VALUE=""
MENU_CHOICE=0
MENU_HOTKEYS=""

# ---------------------------------------------------------------- capabilities

tui_init() {
  local plain="${LDEV_PLAIN:-0}" capable=0

  # A terminal we can draw on: stdout is one and TERM is not `dumb`. The force
  # flag is the test's way in, and it overrides both — a file of keystrokes is
  # not a tty and never will be.
  if [ "${LDEV_FORCE_TUI:-0}" = 1 ] || { [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; }; then
    capable=1
  fi

  case "${LC_ALL:-${LC_CTYPE:-${LANG:-UTF-8}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) TUI_UNICODE=1 ;;
    *) TUI_UNICODE=0 ;;
  esac

  if [ "$plain" = 1 ] || [ "$capable" != 1 ]; then
    TUI_UNICODE=0
  else
    # NO_COLOR is a preference rather than a capability, so it turns colour off
    # without costing the user the menus.
    [ -z "${NO_COLOR:-}" ] && TUI_COLOR=1
    if exec 3<"${LDEV_TTY:-/dev/tty}" 2>/dev/null; then
      TUI_INTERACTIVE=1
      trap 'tui_cleanup' EXIT
      trap 'tui_cleanup; printf "\n"; exit 130' INT TERM
    fi
  fi

  _tui_palette
  _tui_glyphs
  return 0
}

# Leaving a terminal with a hidden cursor is the one way a script like this can
# damage a session it has already exited, so the restore is a trap rather than a
# line at the bottom of the happy path.
tui_cleanup() {
  [ "$TUI_INTERACTIVE" = 1 ] || return 0
  printf '\033[?25h'
  exec 3<&- 2>/dev/null || true
  TUI_INTERACTIVE=0
}

_tui_palette() {
  if [ "$TUI_COLOR" = 1 ]; then
    C_B=$'\033[1m';  C_DIM=$'\033[2m'; C_R=$'\033[0m'
    C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RED=$'\033[31m'
    C_CYN=$'\033[36m'; C_MAG=$'\033[35m'; C_BLU=$'\033[34m'
  else
    C_B=""; C_DIM=""; C_R=""
    C_GRN=""; C_YEL=""; C_RED=""
    C_CYN=""; C_MAG=""; C_BLU=""
  fi
}

_tui_glyphs() {
  if [ "$TUI_UNICODE" = 1 ]; then
    G_OK="✅"; G_NO="❌"; G_WARN="⚠️ "; G_INFO="ℹ️ "; G_SKIP="⏭️ "
    G_ARROW="❯"; G_DOT="·"; G_BULLET="•"; G_RULE="─"
    G_PARTY="🎉"; G_GEAR="⚙️"; G_NET="🌐"; G_LOCK="🔐"; G_FOLDER="📁"
    G_CHART="📊"; G_PKG="📦"; G_PENCIL="✏️ "; G_LIST="📋"; G_BOLT="⚡"
    G_UP="↑"; G_DOWN="↓"; G_WRITE="📝"; G_ROCKET="🚀"
  else
    G_OK="[ok]"; G_NO="[no]"; G_WARN="[!]"; G_INFO="[i]"; G_SKIP="[-]"
    G_ARROW=">"; G_DOT="-"; G_BULLET="*"; G_RULE="-"
    G_PARTY="*"; G_GEAR="*"; G_NET="*"; G_LOCK="*"; G_FOLDER="*"
    G_CHART="*"; G_PKG="*"; G_PENCIL="*"; G_LIST="*"; G_BOLT="*"
    G_UP="^"; G_DOWN="v"; G_WRITE="*"; G_ROCKET="*"
  fi
}

tui_cols() {
  local c
  c="$(tput cols 2>/dev/null || echo 80)"
  case "$c" in ''|*[!0-9]*) c=80 ;; esac
  [ "$c" -lt 40 ] && c=40
  [ "$c" -gt 100 ] && c=100
  printf '%s' "$c"
}

# ---------------------------------------------------------------- plain output

ui_say()   { printf '%s\n' "$*"; }
ui_ok()    { printf '  %s %s\n' "$G_OK" "$*"; }
ui_bad()   { printf '  %s %s%s%s\n' "$G_NO" "$C_RED" "$*" "$C_R"; }
ui_warn()  { printf '  %s %s%s%s\n' "$G_WARN" "$C_YEL" "$*" "$C_R" >&2; }
ui_info()  { printf '  %s %s\n' "$G_INFO" "$*"; }
ui_skip()  { printf '  %s %s%s%s\n' "$G_SKIP" "$C_DIM" "$*" "$C_R"; }
ui_item()  { printf '     %s%s%s %s\n' "$C_DIM" "$G_BULLET" "$C_R" "$*"; }
ui_hint()  { printf '     %s%s%s\n' "$C_DIM" "$*" "$C_R"; }
ui_wrote() { printf '  %s %swrote%s %s\n' "$G_WRITE" "$C_DIM" "$C_R" "$*"; }
ui_cmd()   { printf '       %s%s%s\n' "$C_CYN" "$*" "$C_R"; }

ui_kv() { # ui_kv <label> <value>
  printf '     %s%-12s%s %s\n' "$C_DIM" "$1" "$C_R" "$2"
}

ui_rule() {
  local cols i out=""
  cols="$(tui_cols)"
  for ((i = 0; i < cols - 2; i++)); do out="$out$G_RULE"; done
  printf ' %s%s%s\n' "$C_DIM" "$out" "$C_R"
}

ui_banner() { # ui_banner <title> <subtitle>
  printf '\n %s %s%s%s\n' "$G_BOLT" "$C_B$C_CYN" "$1" "$C_R"
  printf ' %s%s%s\n' "$C_DIM" "$2" "$C_R"
  ui_rule
}

# Steps number themselves, so a run reads as progress rather than as a wall.
TUI_STEP_N=0
TUI_STEP_TOTAL=7
ui_step() { # ui_step <emoji> <title>
  TUI_STEP_N=$((TUI_STEP_N + 1))
  printf '\n %s%s[%d/%d]%s %s %s%s%s\n' \
    "$C_B" "$C_MAG" "$TUI_STEP_N" "$TUI_STEP_TOTAL" "$C_R" "$1" "$C_B" "$2" "$C_R"
  ui_rule
}

# ---------------------------------------------------------------- key input

_tui_key() {
  local k='' rest=''
  TUI_KEY=''
  if ! IFS= read -rsn1 k <&3 2>/dev/null; then TUI_KEY='quit'; return 0; fi
  case "$k" in
    '')      TUI_KEY='enter' ;;
    $'\033')
      # A bare Esc and an arrow key start with the same byte; an arrow's two
      # remaining bytes are already in the buffer, so the timeout only costs
      # anything on a real lone Esc. Fractional -t would need bash 4.
      IFS= read -rsn2 -t 1 rest <&3 2>/dev/null || rest=''
      case "$rest" in
        '[A') TUI_KEY='up' ;;
        '[B') TUI_KEY='down' ;;
        '[C') TUI_KEY='right' ;;
        '[D') TUI_KEY='left' ;;
        *)    TUI_KEY='esc' ;;
      esac ;;
    ' ')     TUI_KEY='space' ;;
    $'\t')   TUI_KEY='down' ;;
    *)       TUI_KEY="char:$k" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- menu

_menu_draw() {
  local i line shown=0
  printf '\033[2K\n'
  printf '\033[2K %s%s%s\n' "$C_B" "$_m_title" "$C_R"
  printf '\033[2K\n'
  for ((i = 0; i < _m_n; i++)); do
    if [ "$i" = "$_m_sel" ]; then
      printf '\033[2K  %s%s%s %s%s%s\n' "$C_CYN" "$G_ARROW" "$C_R" "$C_B$C_CYN" "${_m_labels[$i]}" "$C_R"
    else
      printf '\033[2K    %s\n' "${_m_labels[$i]}"
    fi
  done
  if [ "$_m_desc_h" -gt 0 ]; then
    printf '\033[2K\n'
    while IFS= read -r line; do
      printf '\033[2K      %s%s%s\n' "$C_DIM" "$line" "$C_R"
      shown=$((shown + 1))
    done <<< "${_m_descs[$_m_sel]}"
    while [ "$shown" -lt "$_m_desc_h" ]; do printf '\033[2K\n'; shown=$((shown + 1)); done
  fi
  printf '\033[2K\n'
  printf '\033[2K  %s%s move %s enter select %s 1-9 jump %s esc cancel%s\n' \
    "$C_DIM" "$G_UP$G_DOWN" "$G_DOT" "$G_DOT" "$G_DOT" "$C_R"
}

_menu_erase() {
  local i
  printf '\033[%dA' "$_m_total"
  for ((i = 0; i < _m_total; i++)); do printf '\033[2K\n'; done
  printf '\033[%dA' "$_m_total"
}

# menu_select <title> <default-index> <label> <desc> [<label> <desc> ...]
#   -> MENU_CHOICE (0-based). Returns 1 when the user cancelled.
# Set MENU_HOTKEYS="yn" beforehand to let 'y' pick item 0 and 'n' item 1.
menu_select() {
  local _m_title="$1" _m_sel="$2"; shift 2
  local _m_labels=() _m_descs=() hotkeys="$MENU_HOTKEYS"
  MENU_HOTKEYS=""
  while [ $# -ge 2 ]; do
    _m_labels+=("$1"); _m_descs+=("$2"); shift 2
  done
  local _m_n=${#_m_labels[@]}
  [ "$_m_n" -gt 0 ] || return 1
  case "$_m_sel" in ''|*[!0-9]*) _m_sel=0 ;; esac
  [ "$_m_sel" -lt "$_m_n" ] || _m_sel=0
  MENU_CHOICE="$_m_sel"

  if [ "$TUI_INTERACTIVE" != 1 ]; then
    printf '  %s %s%s%s %s%s%s\n' "$G_ARROW" "$C_DIM" "$_m_title" "$C_R" "$C_B" "${_m_labels[$_m_sel]}" "$C_R"
    return 0
  fi

  local _m_desc_h=0 i h
  for ((i = 0; i < _m_n; i++)); do
    [ -n "${_m_descs[$i]}" ] || continue
    h="$(printf '%s\n' "${_m_descs[$i]}" | wc -l | tr -d ' ')"
    [ "$h" -gt "$_m_desc_h" ] && _m_desc_h="$h"
  done
  local _m_total=$((3 + _m_n + 2))
  [ "$_m_desc_h" -gt 0 ] && _m_total=$((_m_total + 1 + _m_desc_h))

  local first=1 rc=0 ch pos
  printf '\033[?25l'
  while :; do
    [ "$first" = 1 ] || printf '\033[%dA' "$_m_total"
    first=0
    _menu_draw
    _tui_key
    case "$TUI_KEY" in
      up|left)     _m_sel=$(( (_m_sel + _m_n - 1) % _m_n )) ;;
      down|right)  _m_sel=$(( (_m_sel + 1) % _m_n )) ;;
      enter|space) break ;;
      esc|quit)    rc=1; break ;;
      char:*)
        ch="${TUI_KEY#char:}"
        case "$hotkeys" in
          *"$ch"*)
            pos="${hotkeys%%$ch*}"; pos="${#pos}"
            if [ "$pos" -lt "$_m_n" ]; then _m_sel="$pos"; break; fi
            ;;
        esac
        case "$ch" in
          j) _m_sel=$(( (_m_sel + 1) % _m_n )) ;;
          k) _m_sel=$(( (_m_sel + _m_n - 1) % _m_n )) ;;
          q) rc=1; break ;;
          [1-9])
            if [ "$ch" -le "$_m_n" ]; then _m_sel=$((ch - 1)); break; fi
            ;;
        esac ;;
    esac
  done
  _menu_erase
  printf '\033[?25h'
  MENU_CHOICE="$_m_sel"
  if [ "$rc" = 0 ]; then
    printf '  %s %s%s%s %s%s%s\n' "$G_ARROW" "$C_DIM" "$_m_title" "$C_R" "$C_B$C_CYN" "${_m_labels[$_m_sel]}" "$C_R"
  else
    printf '  %s %s%s — cancelled%s\n' "$G_NO" "$C_DIM" "$_m_title" "$C_R"
  fi
  return "$rc"
}

# menu_confirm <question> [yes|no] -> 0 for yes, 1 for no
menu_confirm() {
  local q="$1" def="${2:-no}" d=1
  [ "$def" = "yes" ] && d=0
  [ "$TUI_INTERACTIVE" = 1 ] || return "$d"
  MENU_HOTKEYS="yn"
  menu_select "$q" "$d" "$G_OK Yes" "" "$G_NO No" "" || return 1
  [ "$MENU_CHOICE" = 0 ]
}

# tui_input <prompt> <default> [hint] -> TUI_VALUE
tui_input() {
  local p="$1" d="$2" hint="${3:-}" reply=""
  TUI_VALUE="$d"
  [ "$TUI_INTERACTIVE" = 1 ] || return 0
  printf '\n %s%s%s' "$C_B" "$p" "$C_R"
  [ -n "$hint" ] && printf '  %s%s%s' "$C_DIM" "$hint" "$C_R"
  printf '\n  %s%s%s %s[%s]%s ' "$C_CYN" "$G_ARROW" "$C_R" "$C_DIM" "$d" "$C_R"
  IFS= read -r reply <&3 2>/dev/null || reply=""
  [ -n "$reply" ] && TUI_VALUE="$reply"
  return 0
}

# ---------------------------------------------------------------- spinner

# run_task <message> <command...> — runs the command with its output captured,
# spinning while it works, printing the tail of that output only if it fails.
# Silence on failure would be worse than noise, so failure always prints.
run_task() {
  local msg="$1"; shift
  if [ "$TUI_INTERACTIVE" != 1 ]; then
    printf '  %s %s...\n' "$G_DOT" "$msg"
    if "$@" >/dev/null 2>&1; then ui_ok "$msg"; return 0; fi
    ui_bad "$msg"
    return 1
  fi
  local log; log="$(mktemp -t ldev-task)"
  "$@" >"$log" 2>&1 &
  local pid=$! rc=0 i=0
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  [ "$TUI_UNICODE" = 1 ] || frames=('|' '/' '-' '\')
  printf '\033[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[2K  %s%s%s %s' "$C_CYN" "${frames[$((i % ${#frames[@]}))]}" "$C_R" "$msg"
    i=$((i + 1))
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  printf '\r\033[2K\033[?25h'
  if [ "$rc" = 0 ]; then
    ui_ok "$msg"
  else
    ui_bad "$msg"
    tail -n 6 "$log" | sed "s/^/       /"
  fi
  rm -f "$log"
  return "$rc"
}
