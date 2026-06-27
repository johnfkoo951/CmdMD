# Fix: source/split editor still crashes after #1 — Highlightr `Bundle.module` lookup

> **Claude Code–ready.** Open this repo in Claude Code and say:
> *"Implement the fix in FIX_FOR_CLAUDE_CODE.md and prove it with the regression test."*
> Everything needed to reproduce, fix, and verify is below.

## Status

PR #1 (*"bundle Highlightr SPM resources"*, merged) copies `Highlightr_Highlightr.bundle`
into `Contents/Resources/`. That is **necessary but not sufficient** — the app still hard-crashes
(`SIGTRAP`) the instant the **source/split editor** renders, because the SwiftPM-generated
`Bundle.module` accessor never looks in `Contents/Resources`.

## Symptom

- Preview-only use looks fine (the editor `NSView` is never instantiated).
- Switching to **Source (⌘1) / Split (⌘2)**, or restoring a window that had the editor open, crashes immediately.
- `EXC_BREAKPOINT (SIGTRAP)` — a Swift `fatalError`.

Top of the crash stack:

```
_assertionFailure
closure #1 … static Bundle.module
Highlightr.init(highlightPath:)            // src/classes/Highlightr.swift:56  → let bundle = Bundle.module
SyntaxHighlighter.applyHighlights(…)
MarkdownTextEditor.makeNSView(context:)
```

`Highlightr.init` calls `Bundle.module` **unconditionally** (line 56) before it looks at
`highlightPath`, so passing a path cannot avoid it.

## Reproduce

```bash
printf '# t\n```swift\nlet x = 1\n```\n' > /tmp/t.md
open -a /Applications/CmdMD.app /tmp/t.md
osascript -e 'tell application "CmdMD" to activate' \
          -e 'tell application "System Events" to keystroke "1" using command down'   # Source view
# → process dies; a new ~/Library/Logs/DiagnosticReports/CmdMD-*.ips appears
```

## Root cause

The toolchain emits the two-path accessor in
`.build/…/Highlightr.build/DerivedSources/resource_bundle_accessor.swift`:

```swift
let mainPath  = Bundle.main.bundleURL.appendingPathComponent("Highlightr_Highlightr.bundle").path
let buildPath = "/Users/runner/work/CmdMD/CmdMD/.build/arm64-apple-macosx/release/Highlightr_Highlightr.bundle"
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { Swift.fatalError(…) }
```

For a packaged `.app`, `Bundle.main.bundleURL` is the **`.app` root**, therefore:

- `mainPath` = `…/CmdMD.app/Highlightr_Highlightr.bundle` — the app root, **outside `Contents/`**.
  macOS code signing forbids resources there (`codesign: unsealed contents present in the bundle root`),
  so the bundle can never legally live at this path in a signed app.
- `buildPath` = the CI's `.build` directory, which does not exist on a user's machine.

Both candidates fail → `fatalError`. The accessor **never checks `Bundle.main.resourceURL`**
(= `Contents/Resources`), which is exactly where #1 put the bundle. That is why the crash persists.

Evidence — a minimal `.app` with the same layout prints:

```
Bundle.main.bundleURL = …/X.app
accessor mainPath      = …/X.app/Highlightr_Highlightr.bundle   ← app root (unsignable)
```

## Fix

Two options. **(A)** is verified and minimal; **(B)** is the clean, location-independent long-term fix.

### (A) Verified, minimal — repoint the dead `buildPath` fallback (this PR)

The accessor falls back to `Bundle(path: buildPath)`. Rewrite `buildPath` *in the built binary*
to the bundle #1 already ships in `Contents/Resources`, **before** codesign re-seals it.

`scripts/fix-highlightr-bundle.py` (included) does an in-place, equal-length, null-padded
string replacement (Mach-O offsets preserved):

```
old (any builder):  …/.build/<arch>/release/Highlightr_Highlightr.bundle
new:                /Applications/CmdMD.app/Contents/Resources/Highlightr_Highlightr.bundle
```

`package_app.sh` runs it right after the executable + bundles are staged and just before
`codesign --force --deep --sign -`. Verified on an installed `1.4.7`: Source / Split / Preview
all render, **zero** new crash reports.

**Caveat:** this assumes the documented `/Applications` install location (the README already
instructs dragging to `/Applications`). An `.app` run from elsewhere still won't resolve — use (B)
for full independence.

### (B) Robust, recommended — build the `.app` with Xcode / `xcodebuild`

An Xcode app target emits the multi-candidate resource accessor (it checks
`Bundle.main.resourceURL`), so the `Contents/Resources` bundle from #1 resolves with no patching
and no path assumptions. Replace `swift build` + manual `package_app.sh` staging with an
`xcodebuild` app target.

## Regression test (acceptance criteria)

A fix is complete only when this prints `PASS` and produces **no** new crash report, **and** a code
block visibly renders with syntax colors in the editor (proves the bundle actually loaded — not just
"did not crash"):

```bash
printf '# t\n```swift\nlet x = 1\n```\n' > /tmp/t.md
open -a /Applications/CmdMD.app /tmp/t.md
osascript -e 'tell application "CmdMD" to activate' \
          -e 'tell application "System Events" to keystroke "1" using command down' \
          -e 'tell application "System Events" to keystroke "2" using command down'
sleep 3
pgrep -x CmdMD >/dev/null && echo PASS || echo FAIL
```

## Verified here

- Reproduced on `1.4.6 (12)` and `1.4.7 (13)`, macOS 26.5.1, Apple Silicon.
- Confirmed the bundle is present in `Contents/Resources` yet `Bundle.module` still fails — so #1 alone is insufficient.
- Applied (A) to an installed `1.4.7`: Source / Split / Preview render, **0** new crash reports.
- (B) is recommended but not built/verified here.
