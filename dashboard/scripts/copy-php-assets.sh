#!/bin/bash
# Copy PHP API and Apache config into dist/ after vite build.
# Preserves dist/data/config-path.json when it already exists.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "Copying api.php, .htaccess, and data into dist/..."
cp api.php dist/
if [ -f htaccess-for-dist ]; then
  cp htaccess-for-dist dist/.htaccess
fi
mkdir -p dist/data
if [ ! -f dist/data/config-path.json ]; then
  DEFAULT_CONFIG_PATH="${HOME:-/tmp}/Sites/local-projects-dashboard.json"
  echo "{\"configPath\": \"$DEFAULT_CONFIG_PATH\"}" > dist/data/config-path.json
  echo "Created default config-path (config in ~/Sites)."
fi
