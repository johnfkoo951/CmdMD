#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CmdMD"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/$APP_NAME"
PLIST="$CONTENTS_DIR/Info.plist"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"
ZIP_FILE="$DIST_DIR/$APP_NAME-macos.zip"

echo "Building $APP_NAME release..."
BUILD_BIN_DIR="$(swift build --configuration release --show-bin-path)"
swift build --configuration release

BUILT_EXECUTABLE="$BUILD_BIN_DIR/$APP_NAME"
if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
  echo "Release executable not found: $BUILT_EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_DIR" "$ZIP_FILE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILT_EXECUTABLE" "$EXECUTABLE"
chmod 755 "$EXECUTABLE"

# SwiftPM resource bundles (e.g. Highlightr_Highlightr.bundle — highlight.js +
# CSS themes). Without these, Highlightr's `Bundle.module` accessor traps on the
# first code-block highlight and the app crashes on launch (the 1.4.6
# regression). Copy every generated *.bundle into Contents/Resources so
# `Bundle.module` resolves them via `Bundle.main.resourceURL`.
shopt -s nullglob
resource_bundles=("$BUILD_BIN_DIR"/*.bundle)
shopt -u nullglob
if [[ ${#resource_bundles[@]} -eq 0 ]]; then
  echo "Warning: no SwiftPM resource bundles found in $BUILD_BIN_DIR; code highlighting may be unavailable." >&2
fi
for bundle in "${resource_bundles[@]}"; do
  echo "Bundling resource: $(basename "$bundle")"
  cp -R "$bundle" "$RESOURCES_DIR/"
done

# The copy above is necessary but NOT sufficient. With `swift build`, Highlightr's
# generated `Bundle.module` accessor resolves the bundle from `Bundle.main.bundleURL`
# (the .app ROOT, where code signing forbids resources) and from a baked `.build` path
# (absent on user machines) — it never checks Contents/Resources. So the app still traps
# on the first code-block highlight (editor render). Repoint the baked fallback path to
# the shipped Contents/Resources bundle, before codesign re-seals the binary.
# See FIX_FOR_CLAUDE_CODE.md. Long-term fix: build via an Xcode/xcodebuild app target.
if command -v python3 >/dev/null 2>&1; then
  python3 "$(dirname "$0")/fix-highlightr-bundle.py" "$EXECUTABLE" \
    || echo "Warning: Highlightr bundle-path patch failed; editor view may still crash." >&2
else
  echo "Warning: python3 not found; skipping Highlightr bundle-path patch." >&2
fi

if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
else
  echo "Warning: $APP_ICON not found; bundling without an app icon." >&2
fi

# Brand book glyph used by in-app logo (Welcome / Onboarding heroes).
BOOK_GLYPH="$ROOT_DIR/Resources/cmds-book-white.png"
if [[ -f "$BOOK_GLYPH" ]]; then
  cp "$BOOK_GLYPH" "$RESOURCES_DIR/cmds-book-white.png"
fi

cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>CmdMD</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>mdown</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Markdown Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
      </array>
    </dict>
  </array>
  <key>CFBundleExecutable</key>
  <string>CmdMD</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.cmdmd.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>CmdMD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.4.7</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.cmdmd.app</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>cmdmd</string>
      </array>
    </dict>
  </array>
  <key>CFBundleVersion</key>
  <string>13</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  echo "Ad-hoc signing $APP_NAME.app..."
  codesign --force --deep --sign - "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
else
  echo "codesign not found; leaving $APP_NAME.app unsigned."
fi

(
  cd "$DIST_DIR"
  zip -qry -X "$(basename "$ZIP_FILE")" "$APP_NAME.app"
)

echo "Created $ZIP_FILE"
