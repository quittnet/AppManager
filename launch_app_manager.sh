#!/bin/bash
set -euo pipefail

APP_MANAGER_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_MANAGER_BINARY="$APP_MANAGER_DIR/AppManager"
APP_MANAGER_SOURCE="$APP_MANAGER_DIR/AppManager.swift"
APP_MANAGER_BUNDLE="${HOME}/Applications/AppManager.app"
APP_MANAGER_BUILD=""
trap 'if [ -n "$APP_MANAGER_BUILD" ]; then rm -f "$APP_MANAGER_BUILD"; fi' EXIT

if [ ! -x "$APP_MANAGER_BINARY" ] || [ "$APP_MANAGER_SOURCE" -nt "$APP_MANAGER_BINARY" ] || [ "$0" -nt "$APP_MANAGER_BINARY" ]; then
    APP_MANAGER_BUILD="$(mktemp "$APP_MANAGER_DIR/.AppManager.build.XXXXXX")"
    echo "Building AppManager..."
    swiftc -target "$(uname -m)-apple-macosx14.0" \
        -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
        "$APP_MANAGER_SOURCE" -o "$APP_MANAGER_BUILD" -framework AppKit
fi

# A failed build leaves the existing app running and its binary untouched.
bash "$APP_MANAGER_DIR/stop_app_manager.sh"
if [ -n "$APP_MANAGER_BUILD" ]; then
    mv -f "$APP_MANAGER_BUILD" "$APP_MANAGER_BINARY"
    APP_MANAGER_BUILD=""
fi

mkdir -p "$APP_MANAGER_BUNDLE/Contents/MacOS" "$APP_MANAGER_BUNDLE/Contents/Resources"
cp "$APP_MANAGER_BINARY" "$APP_MANAGER_BUNDLE/Contents/MacOS/AppManager"
cp "$APP_MANAGER_DIR/AppManager-Info.plist" "$APP_MANAGER_BUNDLE/Contents/Info.plist"
cp "$APP_MANAGER_DIR/AppManager.icns" "$APP_MANAGER_BUNDLE/Contents/Resources/AppManagerIcon.icns"
codesign --force --sign - "$APP_MANAGER_BUNDLE"
touch "$APP_MANAGER_BUNDLE"

# LaunchServices keeps the menu bar app independent of the launching terminal.
/usr/bin/open -n "$APP_MANAGER_BUNDLE" \
    --stdout "$APP_MANAGER_DIR/AppManager.log" --stderr "$APP_MANAGER_DIR/AppManager.log"
for ((APP_MANAGER_ATTEMPT = 0; APP_MANAGER_ATTEMPT < 30; APP_MANAGER_ATTEMPT++)); do
    for APP_MANAGER_PID in $(pgrep -x AppManager || true); do
        APP_MANAGER_PATH="$(ps -p "$APP_MANAGER_PID" -o comm= 2>/dev/null || true)"
        if [ "$APP_MANAGER_PATH" = "$APP_MANAGER_BUNDLE/Contents/MacOS/AppManager" ]; then
            echo "AppManager is running (PID $APP_MANAGER_PID). Click its menu bar icon to open."
            exit 0
        fi
    done
    sleep 0.1
done
echo "AppManager did not start. See $APP_MANAGER_DIR/AppManager.log" >&2
exit 1
