# CmdMD — Engineering Notes & Gotchas

A running log of the non-obvious SwiftUI / AppKit problems hit while building
CmdMD, each as **Symptom → Root cause → Fix**. These are the things that cost
real debugging time; read this before touching the related area.

---

## 1. Command Palette / Omnisearch — ↑/↓ didn't move the highlight

**Symptom.** Pressing ↓ in `⌘P` (and `⇧⌘O`) did nothing visible. The selected
row stayed put.

**Root cause — two separate bugs stacked:**

1. **A focused single-line `TextField` swallows the arrow keys.** On macOS, ↑/↓
   move the insertion point, so the field consumes them before `.onKeyPress`
   (or a parent handler) ever sees them. An `NSEvent.addLocalMonitorForEvents`
   workaround that mutated `@State` from its escaping closure also failed —
   mutating `@State` through a captured *View value* doesn't reliably re-render.
2. **`LazyVStack` + `@Observable` doesn't re-diff already-built rows.** Even after
   moving selection into an `@Observable` model (so the mutation *did* land — the
   `body` re-ran, confirmed with `NSLog`), the highlight still didn't repaint.
   A `LazyVStack` caches its created rows and does not re-evaluate them when an
   observable they receive *as a value* (`isSelected`) changes.

**Fix.**
- Key handling: `PaletteTextField` (an `NSViewRepresentable` over `NSTextField`)
  intercepts `moveUp:` / `moveDown:` / `insertNewline:` / `cancelOperation:` in
  `control(_:textView:doCommandBy:)` — the canonical command-palette pattern.
  `AutoFocusTextField` claims first responder in `viewDidMoveToWindow` (a one-shot
  async `makeFirstResponder` in `makeNSView` can race the sheet's window and lose).
- Rendering: switched the result lists from `LazyVStack` to **`VStack`** (the lists
  are small — tens of rows — so eager rendering is fine and always repaints).

**How it was found.** On-device `NSLog` proved `doCommandBy: moveDown:` fired,
`selectedIndex` went `0→1→2`, and `body` re-ran — isolating the failure to the
lazy container's row diffing, not the input path.

---

## 2. Tab switches were slow to open/close

**Symptom.** A visible delay every time you switched, opened, or closed a tab.

**Root cause.** `DocumentEditorView(...).id(document.id)` tore the whole subtree
down and rebuilt it on every tab change — including spawning a fresh `WKWebView`
(a new web content process) and a full editor re-highlight.

**Fix.** Removed the `.id`. The editor + preview panes now persist and update in
place, keyed by a `documentID` passed into each. On a genuine document switch the
editor resets undo/scroll/selection and the preview renders immediately; an
in-place edit or disk reload preserves them.

**Follow-on bug (caught in review).** The preview's debounced render captured no
document id, so a debounced render from the *previous* note could land after a
switch and clobber the new one. Fixed by re-checking `currentDocumentID` inside
both the `DispatchWorkItem` and its async `evaluateJavaScript` completion.

---

## 3. External edits (Obsidian, vim, VS Code) didn't show up

**Symptom.** Editing the same `.md` in another app didn't reflect in CmdMD, or
only after a long delay — the watcher went silent.

**Root cause.** Most editors do **atomic saves**: write a temp file, then `rename`
it over the original. That replaces the file's inode. A `DispatchSource` file
watcher bound to the old inode's file descriptor receives `.rename`/`.delete`
(never `.write`) and the old code *gave up watching*.

**Fix.** On `.rename`/`.delete`, re-resolve the path and **re-arm** the watcher on
the new inode (after a brief delay for the replace to settle), then reload —
preserving document identity so scroll/selection survive. In-app unsaved edits are
never clobbered (a toast prompts a manual `⌥⌘R` reload instead).

---

## 4. Toolbar — a stray search/`»` control at the far right

**Symptom.** A control at the top-right that opened a *search field* (not the
inspector). Clicking where the inspector toggle "should" be did the wrong thing.

**Root cause.** In a `NavigationSplitView`, toolbar items declared by the *sidebar*
views (folder search, refresh, new draft, clear recents) use `.primaryAction`,
which lands at the **window toolbar's trailing edge**, mixing with the detail's
items and overflowing into the macOS `»` chevron. The visible far-right control was
the sidebar's folder-search button.

**Fix.** Moved per-tab sidebar actions out of the window toolbar into in-sidebar
headers (`SidebarHeader`). The window toolbar now carries only detail items, so the
inspector toggle is clean and the stray search/overflow is gone.

> Note: with `.windowStyle(.hiddenTitleBar)` + `.unified(showsTitle: false)`,
> toolbar items tend to left-cluster; `.primaryAction` does not push to the
> absolute right edge. Left as-is for now.

---

## 5. Brand accent that follows light/dark — and stays legible

**Decision.** CMDS is Dark Green `#134538` (light) / Pink `#E985A2` (dark). One
adaptive token drives everything: a dynamic `NSColor(name:dynamicProvider:)` wrapped
as `Color.cmdsAccent`, plus a root `.tint`.

**Gotchas.**
- `.tint` does **not** cross `.sheet` boundaries — every sheet root re-applies it.
- **`--accent-on` rule:** white-on-pink is only ~2.5:1 (fails WCAG AA), but
  near-black-on-pink is ~7.7:1. So text/icons on a solid accent fill use
  `Color.cmdsAccentOn` (white in light, `#0b0f0d` in dark), **not** `.white`.
- Inline `code` inside the CMDS theme's colored table headers inherited the header
  text color on a non-contrasting background → invisible. Fixed with explicit
  `--code-fg` and a dedicated `th code` treatment (dark translucent pill + white).

---

## 6. Editor theme must follow the app appearance

**Symptom.** A light app still showed a dark source pane.

**Fix.** Added `EditorTheme.cmdsLight`; `EditorTheme.resolved(forDark:)` maps
`.cmds`↔`.cmdsLight`. `EditorPane` reads `@Environment(\.colorScheme)` and resolves,
so the default CMDS editor theme tracks light/dark. `.cmdsLight` is hidden from the
picker (`selectableCases`).

---

## 7. Remappable shortcuts despite static `.keyboardShortcut`

**Approach.** `Shortcuts.swift` defines `KeyBinding` + `AppShortcut` (defaults
mirror the user's Obsidian vault: `⌘P` palette, `⌃⌘←/→` sidebars, `⌥⌘C` copy path,
…). `settings.keyBindings` overrides; `View.appShortcut(_:)` applies it. Because the
`.commands` builder reads the `@Observable` `AppState`, remaps apply live — no
restart, no AppKit menu surgery. The Shortcuts settings tab records combos with a
local key monitor.

---

## 8. In-app update checks (direct download, no App Store)

GitHub Releases API (`/releases/latest`): compare `tag_name` to the running bundle
version with a small component-wise semver compare. Silent on launch (throttled 6h),
on-demand via the app menu / About. A status-bar badge appears for older builds.
CmdMD isn't sandboxed, so `URLSession` works without extra entitlements.

---

## 9. Library / CDN gotchas

- **Bundled, not fetched:** the preview loads KaTeX, Pele and highlight.js from
  `Resources/PreviewLibs` (+ Highlightr's bundle) over `cmdmd-lib://`
  (`PreviewLibrarySchemeHandler`), SRI hashed from the served bytes. Only HTML export /
  Copy as HTML use jsDelivr.
- **Diagrams (Pele):** `Resources/PreviewLibs/cmds-pele/` is a consumer copy of the
  cmds-pele module — refresh it with cmds-pele's `bin/pele-sync.py`, never by hand. The
  app reads Pele's version from `cmds-pele.version.json` (the export's jsDelivr URL) and
  hashes the files itself, so a sync needs no code change. ```` ```mermaid ```` renders as
  `<div class="cmdmd-diagram"><pre class="mermaid">`, mounted by `cmdsPele.mountAll` after
  first paint.
- **KaTeX:** `@0.16.47` + `mhchem` + delimiters for `\[ \]` and `\( \)` (masked in
  `maskMathRegions`).
- **CI:** the pinned `swift-actions/setup-swift@5.9` **crashes `swift-frontend`**
  building Yams' module interface. `ci.yml`/`release.yml` use the macOS runner's
  native toolchain instead — do not re-pin 5.9.
- **Diagram captions:** an italic line right after a ```` ```mermaid ```` fence is the
  caption (`p.cmdmd-diagram-caption`; the diagram's `pre` gets `data-captioned` so Pele
  mounts it without a figure). `%% @caption:` is used only when there is no such line —
  cmds-pele's `catalog/SURFACES.md` rule, because the visible line is what Obsidian shows.
- **Diagram colors:** every theme draws diagrams the way the main vault does.
  `PreviewStyles.diagramTokens` fills only the roles Obsidian's `app.css` takes from the
  vault theme: `--cp-bg/fg/muted`, `--cp-line` = the text color, `--cp-surface(-alt)` =
  `--bg-secondary`, `--cp-border` = `--border-color`, and the fonts. It never sets the
  palette (accent, series, critical, key/aux), so cmds-pele's defaults apply. Those come
  from the same `tokens.json` as the vault's `cmds-pele-vault` plugin. The roles were read
  from the running vault (offscreen `MarkdownRenderer.render`, 2026-10-28). On Sepia light's
  cream, series 4 sits at 4.37:1 against cmds-pele's 4.5 rule
  (`testVaultDiagramPaletteHoldsOnEveryThemeBackground`).
- **Task boxes:** `<p><input …/>text`, with no space after the box. The box hangs in the
  bullet's gutter, and a space started the first line ~4 px right of its wrapped lines
  (`testWrappedTaskTextLinesUpInWebKit`).

---

## 10. Typing and tab switches reloaded the whole preview

**Symptom.** Every typing pause re-rendered the note on the main thread and reloaded
the page (110–180 ms for a large note, plus KaTeX/Pele/highlight.js again); a tab
switch did the same; keystrokes in split view cost 30–60 ms of main-thread time.

**Root cause.** Three layers each did whole-document work per change: SwiftUI compared
the bridged 500 KB `String` on every update (11–13 ms per compare), the renderer ran on
the main thread, and the page was replaced with `loadHTMLString`.

**Fix.**
- `PreviewSource` compares length first; `updateNSView` skips only when text, settings
  and base URL match the newest render *requested* (not the page on screen).
- `PreviewRenderThread` (`PreviewScheduling.swift`) renders off-main on one serial thread
  with an **8 MB stack** — a GCD worker's 512 KB stack overflows (SIGBUS) on ~600 nested
  quotes. A newer request for the same preview replaces the waiting one.
- `PreviewPageCache` keeps the last 6 notes' pages; a cached page gets a fresh nonce
  (`refreshingNonce(in:)`, head only). `PreviewDebounce` waits 1.5× the last refresh,
  clamped to 40–250 ms. `PreviewWarmup` starts WebKit when the editor window appears.
- Live pages wrap the note in `#cmdmd-root` with a `<!--cmdmd-->` marker before each
  top-level block (`PreviewBlocks.swift` merges ranges an element spans, e.g. `<details>`
  or footnotes). `PreviewEdit` diffs old/new blocks byte-wise from both ends and
  `cmdmdPreview.patch` (`PreviewRuntime.swift`) swaps only the changed run — passed as
  a `callAsyncJavaScript` argument, parsed in a `<template>`, then highlight.js / KaTeX /
  Pele run on the new nodes only. A nonce or block-count mismatch, a head change (first
  code/math/diagram, new callout type) or markup that would parse differently on its own
  falls back to a full load. Task boxes carry an ordinal (`data-task`), mapped to a line
  by `RenderedBody.taskLines`, so Enter above a task doesn't change every later block.
- Exports use `interactiveTasks = false`: no root, markers, runtime or task bridge.

**Editor side** (`EditorTextView.swift`): the current-line band repaints only its old and
new rects; the line index follows text-storage edits (exact during Korean marked text);
TextKit 1's "redraw everything below the edited line" is held back for edits inside one
line unless the line's height changes, the view scrolls, or the selection leaves the line.

### Measuring

All env-gated (skipped in a plain `swift test`); numbers only mean something in release
and as interleaved A/B medians:

```bash
CMDMD_BENCH_DIR=<fixtures> swift test -c release -Xswiftc -enable-testing --filter RenderBenchmarkTests
CMDMD_HOSTED_BENCH=1 CMDMD_BENCH_DIR=<fixtures> swift test -c release -Xswiftc -enable-testing \
    --filter HostedTypingBenchmarkTests     # typing / tab switch / first paint, patches, WebContent CPU
CMDMD_HOSTED_BENCH=1 CMDMD_BENCH_DIR=<fixtures> swift test -c release -Xswiftc -enable-testing \
    --filter EditorTypingBenchmarkTests     # editor alone, CMDMD_BENCH_IME=1 for Hangul
```

`RenderBenchmarkTests` also writes every fixture's page per theme with
`CMDMD_BENCH_OUT=<dir>`; `RenderEquivalenceDumpTests` (`CMDMD_EQ_DIRS`, `CMDMD_EQ_OUT`)
dumps byte-exact output for proving a refactor changes nothing.

---

## 11. Vault-scale paths: Omnisearch, content search, the note index

**Symptom** (measured on two real vaults: 20k notes, 2.9k images, 188 MB of Markdown).
Each Omnisearch keystroke blocked the main thread 80–110 ms. A content search for a
word in few notes read the whole vault for 12 s (Korean 19 s); the sidebar's folder
search took 3.3 s for 500 hits. The note index walk, run at launch and on every switch
back to CmdMD, cost 1.1–1.4 s of CPU.

**Root causes.**
- `String.range(of:options:)` calls NSString's method through a bridge that reads a
  native String a character at a time. On an `NSString` read straight from the file the
  same call (same case-insensitive, canonical-equivalence rules) is ~7× faster.
- Omnisearch lowercased every title and path per keystroke and matched `Character`s,
  normalizing decomposed Korean names on every compare, then sorted every match.
- The index walk standardized every file URL (a stat each), hashed every path into a
  `Set` (Korean names are normalized before hashing) and compared prefixes canonically.

**Fix.**
- `OmnisearchView.fileHits` scores the notes' precomputed keys (`VaultNote.searchKey`:
  NFC, lowercased UTF-8) scalar by scalar with `memmem` and keeps a bounded top 10.
  A query scalar's whole UTF-8 sequence can only match at a scalar boundary (a lead byte
  never occurs inside another scalar), so the points are the Character version's. 1–8 ms.
- `AppState.performSearch` checks files in batches (32, doubling to 512) in a task
  group with `NSString`, then reads the matches for lines in walk order: the same hits in
  the same order. 0.43 s for the miss, 0.17 / 0.94 s for 500 hits.
- `NoteIndexService.buildIndexes` hashes paths only when one root holds another and
  compares prefixes by bytes first. 0.5 s.

**The URL spelling trap** (caught by the equivalence tests). A walk hands back names
*as stored*: often composed (NFC — Obsidian and most tools write that), and under
`/private` for roots in /tmp or /var. `standardizedFileURL` respells the name decomposed
and drops `/private`, and `URL ==` compares bytes, so the index must keep producing
exactly that spelling: it rebuilds it from `NSString.getFileSystemRepresentation` with
`CFURLCreateFromFileSystemRepresentation` (equal for all 32,720 files of the vaults and
Downloads). `URL(fileURLWithPath:)` is *not* equivalent: it leaves `;` bare where the
walk writes `%3B`. Tests that need the as-stored spelling must create the file with
POSIX `open` (Foundation stores names decomposed) and live outside `/var/folders`
(`NoteIndexEquivalenceUserFolderTests`, `UnicodeTabIdentityTests` use ~/Library/Caches).

The same two spellings opened one note in two tabs (sidebar vs Omnisearch file hit or
wiki link). Tab lookups go through `AppState.isSameDocumentURL`, which also compares
paths with String `==` (canonical).

### Measuring

```bash
CMDMD_VAULT_BENCH_ROOTS="/path/vault1:/path/vault2" swift test -c release \
    -Xswiftc -enable-testing --filter VaultIndexBenchmarkTests
```

Times each path and checks it against the replaced implementations kept in the tests
(`referenceFileHits`, `referenceSearch`, `referenceIndexes`) on the real vaults. A vault
being written to while it runs can make the index comparison differ.

---

## Release flow

`scripts/package_app.sh` builds a universal (arm64 + x86_64) release, bundles
`dist/CmdMD.app` (+ the SwiftPM resource bundles, `AppIcon.icns` and the brand book
glyph), ad-hoc signs, and zips. It needs full Xcode, not just the Command Line Tools:
more than one `--arch` switches SwiftPM to the Xcode build system, whose generated
`Bundle.module` accessors look in `Contents/Resources`. The native build system's
accessor never does (it tries the `.app` root and a baked `.build` path), which crashed
1.4.6–1.4.8 on the first highlighted code block anywhere but `/Applications`, so the
script refuses any slice that carries it.

The version lives only in `VERSION` (`CFBundleShortVersionString` and
`CFBundleVersion`); `package_app.sh` writes both into `Info.plist`. Bump both before
tagging. `swift run` / `swift build` binaries have no Info.plist: About reads
"Version dev" and they skip the update check. Before tagging, run
`bash scripts/smoke_test_app.sh` (and once with `--without-highlightr-bundle`): it
launches a renamed copy of `dist/CmdMD.app` outside `/Applications` with an isolated
`CMDMD_DATA_DIR`, opens a note with a code fence in Split view, and fails on an early
exit, a new crash report, or no "Code highlighting ready" in the log. Pushing a
`vX.Y.Z` tag triggers `release.yml` on a macOS runner, which:

1. fails unless the tag matches `CFBundleShortVersionString` in `VERSION` and
   `CFBundleVersion` is greater than the previous release tag's;
2. runs `swift test` — `ci.yml` runs in parallel on the same commit and cannot block
   the release, so the release gates itself;
3. runs `scripts/test_package_app.sh` (package + universal / per-slice Highlightr
   accessor / version / document-type / codesign checks);
4. builds the DMG with `scripts/make_dmg.sh` (ad-hoc), or `scripts/sign_and_notarize.sh`
   once the Developer ID secrets exist (see `RELEASE_SIGNING.md`);
5. publishes `CmdMD-macos.zip`, `CmdMD-<version>.dmg` and `SHA256SUMS.txt`.

`ci.yml` also runs `scripts/test_package_app.sh` on every push / PR, so packaging
breakage shows up before a tag, not after.

**Dependencies are locked.** `Package.resolved` is committed, and `ci.yml` /
`release.yml` resolve with `--force-resolved-versions`: every build uses the pinned
versions, and a stale lockfile fails instead of silently re-resolving. Bump on
purpose — `swift package update`, then `scripts/test_package_app.sh`, then
`scripts/smoke_test_app.sh` (packaging depends on Highlightr's generated
resource-bundle lookup; see `FIX_FOR_CLAUDE_CODE.md`).

## Dev isolation — `CMDMD_DATA_DIR`

A plain `swift run` shares `~/Library/Application Support/CmdMD/` (settings, session,
drafts, logs…) with the installed app. Point a dev instance at its own directory:

```bash
CMDMD_DATA_DIR="$HOME/Library/Application Support/CmdMD-dev" swift run
```

`AppState` keeps every data JSON there and `LogService` writes to its `logs/`
subfolder, so the dev build never touches the installed app's data.
