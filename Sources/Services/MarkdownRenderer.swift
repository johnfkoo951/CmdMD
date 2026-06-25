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
/// schemes (javascript:, vbscript:, data:text/html).
func sanitizeURL(_ url: String) -> String {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") {
        return "#"
    }
    return htmlEscape(trimmed)
}

// MARK: - Table of Contents

enum TOCBuilder {
    /// Extracts ATX headings with renderer-matching slugs. Fence-aware so a
    /// `# comment` inside a code block doesn't appear in the TOC (and doesn't
    /// desynchronize slug deduplication from the renderer).
    static func extractHeadings(from content: String) -> [TOCHeading] {
        var headings: [TOCHeading] = []
        var slugger = HeadingSlugger()
        var inFence = false

        for (index, line) in content.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
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

            headings.append(TOCHeading(
                level: level,
                text: text,
                lineNumber: index + 1,
                slug: slugger.slug(for: text)
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
}

// MARK: - Task line mapping

/// Maps rendered task checkboxes back to their source line numbers so clicking
/// a checkbox in the preview can toggle the right `- [ ]` in the document.
/// The visitor encounters task items in source order, so a simple queue works.
final class TaskLineQueue {
    private var lines: [Int]
    private var index = 0

    init(lines: [Int]) {
        self.lines = lines
    }

    func next() -> Int? {
        guard index < lines.count else { return nil }
        defer { index += 1 }
        return lines[index]
    }

    static let taskLinePattern = try! NSRegularExpression(
        pattern: #"^(\s*)(?:[-*+]|\d+[.)])\s+\[([ xX])\]\s"#
    )

    /// Scans the ORIGINAL markdown (before any transformation shifts lines) for
    /// task-list lines, skipping fenced code and callout blocks (callout content
    /// is rendered separately and stays non-interactive).
    static func scan(_ markdown: String) -> [Int] {
        var lines: [Int] = []
        var inFence = false
        var inCallout = false

        for (index, line) in markdown.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                inCallout = false
                continue
            }
            if inFence { continue }

            if trimmed.hasPrefix(">") {
                if trimmed.range(of: #"^>\s*\[!\w+\]"#, options: .regularExpression) != nil {
                    inCallout = true
                }
                if inCallout { continue }
            } else {
                inCallout = false
            }

            let ns = line as NSString
            if taskLinePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil {
                lines.append(index + 1)
            }
        }
        return lines
    }
}

// MARK: - Renderer

class MarkdownRenderer {
    private static let internalLinkQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        return allowed
    }()

    private let wikiLinkPattern = try! NSRegularExpression(
        pattern: #"(!?)\[\[(?:(.+?)\|)?(.+?)\]\]"#,
        options: []
    )

    private let calloutPattern = try! NSRegularExpression(
        pattern: #"^>\s*\[!(\w+)\]([+-])?\s*(.*)"#,
        options: [.anchorsMatchLines]
    )

    private let tagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)#([a-zA-Z][a-zA-Z0-9_/-]*)"#,
        options: []
    )

    private let markPattern = try! NSRegularExpression(
        pattern: #"==([^=\n](?:[^=\n]*[^=\n])?)=="#,
        options: []
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
            processedMarkdown = processWikiLinks(processedMarkdown, baseURL: baseURL)
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
        var htmlBody = htmlVisitor.visit(document)

        // Math placeholders come back as escaped literal `$...$` text; the
        // KaTeX auto-render script picks them up from the DOM.
        for (token, original) in mathTokens {
            htmlBody = htmlBody.replacingOccurrences(of: token, with: htmlEscape(original))
        }

        return wrapWithHTML(body: htmlBody, options: options)
    }

    /// Convenience used by tests and callers that don't care about settings.
    func renderToHTML(markdown: String, baseURL: URL? = nil, theme: PreviewTheme) -> String {
        var options = MarkdownRenderOptions()
        options.theme = theme
        return renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
    }

    // MARK: Masking

    /// Replaces fenced and inline code spans with private-use placeholder tokens
    /// so downstream regex pre-processing leaves code untouched. Restored before
    /// the Markdown parse so the code blocks render (and escape) normally.
    private func maskCodeRegions(_ markdown: String) -> (String, [String: String]) {
        var tokens: [String: String] = [:]
        var index = 0
        var result = markdown

        func mask(_ pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            while true {
                let ns = result as NSString
                guard let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)) else { break }
                let token = "\u{E000}CMDMDCODE\(index)\u{E000}"
                tokens[token] = ns.substring(with: match.range)
                result = ns.replacingCharacters(in: match.range, with: token)
                index += 1
            }
        }

        // Line-anchored fences (``` at the start of a line, optional indent) so a
        // stray inline ``` can't pair with a real fence and swallow content
        // between two separate code blocks.
        mask("(?m)^[ \\t]*```[\\s\\S]*?^[ \\t]*```")   // fenced code blocks
        mask("`[^`\n]+`")                                // inline code
        return (result, tokens)
    }

    /// Masks `$$display$$` and `$inline$` math with placeholder tokens. Inline
    /// math must be single-line and non-empty so a lone dollar sign in prose
    /// doesn't start a bogus math region.
    private func maskMathRegions(_ markdown: String) -> (String, [String: String]) {
        var tokens: [String: String] = [:]
        var index = 0
        var result = markdown

        func mask(_ pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            while true {
                let ns = result as NSString
                guard let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)) else { break }
                let token = "\u{E000}CMDMDMATH\(index)\u{E000}"
                tokens[token] = ns.substring(with: match.range)
                result = ns.replacingCharacters(in: match.range, with: token)
                index += 1
            }
        }

        mask(#"\$\$[\s\S]+?\$\$"#)        // display math  $$ … $$
        mask(#"\\\[[\s\S]+?\\\]"#)        // display math  \[ … \]
        mask(#"\\\([\s\S]+?\\\)"#)        // inline math   \( … \)
        mask(#"\$[^$\n]+\$"#)             // inline math   $ … $
        return (result, tokens)
    }

    private func restoreCodeRegions(_ markdown: String, tokens: [String: String]) -> String {
        var result = markdown
        for (token, original) in tokens {
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }

    // MARK: Obsidian extensions

    private func processWikiLinks(_ markdown: String, baseURL: URL?) -> String {
        let nsString = markdown as NSString
        let range = NSRange(location: 0, length: nsString.length)

        var result = markdown
        let matches = wikiLinkPattern.matches(in: markdown, range: range).reversed()

        for match in matches {
            let isEmbed = nsString.substring(with: match.range(at: 1)) == "!"
            let alias = match.range(at: 2).location != NSNotFound
                ? nsString.substring(with: match.range(at: 2))
                : nil
            let target = nsString.substring(with: match.range(at: 3))

            let displayText = htmlEscape(alias ?? target)

            if isEmbed {
                let imgExtensions = ["png", "jpg", "jpeg", "gif", "svg", "webp"]
                let ext = (target as NSString).pathExtension.lowercased()

                if imgExtensions.contains(ext) {
                    let imgPath = baseURL?.appendingPathComponent(target).path ?? target
                    result = (result as NSString).replacingCharacters(
                        in: match.range,
                        with: "<img src=\"file://\(htmlEscape(imgPath))\" alt=\"\(displayText)\" class=\"embedded-image\" />"
                    )
                } else {
                    result = (result as NSString).replacingCharacters(
                        in: match.range,
                        with: "<span class=\"embedded-note\" data-note=\"\(htmlEscape(target))\">\(displayText)</span>"
                    )
                }
            } else {
                let encoded = target.addingPercentEncoding(withAllowedCharacters: Self.internalLinkQueryValueAllowed) ?? target
                let href = "cmdmd://open?note=\(encoded)"
                result = (result as NSString).replacingCharacters(
                    in: match.range,
                    with: "<a href=\"\(htmlEscape(href))\" class=\"wiki-link\">\(displayText)</a>"
                )
            }
        }

        return result
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
        let safeTitle = htmlEscape(title)

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

    private func processTags(_ markdown: String) -> String {
        let nsString = markdown as NSString
        let range = NSRange(location: 0, length: nsString.length)

        var result = markdown
        let matches = tagPattern.matches(in: markdown, range: range).reversed()

        for match in matches {
            let fullMatch = nsString.substring(with: match.range)
            let tagName = nsString.substring(with: match.range(at: 1))

            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: "<span class=\"tag\" data-tag=\"\(htmlEscape(tagName))\">\(htmlEscape(fullMatch))</span>"
            )
        }

        return result
    }

    /// Obsidian `==highlight==` → `<mark>`. The inner text stays Markdown, so
    /// `==**bold** highlight==` renders nested formatting.
    private func processHighlights(_ markdown: String) -> String {
        let nsString = markdown as NSString
        let range = NSRange(location: 0, length: nsString.length)

        var result = markdown
        for match in markPattern.matches(in: markdown, range: range).reversed() {
            let inner = nsString.substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: "<mark>\(inner)</mark>"
            )
        }
        return result
    }

    // MARK: Document shell

    private func wrapWithHTML(body: String, options: MarkdownRenderOptions) -> String {
        let hasMermaid = body.contains("class=\"mermaid\"")
        let hasCode = body.contains("<pre><code")

        // Classic UMD build (sets window.mermaid). The ESM build's `import`
        // misbehaves under WKWebView's file:// base URL, so the global build is
        // the reliable choice here. v11 still auto-renders `.mermaid` via
        // startOnLoad.
        let mermaidScript = hasMermaid ? """
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
            <script>
                document.addEventListener('DOMContentLoaded', function() {
                    if (typeof mermaid === 'undefined') return;
                    mermaid.initialize({
                        startOnLoad: true,
                        theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
                        securityLevel: 'loose',
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

        let katexIncludes = options.enableKaTeX ? """
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.css">
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16/dist/katex.min.js"></script>
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16/dist/contrib/mhchem.min.js"></script>
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16/dist/contrib/auto-render.min.js"
                onload="renderMathInElement(document.body, {delimiters: [{left: '$$', right: '$$', display: true}, {left: '\\\\[', right: '\\\\]', display: true}, {left: '\\\\(', right: '\\\\)', display: false}, {left: '$', right: '$', display: false}], throwOnError: false});"></script>
            """ : ""

        let highlightIncludes = (options.enableCodeHighlight && hasCode)
            ? hljsIncludes(theme: options.preview.codeBlockTheme)
            : ""

        let taskScript = options.interactiveTasks ? """
            <script>
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
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
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
        let charWidthRule = abs(p.charWidth - 1.0) > 0.001 ? """
        .markdown-body p, .markdown-body li,
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6,
        .markdown-body blockquote {
            transform: scaleX(\(String(format: "%.3f", p.charWidth)));
            transform-origin: left center;
        }
        """ : ""

        return """
        body {
            font-family: \(p.fontFamily);
            font-size: \(Int(p.fontSize))px;
            line-height: \(String(format: "%.2f", p.lineHeight));
            max-width: \(Int(p.maxWidth))px;
            letter-spacing: \(String(format: "%.3f", p.letterSpacing))em;
            word-spacing: \(String(format: "%.3f", p.wordSpacing))em;
        }
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

    private func hljsIncludes(theme: String) -> String {
        let base = "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build"
        let styleLinks: String
        switch theme {
        case "github":
            // Auto light/dark pairing for the default theme.
            styleLinks = """
            <link rel="stylesheet" media="(prefers-color-scheme: light)" href="\(base)/styles/github.min.css">
            <link rel="stylesheet" media="(prefers-color-scheme: dark)" href="\(base)/styles/github-dark.min.css">
            """
        default:
            styleLinks = "<link rel=\"stylesheet\" href=\"\(base)/styles/\(htmlEscape(theme)).min.css\">"
        }

        return """
        \(styleLinks)
        <script src="\(base)/highlight.min.js"></script>
        <script>
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
        // Slug from the heading's plain text via the shared, Unicode-aware,
        // deduplicating slugger so non-ASCII and duplicate headings each get a
        // usable anchor id that matches the TOC.
        let id = slugger.slug(for: heading.plainText)
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

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        inlineHTML.rawHTML
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
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
