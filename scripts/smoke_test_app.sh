#!/usr/bin/env bash
# Launch smoke test for a packaged CmdMD.app (run before tagging a release).
#
# Copies the app to a scratch folder under a different name — outside /Applications,
# like the mounted DMG, ~/Downloads or ~/Applications — and runs it against an
# isolated CMDMD_DATA_DIR whose session reopens a note with a fenced code block in
# Split view, so the editor highlights it on launch. Passes when the process is
# still alive after WAIT_SECONDS (default 8), no new CmdMD crash report appeared and
# the log says Highlightr loaded. With --without-highlightr-bundle the bundle is
# removed from the copy first: the app must then run without code highlighting
# instead of trapping in Bundle.module. SMOKE_ARCH=x86_64 runs the Intel slice
# (under Rosetta on Apple silicon).
#
# The copy gets its own bundle identifier and no URL scheme or document types, so it
# never shares preferences, WebKit data or file associations with an installed CmdMD.
#
# Usage: scripts/smoke_test_app.sh [--without-highlightr-bundle] [path/to/CmdMD.app]
set -euo pipefail

cd "$(dirname "$0")/.."

EXPECT_HIGHLIGHTR=1
if [[ "${1:-}" == "--without-highlightr-bundle" ]]; then
  EXPECT_HIGHLIGHTR=0
  shift
fi
SOURCE_APP="${1:-dist/CmdMD.app}"
WAIT_SECONDS="${WAIT_SECONDS:-8}"
SMOKE_ID="com.cmdmd.app.smoketest"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[[ -d "$SOURCE_APP" ]] || { echo "error: $SOURCE_APP not found — run scripts/package_app.sh first" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cmdmd-smoke.XXXXXX")"
APP="$WORK/CmdMD Smoke Copy.app"
DATA_DIR="$WORK/data"
NOTE="$WORK/code-fence.md"
PID=""

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    # stderr of the whole block: it also silences bash's "Terminated" job notice.
    {
      kill "$PID"
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$PID" || break
        sleep 0.5
      done
      kill -9 "$PID"
      wait "$PID"
    } 2>/dev/null || true
  fi
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  defaults delete "$SMOKE_ID" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Saved Application State/$SMOKE_ID.savedState" \
    "$HOME/Library/Caches/$SMOKE_ID" "$HOME/Library/WebKit/$SMOKE_ID" \
    "$HOME/Library/HTTPStorages/$SMOKE_ID" "$HOME/Library/HTTPStorages/$SMOKE_ID.binarycookies"
  rm -rf "$WORK"
}
trap cleanup EXIT

crash_reports() {
  ls "$CRASH_DIR" 2>/dev/null | grep -E '^CmdMD[-_].*\.ips$' || true
}

ditto "$SOURCE_APP" "$APP"
plist="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SMOKE_ID" "$plist"
for key in CFBundleURLTypes CFBundleDocumentTypes UTImportedTypeDeclarations; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null || true
done
if [[ "$EXPECT_HIGHLIGHTR" -eq 0 ]]; then
  rm -rf "$APP/Contents/Resources/Highlightr_Highlightr.bundle"
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  || { echo "error: could not re-sign the smoke-test copy" >&2; exit 1; }

mkdir -p "$DATA_DIR"
cat > "$NOTE" <<'MD'
# Smoke test

```swift
let greeting = "Hello, CmdMD"
print(greeting)
```
MD
# Formats: AppSettings (decodeIfPresent, defaults fill the rest) and SessionState.
note_url="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).as_uri())' "$NOTE")"
printf '{"hasCompletedOnboarding":true,"restoreLastSession":true}\n' > "$DATA_DIR/settings.json"
printf '{"openFiles":["%s"],"activeFileIndex":0,"viewMode":"Split","sidebarVisible":false,"inspectorVisible":false}\n' \
  "$note_url" > "$DATA_DIR/session.json"

launcher=()
if [[ -n "${SMOKE_ARCH:-}" ]]; then
  launcher=(arch "-$SMOKE_ARCH")
fi

reports_before="$(crash_reports)"
echo "==> Launching $(basename "$APP") (${SMOKE_ARCH:-native}) from $WORK (Highlightr bundle: $([[ "$EXPECT_HIGHLIGHTR" -eq 1 ]] && echo present || echo removed))"
CMDMD_DATA_DIR="$DATA_DIR" ${launcher[@]+"${launcher[@]}"} "$APP/Contents/MacOS/CmdMD" \
  -ApplePersistenceIgnoreState YES >"$WORK/stdout.log" 2>&1 &
PID=$!
sleep "$WAIT_SECONDS"

status=0
if ! kill -0 "$PID" 2>/dev/null; then
  echo "FAIL: CmdMD exited within ${WAIT_SECONDS}s" >&2
  tail -20 "$WORK/stdout.log" >&2 || true
  status=1
fi
new_reports="$(comm -13 <(echo "$reports_before") <(crash_reports))"
if [[ -n "$new_reports" ]]; then
  echo "FAIL: new crash report(s): $new_reports" >&2
  status=1
fi
log_lines="$(cat "$DATA_DIR"/logs/*.log 2>/dev/null || true)"
if [[ "$EXPECT_HIGHLIGHTR" -eq 1 ]]; then
  # From this copy's own Contents/Resources, not from an installed CmdMD.
  expected="Code highlighting ready"
  expected_path="/$(basename "$WORK")/$(basename "$APP")/Contents/Resources/Highlightr_Highlightr.bundle"
else
  expected="Code highlighting disabled"
  expected_path=""
fi
match="$(grep -F "$expected" <<<"$log_lines" | head -1 || true)"
if [[ -z "$match" || "$match" != *"$expected_path"* ]]; then
  echo "FAIL: the log does not say \"$expected${expected_path:+ …$expected_path}\"" >&2
  grep -i "highlight" <<<"$log_lines" >&2 || true
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  echo "$match"
  echo "PASS: CmdMD ran ${WAIT_SECONDS}s from $(basename "$APP") outside /Applications"
fi
exit "$status"
