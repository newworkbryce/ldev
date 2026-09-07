#!/bin/bash
# Restart the Homebrew Apache LaunchDaemon (so config changes take effect).
# Asks for password so it can run as root.

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

PLIST_DEST="/Library/LaunchDaemons/org.apache.httpd.homebrew.plist"

echo "Restarting Homebrew Apache LaunchDaemon..."
# Unload
if launchctl bootout system/org.apache.httpd.homebrew 2>/dev/null; then
  echo "Stopped."
elif launchctl unload "$PLIST_DEST" 2>/dev/null; then
  echo "Stopped."
else
  echo "(Was not running.)"
fi
sleep 1
# Load
if launchctl bootstrap system "$PLIST_DEST" 2>/dev/null; then
  echo "Started."
elif launchctl load -w "$PLIST_DEST" 2>/dev/null; then
  echo "Started."
else
  echo "Failed to start. Check: sudo cat /opt/homebrew/var/log/httpd/launchd_stderr.log"
  exit 1
fi
echo "Done. Port 80: sudo lsof -i :80 -P -n"
