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
VERSION_FILE="$ROOT_DIR/VERSION"

# The version and build number live only in VERSION (release.yml checks the tag against it).
version_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }' "$VERSION_FILE"
}
APP_VERSION="$(version_value CFBundleShortVersionString)"
APP_BUILD="$(version_value CFBundleVersion)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ || ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "VERSION must set CFBundleShortVersionString=X.Y[.Z] and CFBundleVersion=<integer>." >&2
  exit 1
fi

# Universal binary: Intel Macs run macOS 14+ too. More than one --arch also switches
# SwiftPM to the Xcode build system, whose generated resource-bundle accessors look in
# Bundle.main.resourceURL, i.e. Contents/Resources. Highlightr therefore finds its bundle
# wherever the .app lives (the DMG, Downloads, ~/Applications, a renamed copy). The native
# build system's accessor tries only the .app root (code signing forbids resources there)
# and a baked .build path, which crashed 1.4.6-1.4.8 outside /Applications.
# Needs Xcode, not just the Command Line Tools. The bin path must use the same flags.
SWIFT_BUILD_FLAGS=(--configuration release --arch arm64 --arch x86_64)

echo "Building $APP_NAME $APP_VERSION ($APP_BUILD) release (arm64 + x86_64)..."
BUILD_BIN_DIR="$(swift build "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
swift build "${SWIFT_BUILD_FLAGS[@]}"

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
# CSS themes). Copy every generated *.bundle into Contents/Resources, where the
# Xcode-build-system `Bundle.module` accessors look (`Bundle.main.resourceURL`).
# Without Highlightr's, code blocks get no syntax highlighting.
if [[ ! -d "$BUILD_BIN_DIR/Highlightr_Highlightr.bundle" ]]; then
  echo "Highlightr_Highlightr.bundle not found in $BUILD_BIN_DIR." >&2
  exit 1
fi
shopt -s nullglob
resource_bundles=("$BUILD_BIN_DIR"/*.bundle)
shopt -u nullglob
for bundle in "${resource_bundles[@]}"; do
  echo "Bundling resource: $(basename "$bundle")"
  cp -R "$bundle" "$RESOURCES_DIR/"
done

# Highlightr's `Bundle.module` traps when its bundle is at none of the accessor's
# paths, so every architecture slice must carry the Xcode-build-system accessor
# (it checks Contents/Resources) and none the native SwiftPM one (it tries a baked
# .build path and the .app root, never Contents/Resources). Refuse anything else.
for arch in $(lipo -archs "$EXECUTABLE"); do
  slice_strings="$(strings -a -arch "$arch" "$EXECUTABLE")"
  if ! grep -q "unable to find bundle named Highlightr_Highlightr" <<<"$slice_strings"; then
    echo "$arch slice: Highlightr's Bundle.module accessor does not check Contents/Resources." >&2
    exit 1
  fi
  if grep -Eq "could not load resource bundle|/\.build/.*Highlightr_Highlightr\.bundle" <<<"$slice_strings"; then
    echo "$arch slice: carries SwiftPM's native resource accessor (baked .build path)." >&2
    exit 1
  fi
done

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

# Unquoted heredoc: only ${APP_VERSION} / ${APP_BUILD} (validated above) expand.
# Document types: Markdown via its UTI. The extension list that sat next to it was
# ignored (LSItemContentTypes wins), so the tags live in the imported declaration,
# which supplies the type where no newer system or app declaration does. Plain text
# (.txt notes) is accepted on drops, but with rank None, so CmdMD stops showing up
# in Open With for every source file and CSV (they all conform to public.plain-text).
cat > "$PLIST" <<PLIST
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
      <key>CFBundleTypeName</key>
      <string>Markdown Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Plain Text Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>None</string>
      <key>LSItemContentTypes</key>
      <array>
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
  <string>${APP_VERSION}</string>
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
  <string>${APP_BUILD}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHumanReadableCopyright</key>
  <string>© 2026 CMDSPACE (구요한). MIT License.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.plain-text</string>
      </array>
      <key>UTTypeDescription</key>
      <string>Markdown Document</string>
      <key>UTTypeIdentifier</key>
      <string>net.daringfireball.markdown</string>
      <key>UTTypeReferenceURL</key>
      <string>https://daringfireball.net/projects/markdown/</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>md</string>
          <string>markdown</string>
          <string>mdown</string>
          <string>mkd</string>
        </array>
        <key>public.mime-type</key>
        <array>
          <string>text/markdown</string>
        </array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null

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
