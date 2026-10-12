#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package_app.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/CmdMD.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/CmdMD"
PLIST="$APP_DIR/Contents/Info.plist"
ZIP_FILE="$DIST_DIR/CmdMD-macos.zip"
HIGHLIGHTR_BUNDLE="$APP_DIR/Contents/Resources/Highlightr_Highlightr.bundle"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null
}

[[ -x "$PACKAGE_SCRIPT" ]] || fail "scripts/package_app.sh is missing or not executable"

rm -rf "$DIST_DIR"
"$PACKAGE_SCRIPT"

[[ -d "$APP_DIR" ]] || fail "app bundle was not created"
[[ -x "$EXECUTABLE" ]] || fail "app executable was not created"
[[ -f "$PLIST" ]] || fail "Info.plist was not created"
[[ -f "$ZIP_FILE" ]] || fail "zip archive was not created"

# Universal binary: Intel Macs run macOS 14+ as well.
archs=" $(lipo -archs "$EXECUTABLE") "
[[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]] \
  || fail "executable is not universal (lipo -archs:$archs)"

# Regression guard for the 1.4.6-1.4.8 crashes: Highlightr's resource bundle must
# ship in Contents/Resources AND every slice's Bundle.module accessor must look
# there. SwiftPM's native accessor (a baked .build path plus the .app root) traps
# on the first highlighted code block anywhere but on the build machine.
[[ -n "$(find "$HIGHLIGHTR_BUNDLE" -name highlight.min.js -print -quit 2>/dev/null)" ]] \
  || fail "Highlightr_Highlightr.bundle (with highlight.min.js) missing from Contents/Resources"
for arch in $(lipo -archs "$EXECUTABLE"); do
  slice_strings="$(strings -a -arch "$arch" "$EXECUTABLE")"
  grep -q "unable to find bundle named Highlightr_Highlightr" <<<"$slice_strings" \
    || fail "$arch slice lacks the Xcode-build-system Highlightr accessor (the one that checks Contents/Resources)"
  if grep -Eq "could not load resource bundle|/\.build/.*Highlightr_Highlightr\.bundle" <<<"$slice_strings"; then
    fail "$arch slice still carries SwiftPM's native resource accessor (baked .build path)"
  fi
done

# Version and build number come from VERSION.
expected_version="$(awk -F= '$1 == "CFBundleShortVersionString" { print $2; exit }' "$ROOT_DIR/VERSION")"
expected_build="$(awk -F= '$1 == "CFBundleVersion" { print $2; exit }' "$ROOT_DIR/VERSION")"
[[ "$(plist_value CFBundleShortVersionString)" == "$expected_version" ]] \
  || fail "CFBundleShortVersionString does not match VERSION ($expected_version)"
[[ "$(plist_value CFBundleVersion)" == "$expected_build" ]] \
  || fail "CFBundleVersion does not match VERSION ($expected_build)"

plist_value "CFBundleURLTypes:0:CFBundleURLSchemes:0" | grep -qx "cmdmd" \
  || fail "Info.plist does not register cmdmd URL scheme"

plist_value NSPrincipalClass | grep -qx "NSApplication" \
  || fail "Info.plist does not declare NSPrincipalClass=NSApplication"

plist_value LSApplicationCategoryType | grep -qx "public.app-category.productivity" \
  || fail "Info.plist does not set LSApplicationCategoryType"

# Document types: Markdown is claimed by UTI; a plain-text claim (which every source
# file and CSV conforms to) may only accept drops (rank None), never Open With.
plist_value "CFBundleDocumentTypes:0:LSItemContentTypes:0" | grep -qx "net.daringfireball.markdown" \
  || fail "first document type does not claim net.daringfireball.markdown"
i=0
while plist_value "CFBundleDocumentTypes:$i" >/dev/null; do
  if plist_value "CFBundleDocumentTypes:$i:CFBundleTypeExtensions" >/dev/null; then
    fail "document type $i lists CFBundleTypeExtensions (ignored next to LSItemContentTypes)"
  fi
  if plist_value "CFBundleDocumentTypes:$i:LSItemContentTypes" | grep -qx "[[:space:]]*public.plain-text"; then
    plist_value "CFBundleDocumentTypes:$i:LSHandlerRank" | grep -qx "None" \
      || fail "document type $i claims public.plain-text with a rank other than None"
  fi
  i=$((i + 1))
done

plist_value "UTImportedTypeDeclarations:0:UTTypeIdentifier" | grep -qx "net.daringfireball.markdown" \
  || fail "Info.plist does not import the net.daringfireball.markdown type"
markdown_tags="$(plist_value "UTImportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension")"
for ext in md markdown mdown; do
  grep -qx "[[:space:]]*$ext" <<<"$markdown_tags" || fail "imported Markdown type lacks the .$ext extension"
done

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
fi

echo "PASS: package app artifact checks passed"
