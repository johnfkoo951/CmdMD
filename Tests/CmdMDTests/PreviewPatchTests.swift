import WebKit
import XCTest
@testable import CmdMD

/// The live page's blocks, the edits between two pages, and the page
/// runtime's checks, without the preview around them.
final class PreviewPatchTests: CheckoutLibrariesTestCase {
    private let renderer = MarkdownRenderer()

    private func blocks(_ markdown: String, options: MarkdownRenderOptions = MarkdownRenderOptions()) -> [String]? {
        let page = renderer.renderPage(markdown: markdown, options: options)
        let bytes = Array(page.html.utf8)
        return page.blocks?.map { String(decoding: bytes[$0], as: UTF8.self) }
    }

    private func coalesced(_ html: String, _ pieces: [String]) -> [String]? {
        var offset = 0
        let ranges = pieces.map { piece -> Range<Int> in
            defer { offset += piece.utf8.count }
            return offset..<(offset + piece.utf8.count)
        }
        XCTAssertEqual(pieces.joined(), html)
        let bytes = Array(html.utf8)
        return PreviewBlocks.coalesce(html, ranges: ranges)?.map { String(decoding: bytes[$0], as: UTF8.self) }
    }

    private func page(_ markdown: String, options: MarkdownRenderOptions = MarkdownRenderOptions(), generation: Int = 1) -> PreviewPage {
        PreviewPage(rendered: renderer.renderPage(markdown: markdown, options: options), source: markdown,
                    baseURL: nil, options: options, generation: generation, renderMs: 1)
    }

    // MARK: Blocks

    func testEachMarkdownBlockIsABlock() {
        XCTAssertEqual(blocks("# A\n\npara\n\n- x\n- y\n"), ["<h1 id=\"a\">A</h1>\n", "<p>para</p>\n", "<ul>\n<li><p>x</p>\n</li>\n<li><p>y</p>\n</li>\n</ul>\n"])
        XCTAssertEqual(blocks(""), [])
    }

    func testRawHTMLElementsAcrossBlocksAreOneBlock() throws {
        let details = try XCTUnwrap(blocks("Before\n\n<details>\n<summary>S</summary>\n\nInside **b**\n\n</details>\n\nAfter\n"))
        XCTAssertEqual(details.count, 3)
        XCTAssertTrue(details[1].hasPrefix("<details>") && details[1].hasSuffix("</details>\n"), details[1])

        let footnotes = try XCTUnwrap(blocks("Text[^1] and more[^2].\n\n[^1]: One.\n[^2]: Two\n\n    with a second paragraph.\n"))
        XCTAssertEqual(footnotes.count, 2)
        XCTAssertTrue(footnotes[1].hasPrefix("<section class=\"footnotes\">") && footnotes[1].hasSuffix("</section>\n"), footnotes[1])
    }

    func testMarkupTheScanFollows() {
        XCTAssertEqual(coalesced("<div title=\"a>b\" data-x='</div>'>x</div>\n", ["<div title=\"a>b\" data-x='</div>'>x</div>\n"])?.count, 1, "quoted >")
        XCTAssertEqual(coalesced("<div>\n<!-- </div> -->\n</div>\nz", ["<div>\n", "<!-- </div> -->\n", "</div>\n", "z"]), ["<div>\n<!-- </div> -->\n</div>\n", "z"])
        XCTAssertEqual(coalesced("<style>div > p { }</STYLE>a", ["<style>div > p { }</STYLE>", "a"])?.count, 2, "raw text, any case")
        XCTAssertEqual(coalesced("<textarea></div></textarea>b", ["<textarea></div></textarea>", "b"])?.count, 2)
        XCTAssertEqual(coalesced("<svg><path d=\"M0\"/><g/></svg>c", ["<svg><path d=\"M0\"/><g/></svg>", "c"])?.count, 2, "SVG closes its own")
        XCTAssertEqual(coalesced("<div/>d</div>e", ["<div/>", "d</div>", "e"]), ["<div/>d</div>", "e"], "HTML's /> opens a div")
        XCTAssertEqual(coalesced("<br><img src=x><hr/>f", ["<br>", "<img src=x>", "<hr/>", "f"])?.count, 4, "void")
        XCTAssertEqual(coalesced("<!---->a<!-->b<![CDATA[x]]>c", ["<!---->a", "<!-->b", "<![CDATA[x]]>c"])?.count, 3)
        XCTAssertEqual(coalesced("a < b and </ c>d", ["a < b and ", "</ c>d"])?.count, 2, "not tags")
    }

    func testMarkupParsedDifferentlyAloneLeavesThePageUnpatchable() {
        for (html, pieces) in [
            ("<div>open", ["<div>", "open"]),
            ("</div>stray", ["</div>", "stray"]),
            ("<b><i></b></i>", ["<b><i></b></i>"]),
            ("<p><div></p></div>", ["<p><div></p></div>"]),
            ("<td>cell</td>", ["<td>cell</td>"]),
            ("<body class=x>", ["<body class=x>"]),
            ("<plaintext>rest", ["<plaintext>rest"]),
            ("<!-- open", ["<!-- open"]),
            ("<div title=\"open>", ["<div title=\"open>"])
        ] {
            XCTAssertNil(coalesced(html, pieces), html)
        }
        XCTAssertEqual(coalesced("<table><tr><td>x</td></tr></table>", ["<table><tr><td>x</td></tr></table>"])?.count, 1, "parts inside a table")
        XCTAssertNil(blocks("<div>\n\nnever closed\n"))
    }

    /// Raw text in the page (it runs script), markup in the `<template>` a
    /// patch parses in: `x &amp; <b>y</b>` came out as `x & <b>y</b>`.
    func testANoscriptBlockLeavesThePageUnpatchable() {
        XCTAssertNil(coalesced("<noscript>x &amp; <b>y</b></noscript>z", ["<noscript>x &amp; <b>y</b></noscript>", "z"]))
        XCTAssertNil(blocks("Before\n\n<noscript>\nx &amp; <b>y</b> edited\n</noscript>\n\nAfter\n"))
        XCTAssertNotNil(blocks("Before\n\n<noembed>\nx &amp; <b>y</b>\n</noembed>\n\nAfter\n"), "raw text in a template too")
    }

    // MARK: Pages

    func testLivePageMarksItsBlocksAndCarriesTheRuntime() throws {
        let html = renderer.renderToHTML(markdown: "# A\n\n- [ ] t\n")
        let start = try XCTUnwrap(html.range(of: "<body")).lowerBound
        let body = String(html[start...])
        XCTAssertTrue(body.contains("\(PreviewRuntime.rootOpening)\(PreviewRuntime.marker)<h1 id=\"a\">A</h1>\n\(PreviewRuntime.marker)<ul>"))
        XCTAssertTrue(body.hasSuffix("</ul>\n\(PreviewRuntime.rootClosing)\n</body>\n</html>"))
        XCTAssertEqual(html.components(separatedBy: "window.cmdmdPreview = {patch: patch}").count, 2, "the runtime, once")
        let nonce = try XCTUnwrap(html.range(of: "'nonce-").map { String(html[$0.upperBound...].prefix(32)) })
        XCTAssertTrue(html.contains("<script nonce=\"\(nonce)\">\(PreviewRuntime.script)</script>"))
        XCTAssertTrue(html.contains(PreviewRuntime.rootCSS))
    }

    func testExportPagesHoldNoneOfTheRuntime() {
        var options = MarkdownRenderOptions()
        options.interactiveTasks = false
        options.enableKaTeX = true
        let page = renderer.renderPage(markdown: "# A\n\n- [ ] t\n\n```swift\nx\n```\n\n$y$\n\n```mermaid\nflowchart LR\nA-->B\n```\n", options: options)
        XCTAssertNil(page.blocks)
        for needle in ["cmdmd-root", PreviewRuntime.marker, "data-task", "cmdmdPreview = {", "toggleTask", PreviewRuntime.rootCSS] {
            XCTAssertFalse(page.html.contains(needle), needle)
        }
        XCTAssertTrue(page.html.contains("<body class=\"markdown-body\">\n    <h1 id=\"a\">A</h1>\n"))
    }

    func testTheRuntimeParsesOnlyInATemplate() {
        let script = PreviewRuntime.script
        XCTAssertFalse(script.contains("createContextualFragment"))
        XCTAssertFalse(script.contains("eval("))
        XCTAssertEqual(script.components(separatedBy: ".innerHTML").count, 2)
        XCTAssertTrue(script.contains("template.innerHTML ="))
        XCTAssertFalse(script.contains("<!--"), "a comment opener in script text changes how the element parses")
    }

    func testHeadNamesTheLibrariesAndCallouts() {
        let plain = renderer.renderPage(markdown: "text").head
        XCTAssertEqual(renderer.renderPage(markdown: "other text\n\nmore").head, plain)
        XCTAssertNotEqual(renderer.renderPage(markdown: "```swift\nx\n```").head, plain, "the first code block brings highlight.js")
        XCTAssertNotEqual(renderer.renderPage(markdown: "> [!tip] T\n> b").head, renderer.renderPage(markdown: "> [!note] T\n> b").head)
        XCTAssertEqual(renderer.renderPage(markdown: "> [!note] A\n> b").head, renderer.renderPage(markdown: "> [!note] B\n> c").head)
    }

    // MARK: Edits

    func testEditsReplaceTheChangedRun() throws {
        let old = page("# A\n\none\n\ntwo\n\nthree\n")
        let edit = try XCTUnwrap(PreviewEdit(from: old, to: page("# A\n\none\n\nTWO\n\nthree\n", generation: 2)))
        XCTAssertEqual(edit.count, 4)
        XCTAssertEqual(edit.runs, [PreviewEdit.Run(at: 2, remove: 1, blocks: ["<p>TWO</p>\n"])])

        let inserted = try XCTUnwrap(PreviewEdit(from: old, to: page("# A\n\none\n\nnew\n\ntwo\n\nthree\n", generation: 2)))
        XCTAssertEqual(inserted.runs, [PreviewEdit.Run(at: 2, remove: 0, blocks: ["<p>new</p>\n"])])

        let removed = try XCTUnwrap(PreviewEdit(from: old, to: page("# A\n\nthree\n", generation: 2)))
        XCTAssertEqual(removed.runs, [PreviewEdit.Run(at: 1, remove: 2, blocks: [])])

        let same = try XCTUnwrap(PreviewEdit(from: old, to: page("# A\n\n\n\none\n\ntwo\n\nthree\n", generation: 2)))
        XCTAssertTrue(same.isEmpty, "blank lines move lines, not blocks")

        let korean = try XCTUnwrap(PreviewEdit(from: old, to: page("# A\n\none\n\n두\n\nthree\n", generation: 2)))
        XCTAssertEqual(korean.language, "ko")
        XCTAssertEqual(korean.argument(forPage: "N")["lang"] as? String, "ko")
        XCTAssertEqual(edit.argument(forPage: "N")["lang"] as? String, "")
    }

    func testTaskOrdinalsKeepEnterAboveATaskToOneBlock() throws {
        let old = page("Intro\n\n- [ ] a\n- [ ] b\n\nEnd\n")
        let new = page("Intro\n\nMore\n\n- [ ] a\n- [ ] b\n\nEnd\n", generation: 2)
        let edit = try XCTUnwrap(PreviewEdit(from: old, to: new))
        XCTAssertEqual(edit.runs, [PreviewEdit.Run(at: 1, remove: 0, blocks: ["<p>More</p>\n"])], "the task list keeps its markup")
        XCTAssertEqual(old.rendered.taskLines, [3, 4])
        XCTAssertEqual(new.rendered.taskLines, [5, 6], "its lines moved")
    }

    /// Blocks far apart changed by one edit: separate runs, the blocks
    /// between kept.
    func testAnEditChangingBlocksFarApartIsSeveralRuns() throws {
        let middle = (0..<20).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let tasks = try XCTUnwrap(PreviewEdit(from: page("- [ ] first\n\n\(middle)\n\n- [ ] last\n"),
                                              to: page("- [ ] first\n- [ ] added\n\n\(middle)\n\n- [ ] last\n", generation: 2)))
        XCTAssertEqual(tasks.runs.map { [$0.at, $0.remove, $0.blocks.count] }, [[0, 1, 1], [21, 1, 1]], "the two lists")
        XCTAssertTrue(tasks.runs[1].blocks[0].contains("data-task=\"2\""))

        let headings = try XCTUnwrap(PreviewEdit(from: page("# Top\n\n\(middle)\n\n## Notes\n"),
                                                 to: page("# Top\n\n## Notes\n\n\(middle)\n\n## Notes\n", generation: 2)))
        XCTAssertEqual(headings.runs.map { [$0.at, $0.remove, $0.blocks.count] }, [[1, 0, 1], [21, 1, 1]])
        XCTAssertEqual(headings.runs[1].blocks, ["<h2 id=\"notes-1\">Notes</h2>\n"])

        // A rewrite: nothing between to keep, one run.
        let others = (0..<200).map { "Other \($0)." }.joined(separator: "\n\n")
        let rewrite = try XCTUnwrap(PreviewEdit(from: page(middle), to: page(others, generation: 2)))
        XCTAssertEqual(rewrite.runs.map { [$0.at, $0.remove, $0.blocks.count] }, [[0, 20, 200]])
    }

    func testMatchesAreAShortestEditScript() {
        func pairs(_ a: String, _ b: String, max: Int = 64) -> [String]? {
            let x = Array(a), y = Array(b)
            return PreviewEdit.matches(oldCount: x.count, newCount: y.count, maxEdits: max) { x[$0] == y[$1] }?.map { "\($0.0)\($0.1)" }
        }
        XCTAssertEqual(pairs("abc", "abc"), ["00", "11", "22"])
        XCTAssertEqual(pairs("", "ab"), [])
        XCTAssertEqual(pairs("ab", ""), [])
        XCTAssertEqual(pairs("xbcy", "bcz"), ["10", "21"])
        XCTAssertEqual(pairs("abcabba", "cbabac")?.count, 4, "Myers' example: an LCS of 4")
        XCTAssertNil(pairs("abcdef", "uvwxyz", max: 3), "past the limit")
    }

    func testOnlyALoadCrossesSettingsFoldersHeadsOrUnpatchablePages() {
        let old = page("text")
        var dark = MarkdownRenderOptions()
        dark.theme = .darkPro
        XCTAssertNil(PreviewEdit(from: old, to: page("text", options: dark)))
        XCTAssertNil(PreviewEdit(from: old, to: PreviewPage(rendered: renderer.renderPage(markdown: "text"), source: "text",
                                                            baseURL: URL(fileURLWithPath: "/tmp"), options: MarkdownRenderOptions(), generation: 2, renderMs: 1)))
        XCTAssertNil(PreviewEdit(from: old, to: page("text\n\n```swift\nx\n```")))
        XCTAssertNil(PreviewEdit(from: old, to: page("text\n\n<div>\n\nopen")))
        XCTAssertNil(PreviewEdit(from: page("text\n\n<div>\n\nopen"), to: old))
    }

    func testARefreshedNonceKeepsTheBlocks() throws {
        let rendered = renderer.renderPage(markdown: "# A\n\n한국어\n")
        let refreshed = rendered.refreshingNonce()
        XCTAssertNotEqual(refreshed.nonce, rendered.nonce)
        XCTAssertTrue(refreshed.html.contains("'nonce-\(refreshed.nonce)'"))
        let before = Array(rendered.html.utf8), after = Array(refreshed.html.utf8)
        XCTAssertEqual(try XCTUnwrap(rendered.blocks).map { before[$0] }, try XCTUnwrap(refreshed.blocks).map { after[$0] })
    }

    // MARK: The page's checks (WebKit)

    /// A live page, loaded; nil when WebKit didn't load it here.
    private func loadedPage(_ markdown: String) throws -> (WKWebView, NSWindow, MarkdownRenderer.RenderedPage) {
        let rendered = renderer.renderPage(markdown: markdown)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(PreviewLibrarySchemeHandler(), forURLScheme: PreviewLibrary.scheme)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.loadHTMLString(rendered.html, baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } while (webView.isLoading || webView.url == nil) && Date() < deadline
        try XCTSkipIf(webView.isLoading, "the page did not load in this environment")
        return (webView, window, rendered)
    }

    private func patch(_ webView: WKWebView, _ edit: [String: Any]) -> [String: Any]? {
        var reply: [String: Any]?
        var done = false
        webView.callAsyncJavaScript("return window.cmdmdPreview.patch(edit);", arguments: ["edit": edit], in: nil, in: .page) { result in
            if case .success(let value) = result { reply = value as? [String: Any] }
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return reply
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var value: Any?
        var done = false
        webView.evaluateJavaScript(script) { result, _ in
            value = result
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return value
    }

    func testThePageRefusesAPatchNotMeantForIt() throws {
        let (webView, window, rendered) = try loadedPage("one\n\ntwo\n")
        defer { window.close() }
        let edit: [String: Any] = ["page": rendered.nonce, "count": 2, "runs": [["at": 1, "remove": 1, "blocks": ["<p>TWO</p>\n"]]], "lang": ""]
        var wrong = edit
        wrong["page"] = String(repeating: "0", count: 32)
        XCTAssertEqual(patch(webView, wrong)?["done"] as? Bool, false, "another page's")
        wrong = edit
        wrong["count"] = 3
        XCTAssertEqual(patch(webView, wrong)?["done"] as? Bool, false, "computed against other blocks")
        wrong = edit
        wrong["runs"] = [["at": 1, "remove": 1, "blocks": ["<div>\n", "<p>x</p>\n"]]]
        XCTAssertEqual(patch(webView, wrong)?["done"] as? Bool, false, "a block that swallows the next one's marker")
        wrong = edit
        wrong["runs"] = [["at": 0, "remove": 1, "blocks": ["<p>ONE</p>\n"]], ["at": 1, "remove": 1, "blocks": ["<p>TWO</p>\n"]]]
        XCTAssertEqual(patch(webView, wrong)?["done"] as? Bool, false, "runs not apart")
        wrong = edit
        wrong["runs"] = [["at": 1, "remove": 1, "blocks": ["<p>TWO</p>\n"]], ["at": 0, "remove": 0, "blocks": ["<p>zero</p>\n"]]]
        XCTAssertEqual(patch(webView, wrong)?["done"] as? Bool, false, "runs out of order")
        XCTAssertEqual(evaluate("document.getElementById('cmdmd-root').textContent", in: webView) as? String, "one\ntwo\n", "refused patches change nothing")

        XCTAssertEqual(patch(webView, edit)?["version"] as? Int, 1)
        XCTAssertEqual(evaluate("document.getElementById('cmdmd-root').textContent", in: webView) as? String, "one\nTWO\n")
    }

    func testThePageTakesSeveralRuns() throws {
        let (webView, window, rendered) = try loadedPage("one\n\ntwo\n\nthree\n\nfour\n")
        defer { window.close() }
        let edit: [String: Any] = ["page": rendered.nonce, "count": 4, "lang": "", "runs": [
            ["at": 0, "remove": 0, "blocks": ["<p>zero</p>\n"]],
            ["at": 1, "remove": 1, "blocks": ["<p>TWO</p>\n", "<p>two and a half</p>\n"]],
            ["at": 3, "remove": 1, "blocks": []]
        ]]
        _ = evaluate("document.querySelectorAll('#cmdmd-root > p')[2].dataset.kept = 'yes'", in: webView)
        XCTAssertEqual(patch(webView, edit)?["version"] as? Int, 1)
        XCTAssertEqual(evaluate("document.getElementById('cmdmd-root').textContent", in: webView) as? String, "zero\none\nTWO\ntwo and a half\nthree\n")
        XCTAssertEqual(evaluate("document.querySelector('[data-kept]').textContent", in: webView) as? String, "three", "the block between, kept")
        let next: [String: Any] = ["page": rendered.nonce, "count": 5, "lang": "", "runs": [["at": 4, "remove": 1, "blocks": ["<p>end</p>\n"]]]]
        XCTAssertEqual(patch(webView, next)?["version"] as? Int, 2, "the markers follow the runs")
        XCTAssertEqual(evaluate("document.getElementById('cmdmd-root').textContent", in: webView) as? String, "zero\none\nTWO\ntwo and a half\nend\n")
    }

    /// The renderer sanitizes every note, but a patch parses in a template
    /// regardless: no script in it runs, even one carrying the page's nonce.
    func testPatchedMarkupRunsNoScript() throws {
        let (webView, window, rendered) = try loadedPage("one\n")
        defer { window.close() }
        let blocks = [
            "<script nonce=\"\(rendered.nonce)\">window.pwned = 1</script>\n",
            "<img src=\"data:,\" onerror=\"window.pwned = 2\">\n",
            "<svg><script nonce=\"\(rendered.nonce)\">window.pwned = 3</script></svg>\n"
        ]
        let edit: [String: Any] = ["page": rendered.nonce, "count": 1, "runs": [["at": 1, "remove": 0, "blocks": blocks]], "lang": ""]
        XCTAssertEqual(patch(webView, edit)?["done"] as? Bool, true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(evaluate("typeof window.pwned", in: webView) as? String, "undefined")
    }
}
