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
DMG="dist/CmdMD-${VERSION}.dmg"

# Private per-run scratch dir (mkdtemp: mode 0700, unique name) for the decoded .p12,
# the throwaway keychain and the notarization zip. The cleanup trap is armed before
# anything is written, so a failed run (e.g. a wrong .p12 password) leaves neither
# the key nor a keychain behind, and the next run doesn't trip over them.
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmdmd-sign.XXXXXX")"
KEYCHAIN="$WORK/cmdmd-signing.keychain-db"
cleanup() {
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Submits $1 to the notary service, waits for the verdict and fails unless it is Accepted.
notarize() {
  local result status
  result="$(xcrun notarytool submit "$1" \
    --apple-id "$MACOS_NOTARY_APPLE_ID" \
    --password "$MACOS_NOTARY_PASSWORD" \
    --team-id "$MACOS_NOTARY_TEAM_ID" \
    --wait --output-format json)" || true   # the status check below is the gate
  status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization of $(basename "$1") ended with status '${status:-unknown}':" >&2
    echo "$result" >&2
    echo "Details: xcrun notarytool log <id> (same credentials)." >&2
    exit 1
  fi
}

# ── 1. Import the cert into a throwaway keychain ───────────────────────────────
KEYCHAIN_PWD="$(uuidgen)"
CERT_P12="$WORK/cmdmd-cert.p12"
( umask 077; echo "$MACOS_CERTIFICATE" | base64 --decode > "$CERT_P12" )

security create-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PWD" "$KEYCHAIN"
security import "$CERT_P12" -P "$MACOS_CERTIFICATE_PWD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PWD" "$KEYCHAIN" >/dev/null
# Prepend our keychain to the search list so codesign can find the identity.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed s/\"//g)
rm -f "$CERT_P12"

# ── 2. Sign the app: Developer ID + hardened runtime + secure timestamp ────────
echo "==> Signing $APP with $MACOS_SIGN_IDENTITY"
codesign --force --options runtime --timestamp --deep \
  --sign "$MACOS_SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ── 3. Notarize (submit a zip of the app; notarytool waits for the verdict) ─────
NOTARIZE_ZIP="$WORK/cmdmd-notarize.zip"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
echo "==> Submitting the app to Apple notary service (this can take a few minutes)…"
notarize "$NOTARIZE_ZIP"
rm -f "$NOTARIZE_ZIP"

# ── 4. Staple the ticket to the app, then build the distributables from it ─────
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"

# Distributable zip (stapled app inside)
( cd dist && rm -f CmdMD-macos.zip && ditto -c -k --sequesterRsrc --keepParent CmdMD.app CmdMD-macos.zip )

# ── 5. Distributable DMG (stapled app inside): sign, notarize, then staple it ───
# stapler only staples a signed container that has a ticket of its own; the app's
# ticket does not cover the DMG. Never re-sign after stapling: it voids the ticket.
scripts/make_dmg.sh "$APP" "$DMG"
codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$DMG"
echo "==> Submitting the DMG to Apple notary service…"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Done. Notarized + stapled: $DMG and dist/CmdMD-macos.zip"
