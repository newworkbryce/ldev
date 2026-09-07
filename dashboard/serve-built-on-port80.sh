#!/bin/bash
#
# 1) Build the React app and copy api.php + data into dist/
# 2) Update Apache port-80 vhost to use DocumentRoot .../dist (so the built app is served)
# 3) Restart Apache
#
# Run from the dashboard folder: ./serve-built-on-port80.sh
# Will ask for your password to edit Apache config and restart.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
PROJECT_ROOT="$SCRIPT_DIR"
VHOSTS="/opt/homebrew/etc/httpd/extra/httpd-vhosts.conf"

# Backup bootstrap config path so a fresh build doesn't wipe it (main config lives in ~/Sites)
BACKUP_CONFIG_PATH="/tmp/local-projects-dashboard-config-path-backup.json"
if [ -f dist/data/config-path.json ]; then
  cp dist/data/config-path.json "$BACKUP_CONFIG_PATH"
  echo "Backed up config-path from dist/data."
fi

echo "Building React app..."
npm run build

if [ -f "$BACKUP_CONFIG_PATH" ]; then
  cp "$BACKUP_CONFIG_PATH" dist/data/config-path.json
  rm -f "$BACKUP_CONFIG_PATH"
  echo "Restored config-path to dist/data."
fi

# Update vhost to serve from dist (requires sudo)
if [ ! -f "$VHOSTS" ]; then
  echo "Vhost file not found: $VHOSTS"
  echo "Point your port 80 DocumentRoot to: $PROJECT_ROOT/dist"
  exit 1
fi

# Only replace if not already pointing at dist
if grep -q "DocumentRoot \"$PROJECT_ROOT/dist\"" "$VHOSTS" 2>/dev/null; then
  echo "Apache vhost already points to dist/."
else
  echo "Updating Apache vhost to serve from dist/ (will ask for your password)..."
  sudo sed -i '' "s|DocumentRoot \"$PROJECT_ROOT\"$|DocumentRoot \"$PROJECT_ROOT/dist\"|g" "$VHOSTS"
  if ! grep -q "DocumentRoot \"$PROJECT_ROOT/dist\"" "$VHOSTS" 2>/dev/null; then
    echo ""
    echo "No DocumentRoot matching this project found in $VHOSTS"
    echo "Manually edit the file and set your port 80 vhost DocumentRoot to:"
    echo "  $PROJECT_ROOT/dist"
    echo "Then run: ./restart-homebrew-apache.sh"
    exit 1
  fi
fi

echo "Restarting Apache..."
sudo "$SCRIPT_DIR/restart-homebrew-apache.sh"

echo ""
echo "Done. Built app is served at http://localhost/ and http://seasonal-drops.ldev/"
