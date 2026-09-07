#!/bin/bash
#
# 1) Disable macOS system Apache so it never starts on port 80.
# 2) Install Homebrew Apache as a system LaunchDaemon (runs as root) so it
#    is the only Apache and binds to port 80 (and 8080, 8443).
#
# Run once: ./setup-homebrew-apache-port80.sh  (will ask for your password)
# The script will ask for your permission before each change.
#

# Re-run as root so we can modify system Apache and install the LaunchDaemon
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

# Colours (only if stdout is a TTY)
if [ -t 1 ]; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  CYAN=$(tput setaf 6)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" RESET=""
fi

# Ask user permission before a change. Returns 0 if yes, 1 if no.
# Usage: confirm "What we will do" "optional detail"
confirm() {
  local msg="$1"
  local detail="${2:-}"
  echo ""
  echo "${CYAN}${BOLD}▶ $msg${RESET}"
  [ -n "$detail" ] && echo "${CYAN}  $detail${RESET}"
  echo -n "${YELLOW}  Proceed? [y/N] ${RESET}"
  read -r ans
  case "$ans" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

info()  { echo "${BLUE}$*${RESET}"; }
ok()    { echo "${GREEN}$*${RESET}"; }
warn()  { echo "${YELLOW}$*${RESET}"; }
err()   { echo "${RED}$*${RESET}"; }

set -e

PLIST_SRC="$(dirname "$0")/org.apache.httpd.homebrew.plist"
PLIST_DEST="/Library/LaunchDaemons/org.apache.httpd.homebrew.plist"
SYSTEM_APACHE_PLIST="/System/Library/LaunchDaemons/org.apache.httpd.plist"
HTTPD_CONF="/opt/homebrew/etc/httpd/httpd.conf"
VHOSTS="/opt/homebrew/etc/httpd/extra/httpd-vhosts.conf"

echo ""
echo "${BOLD}=== Local Projects Dashboard – Apache setup ===${RESET}"
echo "${BOLD}This script will ask before each change. You can skip any step by answering N.${RESET}"

# ---------------------------------------------------------------------------
# 1) Disable macOS system Apache
# ---------------------------------------------------------------------------
if confirm "Disable macOS system Apache (stop it and prevent it starting on boot)" "This frees port 80 for Homebrew Apache. File: $SYSTEM_APACHE_PLIST"; then
  info "Stopping system Apache..."
  apachectl stop 2>/dev/null || true
  if [ -f "$SYSTEM_APACHE_PLIST" ]; then
    info "Unloading from launchd and disabling at boot..."
    if launchctl unload -w "$SYSTEM_APACHE_PLIST" 2>/dev/null; then
      ok "macOS system Apache disabled."
    else
      launchctl bootout system "$SYSTEM_APACHE_PLIST" 2>/dev/null || true
      launchctl disable system/org.apache.httpd 2>/dev/null || true
      ok "macOS system Apache disabled (bootout)."
    fi
  else
    warn "System Apache plist not found; it may already be disabled."
  fi
else
  warn "Skipped: disabling macOS system Apache."
fi

# ---------------------------------------------------------------------------
# 2) Stop any user-started Homebrew Apache
# ---------------------------------------------------------------------------
if confirm "Stop any Homebrew Apache started by you (brew services or manual)" "This avoids two Apache instances when we start the LaunchDaemon."; then
  brew services stop httpd 2>/dev/null || true
  pkill -f '/opt/homebrew/opt/httpd/bin/httpd' 2>/dev/null || true
  sleep 1
  ok "Stopped any user-started Homebrew Apache."
else
  warn "Skipped: stopping user-started Apache. The LaunchDaemon may conflict if Apache is already running."
fi

# ---------------------------------------------------------------------------
# 3) Fix httpd.conf (Listen 80, DocumentRoot, dedupe)
# ---------------------------------------------------------------------------
if [ -f "$HTTPD_CONF" ]; then
  if confirm "Edit Homebrew Apache main config: $HTTPD_CONF" "Enable Listen 80, set main DocumentRoot to /opt/homebrew/var/www, remove duplicate Listen 80."; then
    # Enable Listen 80
    if ! grep -q '^Listen 80$' "$HTTPD_CONF" 2>/dev/null; then
      info "Enabling Listen 80..."
      sed -i '' -e 's/^# Listen 80.*/Listen 80/' -e 's/^#Listen 12.34.56.78:80$/Listen 80/' "$HTTPD_CONF"
      if ! grep -q '^Listen 80$' "$HTTPD_CONF"; then
        sed -i '' '/^Listen 8080/i\
Listen 80
' "$HTTPD_CONF"
      fi
    fi
    # Remove duplicate Listen 80
    count=$(grep -c '^Listen 80$' "$HTTPD_CONF" 2>/dev/null || echo 0)
    if [ "$count" -gt 1 ]; then
      info "Removing duplicate Listen 80..."
      sed -i '' '/^Listen 80$/d' "$HTTPD_CONF"
      sed -i '' '/^Listen 8080/i\
Listen 80
' "$HTTPD_CONF"
    fi
    # Revert main DocumentRoot
    if grep -q 'DocumentRoot "/Users/bryce/Sites/local-projects-dashboard"' "$HTTPD_CONF" 2>/dev/null; then
      info "Reverting main server DocumentRoot to /opt/homebrew/var/www..."
      sed -i '' 's|DocumentRoot "/Users/bryce/Sites/local-projects-dashboard"|DocumentRoot "/opt/homebrew/var/www"|g' "$HTTPD_CONF"
      sed -i '' 's|<Directory "/Users/bryce/Sites/local-projects-dashboard">|<Directory "/opt/homebrew/var/www">|g' "$HTTPD_CONF"
    fi
    ok "Updated $HTTPD_CONF"
  else
    warn "Skipped: editing $HTTPD_CONF"
  fi
else
  warn "Config not found: $HTTPD_CONF (is Homebrew Apache installed?)"
fi

# ---------------------------------------------------------------------------
# 4) Fix vhosts (ServerAlias *.ldev for port 80)
# ---------------------------------------------------------------------------
if [ -f "$VHOSTS" ] && ! grep -q 'ServerAlias \*\.ldev' "$VHOSTS" 2>/dev/null; then
  if confirm "Edit vhosts: $VHOSTS" "Add ServerAlias *.ldev to the port 80 vhost so http://seasonal-drops.ldev/ shows the dashboard."; then
    sed -i '' '0,/ServerAlias 127.0.0.1/s/ServerAlias 127.0.0.1/ServerAlias 127.0.0.1\
    ServerAlias *.ldev/' "$VHOSTS"
    ok "Updated $VHOSTS"
  else
    warn "Skipped: editing $VHOSTS"
  fi
fi

# ---------------------------------------------------------------------------
# 5) Install and start LaunchDaemon
# ---------------------------------------------------------------------------
if [ ! -f "$PLIST_SRC" ]; then
  err "Error: $PLIST_SRC not found. Run this script from the dashboard folder."
  exit 1
fi

if confirm "Install Homebrew Apache as a LaunchDaemon (runs as root, uses port 80)" "Copy plist to $PLIST_DEST, create log files, load the daemon so Apache starts on 80, 8080, 8443."; then
  mkdir -p /opt/homebrew/var/log/httpd
  touch /opt/homebrew/var/log/httpd/launchd_stdout.log /opt/homebrew/var/log/httpd/launchd_stderr.log
  chown root:wheel /opt/homebrew/var/log/httpd/launchd_stdout.log /opt/homebrew/var/log/httpd/launchd_stderr.log 2>/dev/null || true
  chmod 644 /opt/homebrew/var/log/httpd/launchd_stdout.log /opt/homebrew/var/log/httpd/launchd_stderr.log

  cp "$PLIST_SRC" "$PLIST_DEST"
  chown root:wheel "$PLIST_DEST"
  chmod 644 "$PLIST_DEST"
  ok "Installed $PLIST_DEST"

  info "Restarting LaunchDaemon (unload then load)..."
  launchctl bootout system/org.apache.httpd.homebrew 2>/dev/null || true
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
  sleep 1

  if launchctl bootstrap system "$PLIST_DEST" 2>/dev/null; then
    ok "LaunchDaemon started (bootstrap)."
  elif launchctl load -w "$PLIST_DEST" 2>/dev/null; then
    ok "LaunchDaemon started (legacy load)."
  else
    err "Failed to start LaunchDaemon."
    if [ -f /opt/homebrew/var/log/httpd/launchd_stderr.log ]; then
      warn "Recent stderr:"
      tail -20 /opt/homebrew/var/log/httpd/launchd_stderr.log
    fi
    echo ""
    info "Try manually: sudo launchctl bootstrap system $PLIST_DEST"
    exit 1
  fi

  sleep 1
  if lsof -i :80 -sTCP:LISTEN -t 2>/dev/null | head -1 | xargs -I{} ps -p {} -o comm= 2>/dev/null | grep -q httpd; then
    ok "Port 80 is in use by Homebrew Apache."
  else
    warn "Nothing appears to be listening on port 80 yet. Check: sudo cat /opt/homebrew/var/log/httpd/launchd_stderr.log"
  fi
else
  warn "Skipped: installing LaunchDaemon. Apache will not run on port 80 until you run this step."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "${GREEN}${BOLD}Setup complete.${RESET}"
echo ""
echo "  ${BOLD}http://localhost/${RESET} or ${BOLD}http://seasonal-drops.ldev/${RESET}  → Local Projects dashboard"
echo "  ${BOLD}http://seasonal-drops.ldev:8080/${RESET}  → WordPress (HTTP)"
echo "  ${BOLD}https://seasonal-drops.ldev:8443/${RESET} → WordPress (HTTPS)"
echo ""
echo "Restart Apache after config changes: ${CYAN}./restart-homebrew-apache.sh${RESET}"
echo "Check port 80: ${CYAN}sudo lsof -i :80 -P -n${RESET}"
echo ""
