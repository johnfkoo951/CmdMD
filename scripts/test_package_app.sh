#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package_app.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/CmdMD.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/CmdMD"
PLIST="$APP_DIR/Contents/Info.plist"
ZIP_FILE="$DIST_DIR/CmdMD-macos.zip"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -x "$PACKAGE_SCRIPT" ]] || fail "scripts/package_app.sh is missing or not executable"

rm -rf "$DIST_DIR"
"$PACKAGE_SCRIPT"

[[ -d "$APP_DIR" ]] || fail "app bundle was not created"
[[ -x "$EXECUTABLE" ]] || fail "app executable was not created"
[[ -f "$PLIST" ]] || fail "Info.plist was not created"
[[ -f "$ZIP_FILE" ]] || fail "zip archive was not created"

# Regression guard for the 1.4.6 crash: Highlightr's resource bundle must ship
# inside the app or the first code-block highlight traps via Bundle.module.
[[ -d "$APP_DIR/Contents/Resources/Highlightr_Highlightr.bundle" ]] \
  || fail "Highlightr_Highlightr.bundle missing from Contents/Resources (syntax highlighting would crash on launch)"

/usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" "$PLIST" \
  | grep -qx "cmdmd" \
  || fail "Info.plist does not register cmdmd URL scheme"

/usr/libexec/PlistBuddy -c "Print :NSPrincipalClass" "$PLIST" \
  | grep -qx "NSApplication" \
  || fail "Info.plist does not declare NSPrincipalClass=NSApplication"

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
fi

echo "PASS: package app artifact checks passed"
