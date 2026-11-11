#!/bin/bash
set -euo pipefail

APP_MANAGER_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_MANAGER_BINARY="$APP_MANAGER_DIR/AppManager"
APP_MANAGER_BUNDLE_BINARY="${HOME}/Applications/AppManager.app/Contents/MacOS/AppManager"
APP_MANAGER_LEGACY_BINARY="$APP_MANAGER_DIR/AppManager.app/Contents/MacOS/AppManager"
APP_MANAGER_STOPPED=false

# Match the executable path exactly, not a regular expression in a command line.
# This also avoids matching shells, editors, or a different copy of the app.
for APP_MANAGER_PID in $(pgrep -x AppManager || true); do
    APP_MANAGER_PATH="$(ps -p "$APP_MANAGER_PID" -o comm= 2>/dev/null || true)"
    if [ "$APP_MANAGER_PATH" != "$APP_MANAGER_BINARY" ] && [ "$APP_MANAGER_PATH" != "$APP_MANAGER_BUNDLE_BINARY" ] && [ "$APP_MANAGER_PATH" != "$APP_MANAGER_LEGACY_BINARY" ]; then
        continue
    fi
    APP_MANAGER_RUNNING_PATH="$APP_MANAGER_PATH"
    kill -TERM "$APP_MANAGER_PID" 2>/dev/null || true
    APP_MANAGER_STOPPED=true
    for ((APP_MANAGER_ATTEMPT = 0; APP_MANAGER_ATTEMPT < 30; APP_MANAGER_ATTEMPT++)); do
        APP_MANAGER_PATH="$(ps -p "$APP_MANAGER_PID" -o comm= 2>/dev/null || true)"
        [ "$APP_MANAGER_PATH" = "$APP_MANAGER_RUNNING_PATH" ] || break
        sleep 0.1
    done
    if [ "$APP_MANAGER_PATH" = "$APP_MANAGER_RUNNING_PATH" ]; then
        echo "AppManager did not stop within 3 seconds. Existing app left in place." >&2
        exit 1
    fi
done

if "$APP_MANAGER_STOPPED"; then
    echo "AppManager stopped."
else
    echo "AppManager was not running."
fi
