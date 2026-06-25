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
CmdMD isn't sandboxed (it already loads Mermaid/KaTeX over the network), so
`URLSession` works without extra entitlements.

---

## 9. Library / CDN gotchas

- **Mermaid:** use the UMD `dist/mermaid.min.js` (sets `window.mermaid`), **not**
  the ESM build — `import` misbehaves under WKWebView's `file://` base URL.
- **KaTeX:** `@0.16` + `mhchem` + delimiters for `\[ \]` and `\( \)` (masked in
  `maskMathRegions`). Tests assert the substrings `highlight.min.js` / `katex` /
  `class="mermaid"`.
- **CI:** the pinned `swift-actions/setup-swift@5.9` **crashes `swift-frontend`**
  building Yams' module interface. `ci.yml`/`release.yml` use the macOS runner's
  native toolchain instead — do not re-pin 5.9.

---

## Release flow

`scripts/package_app.sh` builds release, bundles `dist/CmdMD.app` (+ `AppIcon.icns`
and the brand book glyph), ad-hoc signs, and zips. Pushing a `vX.Y.Z` tag triggers
`release.yml`, which runs `scripts/test_package_app.sh` on a macОS runner and
publishes `CmdMD-macos.zip`. Bump the two version strings in `package_app.sh`.
