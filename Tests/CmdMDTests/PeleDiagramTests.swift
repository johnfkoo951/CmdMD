import CryptoKit
import JavaScriptCore
import WebKit
import XCTest
@testable import CmdMD

/// ```mermaid fences drawn by Pele through cmds-pele: the page markup, what
/// it loads and from where, the theme hookup, and (in WebKit) the result.
final class PeleDiagramTests: CheckoutLibrariesTestCase {
    private static let peleFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CmdMDTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/PreviewLibs/cmds-pele", isDirectory: true)

    private let diagram = "```mermaid\nflowchart LR\n    A[Open] --> B{Review}\n```"

    private func render(_ markdown: String, configure: (inout MarkdownRenderOptions) -> Void = { _ in }) -> String {
        var options = MarkdownRenderOptions()
        configure(&options)
        return MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
    }

    private func body(of html: String) -> String {
        guard let start = html.range(of: "<body") else { return "" }
        return String(html[start.lowerBound...])
    }

    private func matches(_ pattern: String, in html: String, group: Int = 0) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: group)) }
    }

    private func scriptSources(in html: String) -> [String] {
        let policy = matches(#"<meta http-equiv="Content-Security-Policy" content="([^"]*)""#, in: html, group: 1).first ?? ""
        let directive = policy.components(separatedBy: "; ").first { $0.hasPrefix("script-src ") } ?? ""
        return Array(directive.components(separatedBy: " ").dropFirst(2))
    }

    /// The `{src, integrity}` pairs the loader adds after first paint.
    private func loadedScripts(in html: String) -> [(src: String, integrity: String)] {
        let regex = try! NSRegularExpression(pattern: #"\{src: '([^']*)', integrity: '([^']*)'\}"#)
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    private func bundled(_ file: String) throws -> Data {
        try Data(contentsOf: Self.peleFolder.appendingPathComponent(file))
    }

    private func sha384(_ data: Data) -> String {
        "sha384-" + Data(SHA384.hash(data: data)).base64EncodedString()
    }

    // MARK: Markup

    func testFenceBecomesAPreThatCmdsPeleMounts() {
        let html = body(of: render(diagram))
        XCTAssertTrue(html.contains("<div class=\"cmdmd-diagram\"><pre class=\"mermaid\">flowchart LR\n    A[Open] --&gt; B{Review}\n</pre></div>"))
    }

    /// cmds-pele SURFACES: an italic line right after the fence is the
    /// caption; `%% @caption` stands in only without one.
    func testItalicLineAfterADiagramIsItsCaption() {
        // An export page: no live-page block markers between the blocks.
        let html = body(of: render("\(diagram)\n*The review loop*\n\nAfter.") { $0.interactiveTasks = false })
        XCTAssertTrue(html.contains("<div class=\"cmdmd-diagram\"><pre class=\"mermaid\" data-captioned>flowchart LR"))
        XCTAssertTrue(html.contains("</pre></div>\n<p class=\"cmdmd-diagram-caption\"><em>The review loop</em></p>\n<p>After.</p>"))

        // Not a caption: more than the italic run, another block between,
        // or a diagram inside a quote (only top-level blocks are paired).
        for markdown in ["\(diagram)\n*Italic* and plain", "\(diagram)\n\n---\n\n*Italic*", "\(diagram)\n**Bold**",
                         "> \(diagram.replacingOccurrences(of: "\n", with: "\n> "))\n>\n> *Italic*"] {
            let page = body(of: render(markdown))
            XCTAssertFalse(page.contains("data-captioned"), markdown)
            XCTAssertFalse(page.contains("cmdmd-diagram-caption\""), markdown)
        }
        // Diagrams off: the italic line is a paragraph like any other.
        XCTAssertFalse(body(of: render("\(diagram)\n*The review loop*") { $0.enableMermaid = false }).contains("cmdmd-diagram-caption\""))
    }

    /// The caption sits on its own block, so the live page's block list
    /// still has one range per Markdown block.
    func testCaptionedDiagramKeepsOneBlockRangePerMarkdownBlock() {
        let body = MarkdownRenderer().renderBody(markdown: "# T\n\n\(diagram)\n*Caption*\n\nEnd.", options: MarkdownRenderOptions())
        XCTAssertEqual(body.blockRanges.count, 4)
    }

    func testScriptInADiagramStaysInertText() throws {
        let source = "flowchart TD\n    A[\"</script><script>window.pwned=1</script>\"] --> B[\"<img src=x onerror=alert(1)>\"]\n"
        let html = body(of: render("```mermaid\n\(source)```"))
        XCTAssertFalse(html.lowercased().contains("<script"))
        XCTAssertFalse(html.lowercased().contains("</script"))
        XCTAssertFalse(html.contains("<img"))
        let pre = try XCTUnwrap(matches(#"<pre class="mermaid">([^<]*)</pre>"#, in: html, group: 1).first)
        // The text node Pele reads is the source, character for character.
        let decoded = pre.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        XCTAssertEqual(decoded, source)
    }

    func testMermaidJSIsGoneFromEveryPage() {
        for origin in [PreviewLibraryOrigin.bundled, .cdn] {
            let html = render(diagram, configure: { $0.libraries = origin })
            for needle in ["mermaid.min.js", "mermaid@", "mermaid.initialize", "startOnLoad", "<div class=\"mermaid\""] {
                XCTAssertFalse(html.contains(needle), "\(origin): \(needle)")
            }
        }
    }

    // MARK: What a page loads

    func testBundledDiagramPageAllowsExactlyTheBundledPeleScripts() throws {
        let html = render(diagram)
        let peleURLs = ["cmdmd-lib://lib/cmds-pele/pele.global.js", "cmdmd-lib://lib/cmds-pele/cmds-pele.js"]
        XCTAssertEqual(scriptSources(in: html), peleURLs)

        // Loaded in that order after first paint, each pinned to its bytes.
        let scripts = loadedScripts(in: html)
        XCTAssertEqual(scripts.map(\.src), peleURLs)
        XCTAssertEqual(scripts.map(\.integrity), [sha384(try bundled("pele.global.js")), sha384(try bundled("cmds-pele.js"))])
        XCTAssertTrue(html.contains("<link rel=\"stylesheet\" href=\"cmdmd-lib://lib/cmds-pele/cmds-pele.css\" integrity=\"\(sha384(try bundled("cmds-pele.css")))\" crossorigin=\"anonymous\">"))
        XCTAssertFalse(html.contains("<script src=\"cmdmd-lib://lib/cmds-pele/"), "never parser-blocking")
        XCTAssertTrue(html.contains("profile: 'screen', theme: theme, figure: !source.hasAttribute('data-captioned')"),
                      "%% @caption needs figure, unless a caption line follows")
    }

    func testPagesWithoutADiagramLoadNoPele() {
        for html in [render("```swift\nlet x = 1\n```"), render(diagram, configure: { $0.enableMermaid = false })] {
            XCTAssertFalse(scriptSources(in: html).contains { $0.contains("pele") })
            XCTAssertFalse(html.contains("cmds-pele"))
            XCTAssertFalse(html.contains("cmdmdDiagrams"))
        }
    }

    func testExportLoadsTheBundledPeleReleaseFromJSDelivr() throws {
        let stamp = try XCTUnwrap(JSONSerialization.jsonObject(with: try bundled("cmds-pele.version.json")) as? [String: Any])
        let version = try XCTUnwrap(stamp["pele"] as? String)
        let url = "https://cdn.jsdelivr.net/npm/pele@\(version)/dist/pele.global.js"
        XCTAssertEqual(PreviewLibrary.peleVersion, version)

        let html = ExportService().exportToHTML(
            document: MarkdownDocument(content: diagram, fileURL: URL(fileURLWithPath: "/tmp/notes/n.md")),
            options: MarkdownRenderOptions()
        )
        XCTAssertFalse(html.contains("cmdmd-lib"))
        XCTAssertEqual(scriptSources(in: html), [url])
        let scripts = loadedScripts(in: html)
        XCTAssertEqual(scripts.map(\.src), [url])
        // jsDelivr serves npm's bytes, which cmds-pele ships unchanged.
        XCTAssertEqual(scripts.first?.integrity, sha384(try bundled("pele.global.js")))
    }

    func testExportInlinesTheBootstrapAndThemeWhole() throws {
        let html = render(diagram, configure: { $0.libraries = .cdn })
        let bootstrap = String(decoding: try bundled("cmds-pele.js"), as: UTF8.self)
        let nonce = try XCTUnwrap(matches(#"'nonce-([^']+)'"#, in: html, group: 1).first)
        let open = "<script nonce=\"\(nonce)\">/*! cmds-pele"
        let start = try XCTUnwrap(html.range(of: open)).upperBound
        let end = try XCTUnwrap(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        // The element runs to the bootstrap's own end: no "</script" inside closed it early.
        let inlined = "/*! cmds-pele" + html[start..<end]
        XCTAssertEqual(inlined.replacingOccurrences(of: "<\\/script", with: "</script"), bootstrap)

        let css = String(decoding: try bundled("cmds-pele.css"), as: UTF8.self)
        XCTAssertTrue(html.contains("<style>\(css)</style>"))
    }

    func testScreenProfileTurnsLinksAndImagesOff() throws {
        // Evaluated, not grepped: a later cmds-pele may write it differently.
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var window = this;")
        context.evaluateScript(String(decoding: try bundled("cmds-pele.js"), as: UTF8.self))
        XCTAssertNil(context.exception)
        let screen = context.evaluateScript("window.cmdsPele.profiles.screen")
        XCTAssertEqual(screen?.forProperty("links").toBool(), false)
        XCTAssertEqual(screen?.forProperty("images").toBool(), false)
    }

    // MARK: Theme hookup

    func testEveryThemeHandsPeleItsPageColorsAndFont() {
        for theme in PreviewTheme.allCases {
            let html = render(diagram, configure: {
                $0.theme = theme
                $0.preview.fontFamily = "Inter, sans-serif"
            })
            // The page's fonts reach Pele through the theme tokens, which
            // the font setting overrides.
            for token in ["--cp-bg:var(--bg-primary)", "--cp-fg:var(--text-primary)",
                          "--cp-font:var(--font-body)", "--cp-font-mono:var(--font-mono)"] {
                XCTAssertTrue(html.contains(token), "\(theme): \(token)")
            }
            XCTAssertTrue(html.contains("--font-body: Inter, -apple-system, BlinkMacSystemFont, sans-serif"), theme.rawValue)
            // CMDS keeps cmds-pele's palette, the brand's own.
            XCTAssertEqual(html.contains("--cp-accent:var(--accent)"), theme != .cmds, theme.rawValue)
            XCTAssertTrue(html.contains("'\(theme == .darkPro ? "dark" : "auto")');</script>"), theme.rawValue)
        }
    }

    // MARK: The stamp

    func testPeleVersionComesFromTheStamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMD-PeleStamp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("cmds-pele", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let roots = PreviewLibrary.Roots(libraries: root, highlightr: nil)

        func version(_ stamp: String) throws -> String? {
            try Data(stamp.utf8).write(to: folder.appendingPathComponent("cmds-pele.version.json"))
            return PreviewLibrary.peleVersion(in: roots)
        }
        XCTAssertEqual(try version(#"{"module": "cmds-pele", "version": "0.6.0", "pele": "1.12.0"}"#), "1.12.0")
        XCTAssertEqual(try version(#"{"pele": "2.0.0-beta.1"}"#), "2.0.0-beta.1")
        // It goes into a URL: anything but a plain version is refused.
        for bad in ["latest", "1.10", "1.10.1/../../evil", "1.10.1?x", "1.10.1 ", ""] {
            XCTAssertNil(try version(#"{"pele": "\#(bad)"}"#), bad)
        }
        XCTAssertNil(try version("not json"))
        XCTAssertNil(PreviewLibrary.peleVersion(in: PreviewLibrary.Roots(libraries: nil, highlightr: nil)))
    }

    // MARK: In WebKit

    func testWebKitDrawsDiagramsAndFallsBackToTheSource() throws {
        let markdown = """
        ```mermaid
        %% @key: B
        %% @caption: The review loop
        flowchart LR
            A[Open] --> B{Review}
        ```

        ```mermaid
        flowchart LR
            A[Open --> B{{
        ```

        ```mermaid
        flowchart TD
            A["</script><script>window.pwned=1</script>"] --> B["<img src=x onerror=window.pwned=2>"]
        ```

        ```mermaid
        %% @caption: Not shown
        flowchart LR
            C --> D
        ```
        *The visible caption*
        """
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(PreviewLibrarySchemeHandler(), forURLScheme: PreviewLibrary.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }
        webView.loadHTMLString(render(markdown), baseURL: nil)

        var result: [String: Any]?
        let settled = expectation(description: "diagrams settled")
        func ask() {
            webView.callAsyncJavaScript("""
                if (!window.cmdmdDiagrams) return null;
                await window.cmdmdDiagrams;
                const all = s => Array.from(document.querySelectorAll(s));
                return {
                    drawn: all('.cmdmd-diagram svg.pele').length,
                    captions: all('.cmds-figure figcaption').map(e => e.textContent),
                    lineCaptions: all('.cmdmd-diagram + p.cmdmd-diagram-caption').map(e => e.textContent),
                    keys: all('.cmds-key').length,
                    errors: all('.cmdmd-diagram-error').map(e => e.textContent),
                    sourcesShown: all('.cmdmd-diagram-failed > pre.mermaid').length,
                    pending: document.documentElement.classList.contains('cmdmd-diagrams-pending'),
                    pwned: typeof window.pwned,
                    injected: all('.cmdmd-diagram img, .cmdmd-diagram script').length
                };
                """, arguments: [:], in: nil, in: .page) { value in
                if case .success(let dictionary as [String: Any]) = value {
                    result = dictionary
                    settled.fulfill()
                } else {
                    // The page hasn't parsed its head yet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: ask)
                }
            }
        }
        ask()
        let outcome = XCTWaiter.wait(for: [settled], timeout: 15)
        try XCTSkipUnless(outcome == .completed, "the page did not load in this environment")
        let page = try XCTUnwrap(result)

        XCTAssertEqual(page["drawn"] as? Int, 3)
        XCTAssertEqual(page["captions"] as? [String], ["The review loop"], "the caption line wins over %% @caption")
        XCTAssertEqual(page["lineCaptions"] as? [String], ["The visible caption"])
        XCTAssertGreaterThanOrEqual(page["keys"] as? Int ?? 0, 1, "%% @key marks node B")
        XCTAssertEqual(page["sourcesShown"] as? Int, 1, "the broken diagram is a code block again")
        let errors = page["errors"] as? [String] ?? []
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.hasPrefix("Diagram error: Parse error on line 2: Expecting") ?? false, errors.first ?? "")
        XCTAssertEqual(page["pending"] as? Bool, false)
        XCTAssertEqual(page["pwned"] as? String, "undefined")
        XCTAssertEqual(page["injected"] as? Int, 0)
    }
}
