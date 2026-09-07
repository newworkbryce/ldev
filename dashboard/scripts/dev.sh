#!/bin/bash
# Run PHP API (port 8080) and Vite dev server together.
# Usage: ./scripts/dev.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

cleanup() {
  if [ -n "$PHP_PID" ] && kill -0 "$PHP_PID" 2>/dev/null; then
    kill "$PHP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo "Starting PHP API on http://127.0.0.1:8080 ..."
php -S 127.0.0.1:8080 &
PHP_PID=$!
sleep 0.5

echo "Starting Vite dev server..."
npm run dev
