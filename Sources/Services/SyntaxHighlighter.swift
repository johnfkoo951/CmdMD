import Foundation
import AppKit
import Highlightr

class SyntaxHighlighter {
    /// Highlightr boots a JavaScript engine on init — expensive. One shared
    /// instance serves every editor; the active theme is tracked so repeated
    /// highlight passes don't re-load the theme JSON.
    private static let sharedHighlightr: Highlightr? = SyntaxHighlighter.makeHighlightr()
    private static var activeHighlightrTheme: String = ""

    /// `Highlightr()` reaches for its SwiftPM resource bundle
    /// (`Highlightr_Highlightr.bundle` — highlight.js + CSS themes) through the
    /// synthesized `Bundle.module` accessor, which **traps** (not throws) when the
    /// bundle is at none of the paths it tries. That is what crashed 1.4.6–1.4.8.
    /// Probe exactly those paths first so a mis-packaged build degrades to "no code
    /// highlighting" instead of taking the whole app down on first render.
    private static func makeHighlightr() -> Highlightr? {
        let candidates = highlightrBundleCandidates(resourceURL: Bundle.main.resourceURL,
                                                    bundleURL: Bundle.main.bundleURL)
        guard let bundleURL = resolvedHighlightrBundle(among: candidates) else {
            Log.error("Code highlighting disabled: Highlightr resource bundle not found "
                + "(re-package with scripts/package_app.sh)",
                detail: candidates.map(\.path).joined(separator: ", "))
            return nil
        }
        guard let highlightr = Highlightr() else {
            Log.error("Code highlighting disabled: Highlightr failed to load", detail: bundleURL.path)
            return nil
        }
        Log.info("Code highlighting ready", .editor, detail: bundleURL.path)
        return highlightr
    }

    /// Where `Bundle.module` looks for the Highlightr bundle, in order. It depends on
    /// the build system that generated the accessor:
    /// - The packaged app: scripts/package_app.sh builds universal (`--arch arm64
    ///   --arch x86_64`), which uses the Xcode build system. Its accessor tries
    ///   `Bundle.main.resourceURL` (Contents/Resources, wherever the .app lives), the
    ///   resources of the image linking Highlightr (the app itself: it is linked
    ///   statically) and then `Bundle.main.bundleURL`.
    /// - `swift build` / `swift run` (native build system): `Bundle.main.bundleURL`,
    ///   which for a bare executable is also its `resourceURL`, then a baked `.build`
    ///   path that can't be reproduced here, so a test runner simply gets no code
    ///   highlighting. This accessor never looks in Contents/Resources, which is why
    ///   package_app.sh refuses to package a slice built that way.
    /// Contents/MacOS is not a candidate of either accessor.
    static func highlightrBundleCandidates(resourceURL: URL?, bundleURL: URL) -> [URL] {
        var candidates: [URL] = []
        for root in [resourceURL, bundleURL].compactMap({ $0 }) {
            let url = root.appendingPathComponent("Highlightr_Highlightr.bundle")
            if !candidates.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                candidates.append(url)
            }
        }
        return candidates
    }

    /// The first candidate the accessor would accept: it, too, takes the first
    /// path that `Bundle` can open.
    static func resolvedHighlightrBundle(among candidates: [URL]) -> URL? {
        candidates.first { Bundle(url: $0) != nil }
    }

    /// Documents past this size (UTF-16 units) skip token highlighting and get
    /// base attributes only, keeping typing latency flat on huge files.
    static let highlightSizeLimit = 300_000

    // Outside fenced blocks no pattern crosses a "\n" (`[ \t]`, never `\s`, and
    // newline-free classes), so each line restyles on its own — which is what
    // lets a typing pause restyle only the edited lines.
    private let headingPattern = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+(.+)$", options: .anchorsMatchLines)
    private let boldPattern = try! NSRegularExpression(pattern: "(\\*\\*|__)(.*?)\\1", options: [])
    private let italicPattern = try! NSRegularExpression(pattern: "(\\*|_)(.*?)\\1", options: [])
    private let codeInlinePattern = try! NSRegularExpression(pattern: "`([^`\\n]+)`", options: [])
    private let linkPattern = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\n]+)\\)", options: [])
    private let wikiLinkPattern = try! NSRegularExpression(pattern: "\\[\\[([^\\]|\\n]+)(\\|([^\\]\\n]+))?\\]\\]", options: [])
    private let tagPattern = try! NSRegularExpression(pattern: "(?<![\\w#])#(" + MarkdownDocument.tagNamePattern + ")", options: [])
    private let blockquotePattern = try! NSRegularExpression(pattern: "^>[ \\t]*(.*)$", options: .anchorsMatchLines)
    private let listPattern = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]|\\d+\\.)(?:[ \\t]+|$)", options: .anchorsMatchLines)
    /// A ``` or ~~~ fence line (indented, or inside `>` quotes) through the
    /// next line closing it with the same run. Line-anchored, so a closing
    /// fence can't pair with the following block's opener. Groups: 1 indent and
    /// quote markers, 2 the run, 3 the info word (`c++`, `objective-c`, `js` of
    /// `js title=…`), 4 the code. A CRLF line's `\r` falls in `[^`\n]` / before `$`.
    private let codeBlockPattern = try! NSRegularExpression(
        pattern: "^([ \\t]*+(?:>[ \\t]*+)*+)(`{3,}|~{3,})[ \\t]*+([^\\s`]*+)[^`\\n]*+\\n([\\s\\S]*?)^[ \\t]*+(?:>[ \\t]*+)*+\\2[ \\t]*$",
        options: .anchorsMatchLines
    )
    private let hrPattern = try! NSRegularExpression(pattern: "^([-*_]){3,}[ \\t]*$", options: .anchorsMatchLines)
    private let calloutPattern = try! NSRegularExpression(pattern: "^>[ \\t]*\\[!([\\w-]+)\\]([+-])?[ \\t]*(.*)$", options: .anchorsMatchLines)
    private let markHighlightPattern = try! NSRegularExpression(pattern: "==([^=\\n]+)==", options: [])

    /// Matching inside a region must behave as over the whole text: `^` only
    /// at real line starts, lookbehinds seeing the character before.
    private static let regionOptions: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]

    /// The stretch of text one pass restyles, and the code in it that
    /// Markdown styling must leave alone.
    private struct Scope {
        let text: String
        let range: NSRange
        /// Fenced blocks overlapping `range`; each lies wholly inside it.
        let fences: [NSTextCheckingResult]
        /// Fences plus inline code spans: no headings, emphasis, links or tags.
        var code = IndexSet()
        /// Fences outside blockquotes: a `>` line in one is code, not a quote.
        var unquotedFences = IndexSet()

        init(text: String, range: NSRange, allFences: [NSTextCheckingResult]) {
            self.text = text
            self.range = range
            fences = allFences.filter { $0.range.location < NSMaxRange(range) && NSMaxRange($0.range) > range.location }
            for fence in fences {
                guard let indexes = Range(fence.range) else { continue }
                code.insert(integersIn: indexes)
                if !SyntaxHighlighter.isQuoted(fence, in: text as NSString) {
                    unquotedFences.insert(integersIn: indexes)
                }
            }
        }
    }

    /// What the previous pass left behind, so the next typing pause can
    /// restyle just around the edits made since. Any mismatch: full pass.
    private struct PassState {
        weak var string: NSMutableAttributedString?
        let length: Int
        let fences: [NSRange]
        let fontName: String
        let pointSize: CGFloat
        let theme: EditorTheme
        let tabSize: Int
    }
    private var lastPass: PassState?

    /// Languages the bundled highlight.js has grammars for (canonical names).
    private static let highlightrLanguages = Set(sharedHighlightr?.supportedLanguages() ?? [])

    /// Fence words highlight.js knows only by an alias (its language list has
    /// canonical names only), plus `objective-c` and Obsidian's `dataviewjs`.
    private static let highlightrAliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "dataviewjs": "javascript",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "py": "python", "ipython": "python", "pycon": "python-repl", "rb": "ruby", "pl": "perl", "pm": "perl",
        "sh": "bash", "zsh": "bash", "console": "shell", "shellsession": "shell",
        "ps": "powershell", "ps1": "powershell", "pwsh": "powershell", "bat": "dos", "cmd": "dos",
        "c++": "cpp", "cc": "cpp", "cxx": "cpp", "h++": "cpp", "hh": "cpp", "hpp": "cpp", "hxx": "cpp", "h": "c",
        "c#": "csharp", "cs": "csharp", "f#": "fsharp", "fs": "fsharp",
        "objc": "objectivec", "obj-c": "objectivec", "objective-c": "objectivec",
        "obj-c++": "objectivec", "objective-c++": "objectivec", "mm": "objectivec",
        "rs": "rust", "kt": "kotlin", "kts": "kotlin", "golang": "go", "hs": "haskell",
        "ex": "elixir", "exs": "elixir", "erl": "erlang", "clj": "clojure", "edn": "clojure", "coffee": "coffeescript",
        "html": "xml", "xhtml": "xml", "svg": "xml", "plist": "xml",
        "md": "markdown", "mkd": "markdown", "mkdown": "markdown", "tex": "latex",
        "yml": "yaml", "toml": "ini", "jsonc": "json", "gql": "graphql", "proto": "protobuf",
        "postgres": "pgsql", "postgresql": "pgsql", "vb": "vbnet", "vbs": "vbscript",
        "docker": "dockerfile", "mk": "makefile", "mak": "makefile", "make": "makefile", "patch": "diff",
        "txt": "plaintext", "text": "plaintext"
    ]

    /// The highlight.js language for a fence's info word, or nil when there is
    /// no grammar for it (mermaid, dataview, ad-note…). Highlightr answers an
    /// unknown name with auto-detection over every grammar: tens to hundreds of
    /// ms per block on each pass, and diagrams colored as random code.
    static func highlightrLanguage(for word: String, supported: Set<String>) -> String? {
        let name = word.lowercased()
        let canonical = highlightrAliases[name] ?? name
        return supported.contains(canonical) ? canonical : nil
    }

    /// Whether a fence sits inside a blockquote or callout (`> ```…`).
    private static func isQuoted(_ fence: NSTextCheckingResult, in text: NSString) -> Bool {
        text.range(of: ">", options: .literal, range: fence.range(at: 1)).location != NSNotFound
    }

    /// Whether a match opens or closes inside code: `__init__` in a code span
    /// or `#include` in a fence is not markup.
    private static func touchesCode(_ range: NSRange, _ code: IndexSet) -> Bool {
        code.contains(range.location) || code.contains(NSMaxRange(range) - 1)
    }

    private func highlightr(for theme: EditorTheme) -> Highlightr? {
        guard let highlightr = Self.sharedHighlightr else { return nil }
        let name = theme.highlightrThemeName
        if Self.activeHighlightrTheme != name {
            highlightr.setTheme(to: name)
            Self.activeHighlightrTheme = name
        }
        return highlightr
    }

    /// Builds a fresh highlighted string. Used for one-shot rendering.
    func highlight(markdown: String, font: NSFont, theme: EditorTheme, tabSize: Int = 4) -> NSAttributedString {
        let string = NSMutableAttributedString(string: markdown)
        applyHighlights(to: string, font: font, theme: theme, tabSize: tabSize)
        return string
    }

    /// Applies highlighting attributes IN PLACE on the storage. Because no
    /// characters change, the text view's undo stack, selection, and scroll
    /// position all survive — unlike setAttributedString, which rebuilt the
    /// storage on every debounce tick.
    func applyHighlights(to string: NSMutableAttributedString, font: NSFont, theme: EditorTheme, tabSize: Int = 4) {
        let fullRange = NSRange(location: 0, length: string.length)

        guard string.length <= Self.highlightSizeLimit else {
            lastPass = nil
            string.beginEditing()
            string.setAttributes(baseAttributes(font: font, theme: theme, tabSize: tabSize), range: fullRange)
            string.endEditing()
            return
        }

        let text = string.string
        let fences = codeBlockPattern.matches(in: text, range: fullRange)
        restyle(string, text: text, region: fullRange, fences: fences, font: font, theme: theme, tabSize: tabSize)
    }

    /// Typing-pause pass: restyles only the lines `editedRange` touches (the
    /// union of storage edits since the previous pass, in current
    /// coordinates) and any fenced block overlapping them, instead of
    /// resetting and re-scanning the whole document — a full pass invalidates
    /// layout for every line. Falls back to the full pass when there is no
    /// previous pass on this string with this font and theme, or when the
    /// edit changed which text is fenced elsewhere.
    func applyHighlights(to string: NSMutableAttributedString, font: NSFont, theme: EditorTheme, tabSize: Int = 4, editedRange: NSRange) {
        let length = string.length
        guard let last = lastPass, last.string === string, last.fontName == font.fontName,
              last.pointSize == font.pointSize, last.theme == theme, last.tabSize == tabSize,
              length <= Self.highlightSizeLimit else {
            applyHighlights(to: string, font: font, theme: theme, tabSize: tabSize)
            return
        }

        let text = string.string
        let fences = codeBlockPattern.matches(in: text, range: NSRange(location: 0, length: length))
        guard let region = Self.highlightRegion(
            for: editedRange,
            in: text as NSString,
            fences: fences.map(\.range),
            previousFences: last.fences,
            previousLength: last.length
        ) else {
            restyle(string, text: text, region: NSRange(location: 0, length: length), fences: fences, font: font, theme: theme, tabSize: tabSize)
            return
        }
        restyle(string, text: text, region: region, fences: fences, font: font, theme: theme, tabSize: tabSize)
    }

    /// Folds one storage edit (`edited` in post-edit coordinates, the length
    /// changed by `changeInLength`) into the range still awaiting a pass,
    /// moving that range past the edit first.
    static func union(pending: NSRange?, edited: NSRange, changeInLength delta: Int) -> NSRange {
        guard let pending else { return edited }
        let oldEditEnd = NSMaxRange(edited) - delta
        func moved(_ position: Int) -> Int {
            if position <= edited.location { return position }
            return position >= oldEditEnd ? position + delta : NSMaxRange(edited)
        }
        let start = min(moved(pending.location), edited.location)
        let end = max(moved(NSMaxRange(pending)), NSMaxRange(edited))
        return NSRange(location: start, length: end - start)
    }

    /// The lines to restyle after an edit: `edited` (current coordinates; the
    /// text is `text.length - previousLength` longer than at the previous
    /// pass) widened to whole lines and to every fenced block it overlaps.
    /// nil when a fence the edit didn't cover moved or vanished — e.g. a typed
    /// ``` re-pairs every later fence — so the whole text needs restyling.
    static func highlightRegion(
        for edited: NSRange,
        in text: NSString,
        fences: [NSRange],
        previousFences: [NSRange],
        previousLength: Int
    ) -> NSRange? {
        let delta = text.length - previousLength
        let oldEditEnd = NSMaxRange(edited) - delta
        guard edited.location >= 0, NSMaxRange(edited) <= text.length, oldEditEnd >= edited.location else { return nil }

        // Every earlier fence must still be there, shifted past the edit.
        var expected: [NSRange] = []
        for fence in previousFences {
            if NSMaxRange(fence) <= edited.location {
                expected.append(fence)
            } else if fence.location >= oldEditEnd {
                expected.append(NSRange(location: fence.location + delta, length: fence.length))
            } else if fence.location < edited.location, NSMaxRange(fence) > oldEditEnd {
                expected.append(NSRange(location: fence.location, length: fence.length + delta))
            } else {
                return nil
            }
        }
        guard expected == fences else { return nil }

        var region = lineRange(for: edited, in: text)
        var widened = true
        while widened {
            widened = false
            for fence in fences where fence.location < NSMaxRange(region) && NSMaxRange(fence) > region.location
                && NSUnionRange(region, fence) != region {
                region = lineRange(for: NSUnionRange(region, fence), in: text)
                widened = true
            }
        }
        return region
    }

    /// `range` widened to whole lines, split at "\n" only: a region bounded by
    /// "\n" also holds whole every line `^`/`$` see (they split at \r too).
    private static func lineRange(for range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        if start > 0 {
            let newline = text.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: start))
            start = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        }
        var end = text.length
        let tail = NSMaxRange(range)
        if tail < end {
            let newline = text.range(of: "\n", options: .literal, range: NSRange(location: tail, length: end - tail))
            if newline.location != NSNotFound { end = NSMaxRange(newline) }
        }
        return NSRange(location: start, length: end - start)
    }

    /// The editor's paragraph style. A tab character advances `tabSize`
    /// spaces of `font`: without stops of its own, NSTextView placed tabs at
    /// AppKit's fixed 28 pt stops (about 3 columns, whatever Tab size said)
    /// and wrapped any tab past the twelfth stop onto the next line.
    static func paragraphStyle(font: NSFont, tabSize: Int) -> NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.tabStops = []
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraphStyle.defaultTabInterval = CGFloat(max(1, tabSize)) * spaceWidth
        return paragraphStyle
    }

    private func baseAttributes(font: NSFont, theme: EditorTheme, tabSize: Int) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor(theme.textColor),
            .paragraphStyle: Self.paragraphStyle(font: font, tabSize: tabSize)
        ]
    }

    /// Resets `region` (whole lines, whole fences) to base attributes and
    /// runs every pass over it. `fences` covers the whole text.
    private func restyle(
        _ string: NSMutableAttributedString,
        text: String,
        region: NSRange,
        fences: [NSTextCheckingResult],
        font: NSFont,
        theme: EditorTheme,
        tabSize: Int
    ) {
        string.beginEditing()
        defer { string.endEditing() }

        string.setAttributes(baseAttributes(font: font, theme: theme, tabSize: tabSize), range: region)

        var scope = Scope(text: text, range: region, allFences: fences)
        highlightHeadings(in: string, scope: scope, font: font, theme: theme)
        highlightCodeBlocks(in: string, scope: scope, font: font, theme: theme)
        highlightInlineCode(in: string, scope: &scope, font: font, theme: theme)
        highlightBold(in: string, scope: scope, font: font, theme: theme)
        highlightItalic(in: string, scope: scope, font: font, theme: theme)
        highlightMarks(in: string, scope: scope, theme: theme)
        highlightLinks(in: string, scope: scope, theme: theme)
        highlightWikiLinks(in: string, scope: scope, theme: theme)
        highlightTags(in: string, scope: scope, theme: theme)
        highlightBlockquotes(in: string, scope: scope, theme: theme)
        // After blockquotes: a callout title is a quote line whose color wins.
        highlightCallouts(in: string, scope: scope, font: font, theme: theme)
        highlightLists(in: string, scope: scope, theme: theme)
        highlightHorizontalRules(in: string, scope: scope, theme: theme)

        lastPass = PassState(
            string: string,
            length: string.length,
            fences: fences.map(\.range),
            fontName: font.fontName,
            pointSize: font.pointSize,
            theme: theme,
            tabSize: tabSize
        )
    }

    private func highlightHeadings(in string: NSMutableAttributedString, scope: Scope, font: NSFont, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        headingPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !scope.code.contains(match.range.location) else { return }

            let hashRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            let level = hashRange.length

            // Design sizes at the 14 pt default body font, scaled with the
            // actual font so zoom (and larger body sizes) enlarge headings too.
            let headingSizes: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 18, 5: 16, 6: 14]
            let fontSize = (headingSizes[level] ?? 14) * font.pointSize / 14
            let headingFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)

            string.addAttributes([
                .foregroundColor: NSColor(theme.commentColor),
                .font: font
            ], range: hashRange)

            string.addAttributes([
                .font: headingFont,
                .foregroundColor: NSColor(theme.headingColor)
            ], range: contentRange)
        }
    }

    private func highlightBold(in string: NSMutableAttributedString, scope: Scope, font: NSFont, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        // Bold variant of the *editor* font — swapping to proportional SF Pro
        // here made **bold** spans reflow against the surrounding monospace.
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

        boldPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !Self.touchesCode(match.range, scope.code) else { return }
            string.addAttribute(.font, value: boldFont, range: match.range)
        }
    }

    private func highlightItalic(in string: NSMutableAttributedString, scope: Scope, font: NSFont, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        italicPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !Self.touchesCode(match.range, scope.code) else { return }

            let matchText = (text as NSString).substring(with: match.range)
            let isBoldMarker = matchText.hasPrefix("**") || matchText.hasPrefix("__")
            if isBoldMarker { return }

            let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            string.addAttribute(.font, value: italicFont, range: match.range)
        }
    }

    private func highlightInlineCode(in string: NSMutableAttributedString, scope: inout Scope, font: NSFont, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range
        let fences = scope.code
        var spans = IndexSet()

        codeInlinePattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !fences.contains(match.range.location) else { return }

            let monoFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            string.addAttributes([
                .font: monoFont,
                .foregroundColor: NSColor(theme.stringColor),
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.5)
            ], range: match.range)
            if let indexes = Range(match.range) { spans.insert(integersIn: indexes) }
        }
        scope.code.formUnion(spans)
    }

    private func highlightCodeBlocks(in string: NSMutableAttributedString, scope: Scope, font: NSFont, theme: EditorTheme) {
        let text = scope.text

        for match in scope.fences {
            let monoFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            let langRange = match.range(at: 3)
            let codeRange = match.range(at: 4)

            string.addAttributes([
                .font: monoFont,
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.3)
            ], range: match.range)

            // A quoted fence's lines take the quote colors, which would paint
            // over token colors anyway.
            let hasLanguage = langRange.length > 0 && !Self.isQuoted(match, in: text as NSString)
            if hasLanguage, let highlightr = highlightr(for: theme),
               let lang = Self.highlightrLanguage(
                   for: (text as NSString).substring(with: langRange),
                   supported: Self.highlightrLanguages
               ) {
                let code = (text as NSString).substring(with: codeRange)

                if let highlighted = highlightr.highlight(code, as: lang) {
                    highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attrs, attrRange, _ in
                        let targetRange = NSRange(location: codeRange.location + attrRange.location, length: attrRange.length)
                        let isValidRange = targetRange.location + targetRange.length <= string.length
                        if isValidRange {
                            for (key, value) in attrs where key != .font {
                                string.addAttribute(key, value: value, range: targetRange)
                            }
                        }
                    }
                }
            }
        }
    }

    private func highlightMarks(in string: NSMutableAttributedString, scope: Scope, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        markHighlightPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !Self.touchesCode(match.range, scope.code) else { return }
            string.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(theme.isDark ? 0.25 : 0.35),
                range: match.range
            )
        }
    }

    private func highlightLinks(in string: NSMutableAttributedString, scope: Scope, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        linkPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !Self.touchesCode(match.range, scope.code) else { return }

            let linkTextRange = match.range(at: 1)
            let linkUrlRange = match.range(at: 2)

            string.addAttributes([
                .foregroundColor: NSColor(theme.linkColor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: linkTextRange)

            string.addAttribute(.foregroundColor, value: NSColor(theme.commentColor), range: linkUrlRange)
        }
    }

    private func highlightWikiLinks(in string: NSMutableAttributedString, scope: Scope, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        wikiLinkPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !Self.touchesCode(match.range, scope.code) else { return }

            string.addAttributes([
                .foregroundColor: NSColor(theme.keywordColor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }

    private func highlightTags(in string: NSMutableAttributedString, scope: Scope, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        tagPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !Self.touchesCode(match.range, scope.code) else { return }

            string.addAttributes([
                .foregroundColor: NSColor(theme.linkColor),
                .backgroundColor: NSColor(theme.linkColor).withAlphaComponent(0.15)
            ], range: match.range)
        }
    }

    private func highlightBlockquotes(in string: NSMutableAttributedString, scope: Scope, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        blockquotePattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !scope.unquotedFences.contains(match.range.location) else { return }

            string.addAttributes([
                .foregroundColor: NSColor(theme.commentColor),
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.2)
            ], range: match.range)
        }
    }

    private func highlightLists(in string: NSMutableAttributedString, scope: Scope, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        listPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !scope.code.contains(match.range.location) else { return }

            let markerRange = match.range(at: 2)
            string.addAttribute(.foregroundColor, value: NSColor(theme.keywordColor), range: markerRange)
        }
    }

    private func highlightHorizontalRules(in string: NSMutableAttributedString, scope: Scope, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        hrPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !scope.code.contains(match.range.location) else { return }

            string.addAttribute(.foregroundColor, value: NSColor(theme.commentColor), range: match.range)
        }
    }

    private func highlightCallouts(in string: NSMutableAttributedString, scope: Scope, font: NSFont, theme: EditorTheme) {
        let text = scope.text
        let range = scope.range

        calloutPattern.enumerateMatches(in: text, options: Self.regionOptions, range: range) { match, _, _ in
            guard let match = match, !scope.code.contains(match.range.location) else { return }

            let typeRange = match.range(at: 1)
            let calloutType = (text as NSString).substring(with: typeRange).lowercased()

            let color = calloutColor(for: calloutType)

            string.addAttributes([
                .foregroundColor: color,
                .backgroundColor: color.withAlphaComponent(0.1)
            ], range: match.range)

            let calloutTypeFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            string.addAttribute(.font, value: calloutTypeFont, range: typeRange)
        }
    }

    private func calloutColor(for type: String) -> NSColor {
        switch type {
        case "note": return .systemBlue
        case "abstract", "summary", "tldr": return .systemCyan
        case "info": return .systemTeal
        case "todo": return .systemMint
        case "tip", "hint", "important": return .systemYellow
        case "success", "check", "done": return .systemGreen
        case "question", "help", "faq": return .systemYellow
        case "warning", "caution", "attention": return .systemOrange
        case "failure", "fail", "missing": return .systemRed
        case "danger", "error": return .systemRed
        case "bug": return .systemPink
        case "example": return .systemPurple
        case "quote", "cite": return .systemGray
        default: return .systemGray
        }
    }
}
