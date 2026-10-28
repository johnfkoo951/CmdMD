import Foundation
import Markdown

// MARK: - Shared rendering helpers

/// Slugifies heading text into an anchor id. Unicode-aware so non-ASCII headings
/// (e.g. Korean) produce a real id instead of an empty one. Shared by the
/// renderer (id emission) and the TOC so the ids always match.
func markdownHeadingSlug(_ text: String) -> String {
    var slug = ""
    for character in text.lowercased() {
        if character.isLetter || character.isNumber {
            slug.append(character)
        } else if character == " " || character == "-" || character == "_" {
            slug.append("-")
        }
    }
    while slug.contains("--") {
        slug = slug.replacingOccurrences(of: "--", with: "-")
    }
    return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

/// A parsed heading's visible text, which its anchor is slugged from: text
/// and code, not markup. `plainText` kept the raw HTML a wiki link, `#tag` or
/// `==mark==` becomes (`<a href=…>`), so the id matched no TOC slug.
func headingVisibleText(_ markup: Markup) -> String {
    switch markup {
    case let text as Text: return stripFlankingJoiners(text.string)
    case let code as InlineCode: return code.code
    case is SoftBreak, is LineBreak: return " "
    case is InlineHTML: return ""
    default: return markup.children.map(headingVisibleText).joined()
    }
}

/// Deduplicates heading slugs the way GitHub does ("intro", "intro-1", …).
/// Renderer and TOC each run their own slugger over the same document in the
/// same order, so duplicate headings resolve to matching anchors on both sides.
struct HeadingSlugger {
    private var counts: [String: Int] = [:]
    /// Ids this slugger must never hand out (another sequence owns them).
    var reserved: Set<String> = []

    mutating func slug(for text: String) -> String {
        let base = markdownHeadingSlug(text)
        while true {
            let n = counts[base, default: 0]
            counts[base] = n + 1
            let slug = n == 0 ? base : "\(base)-\(n)"
            if reserved.isEmpty || !reserved.contains(slug) { return slug }
        }
    }
}

/// Substring test over UTF-8 bytes (memmem). Foundation's `contains` /
/// `range(of:)` bridge a native String to UTF-16 first: ~5 ms per call on a
/// 500 KB note (measured), and a render made five such probes that mostly
/// found nothing.
func utf8Contains(_ haystack: String, _ needle: String) -> Bool {
    var haystack = haystack
    var needle = needle
    return haystack.withUTF8 { h in
        needle.withUTF8 { n in
            guard let hb = h.baseAddress, let nb = n.baseAddress, n.count <= h.count else { return n.isEmpty }
            return memmem(hb, h.count, nb, n.count) != nil
        }
    }
}

extension String {
    /// The `String.Index` range of a UTF-16 `NSRange` that a regex over this
    /// string produced. Regex ranges sit on scalar boundaries, where slicing
    /// gives exactly `NSString.substring(with:)`'s text, but as a Substring
    /// of the same storage: appending it copies bytes, where `substring(with:)`
    /// made an NSString that `+=` transcoded back (~50x slower per piece).
    @inline(__always)
    func indexRange(_ range: NSRange) -> Range<String.Index> {
        Range(range, in: self)!
    }

    /// `self[range]` for a regex's UTF-16 range, as a String.
    @inline(__always)
    func slice(_ range: NSRange) -> String {
        String(self[indexRange(range)])
    }

    /// The UTF-8 offset of `index`: O(1), a native String indexes by it.
    @inline(__always)
    func utf8Offset(_ index: String.Index) -> Int {
        utf8.distance(from: startIndex, to: index)
    }

    /// This text as a native UTF-8 String. The editor's text is
    /// `NSTextView.string`, NSString-backed (UTF-16): every byte probe, slice,
    /// regex bridge and cmark's UTF-8 feed paid for that on each pass. One
    /// CFStringGetBytes transcode up front instead (1.6 ms for 500 KB of
    /// Korean; `makeContiguousUTF8` takes 8x that); O(1) when already native.
    func nativeUTF8() -> String {
        if utf8.withContiguousStorageIfAvailable({ _ in true }) == true { return self }
        let cf = self as NSString as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cf))
        let encoding = CFStringBuiltInEncodings.UTF8.rawValue
        var needed: CFIndex = 0
        let converted = CFStringGetBytes(cf, range, encoding, 0, false, nil, 0, &needed)
        // A lone surrogate stops the conversion: Swift's transcoding repairs
        // it, as every `+=` of the NSString text did.
        guard converted == range.length else {
            var copy = self
            copy.makeContiguousUTF8()
            return copy
        }
        return String(unsafeUninitializedCapacity: needed) { buffer in
            var written: CFIndex = 0
            CFStringGetBytes(cf, range, encoding, 0, false, buffer.baseAddress, needed, &written)
            return written
        }
    }
}

/// UTF-8 offsets into a text (the visitor's block boundaries), carried
/// through the passes that rebuild it front to back — copying stretches,
/// swapping matched spans — so they index each pass's result. An offset
/// inside a swapped span moves to the end of its replacement.
struct OffsetTracker {
    private(set) var offsets: [Int]
    private var next = 0

    /// `offsets` ascending.
    init(_ offsets: [Int]) {
        self.offsets = offsets
    }

    /// The pass copied its source verbatim up to `source`; its result is
    /// `rebuilt` bytes long there.
    mutating func copied(upTo source: Int, rebuilt: Int) {
        while next < offsets.count, offsets[next] <= source {
            offsets[next] += rebuilt - source
            next += 1
        }
    }

    /// The pass swapped its source up to `source` for text ending its
    /// result at `rebuilt`.
    mutating func swapped(upTo source: Int, rebuilt: Int) {
        while next < offsets.count, offsets[next] < source {
            offsets[next] = rebuilt
            next += 1
        }
    }

    /// The pass copied the rest of its `source`-byte text; the next pass
    /// starts over.
    mutating func finished(source: Int, rebuilt: Int) {
        copied(upTo: source, rebuilt: rebuilt)
        next = 0
    }
}

// MARK: - CJK-friendly emphasis

/// U+2060 WORD JOINER: to cmark neither whitespace nor punctuation, and no
/// line-break opportunity on the page.
let flankingJoiner: Unicode.Scalar = "\u{2060}"

func stripFlankingJoiners(_ text: String) -> String {
    guard utf8Contains(text, "\u{2060}") else { return text }
    return text.replacingOccurrences(of: "\u{2060}", with: "")
}

/// CommonMark won't let `**` close after punctuation when a letter follows
/// (`**AI(인공지능)**은`), nor open after a letter when punctuation follows
/// (`한국어**"인용"**`) — Korean particles attach straight to the word, so these
/// showed literal asterisks, where Obsidian's reading view bolds them (the
/// `remark-cjk-friendly` rule). A word joiner between the punctuation and the
/// `*` run, only where the other side is CJK, makes the run flanking; the
/// visitor drops the joiners again. Runs on code-masked text.
private let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)

func cjkFriendlyEmphasis(_ markdown: String) -> String {
    guard utf8Contains(markdown, "*") else { return markdown }
    func isPunctuation(_ c: Unicode.Scalar) -> Bool {
        if c.isASCII { return asciiPunctuation.contains(c) }
        // The code-mask sentinel stands in for a code span's backtick.
        if c == "\u{E000}" { return true }
        switch c.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }
    func isCJK(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF, 0xF900...0xFAFF, 0x20000...0x2FFFF: return true
        default: return false
        }
    }
    let scalars = markdown.unicodeScalars
    var out = String.UnicodeScalarView()
    var copied = scalars.startIndex
    var previous: Unicode.Scalar?
    var index = scalars.startIndex
    while index < scalars.endIndex {
        let c = scalars[index]
        guard c == "*" else { previous = c; index = scalars.index(after: index); continue }
        var end = index
        while end < scalars.endIndex, scalars[end] == "*" { end = scalars.index(after: end) }
        let next = end < scalars.endIndex ? scalars[end] : nil
        if let p = previous, let n = next, p != "\\" {
            if isPunctuation(p), isCJK(n) {
                out.append(contentsOf: scalars[copied..<index]); out.append(flankingJoiner); copied = index
            } else if isCJK(p), isPunctuation(n) {
                out.append(contentsOf: scalars[copied..<end]); out.append(flankingJoiner); copied = end
            }
        }
        previous = "*"
        index = end
    }
    guard copied != scalars.startIndex else { return markdown }
    out.append(contentsOf: scalars[copied...])
    return String(out)
}

/// HTML-escapes document-derived text before it is interpolated into the preview
/// HTML. Prevents stored-XSS via crafted Markdown in the JS-enabled WebView.
func htmlEscape(_ string: String) -> String {
    // One UTF-8 pass (five replacingOccurrences passes before, each bridging
    // and copying), and none at all for the common run with nothing to escape.
    let utf8 = string.utf8
    guard utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 || $0 == 0x27 }) else {
        return string
    }
    var out: [UInt8] = []
    out.reserveCapacity(utf8.count + utf8.count / 8)
    for byte in utf8 {
        switch byte {
        case 0x26: out.append(contentsOf: [0x26, 0x61, 0x6D, 0x70, 0x3B])        // &amp;
        case 0x3C: out.append(contentsOf: [0x26, 0x6C, 0x74, 0x3B])              // &lt;
        case 0x3E: out.append(contentsOf: [0x26, 0x67, 0x74, 0x3B])              // &gt;
        case 0x22: out.append(contentsOf: [0x26, 0x71, 0x75, 0x6F, 0x74, 0x3B])  // &quot;
        case 0x27: out.append(contentsOf: [0x26, 0x23, 0x33, 0x39, 0x3B])        // &#39;
        default: out.append(byte)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Escapes a URL for an href/src attribute and neutralizes script-bearing
/// schemes (javascript:, vbscript:, data: other than images).
func sanitizeURL(_ url: String) -> String {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if isScriptBearingURL(trimmed) {
        return "#"
    }
    return htmlEscape(trimmed)
}

/// True for URLs that run script when followed (javascript:, vbscript:) or
/// can carry a document (data: other than data:image/).
func isScriptBearingURL(_ url: String) -> Bool {
    let probe = scriptSchemeProbe(url)
    if probe.hasPrefix("javascript:") || probe.hasPrefix("vbscript:") {
        return true
    }
    return probe.hasPrefix("data:") && !probe.hasPrefix("data:image/")
}

/// Lowercased URL with every control character and space removed. Browsers
/// drop TAB/LF/CR anywhere in a URL and C0/space at its ends, so a scheme
/// check on the raw string misses `java\tscript:` — which is exactly what
/// swift-markdown hands over for an entity-encoded `java&#9;script:`.
func scriptSchemeProbe(_ url: String) -> String {
    let kept = url.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }
    return String(String.UnicodeScalarView(kept)).lowercased()
}

// MARK: - Obsidian comments

/// Follows `%%` comments line by line, as the preview hides them (after code
/// is masked: a `%%` in a fence or a code span doesn't count). A line that
/// STARTS inside a comment is hidden up to its closing `%%`, so neither the
/// TOC nor the task map may count a heading or task on it.
struct CommentLineTracker {
    private var inFence = false
    private var inComment = false
    private static let codeSpan = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    /// Feeds the next line; true when it starts inside a comment.
    mutating func startsInComment(_ line: String) -> Bool {
        let hidden = inComment
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inFence.toggle()
            return hidden
        }
        guard !inFence, utf8Contains(line, "%%") else { return hidden }
        var text = line
        if line.contains("`") {
            text = Self.codeSpan.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
        }
        if text.components(separatedBy: "%%").count % 2 == 0 { inComment.toggle() }
        return hidden
    }
}

// MARK: - Table of Contents

enum TOCBuilder {
    /// Characters that can make a heading's visible text differ from its
    /// source: links, HTML, entities, escapes, code, emphasis, `==marks==`,
    /// `#tags`, math. A heading with none needs no parse.
    private static let inlineMarkup = Set("[<&\\`*_~=#$")

    /// Extracts ATX headings with renderer-matching slugs. Fence-aware so a
    /// `# comment` inside a code block doesn't appear in the TOC (and doesn't
    /// desynchronize slug deduplication from the renderer). Pass the
    /// preview's `options`: they decide how heading text renders.
    static func extractHeadings(from source: String, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> [TOCHeading] {
        let content = source.nativeUTF8()
        var headings: [TOCHeading] = []
        var slugger = HeadingSlugger()
        var inFence = false
        var renderer: MarkdownRenderer?
        var comments = CommentLineTracker()
        let hasComments = utf8Contains(content, "%%")

        // Split on "\n" only (as the editor and toggleTask do): `.newlines`
        // counts a CRLF as two breaks, doubling every line number.
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            // A `# heading` inside a `%%` comment isn't on the page.
            if hasComments, comments.startsInComment(line) { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, trimmed.hasPrefix("#") else { continue }

            let level = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level) else { continue }

            let afterHashes = trimmed.dropFirst(level)
            guard afterHashes.first == " " else { continue }

            let text = afterHashes.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            // Slugged from the text the preview shows, as the renderer slugs
            // it: from the source, a link's URL or a wiki link's markup made
            // an anchor the preview doesn't have, and the click went nowhere.
            var visible = text
            if text.contains(where: inlineMarkup.contains) {
                let shared = renderer ?? MarkdownRenderer()
                renderer = shared
                visible = shared.headingAnchorText(text, options: options)
            }

            headings.append(TOCHeading(
                index: headings.count,
                level: level,
                text: visible.isEmpty ? text : visible,
                lineNumber: index + 1,
                slug: slugger.slug(for: visible)
            ))
        }
        return headings
    }
}

// MARK: - Render Options

/// Everything the renderer needs to honor user settings. Built centrally by
/// `AppState.renderOptions()` so the live preview and every exporter agree.
struct MarkdownRenderOptions: Equatable {
    var theme: PreviewTheme = .github
    var preview: PreviewSettings = PreviewSettings()
    var enableWikiLinks: Bool = true
    var enableCallouts: Bool = true
    var enableMermaid: Bool = true
    var enableKaTeX: Bool = false
    var enableCodeHighlight: Bool = true
    /// Where scripts, styles and fonts come from. The app's own copies for the
    /// preview and PDF export, whose web views serve them; ExportService
    /// switches HTML export and Copy as HTML to the CDN, which works anywhere.
    var libraries: PreviewLibraryOrigin = .bundled
    /// Emit checkbox inputs that post task-toggle messages back to the app.
    /// On for the live preview, off for HTML/PDF export.
    var interactiveTasks: Bool = true
    /// Post `MarkdownRenderer.renderedMessage` once highlighting, math and
    /// diagrams are done. On for PDF export only, which prints then.
    var reportsRendered: Bool = false
    /// Folders (besides the note's own) whose images may be shown. Non-nil
    /// rewrites local `<img>` sources inside them to the app's asset scheme —
    /// the preview and PDF views can't read file:// URLs. Nil (HTML export,
    /// clipboard) keeps note-relative sources so the file works elsewhere.
    var localAssetRoots: [URL]? = nil
    /// Images in the open folder and vaults, so `![[pic.png]]` finds a picture
    /// outside the note's folder (Obsidian's shortest-path links).
    var attachments: AttachmentIndex = .empty
    /// Obsidian reading view (strict line breaks off, its default): a single
    /// newline inside a paragraph is a line break. Off: CommonMark/GitHub,
    /// where it is a space.
    var obsidianLineBreaks: Bool = false
}

/// One parse configuration for every pass: no SmartyPants. cmark's smart
/// option curled quotes and turned `--` into an en dash — `--verbose` read
/// `–verbose`, and `# pre--post` got the id `prepost-heading` while the TOC
/// (slugging the source) linked `pre-post-heading`. Neither GitHub nor
/// Obsidian does it.
let markdownParseOptions: ParseOptions = [.disableSmartOpts]

// MARK: - Task line mapping

/// Maps rendered task checkboxes back to their source line numbers so clicking
/// a checkbox in the preview can toggle the right `- [ ]` in the document.
/// The visitor encounters task items in source order, so a simple queue works.
final class TaskLineQueue {
    let lines: [Int]
    private var index = 0
    private var overdrawn = false

    init(lines: [Int]) {
        self.lines = lines
    }

    /// The next box's ordinal: its line is `lines[ordinal]`.
    func next() -> Int? {
        guard index < lines.count else {
            overdrawn = true
            return nil
        }
        defer { index += 1 }
        return index
    }

    /// True when every scanned line went to exactly one rendered checkbox.
    /// Anything else means the scan and the rendered document disagree about
    /// which items are tasks, so the line numbers can't be trusted.
    var isFullyConsumed: Bool {
        index == lines.count && !overdrawn
    }

    static let taskLinePattern = try! NSRegularExpression(
        pattern: #"^(\s*)(?:[-*+]|\d+[.)])\s+\[([ xX])\]\s"#
    )

    /// Source lines of the ORIGINAL markdown's task items (before any
    /// transformation shifts lines), in the order the visitor meets them. Taken
    /// from the parsed document rather than a line regex, so it agrees with the
    /// renderer on every construct the parser decides: ~~~ and nested fences,
    /// indented code, raw HTML blocks, blockquotes (never checkboxes) and CRLF
    /// files (one line per CRLF, as toggleTask splits). Callout content is
    /// blockquoted here and rendered read-only, so it never takes a line.
    static func scan(_ markdown: String) -> [Int] {
        guard mayContainTasks(markdown) else { return [] }
        return lines(in: Document(parsing: markdown, options: markdownParseOptions), of: markdown)
    }

    /// Skip the parse for the common note without any `[ ]`/`[x]`: three
    /// byte probes (a `\[[ xX]\]` regex bridged the whole note to UTF-16).
    static func mayContainTasks(_ markdown: String) -> Bool {
        utf8Contains(markdown, "[ ]") || utf8Contains(markdown, "[x]") || utf8Contains(markdown, "[X]")
    }

    /// `scan`'s lines, from `document`: the parse of `markdown`.
    static func lines(in document: Document, of markdown: String) -> [Int] {
        var collector = TaskItemCollector()
        collector.visit(document)
        guard utf8Contains(markdown, "%%") else { return collector.lines }
        // A task inside a `%%` comment is hidden: counting it left the queue
        // unconsumed and turned EVERY checkbox in the note read-only.
        var comments = CommentLineTracker()
        var hidden: Set<Int> = []
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() where comments.startsInComment(line) {
            hidden.insert(index + 1)
        }
        return collector.lines.filter { !hidden.contains($0) }
    }

    private struct TaskItemCollector: MarkupWalker {
        var lines: [Int] = []

        mutating func visitListItem(_ listItem: ListItem) {
            if listItem.checkbox != nil {
                // Line 0 (no source position) keeps the queue aligned and is
                // rejected by toggleTask.
                lines.append(listItem.range?.lowerBound.line ?? 0)
            }
            descendInto(listItem)
        }

        // No task item lives inside these; skipping their (mostly inline)
        // children keeps the walk to the document's block structure.
        mutating func visitParagraph(_ paragraph: Paragraph) {}
        mutating func visitHeading(_ heading: Heading) {}
        mutating func visitTable(_ table: Table) {}
    }
}

/// Where a line of the text a page was rendered from is in the note now. A
/// click can come from a page that hasn't caught up with the newest edit
/// (split view re-renders on a debounce, and an accepted toggle re-renders
/// too), so its box names a line of the older text. The lines before the
/// first one that changed keep their number, the lines after the last one
/// move by the lines added or removed, and a line inside the change has no
/// place now (nil). Checking only the old number's text let a shift by the
/// distance between two identical tasks flip the other one.
enum TaskLineMapping {
    /// `line` (1-based) of `old` in `new`; both split on "\n" only, as the
    /// renderer and toggleTask do.
    static func line(_ line: Int, renderedFrom old: String, in new: String) -> Int? {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        guard line >= 1, line <= before.count else { return nil }
        let shorter = min(before.count, after.count)
        var prefix = 0
        while prefix < shorter, same(before[prefix], after[prefix]) { prefix += 1 }
        if line <= prefix { return line }
        var suffix = 0
        while suffix < shorter - prefix, same(before[before.count - 1 - suffix], after[after.count - 1 - suffix]) { suffix += 1 }
        if line > before.count - suffix { return line + after.count - before.count }
        return nil
    }

    /// The same line, or the same task line with its box flipped: a second
    /// click before the re-render (undoing a misclick) is still that task.
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.utf16.count == b.utf16.count, let unmarkedA = unmarked(a) else { return false }
        return unmarkedA == unmarked(b)
    }

    /// A task line with its marker blanked; nil for any other line.
    private static func unmarked(_ line: String) -> String? {
        let ns = line as NSString
        guard let match = TaskLineQueue.taskLinePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.replacingCharacters(in: match.range(at: 2), with: " ")
    }
}

// MARK: - Source parse

/// The untouched note parsed once for the two passes that need the
/// parser's view of it (task lines, indented code): each parsed the whole
/// note on its own. On the caller's thread, as the render's own parse: a
/// GCD worker's 512 KB stack overflowed on nesting the caller handles, and
/// a render waiting on the pool deadlocked once every pool thread waited.
struct SourceParse {
    let taskLines: [Int]
    let indentedCode: [NSRange]

    /// Parses only when either pass is wanted (their byte prechecks said
    /// the note may need it).
    init(_ markdown: String, taskLines wantsTaskLines: Bool, indentedCode wantsIndentedCode: Bool) {
        guard wantsTaskLines || wantsIndentedCode else {
            taskLines = []
            indentedCode = []
            return
        }
        let document = Document(parsing: markdown, options: markdownParseOptions)
        taskLines = wantsTaskLines ? TaskLineQueue.lines(in: document, of: markdown) : []
        indentedCode = wantsIndentedCode ? MarkdownRenderer.indentedCodeRanges(in: markdown, document: document) : []
    }
}

// MARK: - Renderer

class MarkdownRenderer {
    private static let internalLinkQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        return allowed
    }()

    /// Obsidian order `[[target|alias]]`: group 2 is the target (may carry a
    /// `#heading`), group 3 the optional alias (or an embed's size). Neither
    /// may cross brackets or lines, so several links on a line (or in a table
    /// row) stay separate.
    private let wikiLinkPattern = try! NSRegularExpression(
        pattern: #"(!?)\[\[([^\[\]|\n]+)(?:\|([^\[\]\n]*))?\]\]"#,
        options: []
    )

    private let tagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)#("# + MarkdownDocument.tagNamePattern + ")",
        options: []
    )

    /// Obsidian comments — `%%inline%%` or a `%%` … `%%` block.
    private let commentPattern = try! NSRegularExpression(pattern: #"%%[\s\S]*?%%"#)
    /// `[^id]: text` — a footnote definition line.
    private let footnoteDefinitionPattern = try! NSRegularExpression(
        pattern: #"^\[\^([^\]\s]+)\]:[ \t]?(.*)$"#
    )
    /// `[^id]` — a footnote reference (a definition's `[^id]:` excluded).
    private let footnoteReferencePattern = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\](?!:)"#)

    private let markPattern = try! NSRegularExpression(
        // Like emphasis (and Obsidian): no space just inside either `==`, so
        // `a == b and c == d` stays prose.
        pattern: #"==([^=\s](?:[^=\n]*[^=\s])?)=="#,
        options: []
    )

    /// Precompiled masking expressions. Rendering runs frequently while the
    /// user types, so compiling these on every pass is unnecessary work.
    ///
    /// ``` and ~~~ fences in ONE source-ordered pattern, so a fence of one
    /// kind nested in the other stays inside its outer token. As in CommonMark,
    /// the closing run must use the opener's character, be at least as long and
    /// carry no info string, and an unclosed fence runs to the end. A backtick
    /// run followed by another backtick on its line is inline code, not a fence.
    private static let fencedCodePattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:(`{3,})(?![^\n]*`)|(~{3,}))[\s\S]*?(?:^[ \t]*(?:\1`*|\2~*)[ \t]*$|\z)"#
    )
    private static let inlineCodePattern = try! NSRegularExpression(
        pattern: "`[^`\\n]+`"
    )
    private static let displayDollarMathPattern = try! NSRegularExpression(
        pattern: #"\$\$[\s\S]+?\$\$"#
    )
    private static let displayBracketMathPattern = try! NSRegularExpression(
        pattern: #"\\\[[\s\S]+?\\\]"#
    )
    private static let inlineParenMathPattern = try! NSRegularExpression(
        pattern: #"\\\([\s\S]+?\\\)"#
    )
    /// Pandoc/Obsidian rule, so prose prices ("$5 and $10") aren't math: the
    /// opening `$` is followed by a non-space, the closing one is preceded by a
    /// non-space and not followed by a digit; `\$` is a literal dollar.
    private static let inlineDollarMathPattern = try! NSRegularExpression(
        pattern: #"(?<![\\$])\$(?=[^\s$])[^$\n]*?[^\s\\$]\$(?![$\d])"#
    )
    private static let codeTokenPattern = try! NSRegularExpression(
        pattern: "\u{E000}CMDMDCODE\\d+\u{E000}"
    )
    private static let mathTokenPattern = try! NSRegularExpression(
        pattern: "\u{E000}CMDMDMATH\\d+\u{E000}"
    )

    func renderToHTML(markdown source: String, baseURL: URL? = nil, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> String {
        renderPage(markdown: source, baseURL: baseURL, options: options).html
    }

    /// `renderToHTML`'s page, and what the live preview patches it by.
    func renderPage(markdown source: String, baseURL: URL? = nil, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> RenderedPage {
        let body = renderBody(markdown: source, baseURL: baseURL, options: options)
        // Fresh per render: only scripts the renderer writes carry it, so the
        // CSP admits them and nothing a note smuggles in.
        return wrapWithHTML(body: body, options: options, nonce: Self.freshNonce())
    }

    /// The page body `renderToHTML` wraps, and the UTF-8 byte range of each
    /// top-level block in it (in order, back to back): what an incremental
    /// preview update diffs and patches block by block.
    ///
    /// The blocks are the parsed Markdown's, not DOM elements: a raw HTML
    /// block is its own range even when it only opens or closes an element
    /// (the note's `<div>` … `</div>`, `<details>`, and the footnotes'
    /// `<section class="footnotes">` … `</section>` around their list), so
    /// a patcher must treat such a run of ranges as one unit.
    struct RenderedBody {
        let html: String
        let blockRanges: [Range<Int>]
        /// The source line of each live checkbox, by its `data-task` ordinal.
        let taskLines: [Int]
    }

    /// A full page. Live pages (`interactiveTasks`) hold the note in
    /// `#cmdmd-root`, a marker comment before each of its blocks, and carry
    /// the runtime that patches them (`PreviewRuntime`).
    struct RenderedPage {
        let html: String
        /// The UTF-8 range in `html` of each block after its marker; nil for
        /// an export page, or a body that can't be patched (`PreviewBlocks`).
        let blocks: [Range<Int>]?
        let taskLines: [Int]
        /// What the head holds besides the settings: a page whose head
        /// differs can't be patched into.
        let head: PageHead
        /// `<html lang>`.
        let language: String?
        let nonce: String

        /// The page under a fresh nonce, for another load. A nonce is always
        /// 32 characters, so `blocks` still index it.
        func refreshingNonce() -> RenderedPage {
            let fresh = MarkdownRenderer.freshNonce()
            return RenderedPage(html: MarkdownRenderer.refreshingNonce(in: html, to: fresh), blocks: blocks,
                                taskLines: taskLines, head: head, language: language, nonce: fresh)
        }
    }

    /// The libraries a page's body needs (their script URLs) and the
    /// callout styles it uses: the first code block, formula or diagram, or
    /// a new callout type, changes the head.
    struct PageHead: Equatable {
        let scripts: [String]
        let callouts: String
    }

    func renderBody(markdown source: String, baseURL: URL? = nil, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> RenderedBody {
        // The editor's NSString-backed text, transcoded once for every pass.
        let markdown = source.nativeUTF8()
        // Task lines and indented code come from the untouched source, before
        // any transformation can shift lines.
        let sourceParse = SourceParse(
            markdown,
            taskLines: options.interactiveTasks && TaskLineQueue.mayContainTasks(markdown),
            indentedCode: Self.mayHaveIndentedCode(markdown)
        )

        // Mask fenced/inline code first so the wiki-link/callout/tag regex passes
        // don't rewrite Markdown-looking text INSIDE code (e.g. `#define`, `[[x]]`,
        // a leading `> [!note]` in a shell snippet).
        var (processedMarkdown, codeTokens) = maskCodeRegions(markdown, indentedCode: sourceParse.indentedCode)

        // Mask math next (code already protected) so `$a_b$` survives emphasis
        // parsing. Restored into the FINAL HTML, where KaTeX renders it in-DOM.
        var mathTokens: [String: String] = [:]
        if options.enableKaTeX {
            (processedMarkdown, mathTokens) = maskMathRegions(processedMarkdown)
        }

        processedMarkdown = processComments(processedMarkdown)
        processedMarkdown = processFootnotes(processedMarkdown, codeTokens: codeTokens)

        if options.enableWikiLinks {
            processedMarkdown = processWikiLinks(processedMarkdown, baseURL: baseURL, attachments: options.attachments, codeTokens: codeTokens)
        }
        if options.enableWikiLinks {
            processedMarkdown = processTags(processedMarkdown)
        }
        processedMarkdown = processHighlights(processedMarkdown)
        processedMarkdown = cjkFriendlyEmphasis(processedMarkdown)

        processedMarkdown = restoreCodeRegions(processedMarkdown, tokens: codeTokens)

        let document = Document(parsing: processedMarkdown, options: markdownParseOptions)
        let taskQueue = TaskLineQueue(lines: sourceParse.taskLines)
        var htmlVisitor = Self.visitor(options, taskQueue: taskQueue)
        if !mathTokens.isEmpty {
            htmlVisitor.restoreMath = { [self] text in
                restoreRegions(in: text, tokens: mathTokens, matching: Self.mathTokenPattern, transform: { $0 })
            }
        }
        // Room for the markup around the text, so the one buffer rarely grows.
        let capacity = processedMarkdown.utf8.count * 2
        var htmlBody = htmlVisitor.render(document, capacityHint: capacity)
        var blockRanges = htmlVisitor.blockRanges

        // The scan and this parse disagree about which items are tasks (e.g. a
        // list swallowed by an HTML block), so no line number can be trusted:
        // render every box read-only rather than toggle the wrong line.
        if options.interactiveTasks, !taskQueue.isFullyConsumed {
            var readOnlyVisitor = Self.visitor(options, taskQueue: TaskLineQueue(lines: []))
            readOnlyVisitor.restoreMath = htmlVisitor.restoreMath
            htmlBody = readOnlyVisitor.render(document, capacityHint: capacity)
            blockRanges = readOnlyVisitor.blockRanges
        }

        var bounds = OffsetTracker(blockRanges.flatMap { [$0.lowerBound, $0.upperBound] })

        // Math placeholders come back as escaped literal `$...$` text in a
        // `cmdmd-math` span. KaTeX renders only those spans in-DOM, so a prose
        // dollar sign is never handed to it.
        htmlBody = restoreMathRegions(in: htmlBody, tokens: mathTokens, offsets: &bounds)

        if let roots = options.localAssetRoots {
            htmlBody = LocalAssetURL.rewriteImageSources(in: htmlBody, baseURL: baseURL, roots: roots, offsets: &bounds)
        }

        let ends = bounds.offsets
        return RenderedBody(
            html: htmlBody,
            blockRanges: stride(from: 0, to: ends.count, by: 2).map { ends[$0]..<ends[$0 + 1] },
            taskLines: options.interactiveTasks && taskQueue.isFullyConsumed ? taskQueue.lines : []
        )
    }

    private static func visitor(_ options: MarkdownRenderOptions, taskQueue: TaskLineQueue) -> HTMLVisitor {
        var visitor = HTMLVisitor(renderMermaid: options.enableMermaid, taskQueue: taskQueue)
        visitor.renderCallouts = options.enableCallouts
        visitor.softBreak = options.obsidianLineBreaks ? "<br />\n" : "\n"
        return visitor
    }

    /// Convenience used by tests and callers that don't care about settings.
    func renderToHTML(markdown: String, baseURL: URL? = nil, theme: PreviewTheme) -> String {
        var options = MarkdownRenderOptions()
        options.theme = theme
        return renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
    }

    /// The text a heading with this content (`Related [[Project X]]`) has
    /// its anchor slugged from: the passes and parse of `renderToHTML`, then
    /// `headingVisibleText`, so the TOC slugs what the preview does.
    func headingAnchorText(_ headingText: String, options: MarkdownRenderOptions) -> String {
        let line = "# " + headingText
        var (processed, codeTokens) = maskCodeRegions(line, indentedCode: Self.indentedCodeRanges(in: line))
        var mathTokens: [String: String] = [:]
        if options.enableKaTeX {
            (processed, mathTokens) = maskMathRegions(processed)
        }
        if options.enableWikiLinks {
            processed = processTags(processWikiLinks(processed, baseURL: nil, attachments: .empty, codeTokens: codeTokens))
        }
        processed = restoreCodeRegions(cjkFriendlyEmphasis(processHighlights(processed)), tokens: codeTokens)

        guard let heading = Document(parsing: processed, options: markdownParseOptions).child(at: 0) as? Heading else { return headingText }
        return restoreRegions(
            in: headingVisibleText(heading),
            tokens: mathTokens,
            matching: Self.mathTokenPattern,
            transform: { $0 }
        )
    }

    // MARK: Masking

    /// Replaces fenced and inline code spans with private-use placeholder tokens
    /// so downstream regex pre-processing leaves code untouched. Restored before
    /// the Markdown parse so the code blocks render (and escape) normally.
    /// `indentedCode`: `indentedCodeRanges` of `markdown`.
    private func maskCodeRegions(_ markdown: String, indentedCode: [NSRange]) -> (String, [String: String]) {
        // Line-anchored fences (``` at the start of a line, optional indent) so a
        // stray inline ``` can't pair with a real fence and swallow content
        // between two separate code blocks.
        let fences = Self.fencedCodePattern.matches(
            in: markdown,
            range: NSRange(location: 0, length: (markdown as NSString).length)
        ).map(\.range)
        // Indented code a fence match doesn't already cover, masked in the same
        // pass so no token ever ends up inside another.
        let indented = indentedCode.filter { block in
            !fences.contains { NSIntersectionRange($0, block).length > 0 }
        }
        return maskRegions(
            in: markdown,
            ranges: (fences + indented).sorted { $0.location < $1.location },
            patterns: [Self.inlineCodePattern],
            tokenPrefix: "CMDMDCODE"
        )
    }

    /// Whole-line ranges of indented (4-space) code blocks outside block
    /// quotes. Only the parser can tell them from indented list content, so
    /// this parses, but only when an indented line follows a blank line or a
    /// heading, the only places such a block can start.
    private static func indentedCodeRanges(in markdown: String) -> [NSRange] {
        guard mayHaveIndentedCode(markdown) else { return [] }
        return indentedCodeRanges(in: markdown, document: Document(parsing: markdown, options: markdownParseOptions))
    }

    /// Byte-level pre-check, so most notes (indented only inside lists) pay
    /// no parse and no per-line strings.
    static func mayHaveIndentedCode(_ markdown: String) -> Bool {
        let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), cr = UInt8(ascii: "\r")
        var canStartBlock = true
        var hasCandidate = false
        for line in markdown.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == space || $0 == tab }
            let content = line.dropFirst(indent.count)
            let isBlank = content.allSatisfy { $0 == space || $0 == tab || $0 == cr }
            // Four spaces, or a tab (tab stops are 4 columns), reach code depth.
            if canStartBlock, !isBlank, indent.count >= 4 || indent.contains(tab) {
                hasCandidate = true
                break
            }
            canStartBlock = isBlank || content.first == UInt8(ascii: "#")
        }
        return hasCandidate
    }

    /// `indentedCodeRanges`, from `document`: the parse of `markdown`.
    fileprivate static func indentedCodeRanges(in markdown: String, document: Document) -> [NSRange] {
        let lines = markdown.components(separatedBy: "\n")
        var collector = IndentedCodeCollector()
        collector.visit(document)
        guard !collector.lineRanges.isEmpty else { return [] }

        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += line.utf16.count + 1
        }

        return collector.lineRanges.compactMap { lineRange in
            let first = lineRange.lowerBound - 1
            let last = min(lineRange.upperBound, lines.count) - 1
            guard first >= 0, first <= last else { return nil }
            // CodeBlock doesn't say how it was opened; a fenced one starts on
            // its fence line (and is the fence pattern's job).
            let opener = lines[first].trimmingCharacters(in: .whitespaces)
            guard !opener.hasPrefix("```"), !opener.hasPrefix("~~~") else { return nil }
            let end = lineStarts[last] + lines[last].utf16.count
            return NSRange(location: lineStarts[first], length: end - lineStarts[first])
        }
    }

    private struct IndentedCodeCollector: MarkupWalker {
        var lineRanges: [ClosedRange<Int>] = []

        // Whole quoted lines can't be masked without dropping the `>` that
        // keeps them in the quote (or callout), so quotes are left alone.
        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {}

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            guard let range = codeBlock.range, range.upperBound.line >= range.lowerBound.line else { return }
            lineRanges.append(range.lowerBound.line...range.upperBound.line)
        }

        // No code block lives inside these.
        mutating func visitParagraph(_ paragraph: Paragraph) {}
        mutating func visitHeading(_ heading: Heading) {}
        mutating func visitTable(_ table: Table) {}
    }

    /// Masks `$$display$$` and `$inline$` math with placeholder tokens. Inline
    /// math must be single-line and non-empty so a lone dollar sign in prose
    /// doesn't start a bogus math region.
    private func maskMathRegions(_ markdown: String) -> (String, [String: String]) {
        maskRegions(
            in: markdown,
            patterns: [
                Self.displayDollarMathPattern,
                Self.displayBracketMathPattern,
                Self.inlineParenMathPattern,
                Self.inlineDollarMathPattern
            ],
            tokenPrefix: "CMDMDMATH",
            content: Self.unquotedMath
        )
    }

    /// A math region's source minus the quote markers of the lines it spans:
    /// display math in a quote or callout (`> $$` / `> E=mc^2` / `> $$`)
    /// handed KaTeX every line's `>`.
    private static func unquotedMath(_ source: String, _ range: NSRange) -> String {
        let math = source.slice(range)
        guard math.contains("\n") else { return math }
        let ns = source as NSString
        let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
        let lead = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        let depth = lead.prefix { $0 == ">" || $0 == " " || $0 == "\t" }.filter { $0 == ">" }.count
        guard depth > 0 else { return math }
        return math.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            guard index > 0 else { return String(line) }
            var rest = line[...]
            for _ in 0..<depth {
                let trimmed = rest.drop { $0 == " " || $0 == "\t" }
                guard trimmed.first == ">" else { break }
                rest = trimmed.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
            }
            return String(rest)
        }.joined(separator: "\n")
    }

    /// Masks every non-overlapping match from each expression in one forward
    /// pass. The previous first-match loop rebuilt the entire String once per
    /// code span, making code-heavy documents progressively slower.
    private func maskRegions(
        in source: String,
        ranges sourceRanges: [NSRange] = [],
        patterns: [NSRegularExpression],
        tokenPrefix: String,
        content: ((String, NSRange) -> String)? = nil
    ) -> (String, [String: String]) {
        var tokens: [String: String] = [:]
        var index = 0
        var result = source

        // Swaps ordered, non-overlapping ranges of `result` for tokens.
        func mask(_ ranges: [NSRange], in original: String) {
            guard !ranges.isEmpty else { return }

            var masked = ""
            masked.reserveCapacity(original.utf8.count)
            var cursor = original.startIndex

            for range in ranges {
                let token = "\u{E000}\(tokenPrefix)\(index)\u{E000}"
                let r = original.indexRange(range)
                tokens[token] = content?(original, range) ?? String(original[r])
                masked += original[cursor..<r.lowerBound]
                masked += token
                cursor = r.upperBound
                index += 1
            }
            masked += original[cursor...]
            result = masked
        }

        // Precomputed ranges of the untouched source first, then each
        // expression over what is left.
        mask(sourceRanges, in: source)
        for pattern in patterns {
            let original = result
            let matches = pattern.matches(
                in: original,
                range: NSRange(location: 0, length: original.utf16.count)
            )
            mask(matches.map(\.range), in: original)
        }

        return (result, tokens)
    }

    private func restoreCodeRegions(_ markdown: String, tokens: [String: String]) -> String {
        restoreRegions(
            in: markdown,
            tokens: tokens,
            matching: Self.codeTokenPattern,
            transform: { $0 }
        )
    }

    /// Restores every placeholder in one forward pass. Replacing dictionary
    /// entries one at a time copied the full document once per token, undoing
    /// the benefit of batched masking for code-heavy notes.
    private func restoreRegions(
        in source: String,
        tokens: [String: String],
        matching pattern: NSRegularExpression,
        transform: (String) -> String
    ) -> String {
        // No tokens: every match would be kept as is.
        guard !tokens.isEmpty else { return source }
        let matches = pattern.matches(
            in: source,
            range: NSRange(location: 0, length: source.utf16.count)
        )
        guard !matches.isEmpty else { return source }

        var restored = ""
        restored.reserveCapacity(source.utf8.count)
        var cursor = source.startIndex

        for match in matches {
            let r = source.indexRange(match.range)
            restored += source[cursor..<r.lowerBound]
            let token = String(source[r])
            restored += tokens[token].map(transform) ?? token
            cursor = r.upperBound
        }
        restored += source[cursor...]
        return restored
    }

    /// Restores math placeholders: a `cmdmd-math` span in text, but plain
    /// escaped text when the token sits inside a tag — a link's href or an
    /// image's src (`?$filter=a&$top=5`), where a span corrupted the URL. The
    /// rendered body only has raw `<`/`>` as tag delimiters (text and
    /// attribute values are escaped), so one forward scan tracks tag state.
    private func restoreMathRegions(in source: String, tokens: [String: String], offsets: inout OffsetTracker) -> String {
        guard !tokens.isEmpty else { return source }
        let matches = Self.mathTokenPattern.matches(
            in: source,
            range: NSRange(location: 0, length: source.utf16.count)
        )
        guard !matches.isEmpty else { return source }

        let lessThan = UInt8(ascii: "<")
        let greaterThan = UInt8(ascii: ">")
        var restored = ""
        restored.reserveCapacity(source.utf8.count)
        var cursor = source.startIndex
        var insideTag = false

        for match in matches {
            let r = source.indexRange(match.range)
            // `<`/`>` are ASCII: a UTF-8 byte match is a UTF-16 unit match.
            for byte in source.utf8[cursor..<r.lowerBound] {
                if byte == lessThan { insideTag = true } else if byte == greaterThan { insideTag = false }
            }
            restored += source[cursor..<r.lowerBound]
            offsets.copied(upTo: source.utf8Offset(r.lowerBound), rebuilt: restored.utf8.count)
            let token = String(source[r])
            if let math = tokens[token] {
                restored += insideTag ? htmlEscape(math) : "<span class='cmdmd-math'>\(htmlEscape(math))</span>"
            } else {
                restored += token
            }
            offsets.swapped(upTo: source.utf8Offset(r.upperBound), rebuilt: restored.utf8.count)
            cursor = r.upperBound
        }
        restored += source[cursor...]
        offsets.finished(source: source.utf8.count, rebuilt: restored.utf8.count)
        return restored
    }

    // MARK: Obsidian extensions

    /// Rebuilds `source` once, swapping each match of `pattern` for
    /// `replacement(match, source)`. Matches are ordered and
    /// non-overlapping, and their ranges index the untouched source. Replacing
    /// them one at a time copied the whole document per match (O(n·k)).
    private func replacingMatches(
        of pattern: NSRegularExpression,
        in source: String,
        with replacement: (NSTextCheckingResult, String) -> String
    ) -> String {
        let matches = pattern.matches(
            in: source,
            range: NSRange(location: 0, length: source.utf16.count)
        )
        guard !matches.isEmpty else { return source }

        var result = ""
        result.reserveCapacity(source.utf8.count)
        var cursor = source.startIndex

        for match in matches {
            let r = source.indexRange(match.range)
            result += source[cursor..<r.lowerBound]
            result += replacement(match, source)
            cursor = r.upperBound
        }
        result += source[cursor...]
        return result
    }

    private func processWikiLinks(_ markdown: String, baseURL: URL?, attachments: AttachmentIndex, codeTokens: [String: String]) -> String {
        replacingMatches(of: wikiLinkPattern, in: markdown) { match, source in
            let isEmbed = source.slice(match.range(at: 1)) == "!"
            var target = source.slice(match.range(at: 2))
            // In a table the pipe is escaped (`[[Note\|alias]]`), which leaves
            // the backslash on the target.
            if target.hasSuffix("\\") { target.removeLast() }
            // An empty alias (`[[Note|]]`) would leave an invisible link.
            let alias = match.range(at: 3).location != NSNotFound
                ? source.slice(match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                : ""
            let label = alias.isEmpty ? nil : alias

            // Element content keeps the masked text: its code placeholders are
            // restored before the Markdown parse and render as escaped code
            // spans. Attribute values are built from the UNMASKED text — a
            // placeholder restored there after htmlEscape would put the code's
            // raw quotes back into the attribute.
            let displayText = Self.escapeForTableCell(label ?? target)
            let rawLabel = label.map { restoreCodeRegions($0, tokens: codeTokens) }
            let rawTarget = restoreCodeRegions(target, tokens: codeTokens)

            if isEmbed {
                let ext = (rawTarget as NSString).pathExtension.lowercased()

                if LocalAssetURL.imageExtensions.contains(ext) {
                    // `|300` / `|300x200` sizes an image embed; any other
                    // alias is its alt text.
                    let size = label.flatMap(Self.embedSizeAttributes)
                    let altText = Self.escapeForTableCell(size == nil ? (rawLabel ?? rawTarget) : rawTarget)
                    let imgPath = Self.embeddedImagePath(rawTarget, baseURL: baseURL, attachments: attachments)
                    return "<img src=\"file://\(htmlEscape(imgPath))\" alt=\"\(altText)\" class=\"embedded-image\"\(size ?? "") />"
                } else {
                    return "<span class=\"embedded-note\" data-note=\"\(htmlEscape(rawTarget))\">\(displayText)</span>"
                }
            } else if target.hasPrefix("#") {
                // `[[#Heading]]` points into this note; like Obsidian, the last
                // `#` segment names the heading. A `#^block` id has no anchor
                // here, so it gets an empty slug (a no-op click).
                let heading = target.split(separator: "#").last.map(String.init) ?? ""
                let rawHeading = rawTarget.split(separator: "#").last.map(String.init) ?? ""
                let slug = rawHeading.hasPrefix("^") ? "" : markdownHeadingSlug(rawHeading)
                let encoded = slug.addingPercentEncoding(withAllowedCharacters: Self.internalLinkQueryValueAllowed) ?? slug
                let href = "cmdmd://heading?slug=\(encoded)"
                let text = Self.escapeForTableCell(label ?? (heading.isEmpty ? target : heading))
                return "<a href=\"\(htmlEscape(href))\" class=\"wiki-link\">\(text)</a>"
            } else {
                let encoded = rawTarget.addingPercentEncoding(withAllowedCharacters: Self.internalLinkQueryValueAllowed) ?? rawTarget
                let href = "cmdmd://open?note=\(encoded)"
                return "<a href=\"\(htmlEscape(href))\" class=\"wiki-link\">\(displayText)</a>"
            }
        }
    }

    /// `htmlEscape` plus `|`: wiki links are rewritten before cmark splits
    /// table rows, so a literal pipe in generated text would end the cell.
    private static func escapeForTableCell(_ text: String) -> String {
        htmlEscape(text).replacingOccurrences(of: "|", with: "&#124;")
    }

    /// Where an image embed points: beside the note when the file is there
    /// (or nothing else matches), else wherever the index finds that name.
    static func embeddedImagePath(_ target: String, baseURL: URL?, attachments: AttachmentIndex) -> String {
        guard let baseURL else { return target }
        let beside = baseURL.appendingPathComponent(target)
        if FileManager.default.fileExists(atPath: beside.path) { return beside.path }
        return attachments.resolve(target, from: baseURL)?.path ?? beside.path
    }

    /// Obsidian's image-embed size, `300` or `300x200`, as `width`/`height`
    /// attributes; nil when the alias is anything else.
    private static func embedSizeAttributes(_ alias: String) -> String? {
        let parts = alias.split(separator: "x", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        return " width=\"\(parts[0])\"" + (parts.count == 2 ? " height=\"\(parts[1])\"" : "")
    }

    /// Raw HTML tags typed in the note (`<span style="color: #3b82f6">`). The
    /// `#tag` and `==mark==` passes leave their insides alone: a hex color
    /// became a tag span inside the attribute and the element rendered as text.
    private static let rawHTMLTagPattern = try! NSRegularExpression(pattern: #"</?[A-Za-z][^<>]*>"#)

    private static func rawHTMLTagRanges(in markdown: String) -> [NSRange] {
        rawHTMLTagPattern.matches(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length)).map(\.range)
    }

    /// Whether `location` falls in one of `ranges` (sorted, disjoint).
    private static func isInside(_ location: Int, _ ranges: [NSRange]) -> Bool {
        var low = 0, high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if location < ranges[mid].location { high = mid - 1 }
            else if location >= NSMaxRange(ranges[mid]) { low = mid + 1 }
            else { return true }
        }
        return false
    }

    private func processTags(_ markdown: String) -> String {
        let htmlTags = Self.rawHTMLTagRanges(in: markdown)
        return replacingMatches(of: tagPattern, in: markdown) { match, source in
            let fullMatch = source.slice(match.range)
            if Self.isInside(match.range.location, htmlTags) { return fullMatch }
            let tagName = source.slice(match.range(at: 1))

            return "<span class=\"tag\" data-tag=\"\(htmlEscape(tagName))\">\(htmlEscape(fullMatch))</span>"
        }
    }

    /// Obsidian `==highlight==` → `<mark>`. The inner text stays Markdown, so
    /// `==**bold** highlight==` renders nested formatting.
    private func processHighlights(_ markdown: String) -> String {
        let htmlTags = Self.rawHTMLTagRanges(in: markdown)
        return replacingMatches(of: markPattern, in: markdown) { match, source in
            if Self.isInside(match.range.location, htmlTags) { return source.slice(match.range) }
            let inner = source.slice(match.range(at: 1))
            return "<mark>\(inner)</mark>"
        }
    }

    /// Obsidian comments are notes to self, hidden in reading view; they
    /// showed as literal `%%…%%`. Runs on masked text, so a `%%` inside code
    /// is left alone.
    private func processComments(_ markdown: String) -> String {
        guard utf8Contains(markdown, "%%") else { return markdown }
        return replacingMatches(of: commentPattern, in: markdown) { _, _ in "" }
    }

    /// Footnotes, which swift-markdown doesn't parse — `[^1]` and its
    /// `[^1]: text` line both showed as literal text. Definitions (with their
    /// indented continuation lines and paragraphs) move to a numbered list at
    /// the end; each reference becomes a superscript link to its note, which
    /// links back. Notes are numbered in the order they are first REFERENCED
    /// (GitHub, Obsidian), unreferenced ones last; ids are those numbers, so a
    /// label's characters never reach an attribute.
    private func processFootnotes(_ markdown: String, codeTokens: [String: String]) -> String {
        guard utf8Contains(markdown, "[^") else { return markdown }

        // An indented paragraph after a blank line was masked as indented
        // code before this pass; such a line is its token alone.
        func indentedBlock(_ line: String) -> String? {
            guard let block = codeTokens[line], block.hasPrefix("    ") || block.hasPrefix("\t") else { return nil }
            return block
        }
        func isIndented(_ line: String) -> Bool { line.hasPrefix("    ") || line.hasPrefix("\t") || indentedBlock(line) != nil }
        func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }

        var kept: [String] = []
        var definitions: [(label: String, text: String)] = []
        var lines = markdown.components(separatedBy: "\n")[...]
        while let line = lines.popFirst() {
            // The pattern is anchored at `[^`: other lines skip the regex
            // (and its per-line bridge).
            guard line.utf8.starts(with: "[^".utf8), let match = footnoteDefinitionPattern.firstMatch(
                in: line, range: NSRange(location: 0, length: line.utf16.count)
            ) else {
                kept.append(line)
                continue
            }
            var text = line.slice(match.range(at: 2))
            var paragraphBreak = false
            while let next = lines.first {
                if isBlank(next) {
                    // A blank line continues the note only when an indented
                    // line follows: its next paragraph (not an indented code
                    // block in the body, as it rendered before).
                    guard let after = lines.dropFirst().first(where: { !isBlank($0) }), isIndented(after) else { break }
                    paragraphBreak = true
                    lines.removeFirst()
                    continue
                }
                guard isIndented(next) else { break }
                // Four spaces keep each line inside the note's list item.
                var block = indentedBlock(next) ?? next
                while block.last?.isNewline == true { block.removeLast() }
                for (index, piece) in block.components(separatedBy: "\n").enumerated() {
                    let unindented = piece.hasPrefix("\t") ? String(piece.dropFirst()) : String(piece.dropFirst(min(4, piece.prefix { $0 == " " }.count)))
                    text += (index == 0 && paragraphBreak ? "\n\n    " : "\n    ") + unindented
                }
                paragraphBreak = false
                lines.removeFirst()
            }
            definitions.append((line.slice(match.range(at: 1)), text))
        }
        guard !definitions.isEmpty else { return markdown }

        var texts: [String: String] = [:]
        for definition in definitions where texts[definition.label] == nil {
            texts[definition.label] = definition.text
        }

        let source = kept.joined(separator: "\n")
        var numbers: [String: Int] = [:]
        var order: [String] = []
        for match in footnoteReferencePattern.matches(in: source, range: NSRange(location: 0, length: source.utf16.count)) {
            let label = source.slice(match.range(at: 1))
            if texts[label] != nil, numbers[label] == nil {
                order.append(label)
                numbers[label] = order.count
            }
        }
        for definition in definitions where numbers[definition.label] == nil {
            order.append(definition.label)
            numbers[definition.label] = order.count
        }

        var referenced: Set<Int> = []
        let body = replacingMatches(of: footnoteReferencePattern, in: source) { match, text in
            guard let n = numbers[text.slice(match.range(at: 1))] else {
                return text.slice(match.range)
            }
            // Only the first reference carries the id the ↩ link returns to.
            let id = referenced.insert(n).inserted ? " id=\"fnref-\(n)\"" : ""
            return "<sup class=\"footnote-ref\"><a href=\"#fn-\(n)\"\(id)>\(n)</a></sup>"
        }

        // A blank line after the opening tag ends the HTML block, so each
        // note's text is still parsed as Markdown.
        var section = "\n\n<section class=\"footnotes\">\n\n"
        for (index, label) in order.enumerated() {
            let n = index + 1
            let backref = referenced.contains(n) ? " <a href=\"#fnref-\(n)\" class=\"footnote-backref\">↩</a>" : ""
            section += "\(n). <a id=\"fn-\(n)\"></a>\(texts[label] ?? "")\(backref)\n"
        }
        section += "\n</section>\n"
        return body + section
    }

    // MARK: Document shell

    /// Exact versions (not @11 / @0.16 ranges) so the bytes behind each hash
    /// never move. jsdelivr answers with `Access-Control-Allow-Origin: *`,
    /// which the CORS-mode fetch SRI needs from the file:// page. Refresh a
    /// hash with `curl -s URL | openssl dgst -sha384 -binary | openssl base64 -A`.
    private enum CDN {
        static let katexCSS = LibraryResource(
            url: "https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/katex.min.css",
            integrity: "sha384-nH0MfJ44wi1dd7w6jinlyBgljjS8EJAh2JBoRad8a3VDw2K69vfaaqm4WnR+gXtA"
        )
        static let katex = LibraryResource(
            url: "https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/katex.min.js",
            integrity: "sha384-CwjPRVHTvLiMBFjEoij+QZViMV5rhTOIp7CJzl24JEqpRDA1sJFHVXXLURktbYYp"
        )
        static let katexMhchem = LibraryResource(
            url: "https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/contrib/mhchem.min.js",
            integrity: "sha384-fB8BH//9nBzROkMUsu/Dr35jWHIbnKesUo9rW0hfEgw8mZGnkAyBAjKX9F98OVuo"
        )
        static let katexAutoRender = LibraryResource(
            url: "https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/contrib/auto-render.min.js",
            integrity: "sha384-bjyGPfbij8/NDKJhSGZNP/khQVgtHUE5exjm4Ydllo42FwIgYsdLO2lXGmRBf5Mz"
        )
        /// npm mirror of highlight.js: immutable per version, unlike a GitHub
        /// tag. The release the preview runs (Highlightr's highlight.min.js).
        static let highlightBase = "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.11.1"
        static let highlight = LibraryResource(
            url: "\(highlightBase)/highlight.min.js",
            integrity: "sha384-RH2xi4eIQ/gjtbs9fUXM68sLSi99C7ZWBRX1vDrVv6GQXRibxXLbwO2NGZB74MbU"
        )
        /// Hashes for the themes Settings offers: the bytes the preview links
        /// (`Libraries.highlightTheme`). Any other name is drawn in the page
        /// theme's own palette (`codeTheme(_:)`), as in the preview.
        static let highlightThemeIntegrity: [String: String] = [
            "github": "sha384-eFTL69TLRZTkNfYZOLM+G04821K1qZao/4QLJbet1pP4tcF+fdXq/9CdqAbWRl/L",
            "github-dark": "sha384-wH75j6z1lH97ZOpMOInqhgKzFkAInZPPSPlZpYKYTOqsaizPvhQZmAtLcPKXpLyH",
            "atom-one-dark": "sha384-oaMLBGEzBOJx3UHwac0cVndtX5fxGQIfnAeFZ35RTgqPcYlbprH9o9PUV/F8Le07",
            "atom-one-light": "sha384-w6Ujm1VWa9HYFqGc89oAPn/DWDi2gUamjNrq9DRvEYm2X3ClItg9Y9xs1ViVo5b5",
            "monokai": "sha384-Exar9WeMELq1EieDQNh7c2ggVht9/FEoVtGG2JKgmEwcm5zOXQwPMzp3PEsPJ/zq",
            "nord": "sha384-O/y538KpolLjYHZH8xqC17hcGWgjOw79vqDDhXNIT6Q7q3O5KVr29xbsaq9k6fSL",
            "tokyo-night-dark": "sha384-6PRNB60loRkq5oYgj0ETV33K0YsTUlab8qtfTGXhRgW5Nz1IpzS2zwj6UmlJEnyV"
        ]

        static func highlightTheme(_ name: String) -> LibraryResource {
            LibraryResource(
                url: "\(highlightBase)/styles/\(htmlEscape(name)).min.css",
                integrity: highlightThemeIntegrity[name]
            )
        }

        /// npm's copy of the Pele release the app bundles. Its hash is the
        /// bundled file's: cmds-pele ships Pele's npm bytes unchanged.
        static func pele(version: String, integrity: String?) -> LibraryResource {
            LibraryResource(url: "https://cdn.jsdelivr.net/npm/pele@\(version)/dist/pele.global.js", integrity: integrity)
        }
    }

    /// Pele and cmds-pele's CMDS bootstrap (`window.cmdsPele`) and theme.
    private struct DiagramLibrary {
        /// Loaded in order once the text is up: Pele, then the bootstrap
        /// unless it is inline.
        let scripts: [LibraryResource]
        let head: Head

        enum Head {
            /// The bundled theme, linked.
            case linked(css: LibraryResource)
            /// CDN pages: jsDelivr has neither file, so their text goes in the page.
            case inline(bootstrap: String, css: String)
        }
    }

    /// The files a page links, from `MarkdownRenderOptions.libraries`. A
    /// bundled file that isn't installed is nil, and the page goes without
    /// that feature rather than fetch it from the network.
    private struct Libraries {
        let origin: PreviewLibraryOrigin

        var katexCSS: LibraryResource? { pick(CDN.katexCSS, bundled: "katex/katex.min.css") }
        var katex: LibraryResource? { pick(CDN.katex, bundled: "katex/katex.min.js") }
        var katexMhchem: LibraryResource? { pick(CDN.katexMhchem, bundled: "katex/contrib/mhchem.min.js") }
        var katexAutoRender: LibraryResource? { pick(CDN.katexAutoRender, bundled: "katex/contrib/auto-render.min.js") }
        var highlight: LibraryResource? { pick(CDN.highlight, bundled: "\(PreviewLibrary.highlightrPrefix)/highlight.min.js") }

        /// Highlightr's bundle keeps its themes next to highlight.min.js, but
        /// its nord and monokai are highlight.js' base16 ones under the
        /// plain names: the originals (what export links) ship in PreviewLibs.
        func highlightTheme(_ name: String) -> LibraryResource? {
            let bundled = PreviewLibrary.originalHighlightThemes.contains(name)
                ? "\(PreviewLibrary.highlightThemesFolder)/\(name).min.css"
                : "\(PreviewLibrary.highlightrPrefix)/\(name).min.css"
            return pick(CDN.highlightTheme(name), bundled: bundled)
        }

        /// The highlight.js theme a page links: the one asked for when it is
        /// one of the themes the app pins and (from the app) is installed;
        /// otherwise "github", Auto, the page theme's own palette. A theme
        /// that isn't there must not strip the code block's box and leave
        /// its code uncoloured, nor an export fetch an unpinned stylesheet.
        func codeTheme(_ name: String) -> String {
            guard name != "github", CDN.highlightThemeIntegrity[name] != nil, highlightTheme(name) != nil else { return "github" }
            return name
        }

        /// Nil unless all of cmds-pele is installed: a page draws no
        /// diagram rather than fetch a missing piece.
        var diagrams: DiagramLibrary? {
            let folder = PreviewLibrary.peleFolder
            guard let pele = PreviewLibrary.resource("\(folder)/pele.global.js") else { return nil }
            switch origin {
            case .bundled:
                guard let bootstrap = PreviewLibrary.resource("\(folder)/cmds-pele.js"),
                      let theme = PreviewLibrary.resource("\(folder)/cmds-pele.css") else { return nil }
                return DiagramLibrary(scripts: [pele, bootstrap], head: .linked(css: theme))
            case .cdn:
                guard let version = PreviewLibrary.peleVersion,
                      let bootstrap = PreviewLibrary.contents("\(folder)/cmds-pele.js"),
                      let theme = PreviewLibrary.contents("\(folder)/cmds-pele.css") else { return nil }
                return DiagramLibrary(
                    scripts: [CDN.pele(version: version, integrity: pele.integrity)],
                    head: .inline(bootstrap: bootstrap, css: theme)
                )
            }
        }

        private func pick(_ cdn: LibraryResource, bundled path: String) -> LibraryResource? {
            origin == .cdn ? cdn : PreviewLibrary.resource(path)
        }
    }

    private func scriptTag(_ resource: LibraryResource, nonce: String, deferred: Bool = false) -> String {
        "<script\(deferred ? " defer" : "") src=\"\(resource.url)\"\(integrityAttributes(resource)) nonce=\"\(nonce)\"></script>"
    }

    private func stylesheetTag(_ resource: LibraryResource, media: String? = nil) -> String {
        let mediaAttribute = media.map { " media=\"\($0)\"" } ?? ""
        return "<link rel=\"stylesheet\"\(mediaAttribute) href=\"\(resource.url)\"\(integrityAttributes(resource))>"
    }

    /// SRI needs a CORS fetch, hence crossorigin alongside every hash.
    private func integrityAttributes(_ resource: LibraryResource) -> String {
        resource.integrity.map { " integrity=\"\($0)\" crossorigin=\"anonymous\"" } ?? ""
    }

    /// Scripts run only with the per-render nonce (the renderer's inline ones)
    /// or from the exact library files this page includes — never a whole
    /// host (jsdelivr serves any GitHub file) or scheme. Note HTML can still
    /// style the page and show images, but can't run script, frame other
    /// pages, post forms, re-base URLs or open connections. No 'unsafe-eval':
    /// Pele, KaTeX and highlight.js don't need it.
    ///
    /// A bundled page takes styles and fonts from the app alone. https: stays
    /// for CDN pages, and for custom CSS that imports from the web (a web
    /// font in Settings is the user's own choice; a note's `<link>` is not).
    private func contentSecurityPolicy(nonce: String, scriptURLs: [String], options: MarkdownRenderOptions) -> String {
        var styleSources = options.libraries == .bundled ? [PreviewLibrary.origin] : []
        if options.libraries == .cdn || options.preview.customCSS.range(of: "https:", options: .caseInsensitive) != nil {
            styleSources.append("https:")
        }
        let styles = styleSources.joined(separator: " ")
        return [
            "default-src 'none'",
            "script-src \((["'nonce-\(nonce)'"] + scriptURLs).joined(separator: " "))",
            "style-src 'unsafe-inline' \(styles)",
            "font-src \(styles) data:",
            "img-src https: http: data: blob: file: \(LocalAssetURL.scheme):",
            "media-src https: http: data: blob: file:",
            "frame-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "connect-src 'none'"
        ].joined(separator: "; ")
    }

    /// Adds an app-authored script at the end of `<head>`, carrying the page's
    /// nonce so the CSP admits it. Only the FIRST `</head>` is touched — the
    /// renderer's own; the head holds nothing a note controls, while raw HTML
    /// in the body may contain more, and a nonce'd script placed after note
    /// markup could be captured by a dangling tag.
    static func insertingHeadScript(_ script: String, into html: String) -> String {
        guard let headEnd = html.range(of: "</head>") else { return html }
        var nonceAttribute = ""
        if let start = html.range(of: "'nonce-", range: html.startIndex..<headEnd.lowerBound),
           let end = html[start.upperBound..<headEnd.lowerBound].firstIndex(of: "'") {
            nonceAttribute = " nonce=\"\(html[start.upperBound..<end])\""
        }
        return html.replacingCharacters(in: headEnd, with: "<script\(nonceAttribute)>\(script)</script></head>")
    }

    /// A rendered page again, under a new nonce: a cached page shown once
    /// more gets a fresh one, as every load does. The renderer writes the
    /// nonce in its own head only, so the body — the note — is left as is.
    static func refreshingNonce(in html: String, to fresh: String = freshNonce()) -> String {
        guard let headEnd = html.range(of: "</head>"),
              let start = html.range(of: "'nonce-", range: html.startIndex..<headEnd.lowerBound),
              let end = html[start.upperBound..<headEnd.lowerBound].firstIndex(of: "'") else { return html }
        let old = String(html[start.upperBound..<end])
        let head = html[..<headEnd.lowerBound].replacingOccurrences(of: old, with: fresh)
        return head + html[headEnd.lowerBound...]
    }

    /// 128 random bits as hex.
    static func freshNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Footnote styling, plus Korean line breaking: Korean breaks between
    /// words (어절), not between syllables: without
    /// keep-all, "점검" split into "점 / 검" at a line end. Only under
    /// lang="ko" — Japanese and Chinese have no spaces, so keep-all would leave
    /// them no break points at all. A token longer than the column (a URL, an
    /// identifier) still wraps instead of running past the margin;
    /// break-word, unlike anywhere, leaves table min-widths alone.
    static let textWrappingCSS = """
        html:lang(ko) body { word-break: keep-all; }
        body { overflow-wrap: break-word; }
        .footnotes { margin-top: 2.5em; padding-top: 0.8em; border-top: 1px solid var(--border-color, rgba(128, 128, 128, 0.3)); font-size: 0.88em; }
        .footnote-ref { line-height: 0; }
        .footnote-ref a, .footnote-backref { text-decoration: none; }
        [id^="fn-"], [id^="fnref-"] { scroll-margin-top: 1.5em; }
        """

    /// "ko" when the rendered text is Korean (Hangul syllables and no kana),
    /// which turns on the Korean line breaking above.
    static func documentLanguage(of body: String) -> String? {
        var hasHangul = false
        for scalar in body.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3: hasHangul = true
            case 0x3040...0x30FF: return nil
            default: continue
            }
        }
        return hasHangul ? "ko" : nil
    }

    /// The KaTeX auto-render options of a page's math pass (and the live
    /// page's patches): each `.cmdmd-math` span holds one formula.
    static let katexOptions = #"{delimiters: [{left: '$$', right: '$$', display: true}, {left: '\\[', right: '\\]', display: true}, {left: '\\(', right: '\\)', display: false}, {left: '$', right: '$', display: false}], throwOnError: false}"#
    /// What highlight.js colors (minus Mermaid sources): labelled blocks.
    static let highlightTargets = #"pre code[class^="language-"]"#

    private func wrapWithHTML(body rendered: RenderedBody, options: MarkdownRenderOptions, nonce: String) -> RenderedPage {
        let body = rendered.html
        // Only labelled blocks are highlighted; a page whose code is all
        // unlabelled doesn't load highlight.js at all.
        let hasCode = utf8Contains(body, "<pre><code class=\"language-")
        let libraries = Libraries(origin: options.libraries)
        var scriptURLs: [String] = []

        // Pele (~700 KB) only on pages with a diagram, loaded once the text is
        // up. Without it (not installed) the source stays a code block.
        var diagramCSS = ""
        var diagramIncludes = ""
        if options.enableMermaid, utf8Contains(body, HTMLVisitor.diagramOpening), let diagrams = libraries.diagrams {
            scriptURLs += diagrams.scripts.map(\.url)
            diagramCSS = PreviewStyles.diagram(for: options.theme)
            diagramIncludes = self.diagramIncludes(diagrams, theme: options.theme, nonce: nonce)
        }

        // Gate KaTeX on actual math markers (like diagrams/hljs) — loading
        // four resources plus a whole-body DOM scan on every math-free note
        // added latency to each debounced reload. Every masked math region
        // comes back as a `cmdmd-math` span, and only those spans are
        // rendered: a prose `$` (a price) is never math.
        let hasMath = utf8Contains(body, "class='cmdmd-math'")
        var includesKaTeX = false
        var katexIncludes = ""
        // Deferred scripts run before DOMContentLoaded, so the nonce'd listener
        // replaces auto-render's former onload= attribute (inline handlers are
        // outside the CSP).
        if options.enableKaTeX, hasMath, let css = libraries.katexCSS, let katex = libraries.katex,
           let mhchem = libraries.katexMhchem, let autoRender = libraries.katexAutoRender {
            scriptURLs += [katex.url, mhchem.url, autoRender.url]
            includesKaTeX = true
            katexIncludes = """
            \(stylesheetTag(css))
            \(scriptTag(katex, nonce: nonce, deferred: true))
            \(scriptTag(mhchem, nonce: nonce, deferred: true))
            \(scriptTag(autoRender, nonce: nonce, deferred: true))
            <script nonce="\(nonce)">
                document.addEventListener('DOMContentLoaded', function() {
                    if (typeof renderMathInElement === 'undefined') return;
                    document.querySelectorAll('.cmdmd-math').forEach(function(el) {
                        renderMathInElement(el, \(Self.katexOptions));
                    });
                });
            </script>
            """
        }

        var highlightIncludes = ""
        let codeTheme = libraries.codeTheme(options.preview.codeBlockTheme)
        if options.enableCodeHighlight, hasCode, let highlight = libraries.highlight {
            scriptURLs.append(highlight.url)
            highlightIncludes = hljsIncludes(highlight, theme: codeTheme, libraries: libraries, nonce: nonce)
        }
        // The default code theme ("github", shown as Auto) is the page
        // theme's own token palette: no stylesheet, follows light/dark
        // and Dark Pro's always-dark. A named highlight.js theme brings its
        // own background, so its block fills the <pre> edge to edge (one box).
        let highlightBoxCSS = highlightIncludes.isEmpty ? "" : codeTheme == "github"
            ? PreviewStyles.syntaxPalette
            : PreviewStyles.namedCodeThemeBox

        let runtimeScript = options.interactiveTasks ? "<script nonce=\"\(nonce)\">\(PreviewRuntime.script)</script>" : ""

        // PDF export prints once this posts: after the DOMContentLoaded passes
        // above (highlighting, math), every diagram and the fonts in use.
        let renderedScript = options.reportsRendered ? """
            <script nonce="\(nonce)">
                document.addEventListener('DOMContentLoaded', function() {
                    Promise.all([window.cmdmdDiagrams, document.fonts.ready]).then(function() {
                        window.webkit.messageHandlers.\(Self.renderedMessage).postMessage('rendered');
                    });
                });
            </script>
            """ : ""

        let language = Self.documentLanguage(of: body)
        let langAttribute = language.map { " lang=\"\($0)\"" } ?? ""
        let callouts = PreviewStyles.callouts(in: body)

        let head = """
        <!DOCTYPE html>
        <html\(langAttribute)>
        <head>
            <meta charset="UTF-8">
            <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(nonce: nonce, scriptURLs: scriptURLs, options: options))">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta name="color-scheme" content="light dark">
            <style>
                :root { color-scheme: light dark; }
                \(PreviewStyles.base)
                \(options.theme.css)
                \(Self.textWrappingCSS)\(options.interactiveTasks ? "\n" + PreviewRuntime.rootCSS : "")
                \(callouts)
                \(diagramCSS)
                \(highlightBoxCSS)
                \(includesKaTeX ? PreviewStyles.math : "")
                \(settingsOverrideCSS(options.preview))
            </style>
            \(highlightIncludes)
            \(katexIncludes)
            \(diagramIncludes)
            \(runtimeScript)
            \(renderedScript)
        </head>
        <body class="markdown-body">
        """
        var html = head + "\n    "
        var blocks: [Range<Int>]?
        if options.interactiveTasks {
            // The note in a box of its own (no layout box), so what scripts
            // add to <body> stays out of the blocks a patch counts.
            html += PreviewRuntime.rootOpening
            if let coalesced = PreviewBlocks.coalesce(body, ranges: rendered.blockRanges) {
                let index = { body.utf8.index(body.startIndex, offsetBy: $0) }
                var marked: [Range<Int>] = []
                for block in coalesced {
                    html += PreviewRuntime.marker
                    let start = html.utf8.count
                    html += body[index(block.lowerBound)..<index(block.upperBound)]
                    marked.append(start..<html.utf8.count)
                }
                blocks = marked
            } else {
                html += body
            }
            html += PreviewRuntime.rootClosing
        } else {
            html += body
        }
        html += "\n</body>\n</html>"
        return RenderedPage(
            html: html, blocks: blocks, taskLines: rendered.taskLines,
            head: PageHead(scripts: scriptURLs, callouts: callouts), language: language, nonce: nonce
        )
    }

    /// User-tunable typography from Settings → Preview. Emitted AFTER the theme
    /// CSS so it wins the cascade; custom CSS comes last and wins over everything.
    private func settingsOverrideCSS(_ p: PreviewSettings) -> String {
        let scale = max(0.5, p.headingScale)

        let headingColorRule = p.effectiveHeadingColor.map {
            "h1, h2, h3, h4, h5, h6 { color: \(htmlEscape($0)); }"
        } ?? ""

        // 장평 (horizontal glyph scale). CSS has no reflow-safe width property for
        // non-variable fonts, so scaleX the text blocks (tables/code/images keep
        // normal width). Only emitted when changed, so the default is a true no-op.
        // Leaf blocks only: list, quote and callout text is all in a <p>, so
        // scaling li/blockquote too scaled it twice (or more when nested).
        // The width (border box, padding included) is divided by the scale, so
        // the scaled box spans the column exactly: no overflow above 100%, no
        // ragged gap below it.
        let charWidth = String(format: "%.3f", p.charWidth)
        let charWidthRule = abs(p.charWidth - 1.0) > 0.001 ? """
        .markdown-body p,
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
            transform: scaleX(\(charWidth));
            transform-origin: left center;
            box-sizing: border-box;
            width: calc(100% / \(charWidth));
        }
        """ : ""

        // Prose spacing stays out of code (where wider spaces break column
        // alignment), math and diagrams. Only emitted when changed.
        let spacingResetRule = abs(p.letterSpacing) > 0.0001 || abs(p.wordSpacing) > 0.0001 ? """
        .markdown-body pre, .markdown-body code, .markdown-body .katex, .markdown-body .cmdmd-diagram {
            letter-spacing: normal;
            word-spacing: normal;
        }
        """ : ""

        // Only values moved off PreviewSettings' defaults are emitted, so each
        // theme's own typography (Sepia's 18px Iowan, Minimal's 17px,
        // Newsprint's Georgia) shows until the user tunes it. The default
        // font choice ("system-ui", shown as "Theme default") is the theme's.
        // Tuned values go through the theme's tokens, so components that
        // derive from them (headings, measure) follow.
        let d = PreviewSettings()
        func differs(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.0001 }
        var rootVars: [String] = []
        var bodyDecls: [String] = []
        if p.fontFamily != d.fontFamily {
            let stack = Self.previewFontStack(p.fontFamily)
            rootVars.append("--font-body: \(stack); --font-heading: \(stack);")
        }
        if differs(p.fontSize, d.fontSize) { rootVars.append("--fs: \(Int(p.fontSize))px;") }
        if differs(p.lineHeight, d.lineHeight) { let lh = String(format: "%.2f", p.lineHeight); rootVars.append("--lh: \(lh); --lh-ko: \(lh);") }
        if differs(p.maxWidth, d.maxWidth) { rootVars.append("--measure: \(Int(p.maxWidth))px;") }
        if differs(p.headingScale, d.headingScale) { rootVars.append("--hs: \(String(format: "%.3f", scale));") }
        if differs(p.headingMarginTop, d.headingMarginTop) { rootVars.append("--heading-mt: \(Int(p.headingMarginTop))px;") }
        if differs(p.headingMarginBottom, d.headingMarginBottom) { rootVars.append("--heading-mb: \(Int(p.headingMarginBottom))px;") }
        if differs(p.letterSpacing, d.letterSpacing) { bodyDecls.append("letter-spacing: \(String(format: "%.3f", p.letterSpacing))em;") }
        if differs(p.wordSpacing, d.wordSpacing) { bodyDecls.append("word-spacing: \(String(format: "%.3f", p.wordSpacing))em;") }

        // A theme's token block sits in `:root` (and its dark media query),
        // so the user's values need the higher-specificity `html:root`.
        return """
        \(rootVars.isEmpty ? "" : "html:root { \(rootVars.joined(separator: " ")) }")
        \(bodyDecls.isEmpty ? "" : "body { \(bodyDecls.joined(separator: " ")) }")
        \(spacingResetRule)
        \(headingColorRule)
        \(charWidthRule)
        \(p.customCSS)
        """
    }

    /// Settings' "SF Pro Text" and "Inter" fall back to the system font, not
    /// WebKit's generic sans-serif (Helvetica): the system font has no family
    /// name WebKit can reach, and Inter isn't part of macOS. Stored values
    /// are unchanged, so the picker still matches them.
    private static func previewFontStack(_ family: String) -> String {
        switch family {
        case "SF Pro Text, sans-serif": return "'SF Pro Text', -apple-system, BlinkMacSystemFont, sans-serif"
        case "Inter, sans-serif": return "Inter, -apple-system, BlinkMacSystemFont, sans-serif"
        default: return family
        }
    }

    /// Deferred like KaTeX: the script no longer holds up parsing (and first
    /// paint) of the note, and still runs before the DOMContentLoaded pass.
    private func hljsIncludes(_ highlight: LibraryResource, theme: String, libraries: Libraries, nonce: String) -> String {
        let styleLinks: [String]
        switch theme {
        case "github":
            // Auto: the theme's token palette (PreviewStyles.syntaxPalette).
            styleLinks = []
        default:
            styleLinks = [libraries.highlightTheme(theme).map { stylesheetTag($0) }].compactMap { $0 }
        }

        return """
        \(styleLinks.joined(separator: "\n"))
        \(scriptTag(highlight, nonce: nonce, deferred: true))
        <script nonce="\(nonce)">
            document.addEventListener('DOMContentLoaded', function() {
                if (typeof hljs === 'undefined') return;
                document.querySelectorAll('pre code[class^="language-"]').forEach(function(el) {
                    if (el.classList.contains('language-mermaid')) return;
                    hljs.highlightElement(el);
                });
            });
        </script>
        """
    }

    /// The name of the export view's message handler `reportsRendered` posts to.
    static let renderedMessage = "cmdmdRendered"

    private func diagramIncludes(_ diagrams: DiagramLibrary, theme: PreviewTheme, nonce: String) -> String {
        let head: String
        switch diagrams.head {
        case .linked(let css):
            head = stylesheetTag(css)
        case .inline(let bootstrap, let css):
            // A "</script" or "</style" in the text would end the element
            // early, and a "<!--" could keep a later one from ending it.
            let script = bootstrap
                .replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
                .replacingOccurrences(of: "<!--", with: "<\\!--")
            head = """
            <style>\(css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive))</style>
            <script nonce="\(nonce)">\(script)</script>
            """
        }
        let scripts = diagrams.scripts
            .map { "{src: '\($0.url)', integrity: '\($0.integrity ?? "")'}" }
            .joined(separator: ", ")
        return """
        \(head)
        <script nonce="\(nonce)">\(Self.diagramScript)([\(scripts)], '\(nonce)', '\(PreviewStyles.diagramScheme(for: theme))');</script>
        """
    }

    /// Draws every `.cmdmd-diagram` with cmds-pele (profile 'screen': no
    /// links or images in a note's diagram; `%% @caption` as a figure
    /// caption). Pele and the bootstrap load a task after DOMContentLoaded,
    /// so the text paints first, as scripts carrying the page nonce and
    /// their hashes. A diagram Pele can't draw goes back to its source, with
    /// Pele's reason under it; a failed load leaves every source showing.
    /// `window.cmdmdDiagrams` resolves once each has drawn or fallen back.
    private static let diagramScript = """
    (function (scripts, nonce, theme) {
        var root = document.documentElement;
        var resolve;
        window.cmdmdDiagrams = new Promise(function (r) { resolve = r; });
        root.classList.add('cmdmd-diagrams-pending');
        function settle() {
            root.classList.remove('cmdmd-diagrams-pending');
            resolve();
        }
        function showSource(diagram, source, error) {
            var host = diagram.querySelector('.cmds-pele');
            // onError can fire inside mount, before the instance is stored.
            Promise.resolve().then(function () { if (host && host.__cmdsPele) host.__cmdsPele.destroy(); });
            // A parse error is "Parse error on line N:", the line, a caret
            // and what was expected: the first and last lines say it.
            var lines = String((error && error.message) || error).split('\\n');
            var reason = lines.length > 1 ? lines[0] + ' ' + lines[lines.length - 1] : lines[0];
            var caption = document.createElement('p');
            caption.className = 'cmdmd-diagram-error';
            caption.textContent = 'Diagram error: ' + reason.slice(0, 200);
            diagram.classList.add('cmdmd-diagram-failed');
            diagram.replaceChildren(source, caption);
        }
        // Calls `done` once the diagram is drawn or its source is back.
        function draw(diagram, done) {
            var source = diagram.querySelector('pre.mermaid');
            var finished = false;
            function finish(error) {
                if (finished) return;
                finished = true;
                if (error) showSource(diagram, source, error);
                done();
            }
            try {
                var mounted = cmdsPele.mountAll(diagram, {
                    // A caption line after the fence wins over `%% @caption`.
                    profile: 'screen', theme: theme, figure: !source.hasAttribute('data-captioned'),
                    onRender: function () { finish(); },
                    onError: function (e) { finish(e || 'unknown error'); }
                });
                if (!mounted.length) finish();
            } catch (e) {
                finish(e);
            }
        }
        var drawn = false;
        function mount() {
            var diagrams = document.querySelectorAll('.cmdmd-diagram');
            var left = diagrams.length;
            if (!window.pele || !window.cmdsPele || !left) return settle();
            drawn = true;
            Array.prototype.forEach.call(diagrams, function (diagram) {
                draw(diagram, function () { if (--left === 0) settle(); });
            });
        }
        document.addEventListener('DOMContentLoaded', function () {
            // The live preview's patches: the diagrams they bring draw as
            // they come in (Pele draws in the call), once these have (before
            // that, mount finds them); the ones they remove let go of Pele.
            if (window.cmdmdPreview) window.cmdmdPreview.diagrams = {
                draw: function (diagrams) {
                    if (drawn) diagrams.forEach(function (diagram) { draw(diagram, function () {}); });
                },
                drop: function (diagrams) {
                    diagrams.forEach(function (diagram) {
                        var host = diagram.querySelector('.cmds-pele');
                        if (host && host.__cmdsPele) host.__cmdsPele.destroy();
                    });
                }
            };
            setTimeout(function () {
                scripts.forEach(function (file, i) {
                    var script = document.createElement('script');
                    script.src = file.src;
                    script.integrity = file.integrity;
                    script.crossOrigin = 'anonymous';
                    script.nonce = nonce;
                    script.async = false;   // in order: the bootstrap needs Pele
                    script.onerror = settle;
                    if (i === scripts.length - 1) script.onload = mount;
                    document.head.appendChild(script);
                });
            }, 0);
        });
    })
    """

}

// MARK: - HTML Visitor

/// A raw HTML piece compared and hashed by its UTF-8 bytes. String equality
/// is canonical equivalence: an NFD `title="café"` got its NFC twin's bytes.
private struct RawHTMLKey: Hashable {
    let html: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.html.utf8.elementsEqual(rhs.html.utf8)
    }

    func hash(into hasher: inout Hasher) {
        if html.utf8.withContiguousStorageIfAvailable({ hasher.combine(bytes: UnsafeRawBufferPointer($0)) }) == nil {
            Array(html.utf8).withUnsafeBytes { hasher.combine(bytes: $0) }
        }
    }
}

struct HTMLVisitor: MarkupVisitor {
    /// Every visit appends to `out`: returning a String per node, joined by
    /// its parent, copied a block's HTML once per level it sat under.
    typealias Result = Void

    /// What marks a page as having a diagram (see `visitCodeBlock`).
    static let diagramOpening = "<div class=\"cmdmd-diagram\">"

    var renderMermaid: Bool
    /// The diagram being visited has its caption line right after it.
    private var diagramCaptioned = false
    var taskQueue: TaskLineQueue
    /// Swaps math placeholders back for their `$…$` source. Math is masked
    /// before the parse, so heading text still carries the placeholders.
    var restoreMath: (String) -> String = { $0 }
    /// Obsidian callouts are recognized on the PARSED block quote (`> [!type]
    /// title` as its first line), so their body is ordinary Markdown in the
    /// one document: fences with blank lines, nested callouts, lazy lines,
    /// math, mermaid and callouts inside lists all behave as in a quote.
    var renderCallouts: Bool = true
    /// A single newline inside a paragraph: "\n" (CommonMark, GitHub files)
    /// or "<br />\n" (Obsidian's reading view with strict line breaks off).
    var softBreak: String = "\n"
    /// GFM extended autolinks: a bare `https://…` or `www.…` becomes a link.
    var autolinkBareURLs: Bool = true

    private var slugger = HeadingSlugger()
    /// Headings the TOC (a scan of `#` lines) never lists — quoted, on a list
    /// marker's line, setext — must not advance the document's slug
    /// sequence, and must not take an id the TOC links to: they get theirs
    /// from this slugger, which reserves every TOC-sequence id.
    private var nestedSlugger: HeadingSlugger?
    private var quoteDepth = 0
    private var linkDepth = 0
    private var out = ""
    /// Raw HTML repeats (the renderer's own `<mark>`, `</a>`, `</span>`, the
    /// same wiki link): sanitizing is pure, so each distinct piece is cleaned
    /// once per render.
    private var sanitized: [RawHTMLKey: String] = [:]
    /// Each top-level block's UTF-8 byte range in the last `render`'s HTML.
    private(set) var blockRanges: [Range<Int>] = []

    init(renderMermaid: Bool = true, taskQueue: TaskLineQueue = TaskLineQueue(lines: [])) {
        self.renderMermaid = renderMermaid
        self.taskQueue = taskQueue
    }

    /// The HTML of `markup` (the document, or any node).
    mutating func render(_ markup: Markup, capacityHint: Int = 0) -> String {
        out = ""
        out.reserveCapacity(capacityHint)
        blockRanges = []
        visit(markup)
        let html = out
        out = ""
        return html
    }

    private mutating func visitChildren(_ markup: Markup) {
        for child in markup.children { visit(child) }
    }

    mutating func defaultVisit(_ markup: Markup) {
        visitChildren(markup)
    }

    mutating func visitDocument(_ document: Document) {
        var blocks = document.children.makeIterator()
        var next = blocks.next()
        while let block = next {
            next = blocks.next()
            let start = out.utf8.count
            if renderMermaid, let fence = block as? CodeBlock, Self.isDiagram(fence),
               let caption = next as? Paragraph, Self.isCaption(caption) {
                // cmds-pele's caption rule: the italic line after the fence
                // is the caption, `%% @caption` only stands in without one
                // (the line is what Obsidian shows). Marked on both blocks,
                // so a live page redraws the diagram when the line comes or goes.
                diagramCaptioned = true
                visit(fence)
                diagramCaptioned = false
                blockRanges.append(start..<out.utf8.count)
                next = blocks.next()
                let captionStart = out.utf8.count
                out += "<p class=\"cmdmd-diagram-caption\">"
                visitInline(caption.children)
                out += "</p>\n"
                blockRanges.append(captionStart..<out.utf8.count)
                continue
            }
            visit(block)
            blockRanges.append(start..<out.utf8.count)
        }
    }

    private static func isDiagram(_ fence: CodeBlock) -> Bool {
        codeLanguage(fence.language).lowercased() == "mermaid"
    }

    /// A paragraph that is one italic run: `*Figure 1. …*`.
    private static func isCaption(_ paragraph: Paragraph) -> Bool {
        paragraph.childCount == 1 && paragraph.child(at: 0) is Emphasis
    }

    // MARK: Inline content

    /// An inline container's children. cmark splits a run of text at `_`,
    /// `&`, `[`, `!`… into several Text nodes; they are joined first so a bare
    /// URL is seen whole. `droppingPrefix` removes that many characters from
    /// the start of the leading text (a quoted task's `[ ] ` marker).
    private mutating func visitInline<S: Sequence>(_ nodes: S, droppingPrefix: Int = 0) where S.Element == Markup {
        var text = ""
        var drop = droppingPrefix
        for node in nodes {
            if let piece = node as? Text {
                text += piece.string
                continue
            }
            if !text.isEmpty || drop > 0 {
                appendText(String(text.dropFirst(drop)))
                drop = 0
                text = ""
            }
            visit(node)
        }
        if !text.isEmpty {
            appendText(String(text.dropFirst(drop)))
        }
    }

    private mutating func appendText(_ text: String) {
        let text = stripFlankingJoiners(text)
        out += autolinkBareURLs && linkDepth == 0 ? BareURLLinker.html(for: text) : htmlEscape(text)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        out += "<p>"
        visitInline(paragraph.children)
        out += "</p>\n"
    }

    mutating func visitText(_ text: Text) {
        appendText(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        out += "<em>"
        visitInline(emphasis.children)
        out += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        out += "<strong>"
        visitInline(strong.children)
        out += "</strong>"
    }

    /// GFM also strikes `~single~` tildes; Obsidian only `~~double~~`. Korean
    /// prose uses `~` for ranges ("1~2시간, 3~4일"), which struck out the text
    /// between two ranges. A single-tilde run renders as the literal text.
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        var singleTilde = false
        if let outer = strikethrough.range?.lowerBound,
           let first = strikethrough.child(at: 0)?.range?.lowerBound {
            singleTilde = outer.line == first.line && first.column - outer.column == 1
        }
        out += singleTilde ? "~" : "<del>"
        visitInline(strikethrough.children)
        out += singleTilde ? "~" : "</del>"
    }

    mutating func visitHeading(_ heading: Heading) {
        let level = heading.level
        // Slug from the heading's visible text via the shared, Unicode-aware,
        // deduplicating slugger so non-ASCII and duplicate headings each get a
        // usable anchor id that matches the TOC. Math is slugged from its
        // `$…$` source, not its placeholder, as the TOC slugs it.
        let text = restoreMath(headingVisibleText(heading))
        let id: String
        if Self.isInTOCSequence(heading) {
            id = slugger.slug(for: text)
        } else {
            if nestedSlugger == nil { nestedSlugger = reservingTOCSlugs(heading.root) }
            id = nestedSlugger!.slug(for: text)
        }
        out += "<h\(level) id=\"\(id)\">"
        visitInline(heading.children)
        out += "</h\(level)>\n"
    }

    /// Exactly the headings `TOCBuilder` lists: ATX headings whose source
    /// line starts (after indentation) with `#`. Not one in a quote or
    /// callout (`> ## x`), on a list marker's line (`- ## x`), or setext.
    static func isInTOCSequence(_ heading: Heading) -> Bool {
        guard let range = heading.range, range.lowerBound.line == range.upperBound.line else { return false }
        var node = heading.parent
        while let ancestor = node {
            if ancestor is BlockQuote { return false }
            if ancestor is ListItem, ancestor.range?.lowerBound.line == range.lowerBound.line { return false }
            node = ancestor.parent
        }
        return true
    }

    /// A slugger whose reserved set is every id the TOC sequence hands out.
    private func reservingTOCSlugs(_ root: Markup) -> HeadingSlugger {
        var sequence = HeadingSlugger()
        var reserved: Set<String> = []
        func walk(_ markup: Markup) {
            if let heading = markup as? Heading {
                if Self.isInTOCSequence(heading) { reserved.insert(sequence.slug(for: restoreMath(headingVisibleText(heading)))) }
                return
            }
            for child in markup.children { walk(child) }
        }
        walk(root)
        var nested = HeadingSlugger()
        nested.reserved = reserved
        return nested
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let lang = Self.codeLanguage(codeBlock.language)
        let code = codeBlock.code

        // Mermaid syntax, drawn by Pele (cmds-pele mounts `pre.mermaid`). Escaped
        // too: the text node holds the exact source Pele parses, and
        // `<script>` can't break out of the container. Until Pele draws it, or
        // if it can't, the source shows as a code block.
        if renderMermaid, Self.isDiagram(codeBlock) {
            out += Self.diagramOpening
            out += diagramCaptioned ? "<pre class=\"mermaid\" data-captioned>" : "<pre class=\"mermaid\">"
            out += htmlEscape(code)
            out += "</pre></div>\n"
            return
        }

        // No language, no class: highlight.js only colors labelled blocks.
        // An unlabelled block went through auto-detection (every grammar, per
        // block) and plain text came out colored as some language.
        out += lang.isEmpty ? "<pre><code>" : "<pre><code class=\"language-\(htmlEscape(lang))\">"
        out += htmlEscape(code)
        out += "</code></pre>\n"
    }

    /// The info string's first word (CommonMark): "swift title=x" → swift,
    /// pandoc's "{.python}" → python.
    static func codeLanguage(_ info: String?) -> String {
        guard let info else { return "" }
        let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard word.hasPrefix("{") else { return word }
        return word.trimmingCharacters(in: CharacterSet(charactersIn: "{.}"))
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        out += "<code>"
        out += htmlEscape(inlineCode.code)
        out += "</code>"
    }

    /// Raw HTML (the note's own, and the wiki-link/tag markup the renderer
    /// injects before parsing) passes through minus anything that could run
    /// script — backup for the page CSP.
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        out += sanitize(inlineHTML.rawHTML)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        out += sanitize(html.rawHTML)
    }

    private mutating func sanitize(_ raw: String) -> String {
        let key = RawHTMLKey(html: raw)
        if let clean = sanitized[key] { return clean }
        let clean = RawHTMLSanitizer.sanitize(raw)
        sanitized[key] = clean
        return clean
    }

    mutating func visitLink(_ link: Link) {
        out += "<a href=\""
        out += sanitizeURL(link.destination ?? "")
        out += "\""
        if let title = link.title {
            out += " title=\"\(htmlEscape(title))\""
        }
        out += ">"
        linkDepth += 1
        visitInline(link.children)
        linkDepth -= 1
        out += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        let src = sanitizeURL(image.source ?? "")
        var altText = stripFlankingJoiners(image.plainText)
        // Obsidian sizes a Markdown image from its alt text: `![x|300](u)`,
        // `![|300x200](u)` (as `![[x.png|300]]`).
        var size = ""
        if let bar = altText.lastIndex(of: "|") {
            let parts = altText[altText.index(after: bar)...].split(separator: "x", omittingEmptySubsequences: false)
            if (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 5 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) {
                size = " width=\"\(parts[0])\"" + (parts.count == 2 ? " height=\"\(parts[1])\"" : "")
                altText = String(altText[..<bar]).trimmingCharacters(in: .whitespaces)
            }
        }
        let title = image.title.map { " title=\"\(htmlEscape($0))\"" } ?? ""
        out += "<img src=\"\(src)\" alt=\"\(htmlEscape(altText))\"\(title)\(size) />"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        out += self.softBreak
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        out += "<br />\n"
    }

    // MARK: Lists

    /// Tight lists (no blank line between items or inside one) carry no
    /// class; their item paragraphs sit flush (`li > p { margin: 0 }`). Loose
    /// lists keep paragraph spacing. Item text stays in a <p> either way, so
    /// the 장평 scaleX rule keeps scaling each text block exactly once.
    mutating func visitUnorderedList(_ list: UnorderedList) {
        out += "<ul\(Self.listClass(list))>\n"
        visitChildren(list)
        out += "</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        out += "<ol\(start)\(Self.listClass(list))>\n"
        visitChildren(list)
        out += "</ol>\n"
    }

    private static func listClass(_ list: Markup) -> String {
        isLoose(list) ? " class=\"loose\"" : ""
    }

    /// CommonMark: a list is loose when a blank line separates two of its
    /// items, or two blocks directly inside one item. Blank lines inside a
    /// nested list or a fence don't count; neither do trailing ones. Read off
    /// the source lines between sibling blocks.
    static func isLoose(_ list: Markup) -> Bool {
        var previousItemEnd: Int?
        for item in list.children {
            // Between items: from the previous item's last block to this
            // item's marker line (an empty item `- [ ]` has no blocks).
            if let start = item.range?.lowerBound.line, let end = previousItemEnd, start > end + 1 { return true }
            var childEnd: Int?
            for child in item.children {
                guard let range = child.range else { continue }
                if let end = childEnd, range.lowerBound.line > end + 1 { return true }
                childEnd = range.upperBound.line
            }
            previousItemEnd = childEnd ?? item.range?.lowerBound.line
        }
        return false
    }

    mutating func visitListItem(_ item: ListItem) {
        var checkbox = ""
        var markerLength = 0
        switch item.checkbox {
        case .checked, .unchecked:
            let checked = item.checkbox == .checked ? " checked" : ""
            if let ordinal = taskQueue.next() {
                // Live checkbox: clicking it posts its ordinal back to the app,
                // which flips `[ ]`/`[x]` on its line (`RenderedBody.taskLines`).
                // Not the line itself: Enter above a task would change every
                // later block, and a live page patches only the changed ones.
                checkbox = "<input type=\"checkbox\"\(checked) data-task=\"\(ordinal)\" />"
            } else {
                checkbox = "<input type=\"checkbox\"\(checked) disabled />"
            }
        case .none:
            // cmark-gfm doesn't see `[ ]` items inside a block quote (callouts
            // included), and neither does the task scan, so these are shown
            // read-only and never take a queue line.
            if quoteDepth > 0, let checked = Self.quotedTaskMarker(item) {
                checkbox = "<input type=\"checkbox\"\(checked ? " checked" : "") disabled />"
                markerLength = 4
            }
        }

        out += checkbox.isEmpty ? "<li>" : "<li class=\"task-list-item\">"
        var pending = checkbox
        for child in item.children {
            // The box goes INSIDE the first paragraph, on the text's line
            // (GitHub's markup); before it, a block <p> pushed the text below.
            if let paragraph = child as? Paragraph, !pending.isEmpty {
                out += "<p>\(pending) "
                visitInline(paragraph.children, droppingPrefix: markerLength)
                out += "</p>\n"
            } else {
                out += pending
                visit(child)
            }
            pending = ""
        }
        out += pending
        out += "</li>\n"
    }

    private static func quotedTaskMarker(_ item: ListItem) -> Bool? {
        guard let paragraph = item.child(at: 0) as? Paragraph,
              let text = paragraph.child(at: 0) as? Text else { return nil }
        if text.string.hasPrefix("[ ] ") { return false }
        if text.string.hasPrefix("[x] ") || text.string.hasPrefix("[X] ") { return true }
        return nil
    }

    // MARK: Quotes and callouts

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        quoteDepth += 1
        defer { quoteDepth -= 1 }
        if renderCallouts, let callout = Callout(blockQuote) {
            renderCallout(callout, blockQuote)
            return
        }
        out += "<blockquote>\n"
        visitChildren(blockQuote)
        out += "</blockquote>\n"
    }

    private mutating func renderCallout(_ callout: Callout, _ blockQuote: BlockQuote) {
        let type = htmlEscape(callout.type)
        if let open = callout.foldedOpen {
            out += "<details class=\"callout callout-\(type)\"\(open ? " open" : "")><summary>"
        } else {
            out += "<div class=\"callout callout-\(type)\"><div class=\"callout-header\">"
        }
        out += "<span class=\"callout-icon\">\(Callout.icon(for: callout.type))</span> <span class=\"callout-title\">"
        let titleStart = out.utf8.count
        out += htmlEscape(callout.titleText)
        visitInline(callout.titleNodes)
        let title = out.utf8.index(out.utf8.startIndex, offsetBy: titleStart)
        if out[title...].trimmingCharacters(in: .whitespaces).isEmpty {
            // `> [!abstract]` alone: Obsidian titles it with the type.
            out.removeSubrange(title...)
            out += htmlEscape(callout.type.prefix(1).uppercased() + callout.type.dropFirst())
        }
        out += callout.foldedOpen == nil ? "</span></div>\n" : "</span></summary>\n"
        out += "<div class=\"callout-content\">\n"
        if !callout.bodyNodes.isEmpty {
            out += "<p>"
            visitInline(callout.bodyNodes)
            out += "</p>\n"
        }
        for child in blockQuote.children.dropFirst() { visit(child) }
        out += callout.foldedOpen == nil ? "</div></div>\n" : "</div></details>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        out += "<hr />\n"
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) {
        let alignments = table.columnAlignments.map { alignment -> String in
            switch alignment {
            // `align` (cmark-gfm's own output) holds outside this page too;
            // the shared CSS makes it beat the themes' `th, td` alignment.
            case .left: return " align=\"left\""
            case .center: return " align=\"center\""
            case .right: return " align=\"right\""
            case nil: return ""
            }
        }
        // The wrapper scrolls a table wider than the page inside its own box;
        // before, a 20-column table or a long URL in a cell pushed the whole
        // page past the viewport (and CMDS clipped it at the rounded edge).
        out += "<div class=\"table-scroll\"><table>\n<thead>\n<tr>"
        visitCells(table.head.cells, tag: "th", alignments)
        out += "</tr>\n</thead>\n"
        let rows = Array(table.body.rows)
        if !rows.isEmpty {
            out += "<tbody>\n"
            for row in rows {
                out += "<tr>"
                visitCells(row.cells, tag: "td", alignments)
                out += "</tr>\n"
            }
            out += "</tbody>\n"
        }
        out += "</table></div>\n"
    }

    private mutating func visitCells<S: Sequence>(_ row: S, tag: String, _ alignments: [String]) where S.Element == Table.Cell {
        for (column, cell) in row.enumerated() {
            let align = column < alignments.count ? alignments[column] : ""
            out += "<\(tag)\(align)>"
            visitInline(cell.children)
            out += "</\(tag)>"
        }
    }
}

/// An Obsidian callout: a block quote whose first line is `[!type]`, an
/// optional fold marker (`+` open, `-` closed) and an optional title.
struct Callout {
    let type: String
    /// nil: not foldable; else whether it starts open.
    let foldedOpen: Bool?
    /// The title's leading plain text (after the marker) …
    let titleText: String
    /// … and the rest of the first line (links, emphasis, code).
    let titleNodes: [Markup]
    /// The first paragraph's remaining lines: the callout's first body lines.
    let bodyNodes: [Markup]

    private static let marker = try! NSRegularExpression(pattern: #"^\[!([^\]\s]+)\]([+-])?[ \t]*"#)

    init?(_ blockQuote: BlockQuote) {
        guard let first = blockQuote.child(at: 0) as? Paragraph else { return nil }
        let inlines = Array(first.children)
        var leading = ""
        var index = 0
        while index < inlines.count, let text = inlines[index] as? Text {
            leading += text.string
            index += 1
        }
        let ns = leading as NSString
        guard let match = Self.marker.firstMatch(in: leading, range: NSRange(location: 0, length: ns.length)) else { return nil }
        type = ns.substring(with: match.range(at: 1)).lowercased()
        foldedOpen = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2)) == "+"
        titleText = ns.substring(from: NSMaxRange(match.range))

        var rest = inlines[index...]
        var title: [Markup] = []
        while let node = rest.first, !(node is SoftBreak || node is LineBreak) {
            title.append(node)
            rest = rest.dropFirst()
        }
        titleNodes = title
        bodyNodes = Array(rest.dropFirst())
    }

    static func icon(for type: String) -> String {
        switch type {
        case "note": return "📝"
        case "abstract", "summary", "tldr": return "📋"
        case "info": return "ℹ️"
        case "todo": return "☑️"
        case "tip", "hint", "important": return "💡"
        case "success", "check", "done": return "✅"
        case "question", "help", "faq": return "❓"
        case "warning", "caution", "attention": return "⚠️"
        case "failure", "fail", "missing": return "❌"
        case "danger", "error": return "🚨"
        case "bug": return "🐛"
        case "example": return "📖"
        case "quote", "cite": return "💬"
        default: return "📌"
        }
    }
}

/// GFM extended autolinks for text runs: `https://…`, `http://…` and
/// `www.…`, with GFM's trailing-punctuation and unbalanced-paren trimming.
enum BareURLLinker {
    private static let candidate = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9/.@+\-])(?:https?://|www\.)[^\s<>"'`]+"#,
        options: [.caseInsensitive]
    )
    /// Never part of a URL: CJK punctuation and brackets that follow one.
    private static let stoppers = Set("。、，．：；！？）」』】〉》〕")
    private static let trailing = Set("?!.,:*_~'\";")

    static func html(for text: String) -> String {
        guard utf8Contains(text, "://") || utf8Contains(text, "www.") else { return htmlEscape(text) }
        let ns = text as NSString
        let matches = candidate.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return htmlEscape(text) }

        var html = ""
        var cursor = 0
        for match in matches {
            var url = ns.substring(with: match.range)
            if let stop = url.firstIndex(where: stoppers.contains) { url = String(url[..<stop]) }
            url = trimmed(url)
            guard isLinkable(url) else { continue }
            html += htmlEscape(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let href = url.lowercased().hasPrefix("www.") ? "http://" + url : url
            html += "<a href=\"\(sanitizeURL(href))\">\(htmlEscape(url))</a>"
            cursor = match.range.location + (url as NSString).length
        }
        html += htmlEscape(ns.substring(from: cursor))
        return html
    }

    private static func trimmed(_ url: String) -> String {
        var url = Substring(url)
        while let last = url.last {
            if trailing.contains(last) {
                url = url.dropLast()
            } else if last == ")", url.filter({ $0 == ")" }).count > url.filter({ $0 == "(" }).count {
                url = url.dropLast()
            } else {
                break
            }
        }
        return String(url)
    }

    /// A host after the scheme, and a dotted domain after `www.`.
    private static func isLinkable(_ url: String) -> Bool {
        let afterScheme = url.range(of: "://").map { url[$0.upperBound...] } ?? Substring(url)
        let host = afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || "-._:".contains($0) }) else { return false }
        return true
    }
}

// MARK: - Preview Themes

enum PreviewTheme: String, CaseIterable, Codable {
    case github = "GitHub"
    case obsidian = "Obsidian"
    case minimal = "Minimal"
    case cmds = "CMDS"
    case sepia = "Sepia"
    case newsprint = "Newsprint"
    case darkPro = "Dark Pro"

    /// Token block + signature rules; the shared base lives in PreviewStyles.
    var css: String { PreviewStyles.css(for: self) }
}
