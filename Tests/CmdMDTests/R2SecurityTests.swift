import XCTest
import WebKit
@testable import CmdMD

/// Preview security: opening an untrusted note must not run script, launch
/// URLs or read local files.
final class R2SecurityTests: XCTestCase {
    private func render(
        _ markdown: String,
        baseURL: URL? = nil,
        configure: (inout MarkdownRenderOptions) -> Void = { _ in }
    ) -> String {
        var options = MarkdownRenderOptions()
        configure(&options)
        return MarkdownRenderer().renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
    }

    private func body(of html: String) -> String {
        guard let start = html.range(of: "<body") else { return "" }
        return String(html[start.lowerBound...])
    }

    private func csp(in html: String) -> String? {
        let marker = "<meta http-equiv=\"Content-Security-Policy\" content=\""
        guard let start = html.range(of: marker)?.upperBound,
              let end = html[start...].firstIndex(of: "\"") else { return nil }
        return String(html[start..<end])
    }

    private func directive(_ name: String, in policy: String) -> String {
        policy.components(separatedBy: "; ").first { $0.hasPrefix(name + " ") } ?? ""
    }

    private func nonce(in html: String) -> String? {
        guard let policy = csp(in: html),
              let start = policy.range(of: "'nonce-")?.upperBound,
              let end = policy[start...].firstIndex(of: "'") else { return nil }
        return String(policy[start..<end])
    }

    private func matches(_ pattern: String, in html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    // MARK: Content-Security-Policy (F053)

    func testPageCarriesStrictPolicyBeforeAnyScriptOrStyle() throws {
        let html = render("```swift\nlet x = 1\n```")
        let policy = try XCTUnwrap(csp(in: html))
        for required in ["default-src 'none'", "object-src 'none'", "base-uri 'none'",
                         "form-action 'none'", "connect-src 'none'", "frame-src 'none'"] {
            XCTAssertTrue(policy.contains(required), "missing \(required)")
        }
        XCTAssertFalse(policy.contains("unsafe-eval"))

        let scriptSources = directive("script-src", in: policy).components(separatedBy: " ").dropFirst()
        XCTAssertFalse(scriptSources.contains("'unsafe-inline'"))
        for source in scriptSources where !source.hasPrefix("'nonce-") {
            XCTAssertTrue(source.hasSuffix(".js"), "script-src must list exact files, not hosts: \(source)")
        }

        let policyStart = try XCTUnwrap(html.range(of: "Content-Security-Policy")).lowerBound
        XCTAssertLessThan(policyStart, try XCTUnwrap(html.range(of: "<style")).lowerBound)
        XCTAssertLessThan(policyStart, try XCTUnwrap(html.range(of: "<script")).lowerBound)
    }

    func testEveryScriptTagCarriesThePageNonce() throws {
        let html = render(
            "- [ ] task\n\n```swift\nlet x = 1\n```\n\n```mermaid\ngraph TD; A-->B\n```\n\n$a_b$",
            configure: { $0.enableKaTeX = true }
        )
        let nonce = try XCTUnwrap(nonce(in: html))
        XCTAssertGreaterThanOrEqual(nonce.count, 32)

        let scripts = matches("<script\\b[^>]*>", in: html)
        // hljs + init, mermaid + init, KaTeX ×3 + init, task bridge.
        XCTAssertEqual(scripts.count, 9)
        for tag in scripts {
            XCTAssertTrue(tag.contains("nonce=\"\(nonce)\""), "script without nonce: \(tag)")
        }
        XCTAssertFalse(html.contains("onload="), "inline handlers are outside the CSP")
    }

    func testNonceIsFreshPerRender() {
        XCTAssertNotEqual(nonce(in: render("a")), nonce(in: render("a")))
    }

    func testScriptSourceListsOnlyIncludedFiles() throws {
        let plain = try XCTUnwrap(csp(in: render("just text")))
        XCTAssertFalse(directive("script-src", in: plain).contains("https://"))

        let withCode = try XCTUnwrap(csp(in: render("```swift\nlet x = 1\n```")))
        XCTAssertTrue(directive("script-src", in: withCode).contains("/highlight.min.js"))
        XCTAssertFalse(directive("script-src", in: withCode).contains("mermaid"))
    }

    // MARK: Raw HTML neutralized (F053)

    func testRawScriptElementIsRemoved() {
        let html = body(of: render("before\n\n<script>window.pwned = 1</script>\n\nafter"))
        XCTAssertFalse(html.lowercased().contains("<script"))
        XCTAssertFalse(html.contains("window.pwned"))
        XCTAssertTrue(html.contains("after"))
    }

    func testInlineScriptTagIsRemoved() {
        let html = body(of: render("text <SCRIPT>alert(1)</SCRIPT> more"))
        XCTAssertFalse(html.lowercased().contains("<script"))
        XCTAssertFalse(html.lowercased().contains("</script"))
    }

    func testEventHandlerAttributesAreStripped() {
        let html = body(of: render(
            "<img src=x onerror=\"alert(1)\">\n\n<div onclick='x()' class=\"keep\">hi</div>\n\n<p>\n<svg/onload=alert(1)>\n</p>"
        ))
        XCTAssertFalse(html.lowercased().contains("onerror"))
        XCTAssertFalse(html.lowercased().contains("onclick"))
        XCTAssertFalse(html.lowercased().contains("onload"))
        XCTAssertTrue(html.contains("<div class=\"keep\">"))
    }

    func testScriptURLsAndSrcdocInRawHTMLAreStripped() {
        let html = body(of: render("""
        <a href="javascript:alert(1)">a</a>
        <a href="java&#x09;script:alert(1)">b</a>
        <a href="javascript&colon;alert(1)">c</a>
        <a href="data:text/html,x">d</a>
        <iframe srcdoc="<script>alert(1)</script>"></iframe>
        <svg><a><animate attributeName="href" values="javascript:alert(1)"/></a></svg>
        """))
        XCTAssertFalse(html.lowercased().contains("javascript"))
        XCTAssertFalse(html.contains("data:text/html"))
        XCTAssertFalse(html.contains("srcdoc"))
        XCTAssertTrue(html.contains("<a>a</a>"), "the element stays, only the attribute goes")
    }

    func testMarkdownScriptLinksAreNeutralized() {
        let html = render("[a](javascript:alert(1)) [b](java&#9;script:alert(1)) [c](&#1;javascript:alert(1))")
        XCTAssertFalse(body(of: html).lowercased().contains("script:"))
        XCTAssertEqual(matches("href=\"#\"", in: html).count, 3)
    }

    func testQuotedGreaterThanCannotHideAHandler() {
        let html = body(of: render("<img alt=\">\" src=x onerror=alert(1)>"))
        XCTAssertFalse(html.contains("onerror"))
    }

    func testCommentCannotHideAHandler() {
        let html = body(of: render("<div>\n<!-- <img alt=\" -->\n<img src=x onerror=alert(1) title=\"x\">\n</div>"))
        XCTAssertFalse(html.contains("onerror"))
        XCTAssertFalse(html.contains("<!--"))
    }

    func testUnterminatedTagIsEscapedInsteadOfSwallowingLaterMarkup() {
        // The open quote must not pair with a quote in the link rendered after it.
        let html = body(of: render("<div>\n<img src=x alt=\"\n\n[a](<b onerror=alert(1) x>)"))
        XCTAssertTrue(html.contains("&lt;img src=x alt=\""))
        XCTAssertFalse(html.contains("<img src=x"))
    }

    func testUnclosedRawTextElementIsEscaped() {
        // An inline <style> that never closes in its node must not put the
        // browser in raw-text mode across the markup that follows.
        let html = body(of: render("a <style> b\n\n<div title=\"</style><img src=x onerror=alert(1)>\">"))
        XCTAssertTrue(html.contains("a &lt;style> b"))
        XCTAssertTrue(matches("<img\\b[^>]*onerror", in: html).isEmpty, "no live handler")

        let closed = body(of: render("<style>\n\n<div title=\"</style><img src=x onerror=alert(1)>\">"))
        XCTAssertTrue(closed.contains("<style>\n\n&lt;div title=\"</style><img src=\"x\">"))
    }

    func testRawTextContentCannotOpenTags() {
        // Inside <svg>, <style> content is markup, not text.
        let html = RawHTMLSanitizer.sanitize("<svg><style><img src=x onerror=alert(1)></style></svg>")
        XCTAssertEqual(html, "<svg><style>&lt;img src=x onerror=alert(1)></style></svg>")
    }

    func testMetaRefreshBaseAndPluginsAreDropped() {
        let html = body(of: render("""
        <meta http-equiv="refresh" content="0;url=https://example.com">
        <base href="https://evil.example/">
        <object data="x.swf"></object><embed src="y">
        """))
        XCTAssertFalse(html.contains("<meta"))
        XCTAssertFalse(html.contains("<base"))
        XCTAssertFalse(html.contains("<object"))
        XCTAssertFalse(html.contains("<embed"))
    }

    func testAppMarkupSurvivesSanitizing() {
        let html = render("""
        > [!note] Title
        > See [[Other Note]] and #tag ==hi==

        <details><summary>More</summary>

        body

        </details>
        """)
        XCTAssertTrue(html.contains("class=\"callout callout-note\""))
        XCTAssertTrue(html.contains("<a href=\"cmdmd://open?note=Other%20Note\" class=\"wiki-link\">Other Note</a>"))
        XCTAssertTrue(html.contains("<span class=\"tag\" data-tag=\"tag\">#tag</span>"))
        XCTAssertTrue(html.contains("<mark>hi</mark>"))
        XCTAssertTrue(html.contains("<details><summary>More</summary>"))
    }

    func testTextMentioningJavaScriptIsNotStripped() {
        let html = render("[[JavaScript: The Good Parts]]\n\n<abbr title=\"javascript: a scheme\">js</abbr>")
        XCTAssertTrue(html.contains("href=\"cmdmd://open?note=JavaScript:%20The%20Good%20Parts\""))
        XCTAssertTrue(html.contains("<abbr title=\"javascript: a scheme\">"))
    }

    func testSanitizerNormalizesAndIsIdempotent() {
        let once = RawHTMLSanitizer.sanitize("<img src='a.png' alt=x/>")
        XCTAssertEqual(once, "<img src=\"a.png\" alt=\"x/\">")
        XCTAssertEqual(RawHTMLSanitizer.sanitize(once), once)
        XCTAssertEqual(RawHTMLSanitizer.sanitize("<br/>"), "<br />")
        XCTAssertEqual(RawHTMLSanitizer.sanitize("a < b"), "a &lt; b")
    }

    // MARK: sanitizeURL (F058)

    func testSanitizeURLChecksSchemeAfterDroppingControlCharacters() {
        XCTAssertEqual(sanitizeURL("java\tscript:alert(1)"), "#")
        XCTAssertEqual(sanitizeURL("\u{1}javascript:alert(1)"), "#")
        XCTAssertEqual(sanitizeURL("java\nscript:alert(1)"), "#")
        XCTAssertEqual(sanitizeURL("JaVaScRiPt:alert(1)"), "#")
        XCTAssertEqual(sanitizeURL("vb\u{0}script:x"), "#")
        XCTAssertEqual(sanitizeURL("data:text/html,<script>"), "#")
        XCTAssertEqual(sanitizeURL("data:image/png;base64,AAAA"), "data:image/png;base64,AAAA")
        XCTAssertEqual(sanitizeURL("https://a.b/?q=1&r=2"), "https://a.b/?q=1&amp;r=2")
        XCTAssertEqual(sanitizeURL("notes/My Note.md"), "notes/My Note.md")
    }

    // MARK: Wiki embeds and callout titles (F056)

    func testWikiEmbedCodeSpanCannotBreakOutOfAttributes() {
        let html = render("![[`x\" onerror=\"alert(1)//`.png]]")
        XCTAssertFalse(html.contains("onerror=\"alert"))
        XCTAssertTrue(html.contains("&quot; onerror=&quot;alert(1)//`.png\""), "quotes must stay escaped inside src")

        // Obsidian order: target first, then the alias (the alt text here).
        let alias = render("![[x.png|`\" onerror=alert(1) x=\"`]]")
        XCTAssertTrue(alias.contains("alt=\"`&quot; onerror=alert(1) x=&quot;`\""))

        // A code span as the target lands in data-note, escaped just the same.
        let target = render("![[`\" onerror=alert(1) x=\"`|x.png]]")
        XCTAssertTrue(target.contains("data-note=\"`&quot; onerror=alert(1) x=&quot;`\""))
        XCTAssertFalse(target.contains("\" onerror=alert(1)"))
    }

    func testWikiLinkWithCodeSpanKeepsACleanHref() {
        let html = render("[[`code` note]]")
        XCTAssertTrue(html.contains("href=\"cmdmd://open?note=%60code%60%20note\""))
        XCTAssertFalse(html.contains("%EE%80%80"), "no placeholder may leak into the link")
        XCTAssertTrue(html.contains("<code>code</code>"), "link text still renders the code span")
    }

    func testCalloutTitleCodeIsEscaped() {
        let html = render("> [!tip] Use `<img src=x onerror=alert(1)>` here\n> body")
        XCTAssertTrue(html.contains("Use `&lt;img src=x onerror=alert(1)&gt;` here"))
        XCTAssertFalse(body(of: html).contains("<img src=x"))
    }

    // MARK: Pinned CDN with SRI (F060)

    func testCDNTagsArePinnedWithSubresourceIntegrity() {
        let html = render(
            "```swift\nlet x = 1\n```\n\n```mermaid\ngraph TD; A-->B\n```\n\n$x$",
            configure: { $0.enableKaTeX = true }
        )
        XCTAssertTrue(html.contains("highlight.min.js"))
        XCTAssertTrue(html.contains("katex"))
        XCTAssertTrue(html.contains("class=\"mermaid\""))

        let cdnTags = matches("<(script|link)\\b[^>]*cdn\\.jsdelivr\\.net[^>]*>", in: html)
        // hljs light+dark CSS, hljs, mermaid, KaTeX CSS + 3 scripts.
        XCTAssertEqual(cdnTags.count, 8)
        for tag in cdnTags {
            XCTAssertTrue(tag.contains("integrity=\"sha384-"), "no SRI: \(tag)")
            XCTAssertTrue(tag.contains("crossorigin=\"anonymous\""), "no CORS mode: \(tag)")
        }
        for floating in ["mermaid@11/", "katex@0.16/", "cdn-release@"] {
            XCTAssertFalse(html.contains(floating), "floating version range: \(floating)")
        }
    }

    // MARK: Mermaid (F026)

    func testMermaidUsesStrictSecurityLevel() {
        let html = render("```mermaid\ngraph TD; A-->B\n```")
        XCTAssertTrue(html.contains("securityLevel: 'strict'"))
        XCTAssertFalse(html.contains("'loose'"))
    }

    // MARK: Scroll-restore injection

    func testInsertedHeadScriptCarriesNonceAndOnlyHitsTheRendererHead() throws {
        // Raw HTML may itself contain `</head>`; only the renderer's own counts.
        let html = render("<div>\n</head><p>x</p>\n</div>")
        let nonce = try XCTUnwrap(nonce(in: html))
        let injected = MarkdownRenderer.insertingHeadScript("window.y=1;", into: html)

        XCTAssertTrue(injected.contains("<script nonce=\"\(nonce)\">window.y=1;</script></head>"))
        XCTAssertEqual(injected.components(separatedBy: "window.y=1;").count, 2)
        let script = try XCTUnwrap(injected.range(of: "window.y=1;")).lowerBound
        XCTAssertLessThan(script, try XCTUnwrap(injected.range(of: "<body")).lowerBound)
    }

    // MARK: Navigation policy (F119, F131)

    private let page = URL(fileURLWithPath: "/Users/me/notes/", isDirectory: true)

    private func decide(
        _ url: URL,
        _ type: WKNavigationType,
        mainFrame: Bool = true,
        page: URL? = nil
    ) -> PreviewNavigationPolicy.Decision {
        PreviewNavigationPolicy.decide(url: url, navigationType: type, isMainFrame: mainFrame, pageURL: page ?? self.page)
    }

    func testOnlyThePagesOwnLoadPassesWithoutAClick() {
        XCTAssertEqual(decide(page, .other), .allow)
        XCTAssertEqual(decide(URL(string: "about:blank")!, .other, page: URL(string: "about:blank")!), .allow)

        // Meta refresh, scripted location, form posts: never leave the page.
        XCTAssertEqual(decide(URL(string: "https://example.com/phish")!, .other), .cancel)
        XCTAssertEqual(decide(URL(string: "obsidian://new?vault=Notes&name=pwned")!, .other), .cancel)
        XCTAssertEqual(decide(URL(string: "cmdmd://open?path=/etc/hosts")!, .other), .cancel)
        XCTAssertEqual(decide(URL(fileURLWithPath: "/Users/me/other.md"), .other), .cancel)
        XCTAssertEqual(decide(URL(fileURLWithPath: "/Users/me/", isDirectory: true), .other), .cancel)
        XCTAssertEqual(decide(URL(fileURLWithPath: "/Users/me/notes"), .other), .cancel)
        XCTAssertEqual(decide(URL(string: "https://example.com")!, .formSubmitted), .cancel)
        XCTAssertEqual(decide(URL(string: "about:blank")!, .other), .cancel)
    }

    func testSubframesNeverLeaveThePage() {
        XCTAssertEqual(decide(URL(string: "obsidian://new?name=x")!, .other, mainFrame: false), .cancel)
        XCTAssertEqual(decide(URL(string: "https://example.com")!, .other, mainFrame: false), .cancel)
        XCTAssertEqual(decide(URL(string: "https://example.com")!, .linkActivated, mainFrame: false), .cancel)
        XCTAssertEqual(decide(URL(string: "about:blank")!, .other, mainFrame: false), .allow)
    }

    func testClickedLinksRouteBySchemeAndFileType() {
        let https = URL(string: "https://example.com/a")!
        let mail = URL(string: "mailto:me@example.com")!
        let obsidian = URL(string: "obsidian://open?vault=V&file=N")!
        let internalLink = URL(string: "cmdmd://open?note=Other")!
        XCTAssertEqual(decide(https, .linkActivated), .openExternal(https))
        XCTAssertEqual(decide(mail, .linkActivated), .openExternal(mail))
        XCTAssertEqual(decide(obsidian, .linkActivated), .openExternal(obsidian))
        XCTAssertEqual(decide(internalLink, .linkActivated), .openInternal(internalLink))
        XCTAssertEqual(decide(URL(string: "zotero://select/x")!, .linkActivated), .cancel)
        XCTAssertEqual(decide(URL(string: "data:text/html,x")!, .linkActivated), .cancel)
        XCTAssertEqual(decide(URL(string: "cmdmd-asset://local/Users/me/a.png")!, .linkActivated), .cancel)

        let note = URL(fileURLWithPath: "/Users/me/notes/Other.md")
        XCTAssertEqual(decide(URL(string: note.absoluteString + "#setup")!, .linkActivated), .openNote(note))
        let script = URL(fileURLWithPath: "/Users/me/notes/run.command")
        XCTAssertEqual(decide(script, .linkActivated), .revealInFinder(script), "local files are shown, never launched")
    }

    func testInPageAnchorsScrollInsteadOfOpeningFinder() {
        XCTAssertEqual(decide(URL(string: page.absoluteString + "#install")!, .linkActivated), .allow)
        XCTAssertEqual(decide(URL(string: page.absoluteString + "#")!, .linkActivated), .allow)
        XCTAssertEqual(decide(URL(string: page.absoluteString + "#%ED%95%9C%EA%B5%AD%EC%96%B4")!, .linkActivated), .allow)
        XCTAssertEqual(decide(URL(string: "about:blank#x")!, .linkActivated, page: URL(string: "about:blank")!), .allow)
        // WebKit's NSURL form of a draft anchor (its `fragment` is nil).
        let draftAnchor = NSURL(string: "about:blank#x")! as URL
        XCTAssertEqual(decide(draftAnchor, .linkActivated, page: URL(string: "about:blank")!), .allow)
        // A link to the folder itself is not an anchor.
        XCTAssertEqual(decide(page, .linkActivated), .revealInFinder(page))
    }

    // MARK: Local images (F125)

    func testLocalImageSourcesRewriteToAssetScheme() {
        let base = URL(fileURLWithPath: "/tmp/notes/", isDirectory: true)
        let html = render(
            "![a](<img dir/한.png>)\n\n![[x.png]]\n\n<img src=\"docs/b.png\">\n\n> [!note]\n> ![c](c.png)\n\n![r](https://example.com/r.png)",
            baseURL: base,
            configure: { $0.localAssetRoots = [] }
        )
        XCTAssertTrue(html.contains("src=\"cmdmd-asset://local/tmp/notes/img%20dir/%ED%95%9C.png\""))
        XCTAssertTrue(html.contains("src=\"cmdmd-asset://local/tmp/notes/x.png\""))
        XCTAssertTrue(html.contains("src=\"cmdmd-asset://local/tmp/notes/docs/b.png\""))
        XCTAssertTrue(html.contains("src=\"cmdmd-asset://local/tmp/notes/c.png\""), "callout images too")
        XCTAssertTrue(html.contains("src=\"https://example.com/r.png\""))
    }

    func testImagesKeepTheirSourcesWithoutAssetRoots() {
        let html = render("![a](a.png)", baseURL: URL(fileURLWithPath: "/tmp/notes/", isDirectory: true))
        XCTAssertTrue(html.contains("src=\"a.png\""))
        XCTAssertFalse(html.contains("src=\"cmdmd-asset:"))
    }

    func testImageRewriteStaysInsideAllowedRoots() {
        let base = URL(fileURLWithPath: "/tmp/vault/notes/", isDirectory: true)
        let vault = URL(fileURLWithPath: "/tmp/vault/", isDirectory: true)
        func asset(_ source: String, roots: [URL] = [vault]) -> String? {
            LocalAssetURL.assetURL(forImageSource: source, baseURL: base, roots: roots)
        }

        XCTAssertEqual(asset("../attachments/a.png"), "cmdmd-asset://local/tmp/vault/attachments/a.png")
        XCTAssertEqual(asset("/tmp/vault/b.png"), "cmdmd-asset://local/tmp/vault/b.png")
        XCTAssertNil(asset("../attachments/a.png", roots: []), "outside the note folder and no vault")
        XCTAssertNil(asset("../../../etc/a.png"))
        XCTAssertNil(asset("%2e%2e/%2e%2e/%2e%2e/etc/a.png"))
        XCTAssertNil(asset("/etc/a.png"))
        XCTAssertNil(asset("file:///etc/a.png"))
        XCTAssertNil(asset("/tmp/vault-other/a.png"), "a sibling with the root's prefix is outside")
        XCTAssertNil(asset("notes.txt"))
        XCTAssertNil(asset("https://example.com/a.png"))
        XCTAssertNil(asset("//example.com/a.png"))
        XCTAssertNil(asset("data:image/png;base64,AAAA"))
    }

    func testAssetHandlerOnlyServesImagesInsideRoots() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("r2sec-\(UUID().uuidString)")
        let vault = dir.appendingPathComponent("vault")
        let outside = dir.appendingPathComponent("outside")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data([0x89]).write(to: vault.appendingPathComponent("a b.png"))
        try Data([0x89]).write(to: outside.appendingPathComponent("secret.png"))
        try Data("x".utf8).write(to: vault.appendingPathComponent("note.md"))
        try fm.createSymbolicLink(
            at: vault.appendingPathComponent("link.png"),
            withDestinationURL: outside.appendingPathComponent("secret.png")
        )

        func request(_ path: String, host: String = "local") -> URL {
            URL(string: "cmdmd-asset://\(host)" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
        }
        func served(_ url: URL) -> URL? {
            LocalAssetURL.fileURL(for: url, allowedRoots: [vault])
        }

        XCTAssertEqual(served(request(vault.path + "/a b.png"))?.lastPathComponent, "a b.png")
        XCTAssertNil(served(request(outside.path + "/secret.png")))
        XCTAssertNil(served(request(vault.path + "/../outside/secret.png")))
        XCTAssertNil(served(request(vault.path + "/link.png")), "symlinks can't reach outside a root")
        XCTAssertNil(served(request(vault.path + "/note.md")), "images only")
        XCTAssertNil(served(request(vault.path + "/a b.png", host: "elsewhere")))
        XCTAssertNil(LocalAssetURL.fileURL(for: vault.appendingPathComponent("a b.png"), allowedRoots: [vault]))
    }

    func testHTMLExportKeepsNoteRelativeImageSources() {
        var options = MarkdownRenderOptions()
        options.localAssetRoots = [URL(fileURLWithPath: "/tmp", isDirectory: true)]
        let document = MarkdownDocument(content: "![a](a.png)", fileURL: URL(fileURLWithPath: "/tmp/notes/n.md"))
        let html = ExportService().exportToHTML(document: document, options: options)
        XCTAssertTrue(html.contains("src=\"a.png\""))
        XCTAssertFalse(html.contains("src=\"cmdmd-asset:"))
    }

    // MARK: PDF export (F135)

    func testPDFExportViewIsLightAndCanShowLocalImages() {
        let webView = PDFExporter.makeWebView(assetRoots: [])
        XCTAssertEqual(webView.appearance?.name, .aqua)
        XCTAssertNotNil(webView.configuration.urlSchemeHandler(forURLScheme: LocalAssetURL.scheme))
        XCTAssertTrue(webView.configuration.preferences.shouldPrintBackgrounds)
    }
}
