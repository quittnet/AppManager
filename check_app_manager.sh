#!/bin/bash
set -euo pipefail

APP_MANAGER_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_MANAGER_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/appmanager-check.XXXXXX")"
trap 'rm -rf "$APP_MANAGER_CHECK_DIR"' EXIT

swift format lint --strict "$APP_MANAGER_DIR/AppManager.swift" "$APP_MANAGER_DIR/AppManagerTests.swift"
for script in launch_app_manager.sh stop_app_manager.sh check_app_manager.sh; do
    bash -n "$APP_MANAGER_DIR/$script"
done
plutil -lint "$APP_MANAGER_DIR/AppManager-Info.plist"
swiftc -target "$(uname -m)-apple-macosx14.0" \
    -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$APP_MANAGER_CHECK_DIR/module-cache" \
    "$APP_MANAGER_DIR/AppManager.swift" -o "$APP_MANAGER_CHECK_DIR/AppManager" -framework AppKit
swiftc -target "$(uname -m)-apple-macosx14.0" \
    -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path "$APP_MANAGER_CHECK_DIR/module-cache" -D APPMANAGER_TEST \
    "$APP_MANAGER_DIR/AppManager.swift" "$APP_MANAGER_DIR/AppManagerTests.swift" \
    -o "$APP_MANAGER_CHECK_DIR/AppManagerTests" -framework AppKit
"$APP_MANAGER_CHECK_DIR/AppManagerTests"
echo "AppManager formatting, build, script syntax, and regression checks passed."
