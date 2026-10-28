import XCTest
import AppKit
@testable import CmdMD

/// Byte-exact dumps of the renderer, for proving a refactor changes no
/// output: every .md in each CMDMD_EQ_DIRS folder (colon-separated) under
/// every theme × line-break × live/export setting (plus plain, KaTeX-off and
/// named-code-theme sets), its TOC, the same notes as NSTextView text (the
/// editor hands over NSString-backed strings) and lone-surrogate text, into
/// CMDMD_EQ_OUT. The page nonce is replaced, so two dumps compare with
/// `diff -r`. Skipped unless both are set.
final class RenderEquivalenceDumpTests: XCTestCase {
    func testDump() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirs = env["CMDMD_EQ_DIRS"], let out = env["CMDMD_EQ_OUT"] else {
            throw XCTSkip("set CMDMD_EQ_DIRS/CMDMD_EQ_OUT")
        }
        let renderer = MarkdownRenderer()
        let variants = Self.variants()
        let bridgedVariants: Set<String> = ["CMDS-obsidianbr-live", "GitHub-strict-export"]
        let tocOptions: [(String, MarkdownRenderOptions)] = {
            var katex = MarkdownRenderOptions(); katex.enableKaTeX = true
            var noWiki = MarkdownRenderOptions(); noWiki.enableWikiLinks = false
            return [("default", MarkdownRenderOptions()), ("katex", katex), ("nowiki", noWiki)]
        }()

        for dir in dirs.split(separator: ":").map(String.init) {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            let group = base.lastPathComponent
            let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".md") }.sorted()
            for file in files {
                let raw = try String(contentsOfFile: (dir as NSString).appendingPathComponent(file), encoding: .utf8)
                let markdown = FileService.parseFrontmatter(from: raw).body
                let textView = NSTextView()
                textView.string = markdown
                let bridged = textView.string
                // Up to 15 bytes bridge to a native small string.
                if markdown.utf8.count > 15 {
                    XCTAssertNil(bridged.utf8.withContiguousStorageIfAvailable { _ in true }, "\(file): NSTextView text should be NSString-backed")
                }

                for (name, var options) in variants {
                    if options.localAssetRoots != nil { options.localAssetRoots = [base] }
                    let page = renderer.renderToHTML(markdown: markdown, baseURL: base, options: options)
                    try Self.write(page, out, name, group, file + ".html")
                    Self.checkBlocks(renderer.renderBody(markdown: markdown, baseURL: base, options: options), page: page, "\(name)/\(file)")
                    if bridgedVariants.contains(name) {
                        try Self.write(renderer.renderToHTML(markdown: bridged, baseURL: base, options: options), out, "bridged-" + name, group, file + ".html")
                    }
                }
                for (name, options) in tocOptions {
                    try Self.write(Self.toc(markdown, options), out, "toc-" + name, group, file + ".toc")
                    try Self.write(Self.toc(bridged, options), out, "toc-bridged-" + name, group, file + ".toc")
                }
            }
        }

        // NSString text can hold a lone surrogate, which a Swift String never does.
        for (index, units) in Self.loneSurrogateNotes.enumerated() {
            let text = NSString(characters: units, length: units.count) as String
            for (name, options) in variants where bridgedVariants.contains(name) {
                try Self.write(renderer.renderToHTML(markdown: text, baseURL: nil, options: options), out, "lone-" + name, "lone", "\(index).html")
            }
            try Self.write(Self.toc(text, MarkdownRenderOptions()), out, "toc-lone", "lone", "\(index).toc")
        }
    }

    private static func variants() -> [(String, MarkdownRenderOptions)] {
        var variants: [(String, MarkdownRenderOptions)] = []
        for theme in PreviewTheme.allCases {
            for obsidianBreaks in [false, true] {
                for live in [true, false] {
                    var options = MarkdownRenderOptions()
                    options.theme = theme
                    options.enableKaTeX = true
                    options.obsidianLineBreaks = obsidianBreaks
                    options.interactiveTasks = live
                    // The live preview rewrites local images; export doesn't.
                    options.localAssetRoots = live ? [] : nil
                    let name = "\(theme.rawValue.replacingOccurrences(of: " ", with: ""))-\(obsidianBreaks ? "obsidianbr" : "strict")-\(live ? "live" : "export")"
                    variants.append((name, options))
                }
            }
        }
        var plain = MarkdownRenderOptions()
        plain.theme = .sepia
        plain.enableWikiLinks = false
        plain.enableCallouts = false
        plain.enableMermaid = false
        plain.enableCodeHighlight = false
        variants.append(("plain", plain))
        var noKaTeX = MarkdownRenderOptions()
        noKaTeX.theme = .cmds
        noKaTeX.localAssetRoots = []
        variants.append(("nokatex", noKaTeX))
        var namedCodeTheme = MarkdownRenderOptions()
        namedCodeTheme.enableKaTeX = true
        namedCodeTheme.preview.codeBlockTheme = "monokai"
        variants.append(("monokai", namedCodeTheme))
        return variants
    }

    private static let loneSurrogateNotes: [[unichar]] = [
        Array("# H\u{FFFD}x\n\n`a`\u{FFFD}b #t\u{FFFD} [[n\u{FFFD}]] $x$\u{FFFD} ==\u{FFFD}==\n\n- [ ] \u{FFFD} task\n".utf16).map { $0 == 0xFFFD ? 0xD800 : $0 },
        Array("> [!note] \u{FFFD}\n> $$\n> \u{FFFD}\n> $$\n\nref[^\u{FFFD}]\n\n[^\u{FFFD}]: x\n".utf16).map { $0 == 0xFFFD ? 0xDC00 : $0 },
    ]

    private static func toc(_ markdown: String, _ options: MarkdownRenderOptions) -> String {
        TOCBuilder.extractHeadings(from: markdown, options: options)
            .map { "\($0.id) \($0.level) \($0.lineNumber) \($0.slug) \($0.text)" }
            .joined(separator: "\n")
    }

    /// The body's blocks run back to back over all of it, each ending a line
    /// (as every block the visitor writes does), and the page holds the body.
    private static func checkBlocks(_ body: MarkdownRenderer.RenderedBody, page: String, _ label: String) {
        let bytes = Array(body.html.utf8)
        var end = 0
        for range in body.blockRanges {
            XCTAssertEqual(range.lowerBound, end, label)
            XCTAssertTrue(range.isEmpty || bytes[range.upperBound - 1] == UInt8(ascii: "\n"), "\(label): block ends mid-line at \(range)")
            end = range.upperBound
        }
        XCTAssertEqual(end, bytes.count, label)
        // Bytes, not canonical equivalence; an empty body is in every page.
        // A live page marks its blocks: they hold the body.
        let unmarked = page.replacingOccurrences(of: PreviewRuntime.marker, with: "")
        XCTAssertTrue(body.html.isEmpty || Data(unmarked.utf8).range(of: Data(body.html.utf8)) != nil, label)
    }

    /// Writes `text` with the page's per-render nonce swapped for NONCE.
    private static func write(_ text: String, _ out: String, _ variant: String, _ group: String, _ file: String) throws {
        var text = text
        if let start = text.range(of: "'nonce-") {
            let nonce = String(text[start.upperBound...].prefix(32))
            text = text.replacingOccurrences(of: nonce, with: "NONCE")
        }
        let dir = ((out as NSString).appendingPathComponent(variant) as NSString).appendingPathComponent(group)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try text.write(toFile: (dir as NSString).appendingPathComponent(file), atomically: false, encoding: .utf8)
    }
}
