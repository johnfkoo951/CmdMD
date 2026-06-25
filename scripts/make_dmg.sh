#!/usr/bin/env bash
# Build a drag-to-install DMG from a built CmdMD.app.
# Usage: scripts/make_dmg.sh [path/to/CmdMD.app] [output.dmg]
# Defaults: dist/CmdMD.app -> dist/CmdMD-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

APP="${1:-dist/CmdMD.app}"
if [[ ! -d "$APP" ]]; then
  echo "error: app not found at '$APP' — run scripts/package_app.sh first" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOL_NAME="CmdMD ${VERSION}"
DMG="${2:-dist/CmdMD-${VERSION}.dmg}"

echo "==> Building DMG for CmdMD ${VERSION}"

# Stage the app + an /Applications symlink so users can drag-to-install.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
# UDZO = zlib-compressed, the standard distributable read-only format.
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

# Ad-hoc sign the DMG so Gatekeeper shows a cleaner (still unidentified) prompt.
codesign --force --sign - "$DMG" 2>/dev/null || true

SIZE="$(du -h "$DMG" | cut -f1)"
echo "==> Created $DMG ($SIZE)"
echo "    volume: $VOL_NAME"