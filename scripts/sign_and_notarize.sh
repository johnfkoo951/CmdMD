#!/usr/bin/env bash
# Developer ID sign + notarize + staple CmdMD for Gatekeeper-clean distribution.
# Produces a notarized, stapled dist/CmdMD-<version>.dmg and dist/CmdMD-macos.zip.
#
# Runs only when signing credentials are present (CI gates it on secrets); the
# normal build stays ad-hoc signed without these. Required env vars:
#   MACOS_CERTIFICATE       base64 of the "Developer ID Application" cert (.p12)
#   MACOS_CERTIFICATE_PWD   password for that .p12
#   MACOS_SIGN_IDENTITY     e.g. "Developer ID Application: Your Name (TEAMID)"
#   MACOS_NOTARY_APPLE_ID   Apple ID email used for enrollment
#   MACOS_NOTARY_PASSWORD   app-specific password (appleid.apple.com → Sign-In & Security)
#   MACOS_NOTARY_TEAM_ID    10-char Team ID
set -euo pipefail

cd "$(dirname "$0")/.."

APP="dist/CmdMD.app"
[[ -d "$APP" ]] || { echo "error: $APP missing — run scripts/package_app.sh first" >&2; exit 1; }

: "${MACOS_CERTIFICATE:?}" "${MACOS_CERTIFICATE_PWD:?}" "${MACOS_SIGN_IDENTITY:?}"
: "${MACOS_NOTARY_APPLE_ID:?}" "${MACOS_NOTARY_PASSWORD:?}" "${MACOS_NOTARY_TEAM_ID:?}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
WORK="${RUNNER_TEMP:-/tmp}"
DMG="dist/CmdMD-${VERSION}.dmg"

# ── 1. Import the cert into a throwaway keychain ───────────────────────────────
KEYCHAIN="$WORK/cmdmd-signing.keychain-db"
KEYCHAIN_PWD="$(uuidgen)"
CERT_P12="$WORK/cmdmd-cert.p12"
echo "$MACOS_CERTIFICATE" | base64 --decode > "$CERT_P12"

security create-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN"
security import "$CERT_P12" -P "$MACOS_CERTIFICATE_PWD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PWD" "$KEYCHAIN" >/dev/null
# Prepend our keychain to the search list so codesign can find the identity.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed s/\"//g)
rm -f "$CERT_P12"

cleanup() { security delete-keychain "$KEYCHAIN" 2>/dev/null || true; }
trap cleanup EXIT

# ── 2. Sign the app: Developer ID + hardened runtime + secure timestamp ────────
echo "==> Signing $APP with $MACOS_SIGN_IDENTITY"
codesign --force --options runtime --timestamp --deep \
  --sign "$MACOS_SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ── 3. Notarize (submit a zip of the app; notarytool waits for the verdict) ─────
NOTARIZE_ZIP="$WORK/cmdmd-notarize.zip"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
echo "==> Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --apple-id "$MACOS_NOTARY_APPLE_ID" \
  --password "$MACOS_NOTARY_PASSWORD" \
  --team-id "$MACOS_NOTARY_TEAM_ID" \
  --wait
rm -f "$NOTARIZE_ZIP"

# ── 4. Staple the ticket to the app, then build the distributables from it ─────
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"

# Distributable zip (stapled app inside)
( cd dist && rm -f CmdMD-macos.zip && ditto -c -k --sequesterRsrc --keepParent CmdMD.app CmdMD-macos.zip )

# Distributable DMG (stapled app inside), then staple the DMG container too
scripts/make_dmg.sh "$APP" "$DMG"
xcrun stapler staple "$DMG"

echo "==> Done. Notarized + stapled: $DMG and dist/CmdMD-macos.zip"
xcrun stapler validate "$DMG" || true
