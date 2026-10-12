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
    case let text as Text: return text.string
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

    mutating func slug(for text: String) -> String {
        let base = markdownHeadingSlug(text)
        let n = counts[base, default: 0]
        counts[base] = n + 1
        return n == 0 ? base : "\(base)-\(n)"
    }
}

/// HTML-escapes document-derived text before it is interpolated into the preview
/// HTML. Prevents stored-XSS via crafted Markdown in the JS-enabled WebView.
func htmlEscape(_ string: String) -> String {
    var result = string
    result = result.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    result = result.replacingOccurrences(of: "\"", with: "&quot;")
    result = result.replacingOccurrences(of: "'", with: "&#39;")
    return result
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
    static func extractHeadings(from content: String, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> [TOCHeading] {
        var headings: [TOCHeading] = []
        var slugger = HeadingSlugger()
        var inFence = false
        var renderer: MarkdownRenderer?

        // Split on "\n" only (as the editor and toggleTask do): `.newlines`
        // counts a CRLF as two breaks, doubling every line number.
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
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
    /// Emit checkbox inputs that post task-toggle messages back to the app.
    /// On for the live preview, off for HTML/PDF export.
    var interactiveTasks: Bool = true
    /// Folders (besides the note's own) whose images may be shown. Non-nil
    /// rewrites local `<img>` sources inside them to the app's asset scheme —
    /// the preview and PDF views can't read file:// URLs. Nil (HTML export,
    /// clipboard) keeps note-relative sources so the file works elsewhere.
    var localAssetRoots: [URL]? = nil
}

// MARK: - Task line mapping

/// Maps rendered task checkboxes back to their source line numbers so clicking
/// a checkbox in the preview can toggle the right `- [ ]` in the document.
/// The visitor encounters task items in source order, so a simple queue works.
final class TaskLineQueue {
    private var lines: [Int]
    private var index = 0
    private var overdrawn = false

    init(lines: [Int]) {
        self.lines = lines
    }

    func next() -> Int? {
        guard index < lines.count else {
            overdrawn = true
            return nil
        }
        defer { index += 1 }
        return lines[index]
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

    private static let checkboxMarkerPattern = try! NSRegularExpression(pattern: #"\[[ xX]\]"#)

    /// Source lines of the ORIGINAL markdown's task items (before any
    /// transformation shifts lines), in the order the visitor meets them. Taken
    /// from the parsed document rather than a line regex, so it agrees with the
    /// renderer on every construct the parser decides: ~~~ and nested fences,
    /// indented code, raw HTML blocks, blockquotes (never checkboxes) and CRLF
    /// files (one line per CRLF, as toggleTask splits). Callout content is
    /// blockquoted here and rendered read-only, so it never takes a line.
    static func scan(_ markdown: String) -> [Int] {
        // Skip the parse for the common note without any `[ ]`/`[x]`.
        let ns = markdown as NSString
        guard checkboxMarkerPattern.firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)) != nil else {
            return []
        }
        var collector = TaskItemCollector()
        collector.visit(Document(parsing: markdown))
        return collector.lines
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

    private let calloutPattern = try! NSRegularExpression(
        pattern: #"^>\s*\[!(\w+)\]([+-])?\s*(.*)"#,
        options: [.anchorsMatchLines]
    )

    private let tagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)#("# + MarkdownDocument.tagNamePattern + ")",
        options: []
    )

    private let markPattern = try! NSRegularExpression(
        pattern: #"==([^=\n](?:[^=\n]*[^=\n])?)=="#,
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

    func renderToHTML(markdown: String, baseURL: URL? = nil, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> String {
        // Task-line scan runs against the untouched source, before any
        // transformation can shift line numbers.
        let taskQueue = TaskLineQueue(lines: options.interactiveTasks ? TaskLineQueue.scan(markdown) : [])

        // Mask fenced/inline code first so the wiki-link/callout/tag regex passes
        // don't rewrite Markdown-looking text INSIDE code (e.g. `#define`, `[[x]]`,
        // a leading `> [!note]` in a shell snippet).
        var (processedMarkdown, codeTokens) = maskCodeRegions(markdown)

        // Mask math next (code already protected) so `$a_b$` survives emphasis
        // parsing. Restored into the FINAL HTML, where KaTeX renders it in-DOM.
        var mathTokens: [String: String] = [:]
        if options.enableKaTeX {
            (processedMarkdown, mathTokens) = maskMathRegions(processedMarkdown)
        }

        if options.enableWikiLinks {
            processedMarkdown = processWikiLinks(processedMarkdown, baseURL: baseURL, codeTokens: codeTokens)
        }
        if options.enableCallouts {
            processedMarkdown = processCallouts(processedMarkdown, codeTokens: codeTokens)
        }
        if options.enableWikiLinks {
            processedMarkdown = processTags(processedMarkdown)
        }
        processedMarkdown = processHighlights(processedMarkdown)

        processedMarkdown = restoreCodeRegions(processedMarkdown, tokens: codeTokens)

        let document = Document(parsing: processedMarkdown)
        var htmlVisitor = HTMLVisitor(renderMermaid: options.enableMermaid, taskQueue: taskQueue)
        if !mathTokens.isEmpty {
            htmlVisitor.restoreMath = { [self] text in
                restoreRegions(in: text, tokens: mathTokens, matching: Self.mathTokenPattern, transform: { $0 })
            }
        }
        var htmlBody = htmlVisitor.visit(document)

        // The scan and this parse disagree about which items are tasks (e.g. a
        // list swallowed by an HTML block), so no line number can be trusted:
        // render every box read-only rather than toggle the wrong line.
        if options.interactiveTasks, !taskQueue.isFullyConsumed {
            var readOnlyVisitor = HTMLVisitor(renderMermaid: options.enableMermaid)
            readOnlyVisitor.restoreMath = htmlVisitor.restoreMath
            htmlBody = readOnlyVisitor.visit(document)
        }

        // Math placeholders come back as escaped literal `$...$` text in a
        // `cmdmd-math` span. KaTeX renders only those spans in-DOM, so a prose
        // dollar sign is never handed to it.
        htmlBody = restoreMathRegions(in: htmlBody, tokens: mathTokens)

        if let roots = options.localAssetRoots {
            htmlBody = LocalAssetURL.rewriteImageSources(in: htmlBody, baseURL: baseURL, roots: roots)
        }

        // Fresh per render: only scripts the renderer writes carry it, so the
        // CSP admits them and nothing a note smuggles in.
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return wrapWithHTML(body: htmlBody, options: options, nonce: nonce)
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
        var (processed, codeTokens) = maskCodeRegions("# " + headingText)
        var mathTokens: [String: String] = [:]
        if options.enableKaTeX {
            (processed, mathTokens) = maskMathRegions(processed)
        }
        if options.enableWikiLinks {
            processed = processTags(processWikiLinks(processed, baseURL: nil, codeTokens: codeTokens))
        }
        processed = restoreCodeRegions(processHighlights(processed), tokens: codeTokens)

        guard let heading = Document(parsing: processed).child(at: 0) as? Heading else { return headingText }
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
    private func maskCodeRegions(_ markdown: String) -> (String, [String: String]) {
        // Line-anchored fences (``` at the start of a line, optional indent) so a
        // stray inline ``` can't pair with a real fence and swallow content
        // between two separate code blocks.
        let fences = Self.fencedCodePattern.matches(
            in: markdown,
            range: NSRange(location: 0, length: (markdown as NSString).length)
        ).map(\.range)
        // Indented code a fence match doesn't already cover, masked in the same
        // pass so no token ever ends up inside another.
        let indented = Self.indentedCodeRanges(in: markdown).filter { block in
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
        // Byte-level pre-check, so most notes (indented only inside lists) pay
        // no parse and no per-line strings.
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
        guard hasCandidate else { return [] }

        let lines = markdown.components(separatedBy: "\n")
        var collector = IndentedCodeCollector()
        collector.visit(Document(parsing: markdown))
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
            tokenPrefix: "CMDMDMATH"
        )
    }

    /// Masks every non-overlapping match from each expression in one forward
    /// pass. The previous first-match loop rebuilt the entire String once per
    /// code span, making code-heavy documents progressively slower.
    private func maskRegions(
        in source: String,
        ranges sourceRanges: [NSRange] = [],
        patterns: [NSRegularExpression],
        tokenPrefix: String
    ) -> (String, [String: String]) {
        var tokens: [String: String] = [:]
        var index = 0
        var result = source

        // Swaps ordered, non-overlapping ranges of `result` for tokens.
        func mask(_ ranges: [NSRange], in original: NSString) {
            guard !ranges.isEmpty else { return }

            var masked = ""
            masked.reserveCapacity(result.utf8.count)
            var cursor = 0

            for range in ranges {
                let token = "\u{E000}\(tokenPrefix)\(index)\u{E000}"
                tokens[token] = original.substring(with: range)
                masked += original.substring(
                    with: NSRange(location: cursor, length: range.location - cursor)
                )
                masked += token
                cursor = NSMaxRange(range)
                index += 1
            }
            masked += original.substring(
                with: NSRange(location: cursor, length: original.length - cursor)
            )
            result = masked
        }

        // Precomputed ranges of the untouched source first, then each
        // expression over what is left.
        mask(sourceRanges, in: source as NSString)
        for pattern in patterns {
            let original = result as NSString
            let matches = pattern.matches(
                in: result,
                range: NSRange(location: 0, length: original.length)
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
        let original = source as NSString
        let matches = pattern.matches(
            in: source,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return source }

        var restored = ""
        restored.reserveCapacity(source.utf8.count)
        var cursor = 0

        for match in matches {
            restored += original.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let token = original.substring(with: match.range)
            restored += tokens[token].map(transform) ?? token
            cursor = NSMaxRange(match.range)
        }
        restored += original.substring(
            with: NSRange(location: cursor, length: original.length - cursor)
        )
        return restored
    }

    /// Restores math placeholders: a `cmdmd-math` span in text, but plain
    /// escaped text when the token sits inside a tag — a link's href or an
    /// image's src (`?$filter=a&$top=5`), where a span corrupted the URL. The
    /// rendered body only has raw `<`/`>` as tag delimiters (text and
    /// attribute values are escaped), so one forward scan tracks tag state.
    private func restoreMathRegions(in source: String, tokens: [String: String]) -> String {
        let original = source as NSString
        let matches = Self.mathTokenPattern.matches(
            in: source,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return source }

        let lessThan = UInt16(UInt8(ascii: "<"))
        let greaterThan = UInt16(UInt8(ascii: ">"))
        var restored = ""
        restored.reserveCapacity(source.utf8.count)
        var cursor = 0
        var insideTag = false

        for match in matches {
            for index in cursor..<match.range.location {
                let unit = original.character(at: index)
                if unit == lessThan { insideTag = true } else if unit == greaterThan { insideTag = false }
            }
            restored += original.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let token = original.substring(with: match.range)
            if let math = tokens[token] {
                restored += insideTag ? htmlEscape(math) : "<span class='cmdmd-math'>\(htmlEscape(math))</span>"
            } else {
                restored += token
            }
            cursor = NSMaxRange(match.range)
        }
        restored += original.substring(from: cursor)
        return restored
    }

    // MARK: Obsidian extensions

    /// Rebuilds `source` once, swapping each match of `pattern` for
    /// `replacement(match, source as NSString)`. Matches are ordered and
    /// non-overlapping, and their ranges index the untouched source. Replacing
    /// them one at a time copied the whole document per match (O(n·k)).
    private func replacingMatches(
        of pattern: NSRegularExpression,
        in source: String,
        with replacement: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let original = source as NSString
        let matches = pattern.matches(
            in: source,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return source }

        var result = ""
        result.reserveCapacity(source.utf8.count)
        var cursor = 0

        for match in matches {
            result += original.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            result += replacement(match, original)
            cursor = NSMaxRange(match.range)
        }
        result += original.substring(from: cursor)
        return result
    }

    private func processWikiLinks(_ markdown: String, baseURL: URL?, codeTokens: [String: String]) -> String {
        replacingMatches(of: wikiLinkPattern, in: markdown) { match, nsString in
            let isEmbed = nsString.substring(with: match.range(at: 1)) == "!"
            var target = nsString.substring(with: match.range(at: 2))
            // In a table the pipe is escaped (`[[Note\|alias]]`), which leaves
            // the backslash on the target.
            if target.hasSuffix("\\") { target.removeLast() }
            // An empty alias (`[[Note|]]`) would leave an invisible link.
            let alias = match.range(at: 3).location != NSNotFound
                ? nsString.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
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
                let imgExtensions = ["png", "jpg", "jpeg", "gif", "svg", "webp"]
                let ext = (rawTarget as NSString).pathExtension.lowercased()

                if imgExtensions.contains(ext) {
                    // `|300` / `|300x200` sizes an image embed; any other
                    // alias is its alt text.
                    let size = label.flatMap(Self.embedSizeAttributes)
                    let altText = Self.escapeForTableCell(size == nil ? (rawLabel ?? rawTarget) : rawTarget)
                    let imgPath = baseURL?.appendingPathComponent(rawTarget).path ?? rawTarget
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

    /// Obsidian's image-embed size, `300` or `300x200`, as `width`/`height`
    /// attributes; nil when the alias is anything else.
    private static func embedSizeAttributes(_ alias: String) -> String? {
        let parts = alias.split(separator: "x", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } })
        else { return nil }
        return " width=\"\(parts[0])\"" + (parts.count == 2 ? " height=\"\(parts[1])\"" : "")
    }

    private func processCallouts(_ markdown: String, codeTokens: [String: String]) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []
        var inCallout = false
        var calloutType = ""
        var calloutTitle = ""
        var calloutContent: [String] = []
        var isFoldable = false
        var isExpanded = true

        func flush() {
            result.append(buildCalloutHTML(
                type: calloutType,
                title: calloutTitle,
                content: calloutContent,
                isFoldable: isFoldable,
                isExpanded: isExpanded,
                codeTokens: codeTokens
            ))
            // End the <div> HTML block here: without a blank line it runs on
            // and swallows what follows the callout (e.g. a task list) as raw
            // HTML text.
            result.append("")
            calloutContent = []
        }

        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            if let match = calloutPattern.firstMatch(in: line, range: range) {
                if inCallout { flush() }

                inCallout = true
                calloutType = nsLine.substring(with: match.range(at: 1)).lowercased()

                if match.range(at: 2).location != NSNotFound {
                    let foldMarker = nsLine.substring(with: match.range(at: 2))
                    isFoldable = true
                    isExpanded = foldMarker == "+"
                } else {
                    isFoldable = false
                    isExpanded = true
                }

                calloutTitle = match.range(at: 3).location != NSNotFound
                    ? nsLine.substring(with: match.range(at: 3))
                    : calloutType.capitalized

            } else if inCallout && line.hasPrefix(">") {
                let content = String(line.dropFirst())
                calloutContent.append(content.hasPrefix(" ") ? String(content.dropFirst()) : content)
            } else {
                if inCallout {
                    flush()
                    inCallout = false
                }
                result.append(line)
            }
        }

        if inCallout { flush() }

        return result.joined(separator: "\n")
    }

    private func buildCalloutHTML(type: String, title: String, content: [String], isFoldable: Bool, isExpanded: Bool, codeTokens: [String: String]) -> String {
        let icon = calloutIcon(for: type)
        let safeType = htmlEscape(type)
        // Unmask before escaping: the title lands in raw HTML, where a code
        // placeholder restored later would re-insert the code unescaped.
        let safeTitle = htmlEscape(restoreCodeRegions(title, tokens: codeTokens))

        // Render the callout body as real Markdown (bold, lists, links, code —
        // and previously-processed wiki-link HTML passes straight through).
        // Code placeholders are restored first so code inside callouts renders
        // as code instead of leaking placeholder tokens.
        let rawContent = restoreCodeRegions(content.joined(separator: "\n"), tokens: codeTokens)
        let contentDocument = Document(parsing: rawContent)
        var visitor = HTMLVisitor(renderMermaid: false, taskQueue: TaskLineQueue(lines: []))
        let contentHTML = visitor.visit(contentDocument)

        if isFoldable {
            return """
            <details class="callout callout-\(safeType)" \(isExpanded ? "open" : "")>
                <summary><span class="callout-icon">\(icon)</span> <span class="callout-title">\(safeTitle)</span></summary>
                <div class="callout-content">\(contentHTML)</div>
            </details>
            """
        } else {
            return """
            <div class="callout callout-\(safeType)">
                <div class="callout-header"><span class="callout-icon">\(icon)</span> <span class="callout-title">\(safeTitle)</span></div>
                <div class="callout-content">\(contentHTML)</div>
            </div>
            """
        }
    }

    private func calloutIcon(for type: String) -> String {
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
        return replacingMatches(of: tagPattern, in: markdown) { match, nsString in
            let fullMatch = nsString.substring(with: match.range)
            if Self.isInside(match.range.location, htmlTags) { return fullMatch }
            let tagName = nsString.substring(with: match.range(at: 1))

            return "<span class=\"tag\" data-tag=\"\(htmlEscape(tagName))\">\(htmlEscape(fullMatch))</span>"
        }
    }

    /// Obsidian `==highlight==` → `<mark>`. The inner text stays Markdown, so
    /// `==**bold** highlight==` renders nested formatting.
    private func processHighlights(_ markdown: String) -> String {
        let htmlTags = Self.rawHTMLTagRanges(in: markdown)
        return replacingMatches(of: markPattern, in: markdown) { match, nsString in
            if Self.isInside(match.range.location, htmlTags) { return nsString.substring(with: match.range) }
            let inner = nsString.substring(with: match.range(at: 1))
            return "<mark>\(inner)</mark>"
        }
    }

    // MARK: Document shell

    /// A pinned CDN file and its Subresource Integrity hash.
    private struct CDNResource {
        let url: String
        let integrity: String?
    }

    /// Exact versions (not @11 / @0.16 ranges) so the bytes behind each hash
    /// never move. jsdelivr answers with `Access-Control-Allow-Origin: *`,
    /// which the CORS-mode fetch SRI needs from the file:// page. Refresh a
    /// hash with `curl -s URL | openssl dgst -sha384 -binary | openssl base64 -A`.
    private enum CDN {
        static let mermaid = CDNResource(
            url: "https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.min.js",
            integrity: "sha384-EOXBFmc3gx5mb+vn0vPvvGqACToJD24hhacX5Yx+8NUUQrHIle/Qi5Bg9o3zKwW2"
        )
        static let katexCSS = CDNResource(
            url: "https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/katex.min.css",
            integrity: "sha384-nH0MfJ44wi1dd7w6jinlyBgljjS8EJAh2JBoRad8a3VDw2K69vfaaqm4WnR+gXtA"
        )
        static let katex = CDNResource(
            url: "https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/katex.min.js",
            integrity: "sha384-CwjPRVHTvLiMBFjEoij+QZViMV5rhTOIp7CJzl24JEqpRDA1sJFHVXXLURktbYYp"
        )
        static let katexMhchem = CDNResource(
            url: "https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/contrib/mhchem.min.js",
            integrity: "sha384-fB8BH//9nBzROkMUsu/Dr35jWHIbnKesUo9rW0hfEgw8mZGnkAyBAjKX9F98OVuo"
        )
        static let katexAutoRender = CDNResource(
            url: "https://cdn.jsdelivr.net/npm/katex@0.16.47/dist/contrib/auto-render.min.js",
            integrity: "sha384-bjyGPfbij8/NDKJhSGZNP/khQVgtHUE5exjm4Ydllo42FwIgYsdLO2lXGmRBf5Mz"
        )
        /// npm mirror of highlight.js: immutable per version, unlike a GitHub tag.
        static let highlightBase = "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.12.0"
        static let highlight = CDNResource(
            url: "\(highlightBase)/highlight.min.js",
            integrity: "sha384-wjfDDhOPPdjtva8vWBhWeVprSpmxisEu5aYT3q1JyACqXpdKpo3PWZTMVq24MBix"
        )
        /// Hashes for the themes Settings offers; a hand-edited theme name
        /// still loads from the pinned version, just without SRI.
        static let highlightThemeIntegrity: [String: String] = [
            "github": "sha384-eFTL69TLRZTkNfYZOLM+G04821K1qZao/4QLJbet1pP4tcF+fdXq/9CdqAbWRl/L",
            "github-dark": "sha384-wH75j6z1lH97ZOpMOInqhgKzFkAInZPPSPlZpYKYTOqsaizPvhQZmAtLcPKXpLyH",
            "atom-one-dark": "sha384-oaMLBGEzBOJx3UHwac0cVndtX5fxGQIfnAeFZ35RTgqPcYlbprH9o9PUV/F8Le07",
            "atom-one-light": "sha384-w6Ujm1VWa9HYFqGc89oAPn/DWDi2gUamjNrq9DRvEYm2X3ClItg9Y9xs1ViVo5b5",
            "monokai": "sha384-Exar9WeMELq1EieDQNh7c2ggVht9/FEoVtGG2JKgmEwcm5zOXQwPMzp3PEsPJ/zq",
            "nord": "sha384-O/y538KpolLjYHZH8xqC17hcGWgjOw79vqDDhXNIT6Q7q3O5KVr29xbsaq9k6fSL",
            "tokyo-night-dark": "sha384-6PRNB60loRkq5oYgj0ETV33K0YsTUlab8qtfTGXhRgW5Nz1IpzS2zwj6UmlJEnyV"
        ]

        static func highlightTheme(_ name: String) -> CDNResource {
            CDNResource(
                url: "\(highlightBase)/styles/\(htmlEscape(name)).min.css",
                integrity: highlightThemeIntegrity[name]
            )
        }
    }

    private func scriptTag(_ resource: CDNResource, nonce: String, deferred: Bool = false) -> String {
        "<script\(deferred ? " defer" : "") src=\"\(resource.url)\"\(integrityAttributes(resource)) nonce=\"\(nonce)\"></script>"
    }

    private func stylesheetTag(_ resource: CDNResource, media: String? = nil) -> String {
        let mediaAttribute = media.map { " media=\"\($0)\"" } ?? ""
        return "<link rel=\"stylesheet\"\(mediaAttribute) href=\"\(resource.url)\"\(integrityAttributes(resource))>"
    }

    /// SRI needs a CORS fetch, hence crossorigin alongside every hash.
    private func integrityAttributes(_ resource: CDNResource) -> String {
        resource.integrity.map { " integrity=\"\($0)\" crossorigin=\"anonymous\"" } ?? ""
    }

    /// Scripts run only with the per-render nonce (the renderer's inline ones)
    /// or from the exact pinned CDN files this page includes — never a whole
    /// host (jsdelivr serves any GitHub file). Note HTML can still style the
    /// page and show images, but can't run script, frame other pages, post
    /// forms, re-base URLs or open connections. No 'unsafe-eval': mermaid,
    /// KaTeX and highlight.js don't need it.
    private func contentSecurityPolicy(nonce: String, scriptURLs: [String]) -> String {
        [
            "default-src 'none'",
            "script-src \((["'nonce-\(nonce)'"] + scriptURLs).joined(separator: " "))",
            "style-src 'unsafe-inline' https:",
            "font-src https: data:",
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

    private func wrapWithHTML(body: String, options: MarkdownRenderOptions, nonce: String) -> String {
        let hasMermaid = body.contains("class=\"mermaid\"")
        let hasCode = body.contains("<pre><code")
        var scriptURLs: [String] = []

        // Classic UMD build (sets window.mermaid). The ESM build's `import`
        // misbehaves under WKWebView's file:// base URL, so the global build is
        // the reliable choice here. v11 still auto-renders `.mermaid` via
        // startOnLoad. securityLevel 'strict' (mermaid's default) keeps the
        // DOMPurify pass and drops `click … call` callbacks / javascript: links
        // that 'loose' allowed in a note's diagram.
        if hasMermaid { scriptURLs.append(CDN.mermaid.url) }
        let mermaidScript = hasMermaid ? """
            \(scriptTag(CDN.mermaid, nonce: nonce))
            <script nonce="\(nonce)">
                document.addEventListener('DOMContentLoaded', function() {
                    if (typeof mermaid === 'undefined') return;
                    mermaid.initialize({
                        startOnLoad: true,
                        theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
                        securityLevel: 'strict',
                        fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'
                    });
                });
            </script>
            """ : ""

        let mermaidCSS = hasMermaid ? """
            .mermaid {
                text-align: center;
                margin: 24px 0;
                padding: 16px;
                background: var(--bg-secondary, #f6f8fa);
                border-radius: 8px;
            }
            .mermaid svg {
                max-width: 100%;
                height: auto;
            }
            """ : ""

        // Gate KaTeX on actual math markers (like mermaid/hljs above) — loading
        // four resources plus a whole-body DOM scan on every math-free note
        // added latency to each debounced reload. Every masked math region
        // comes back as a `cmdmd-math` span, and only those spans are
        // rendered: a prose `$` (a price) is never math.
        let hasMath = body.contains("class='cmdmd-math'")
        let includesKaTeX = options.enableKaTeX && hasMath
        if includesKaTeX {
            scriptURLs += [CDN.katex.url, CDN.katexMhchem.url, CDN.katexAutoRender.url]
        }
        // Deferred scripts run before DOMContentLoaded, so the nonce'd listener
        // replaces auto-render's former onload= attribute (inline handlers are
        // outside the CSP).
        let katexIncludes = includesKaTeX ? """
            \(stylesheetTag(CDN.katexCSS))
            \(scriptTag(CDN.katex, nonce: nonce, deferred: true))
            \(scriptTag(CDN.katexMhchem, nonce: nonce, deferred: true))
            \(scriptTag(CDN.katexAutoRender, nonce: nonce, deferred: true))
            <script nonce="\(nonce)">
                document.addEventListener('DOMContentLoaded', function() {
                    if (typeof renderMathInElement === 'undefined') return;
                    document.querySelectorAll('.cmdmd-math').forEach(function(el) {
                        renderMathInElement(el, {delimiters: [{left: '$$', right: '$$', display: true}, {left: '\\\\[', right: '\\\\]', display: true}, {left: '\\\\(', right: '\\\\)', display: false}, {left: '$', right: '$', display: false}], throwOnError: false});
                    });
                });
            </script>
            """ : ""

        let includesHighlight = options.enableCodeHighlight && hasCode
        if includesHighlight { scriptURLs.append(CDN.highlight.url) }
        let highlightIncludes = includesHighlight
            ? hljsIncludes(theme: options.preview.codeBlockTheme, nonce: nonce)
            : ""

        let taskScript = options.interactiveTasks ? """
            <script nonce="\(nonce)">
                document.addEventListener('DOMContentLoaded', function() {
                    document.querySelectorAll('input[type="checkbox"][data-line]').forEach(function(cb) {
                        cb.addEventListener('change', function(e) {
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cmdmd) {
                                window.webkit.messageHandlers.cmdmd.postMessage({
                                    type: 'toggleTask',
                                    line: parseInt(e.target.dataset.line, 10),
                                    checked: e.target.checked
                                });
                            }
                        });
                    });
                });
            </script>
            """ : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(nonce: nonce, scriptURLs: scriptURLs))">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta name="color-scheme" content="light dark">
            <style>
                :root { color-scheme: light dark; }
                \(options.theme.css)
                \(obsidianExtensionsCSS)
                \(mermaidCSS)
                \(settingsOverrideCSS(options.preview))
            </style>
            \(highlightIncludes)
            \(katexIncludes)
            \(mermaidScript)
            \(taskScript)
        </head>
        <body class="markdown-body">
            \(body)
        </body>
        </html>
        """
    }

    /// User-tunable typography from Settings → Preview. Emitted AFTER the theme
    /// CSS so it wins the cascade; custom CSS comes last and wins over everything.
    private func settingsOverrideCSS(_ p: PreviewSettings) -> String {
        let scale = max(0.5, p.headingScale)
        let headingSizes: [(String, Double)] = [
            ("h1", 2.0), ("h2", 1.5), ("h3", 1.25), ("h4", 1.1), ("h5", 1.0), ("h6", 0.9)
        ]
        let headingRules = headingSizes
            .map { "\($0.0) { font-size: \(String(format: "%.3f", $0.1 * scale))em; }" }
            .joined(separator: "\n")

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
        .markdown-body pre, .markdown-body code, .markdown-body .katex, .markdown-body .mermaid {
            letter-spacing: normal;
            word-spacing: normal;
        }
        """ : ""

        return """
        body {
            font-family: \(Self.previewFontStack(p.fontFamily));
            font-size: \(Int(p.fontSize))px;
            line-height: \(String(format: "%.2f", p.lineHeight));
            max-width: \(Int(p.maxWidth))px;
            letter-spacing: \(String(format: "%.3f", p.letterSpacing))em;
            word-spacing: \(String(format: "%.3f", p.wordSpacing))em;
        }
        \(spacingResetRule)
        h1, h2, h3, h4, h5, h6 {
            margin-top: \(Int(p.headingMarginTop))px;
            margin-bottom: \(Int(p.headingMarginBottom))px;
        }
        \(headingRules)
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

    private func hljsIncludes(theme: String, nonce: String) -> String {
        let styleLinks: String
        switch theme {
        case "github":
            // Auto light/dark pairing for the default theme.
            styleLinks = """
            \(stylesheetTag(CDN.highlightTheme("github"), media: "(prefers-color-scheme: light)"))
            \(stylesheetTag(CDN.highlightTheme("github-dark"), media: "(prefers-color-scheme: dark)"))
            """
        default:
            styleLinks = stylesheetTag(CDN.highlightTheme(theme))
        }

        return """
        \(styleLinks)
        \(scriptTag(CDN.highlight, nonce: nonce))
        <script nonce="\(nonce)">
            document.addEventListener('DOMContentLoaded', function() {
                if (typeof hljs === 'undefined') return;
                document.querySelectorAll('pre code').forEach(function(el) {
                    if (el.classList.contains('language-mermaid')) return;
                    hljs.highlightElement(el);
                });
            });
        </script>
        """
    }

    private var obsidianExtensionsCSS: String {
        """
        /* One native mono stack for every theme — ui-monospace resolves to SF
           Mono on macOS; themes without an explicit stack fell back to Courier. */
        code, pre, kbd, samp {
            font-family: ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Monaco, monospace;
        }
        /* Task checkboxes: native control tinted with the theme accent, sized
           to sit on the text baseline instead of a raw default form control. */
        input[type="checkbox"] {
            accent-color: var(--link-color, #007aff);
            width: 14px;
            height: 14px;
            vertical-align: -2px;
        }
        .wiki-link {
            color: var(--link-color, #134538);
            text-decoration: none;
            border-bottom: 1px dashed var(--link-color, #134538);
        }
        .wiki-link:hover {
            border-bottom-style: solid;
        }
        .embedded-image {
            max-width: 100%;
            border-radius: 8px;
        }
        .embedded-note {
            background: var(--bg-secondary, #f3f4f6);
            padding: 2px 6px;
            border-radius: 4px;
            font-style: italic;
        }
        .tag {
            background: var(--tag-bg, #dcebe3);
            color: var(--tag-color, #0d3529);
            padding: 2px 8px;
            border-radius: 12px;
            font-size: 0.875em;
            font-weight: 500;
        }
        @media (prefers-color-scheme: dark) {
            .tag { background: var(--tag-bg, #2b1922); color: var(--tag-color, #F4A4B8); }
        }
        mark {
            background: rgba(255, 208, 0, 0.4);
            border-radius: 3px;
            padding: 0 2px;
        }
        @media (prefers-color-scheme: dark) {
            mark { background: rgba(255, 208, 0, 0.3); color: inherit; }
        }
        .callout {
            border-radius: 8px;
            padding: 12px 16px;
            margin: 16px 0;
            border-left: 4px solid;
        }
        .callout-header {
            font-weight: 600;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .callout-content {
            margin-left: 28px;
        }
        .callout-content > p:first-child { margin-top: 0; }
        .callout-content > p:last-child { margin-bottom: 0; }
        .callout-note { background: #eff6ff; border-color: #3b82f6; }
        .callout-info { background: #ecfeff; border-color: #06b6d4; }
        .callout-tip, .callout-hint, .callout-important { background: #fefce8; border-color: #eab308; }
        .callout-warning, .callout-caution, .callout-attention { background: #fff7ed; border-color: #f97316; }
        .callout-danger, .callout-error { background: #fef2f2; border-color: #ef4444; }
        .callout-success, .callout-check, .callout-done { background: #f0fdf4; border-color: #22c55e; }
        .callout-quote, .callout-cite { background: #f9fafb; border-color: #6b7280; }
        .callout-bug { background: #fdf4ff; border-color: #d946ef; }
        .callout-example { background: #faf5ff; border-color: #a855f7; }
        @media (prefers-color-scheme: dark) {
            .callout-note { background: rgba(59, 130, 246, 0.12); }
            .callout-info { background: rgba(6, 182, 212, 0.12); }
            .callout-tip, .callout-hint, .callout-important { background: rgba(234, 179, 8, 0.12); }
            .callout-warning, .callout-caution, .callout-attention { background: rgba(249, 115, 22, 0.12); }
            .callout-danger, .callout-error { background: rgba(239, 68, 68, 0.12); }
            .callout-success, .callout-check, .callout-done { background: rgba(34, 197, 94, 0.12); }
            .callout-quote, .callout-cite { background: rgba(107, 114, 128, 0.12); }
            .callout-bug { background: rgba(217, 70, 239, 0.12); }
            .callout-example { background: rgba(168, 85, 247, 0.12); }
        }
        details.callout > summary {
            cursor: pointer;
            list-style: none;
            display: flex;
            align-items: center;
            gap: 8px;
            font-weight: 600;
        }
        details.callout > summary::-webkit-details-marker {
            display: none;
        }
        details.callout > summary::before {
            content: "▶";
            font-size: 0.75em;
            transition: transform 0.2s;
        }
        details.callout[open] > summary::before {
            transform: rotate(90deg);
        }
        """
    }
}

// MARK: - HTML Visitor

struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    var renderMermaid: Bool
    var taskQueue: TaskLineQueue
    /// Swaps math placeholders back for their `$…$` source. Math is masked
    /// before the parse, so heading text still carries the placeholders.
    var restoreMath: (String) -> String = { $0 }
    private var slugger = HeadingSlugger()

    init(renderMermaid: Bool = true, taskQueue: TaskLineQueue = TaskLineQueue(lines: [])) {
        self.renderMermaid = renderMermaid
        self.taskQueue = taskQueue
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0) }.joined()
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(paragraph.children.map { visit($0) }.joined())</p>\n"
    }

    mutating func visitText(_ text: Text) -> String {
        htmlEscape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(emphasis.children.map { visit($0) }.joined())</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(strong.children.map { visit($0) }.joined())</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(strikethrough.children.map { visit($0) }.joined())</del>"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = heading.level
        let content = heading.children.map { visit($0) }.joined()
        // Slug from the heading's visible text via the shared, Unicode-aware,
        // deduplicating slugger so non-ASCII and duplicate headings each get a
        // usable anchor id that matches the TOC. Math is slugged from its
        // `$…$` source, not its placeholder, as the TOC slugs it.
        let id = slugger.slug(for: restoreMath(headingVisibleText(heading)))
        return "<h\(level) id=\"\(id)\">\(content)</h\(level)>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let lang = codeBlock.language ?? ""
        let code = codeBlock.code

        // Mermaid: escape too. The browser decodes the entities back to the
        // original text in the DOM text node, so Mermaid still parses the
        // diagram correctly while `<script>` can't break out of the container.
        if renderMermaid, lang.lowercased() == "mermaid" {
            return "<div class=\"mermaid\">\(htmlEscape(code))</div>\n"
        }

        return "<pre><code class=\"language-\(htmlEscape(lang))\">\(htmlEscape(code))</code></pre>\n"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(htmlEscape(inlineCode.code))</code>"
    }

    /// Raw HTML (the note's own, and the wiki-link/callout/tag markup the
    /// renderer injects before parsing) passes through minus anything that
    /// could run script — backup for the page CSP.
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        RawHTMLSanitizer.sanitize(inlineHTML.rawHTML)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        RawHTMLSanitizer.sanitize(html.rawHTML)
    }

    mutating func visitLink(_ link: Link) -> String {
        let href = sanitizeURL(link.destination ?? "")
        let content = link.children.map { visit($0) }.joined()
        return "<a href=\"\(href)\">\(content)</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let src = sanitizeURL(image.source ?? "")
        let alt = htmlEscape(image.plainText)
        return "<img src=\"\(src)\" alt=\"\(alt)\" />"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul>\n\(list.children.map { visit($0) }.joined())</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        "<ol>\n\(list.children.map { visit($0) }.joined())</ol>\n"
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        let checkboxHTML: String
        switch item.checkbox {
        case .checked, .unchecked:
            let checked = item.checkbox == .checked ? " checked" : ""
            if let line = taskQueue.next() {
                // Live checkbox: clicking it posts the source line back to the
                // app, which flips `[ ]`/`[x]` in the document.
                checkboxHTML = "<input type=\"checkbox\"\(checked) data-line=\"\(line)\" /> "
            } else {
                checkboxHTML = "<input type=\"checkbox\"\(checked) disabled /> "
            }
        case .none:
            checkboxHTML = ""
        }
        return "<li class=\"\(item.checkbox != nil ? "task-item" : "")\">\(checkboxHTML)\(item.children.map { visit($0) }.joined())</li>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(blockQuote.children.map { visit($0) }.joined())</blockquote>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr />\n"
    }

    mutating func visitTable(_ table: Table) -> String {
        var html = "<table>\n"

        let head = table.head
        html += "<thead><tr>\n"
        for cell in head.cells {
            html += "<th>\(cell.children.map { visit($0) }.joined())</th>\n"
        }
        html += "</tr></thead>\n"

        html += "<tbody>\n"
        for row in table.body.rows {
            html += "<tr>\n"
            for cell in row.cells {
                html += "<td>\(cell.children.map { visit($0) }.joined())</td>\n"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"

        return html
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br />\n"
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

    var css: String {
        switch self {
        case .github:
            return githubCSS
        case .obsidian:
            return obsidianCSS
        case .minimal:
            return minimalCSS
        case .cmds:
            return cmdsCSS
        case .sepia:
            return sepiaCSS
        case .newsprint:
            return newsprintCSS
        case .darkPro:
            return darkProCSS
        }
    }

    private var githubCSS: String {
        """
        :root {
            --bg-primary: #ffffff;
            --bg-secondary: #f6f8fa;
            --text-primary: #24292f;
            --text-secondary: #57606a;
            --link-color: #0969da;
            --border-color: #d0d7de;
            --code-bg: #f6f8fa;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-primary: #0d1117;
                --bg-secondary: #161b22;
                --text-primary: #c9d1d9;
                --text-secondary: #8b949e;
                --link-color: #58a6ff;
                --border-color: #30363d;
                --code-bg: #161b22;
            }
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
            font-size: 16px;
            line-height: 1.6;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 900px;
            margin: 0 auto;
            padding: 32px;
        }
        h1, h2, h3, h4, h5, h6 { margin-top: 24px; margin-bottom: 16px; font-weight: 600; }
        h1 { font-size: 2em; border-bottom: 1px solid var(--border-color); padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid var(--border-color); padding-bottom: 0.3em; }
        a { color: var(--link-color); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { background: var(--code-bg); padding: 0.2em 0.4em; border-radius: 6px; font-size: 85%; }
        pre { background: var(--code-bg); padding: 16px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 4px solid var(--border-color); margin: 0; padding-left: 16px; color: var(--text-secondary); }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid var(--border-color); padding: 8px 12px; }
        th { background: var(--bg-secondary); }
        img { max-width: 100%; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 24px 0; }
        ul, ol { padding-left: 2em; }
        li { margin: 4px 0; }
        li.task-item { list-style: none; margin-left: -1.4em; }
        input[type="checkbox"] { margin-right: 8px; }
        """
    }

    private var obsidianCSS: String {
        """
        :root {
            --bg-primary: #ffffff;
            --bg-secondary: #f5f6f8;
            --text-primary: #2e3338;
            --text-secondary: #6c7489;
            --link-color: #7c3aed;
            --border-color: #e3e5e8;
            --code-bg: #f5f6f8;
            --tag-bg: #e0e7ff;
            --tag-color: #4338ca;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-primary: #1e1e1e;
                --bg-secondary: #262626;
                --text-primary: #dcddde;
                --text-secondary: #888;
                --link-color: #a78bfa;
                --border-color: #3c3c3c;
                --code-bg: #2d2d2d;
                --tag-bg: #312e81;
                --tag-color: #c4b5fd;
            }
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, Inter, 'Segoe UI', Roboto, sans-serif;
            font-size: 16px;
            line-height: 1.75;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 800px;
            margin: 0 auto;
            padding: 40px;
        }
        h1, h2, h3, h4, h5, h6 { margin-top: 1.5em; margin-bottom: 0.5em; font-weight: 700; }
        h1 { font-size: 1.875em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.25em; }
        a { color: var(--link-color); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { background: var(--code-bg); padding: 2px 6px; border-radius: 4px; font-family: 'SF Mono', Menlo, monospace; font-size: 0.875em; }
        pre { background: var(--code-bg); padding: 16px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid var(--link-color); margin: 16px 0; padding-left: 16px; color: var(--text-secondary); font-style: italic; }
        table { border-collapse: collapse; width: 100%; margin: 16px 0; }
        th, td { border: 1px solid var(--border-color); padding: 10px 14px; text-align: left; }
        th { background: var(--bg-secondary); font-weight: 600; }
        img { max-width: 100%; border-radius: 8px; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 32px 0; }
        ul, ol { padding-left: 1.5em; }
        li { margin: 6px 0; }
        li::marker { color: var(--text-secondary); }
        li.task-item { list-style: none; margin-left: -1.2em; }
        input[type="checkbox"] { margin-right: 8px; accent-color: var(--link-color); }
        """
    }

    private var minimalCSS: String {
        """
        :root {
            --bg-primary: #ffffff;
            --bg-secondary: #f5f5f7;
            --text-primary: #1d1d1f;
            --text-secondary: #6e6e73;
            --link-color: #0066cc;
            --border-color: #d1d1d6;
            --code-bg: #f5f5f7;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-primary: #1d1d1f;
                --bg-secondary: #2c2c2e;
                --text-primary: #f5f5f7;
                --text-secondary: #98989d;
                --link-color: #0a84ff;
                --border-color: #3a3a3c;
                --code-bg: #2c2c2e;
            }
        }
        body {
            font-family: 'SF Pro Text', -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 17px;
            line-height: 1.8;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 680px;
            margin: 0 auto;
            padding: 48px 24px;
        }
        h1, h2, h3, h4 { font-weight: 600; margin-top: 2em; margin-bottom: 0.5em; }
        h1 { font-size: 2em; }
        h2 { font-size: 1.5em; }
        a { color: var(--link-color); text-decoration: none; }
        code { background: var(--code-bg); padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
        pre { background: var(--code-bg); padding: 20px; border-radius: 12px; overflow-x: auto; }
        pre code { background: none; }
        blockquote { margin: 24px 0; padding-left: 20px; border-left: 3px solid var(--border-color); color: var(--text-secondary); }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid var(--border-color); padding: 8px 12px; }
        th { background: var(--bg-secondary); }
        img { max-width: 100%; border-radius: 12px; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 40px 0; }
        li.task-item { list-style: none; margin-left: -1.4em; }
        """
    }

    /// CMDSPACE brand theme — Dark Green primary (light) / Pink accent (dark),
    /// SF Pro typography, rounded code blocks. Matches CMDS Color System v2.5.
    private var cmdsCSS: String {
        """
        :root {
            --bg-primary: #fbfbfa;
            --bg-secondary: #f1f7f4;
            --text-primary: #0a0d0b;
            --text-secondary: #4a544f;
            --link-color: #134538;
            --border-color: #e6e8e6;
            --code-bg: #eef1ee;
            --code-fg: #0d3529;
            --tag-bg: #dcebe3;
            --tag-color: #0d3529;
            --accent: #134538;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-primary: #06080a;
                --bg-secondary: #0d1411;
                --text-primary: #f2f4f3;
                --text-secondary: #9aa39d;
                --link-color: #E985A2;
                --border-color: #1a231f;
                --code-bg: #1c2420;
                --code-fg: #8fe3c4;
                --tag-bg: #2b1922;
                --tag-color: #F4A4B8;
                --accent: #E985A2;
            }
        }
        body {
            font-family: 'SF Pro Text', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            font-size: 16px;
            line-height: 1.7;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 820px;
            margin: 0 auto;
            padding: 40px;
        }
        h1, h2, h3, h4, h5, h6 { margin-top: 1.6em; margin-bottom: 0.5em; font-weight: 700; letter-spacing: -0.01em; color: var(--text-primary); }
        h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 2px solid var(--accent); }
        h2 { font-size: 1.5em; padding-bottom: 0.2em; border-bottom: 1px solid var(--border-color); }
        h3 { font-size: 1.25em; }
        a { color: var(--link-color); text-decoration: none; font-weight: 500; }
        a:hover { text-decoration: underline; text-underline-offset: 3px; }
        code { background: var(--code-bg); color: var(--code-fg); padding: 1px 6px; border-radius: 5px; font-family: 'SF Mono', ui-monospace, Menlo, monospace; font-size: 0.86em; border: 1px solid var(--border-color); overflow-wrap: anywhere; }
        pre { background: var(--code-bg); padding: 16px; border-radius: 10px; overflow-x: auto; border: 1px solid var(--border-color); }
        pre code { background: none; padding: 0; border: none; border-radius: 0; color: inherit; overflow-wrap: normal; }
        blockquote { border-left: 4px solid var(--accent); margin: 16px 0; padding: 4px 16px; background: var(--bg-secondary); border-radius: 0 8px 8px 0; color: var(--text-secondary); }
        table { border-collapse: collapse; width: 100%; margin: 16px 0; border-radius: 8px; overflow: hidden; }
        th, td { border: 1px solid var(--border-color); padding: 10px 14px; text-align: left; vertical-align: top; }
        td code { font-size: 0.84em; }
        th { background: var(--accent); color: #fff; font-weight: 600; }
        /* Inline code inside the colored header: a dark translucent pill with
           white text reads cleanly on both the green (light) and pink (dark) bar. */
        th code { background: rgba(0, 0, 0, 0.32); color: #ffffff; border-color: transparent; }
        @media (prefers-color-scheme: dark) { th { color: #0b0f0d; } }
        img { max-width: 100%; border-radius: 10px; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 32px 0; }
        ul, ol { padding-left: 1.6em; }
        li { margin: 5px 0; }
        li::marker { color: var(--accent); }
        li.task-item { list-style: none; margin-left: -1.3em; }
        input[type="checkbox"] { margin-right: 8px; accent-color: var(--accent); }
        """
    }

    /// Warm paper-tone reading theme for long-form documents.
    private var sepiaCSS: String {
        """
        :root {
            --bg-primary: #f4ecd8;
            --bg-secondary: #ece2c8;
            --text-primary: #433422;
            --text-secondary: #6b5a42;
            --link-color: #9a5b2f;
            --border-color: #d8c9a8;
            --code-bg: #ece2c8;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-primary: #2b2114;
                --bg-secondary: #34291a;
                --text-primary: #e8dcc4;
                --text-secondary: #b3a484;
                --link-color: #d99a5b;
                --border-color: #4a3c28;
                --code-bg: #34291a;
            }
        }
        body {
            font-family: 'Iowan Old Style', Palatino, Georgia, serif;
            font-size: 18px;
            line-height: 1.8;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 720px;
            margin: 0 auto;
            padding: 48px 32px;
        }
        h1, h2, h3, h4 { font-weight: 700; margin-top: 1.8em; margin-bottom: 0.5em; color: var(--text-primary); }
        h1 { font-size: 2em; }
        h2 { font-size: 1.5em; }
        a { color: var(--link-color); text-decoration: underline; text-underline-offset: 2px; }
        code { background: var(--code-bg); padding: 2px 6px; border-radius: 4px; font-size: 0.85em; }
        pre { background: var(--code-bg); padding: 16px; border-radius: 8px; overflow-x: auto; border: 1px solid var(--border-color); }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid var(--link-color); margin: 20px 0; padding-left: 18px; color: var(--text-secondary); font-style: italic; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid var(--border-color); padding: 8px 12px; }
        th { background: var(--bg-secondary); }
        img { max-width: 100%; border-radius: 6px; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 36px 0; }
        li.task-item { list-style: none; margin-left: -1.4em; }
        """
    }

    /// Editorial / newspaper feel — serif body, tight headlines, hairline rules.
    private var newsprintCSS: String {
        """
        :root {
            --bg-primary: #ffffff;
            --bg-secondary: #f3f3f1;
            --text-primary: #1a1a1a;
            --text-secondary: #555;
            --link-color: #1a1a1a;
            --border-color: #cfcfcf;
            --code-bg: #f3f3f1;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-primary: #121212;
                --bg-secondary: #1d1d1d;
                --text-primary: #ededed;
                --text-secondary: #a0a0a0;
                --link-color: #ededed;
                --border-color: #333;
                --code-bg: #1d1d1d;
            }
        }
        body {
            font-family: 'Georgia', 'Times New Roman', 'Noto Serif KR', serif;
            font-size: 17px;
            line-height: 1.7;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 760px;
            margin: 0 auto;
            padding: 44px 28px;
        }
        h1, h2, h3, h4, h5, h6 { font-weight: 700; line-height: 1.2; margin-top: 1.4em; margin-bottom: 0.4em; }
        h1 { font-size: 2.4em; letter-spacing: -0.02em; border-bottom: 3px double var(--border-color); padding-bottom: 0.2em; }
        h2 { font-size: 1.6em; }
        h3 { font-size: 1.25em; font-style: italic; }
        a { color: var(--link-color); text-decoration: underline; text-decoration-thickness: 1px; text-underline-offset: 2px; }
        code { background: var(--code-bg); padding: 2px 5px; border-radius: 3px; font-family: 'SF Mono', monospace; font-size: 0.85em; }
        pre { background: var(--code-bg); padding: 16px; border-radius: 4px; overflow-x: auto; border: 1px solid var(--border-color); }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 4px solid var(--text-primary); margin: 20px 0; padding-left: 18px; font-style: italic; color: var(--text-secondary); }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid var(--border-color); padding: 8px 12px; }
        th { background: var(--bg-secondary); text-transform: uppercase; font-size: 0.85em; letter-spacing: 0.04em; }
        img { max-width: 100%; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 32px 0; }
        li.task-item { list-style: none; margin-left: -1.4em; }
        """
    }

    /// High-contrast dark theme for presentations / low-light review.
    private var darkProCSS: String {
        """
        :root {
            --bg-primary: #0d0d0d;
            --bg-secondary: #1a1a1a;
            --text-primary: #fafafa;
            --text-secondary: #a3a3a3;
            --link-color: #5eead4;
            --border-color: #2a2a2a;
            --code-bg: #161616;
            --tag-bg: #1f2937;
            --tag-color: #93c5fd;
        }
        body {
            font-family: 'SF Pro Text', -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 16px;
            line-height: 1.7;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 820px;
            margin: 0 auto;
            padding: 40px;
        }
        h1, h2, h3, h4, h5, h6 { font-weight: 700; margin-top: 1.5em; margin-bottom: 0.5em; color: #ffffff; }
        h1 { font-size: 2.1em; }
        h2 { font-size: 1.55em; border-bottom: 1px solid var(--border-color); padding-bottom: 0.2em; }
        h3 { font-size: 1.25em; }
        a { color: var(--link-color); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { background: var(--code-bg); padding: 2px 6px; border-radius: 6px; font-family: 'SF Mono', Menlo, monospace; font-size: 0.875em; color: #e2e8f0; }
        pre { background: var(--code-bg); padding: 18px; border-radius: 10px; overflow-x: auto; border: 1px solid var(--border-color); }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 4px solid var(--link-color); margin: 16px 0; padding: 4px 16px; background: var(--bg-secondary); border-radius: 0 8px 8px 0; color: var(--text-secondary); }
        table { border-collapse: collapse; width: 100%; margin: 16px 0; }
        th, td { border: 1px solid var(--border-color); padding: 10px 14px; text-align: left; }
        th { background: var(--bg-secondary); font-weight: 600; }
        img { max-width: 100%; border-radius: 10px; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 32px 0; }
        ul, ol { padding-left: 1.6em; }
        li { margin: 5px 0; }
        li.task-item { list-style: none; margin-left: -1.3em; }
        input[type="checkbox"] { margin-right: 8px; accent-color: var(--link-color); }
        """
    }
}
