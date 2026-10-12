import XCTest
@testable import CmdMD

final class R2RendercorrectTests: XCTestCase {
    private func render(_ markdown: String, configure: (inout MarkdownRenderOptions) -> Void = { _ in }) -> String {
        var options = MarkdownRenderOptions()
        configure(&options)
        return MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The rendered body only (the style block mentions element names too).
    private func body(of html: String) -> String {
        guard let start = html.range(of: "<body"),
              let end = html.range(of: "</body>", options: .backwards) else { return html }
        return String(html[start.lowerBound..<end.upperBound])
    }

    // MARK: F124 wiki-link parsing

    func testWikiLinkAliasFollowsObsidianOrder() {
        let html = render("See [[Note Name|Display Text]]")
        XCTAssertTrue(html.contains("<a href=\"cmdmd://open?note=Note%20Name\" class=\"wiki-link\">Display Text</a>"))
        XCTAssertFalse(html.contains("note=Display"))
    }

    func testSeveralWikiLinksOnOneLineStaySeparate() {
        let html = render("[[A]] and [[B|b]]")
        XCTAssertEqual(count("class=\"wiki-link\"", in: html), 2)
        XCTAssertTrue(html.contains(
            "<a href=\"cmdmd://open?note=A\" class=\"wiki-link\">A</a> and <a href=\"cmdmd://open?note=B\" class=\"wiki-link\">b</a>"
        ))
    }

    func testWikiLinksInTableRowKeepTheirCells() {
        let html = render("| x | y |\n|---|---|\n| [[A]] | [[B]] |")
        XCTAssertEqual(count("<td>", in: html), 2)
        XCTAssertEqual(count("class=\"wiki-link\"", in: html), 2)
    }

    func testTableEscapedPipesKeepAliasAndImageSize() {
        let html = render("| x | y |\n|---|---|\n| [[A\\|b]] | ![[a.png\\|300]] |")
        XCTAssertEqual(count("<td>", in: html), 2)
        XCTAssertTrue(html.contains("<a href=\"cmdmd://open?note=A\" class=\"wiki-link\">b</a>"))
        XCTAssertTrue(html.contains("alt=\"a.png\" class=\"embedded-image\" width=\"300\" />"))
    }

    func testPipeInAliasDoesNotSplitTableCell() {
        let html = render("| x | y |\n|---|---|\n| [[A|b|c]] | z |")
        XCTAssertEqual(count("<td>", in: html), 2)
        XCTAssertTrue(html.contains("class=\"wiki-link\">b|c</a>"))
    }

    func testSizedImageEmbedsRenderAsImages() {
        let html = render("![[image.png|300]] and ![[photo.jpg|300x200]] and ![[chart.png|A chart]]")
        XCTAssertEqual(count("class=\"embedded-image\"", in: html), 3)
        XCTAssertTrue(html.contains("alt=\"image.png\" class=\"embedded-image\" width=\"300\" />"))
        XCTAssertTrue(html.contains("width=\"300\" height=\"200\" />"))
        XCTAssertTrue(html.contains("alt=\"A chart\" class=\"embedded-image\" />"))
        XCTAssertFalse(html.contains("embedded-note\" data-note"))
    }

    func testSameNoteHeadingLinkPointsAtTheSlug() {
        let html = render("Jump to [[#My Heading]] or [[#한국어 제목|여기]]")
        XCTAssertTrue(html.contains("<a href=\"cmdmd://heading?slug=my-heading\" class=\"wiki-link\">My Heading</a>"))
        let korean = "한국어-제목".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertTrue(html.contains("<a href=\"cmdmd://heading?slug=\(korean)\" class=\"wiki-link\">여기</a>"))
        XCTAssertFalse(html.contains("cmdmd://open"))
    }

    func testHeadingLinkUsesLastSegmentAndSkipsBlockIds() {
        let html = render("[[#H1#H2]] and [[#^block1]]")
        XCTAssertTrue(html.contains("href=\"cmdmd://heading?slug=h2\""))
        XCTAssertTrue(html.contains("href=\"cmdmd://heading?slug=\" class=\"wiki-link\">^block1</a>"))
    }

    func testNoteHeadingLinkKeepsFragmentAndAlias() {
        let html = render("[[Other Note#Section|see there]]")
        XCTAssertTrue(html.contains("<a href=\"cmdmd://open?note=Other%20Note%23Section\" class=\"wiki-link\">see there</a>"))
    }

    func testEmptyAliasFallsBackToTarget() {
        let html = render("[[Note|]] [[Other| ]]")
        XCTAssertTrue(html.contains("class=\"wiki-link\">Note</a>"))
        XCTAssertTrue(html.contains("class=\"wiki-link\">Other</a>"))
    }

    // MARK: F097 one pass per extension

    func testAdjacentAndEdgeMatchesSurviveTheForwardPass() {
        let html = render("[[a]][[b]] ==x== ==y== end #tag")
        XCTAssertTrue(html.contains(
            "<a href=\"cmdmd://open?note=a\" class=\"wiki-link\">a</a><a href=\"cmdmd://open?note=b\" class=\"wiki-link\">b</a>"
        ))
        XCTAssertTrue(html.contains("<mark>x</mark> <mark>y</mark> end <span class=\"tag\" data-tag=\"tag\">#tag</span>"))
        XCTAssertTrue(render("plain text").contains("<p>plain text</p>"))
    }

    func testLargeLinkTagMarkNoteRendersEveryMatch() {
        let lines = (0..<3000).map { "- [[노트 \($0)]] #t\($0) ==m\($0)== —" }
        let start = Date()
        let html = render(lines.joined(separator: "\n"))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(count("class=\"wiki-link\"", in: html), 3000)
        XCTAssertEqual(count("class=\"tag\"", in: html), 3000)
        XCTAssertEqual(count("<mark>", in: html), 3000)
        XCTAssertTrue(html.contains("note=%EB%85%B8%ED%8A%B8%202999\" class=\"wiki-link\">노트 2999</a>"))
        // Per-match document copies took several seconds here.
        XCTAssertLessThan(elapsed, 3)
    }

    // MARK: F027 code the extensions must not touch

    func testTildeFenceIsNotRewritten() {
        let html = render("~~~c\n#include <stdio.h>\nif (a == b && c == d) {}\n[[Daily Note]]\n~~~")
        XCTAssertTrue(html.contains("#include &lt;stdio.h&gt;"))
        XCTAssertTrue(html.contains("if (a == b &amp;&amp; c == d) {}"))
        XCTAssertTrue(html.contains("[[Daily Note]]"))
        XCTAssertFalse(html.contains("&lt;span"))
        XCTAssertFalse(html.contains("&lt;mark&gt;"))
        XCTAssertFalse(html.contains("&lt;a href"))
    }

    func testTildeFenceWithBlankLineStaysMasked() {
        let html = render("~~~\na\n\n[[x]] ==y==\n~~~\n\nafter [[z]]")
        XCTAssertEqual(count("class=\"wiki-link\"", in: html), 1)
        XCTAssertTrue(html.contains("[[x]] ==y=="))
        XCTAssertFalse(html.contains("<mark>"))
    }

    func testNestedFencesStayOneCodeBlock() {
        let html = render("~~~md\n```py\nx = [[a]]\n```\n~~~\n\nAfter [[Link]]")
        XCTAssertFalse(html.contains("\u{E000}"))
        XCTAssertTrue(html.contains("x = [[a]]"))
        XCTAssertEqual(count("class=\"wiki-link\"", in: html), 1)
    }

    func testUnbalancedFenceDoesNotSwallowProse() {
        let html = render("~~~\n```\n~~~\n\n[[Link]]\n\n```\ncode\n```")
        XCTAssertEqual(count("class=\"wiki-link\"", in: html), 1)
    }

    func testIndentedCodeBlockIsNotRewritten() {
        let html = render("Para\n\n    #include <stdio.h>\n    [[Daily Note]] ==x==\n\nAfter [[Link]] #tag")
        XCTAssertTrue(html.contains("#include &lt;stdio.h&gt;\n[[Daily Note]] ==x=="))
        XCTAssertEqual(count("class=\"wiki-link\"", in: html), 1)
        XCTAssertEqual(count("class=\"tag\"", in: html), 1)
        XCTAssertFalse(html.contains("<mark>"))
    }

    func testIndentedCodeAfterHeadingIsNotRewritten() {
        let html = render("# Title\n    [[x]] #y")
        XCTAssertTrue(html.contains("[[x]] #y"))
        XCTAssertFalse(html.contains("class=\"wiki-link\""))
    }

    func testTabIndentedCodeInCRLFNoteIsNotRewritten() {
        let html = render("Para\r\n\r\n\t[[x]] #y ==z==\r\n\r\nAfter [[Link]]")
        XCTAssertTrue(html.contains("[[x]] #y ==z=="))
        XCTAssertEqual(count("class=\"wiki-link\"", in: html), 1)
        XCTAssertFalse(html.contains("class=\"tag\""))
        XCTAssertFalse(html.contains("\u{E000}"))
    }

    func testIndentedListContinuationKeepsExtensions() {
        let html = render("- item\n\n    continuation [[Link]] #tag ==hi==")
        XCTAssertTrue(html.contains("class=\"wiki-link\""))
        XCTAssertTrue(html.contains("class=\"tag\""))
        XCTAssertTrue(html.contains("<mark>hi</mark>"))
        XCTAssertFalse(body(of: html).contains("<pre>"))
    }

    // MARK: F029 prose dollar amounts

    func testProseDollarAmountsAreNotMath() {
        let html = render("I paid $5 and $10 total, then $20,000 and $30,000.", configure: { $0.enableKaTeX = true })
        XCTAssertTrue(html.contains("I paid $5 and $10 total, then $20,000 and $30,000."))
        XCTAssertFalse(html.contains("class='cmdmd-math'"))
        XCTAssertFalse(html.contains("katex.min.js"), "a price alone must not load KaTeX")
    }

    func testMathInsideAURLStaysPlainText() {
        // Final review: `?$filter=a&$top=5` masks as math, and a span restored
        // into the href/src corrupted the link.
        let link = render("[odata](https://ex.com/Products?$filter=a&$top=5)", configure: { $0.enableKaTeX = true })
        XCTAssertTrue(link.contains("href=\"https://ex.com/Products?$filter=a&amp;$top=5\""), link)
        XCTAssertFalse(link.contains("class='cmdmd-math'"))

        let image = render("![p](https://ex.com/$x$/a.png) and $y$", configure: { $0.enableKaTeX = true })
        XCTAssertFalse(image.contains("src=\"https://ex.com/<span"), image)
        XCTAssertEqual(count("class='cmdmd-math'", in: image), 1, "prose math next to it is still math")
    }

    func testMathNextToPricesIsTheOnlyMathSpan() {
        let html = render("Euler $a_b$ costs $5 and $10", configure: { $0.enableKaTeX = true })
        XCTAssertEqual(count("class='cmdmd-math'", in: html), 1)
        XCTAssertTrue(html.contains("<span class='cmdmd-math'>$a_b$</span> costs $5 and $10"))
        XCTAssertFalse(html.contains("<em>"))
        XCTAssertTrue(html.contains("katex.min.js"))
    }

    func testPandocDollarRules() {
        let html = render("a $ x $ b $x$5 c \\$y$ d $z$", configure: { $0.enableKaTeX = true })
        XCTAssertEqual(count("class='cmdmd-math'", in: html), 1)
        XCTAssertTrue(html.contains("<span class='cmdmd-math'>$z$</span>"))
    }

    // MARK: F081 task line mapping

    func testTaskScanCountsCRLFLinesOnce() {
        XCTAssertEqual(TaskLineQueue.scan("- [ ] a\r\n- [ ] b\r\n- [ ] c\r\n"), [1, 2, 3])
        let html = render("- [ ] a\r\n- [ ] b\r\n- [ ] c\r\n")
        XCTAssertTrue(html.contains("data-line=\"2\""))
        XCTAssertTrue(html.contains("data-line=\"3\""))
    }

    func testTasksInRawHTMLOrCodeAreNotQueued() {
        XCTAssertEqual(TaskLineQueue.scan("<!--\n- [ ] h\n-->\n- [ ] real"), [4])
        XCTAssertEqual(TaskLineQueue.scan("Para\n\n    - [ ] code\n\n- [ ] real"), [5])
        XCTAssertEqual(TaskLineQueue.scan("~~~\n```\n- [ ] in\n```\n~~~\n- [ ] real"), [6])

        let html = render("<!--\n- [ ] h\n-->\n- [ ] real")
        XCTAssertEqual(count("data-line=\"", in: html), 1)
        XCTAssertTrue(html.contains("data-line=\"4\""))
    }

    func testBlockquotedTaskDoesNotShiftLaterCheckboxes() {
        let html = render("> - [ ] quoted\n- [ ] A\n- [ ] B")
        XCTAssertEqual(count("data-line=\"", in: html), 2)
        XCTAssertTrue(html.contains("data-line=\"2\""))
        XCTAssertTrue(html.contains("data-line=\"3\""))
    }

    func testTasksRightAfterACalloutRenderAndMap() {
        let html = render("> [!note]\n> t\n- [ ] A\n\n- [ ] B")
        XCTAssertTrue(html.contains("callout-note"))
        XCTAssertTrue(html.contains("data-line=\"3\""))
        XCTAssertTrue(html.contains("data-line=\"5\""))

        let fixture = "- [ ] real one\n```\n- [ ] inside fence\n```\n> [!todo]\n> - [ ] inside callout\n- [ ] real two"
        let fixtureHTML = render(fixture)
        XCTAssertTrue(fixtureHTML.contains("data-line=\"1\""))
        XCTAssertTrue(fixtureHTML.contains("data-line=\"7\""), "the task glued under the callout was swallowed as raw HTML")
    }

    func testDisagreeingScanRendersCheckboxesReadOnly() {
        // The embed becomes a lone <img> line: an HTML block that swallows the
        // glued task, so the later box would otherwise post that task's line.
        let html = render("![[img.png]]\n- [ ] swallowed\n\n- [ ] real")
        XCTAssertFalse(html.contains("data-line=\""))
        XCTAssertTrue(html.contains("type=\"checkbox\" disabled"))
    }

    func testTOCLineNumbersCountCRLFOnce() {
        let headings = TOCBuilder.extractHeadings(from: "# A\r\n\r\ntext\r\n## B\r\n")
        XCTAssertEqual(headings.map(\.lineNumber), [1, 4])
        XCTAssertEqual(headings.map(\.text), ["A", "B"])
    }

    // MARK: F034 math in headings

    func testMathHeadingIdsMatchTOCSlugs() {
        let markdown = "## Energy $E=mc^2$\n\ntext\n\n## Energy $p=mv$\n\n## Energy $E=mc^2$"
        let html = render(markdown, configure: { $0.enableKaTeX = true })
        let headings = TOCBuilder.extractHeadings(from: markdown)

        XCTAssertEqual(headings.map(\.slug), ["energy-emc2", "energy-pmv", "energy-emc2-1"])
        for heading in headings {
            XCTAssertTrue(html.contains("id=\"\(heading.slug)\""), "renderer must emit anchor for TOC slug \(heading.slug)")
        }
        XCTAssertFalse(html.lowercased().contains("cmdmdmath"))
    }

    // MARK: F032 heading fragments

    func testSplitTargetSeparatesNoteAndHeading() {
        XCTAssertNil(LinkedNoteResolver.normalizedTarget("#Conclusion"))

        let sameNote = LinkedNoteResolver.splitTarget("#Conclusion")
        XCTAssertNil(sameNote.note)
        XCTAssertEqual(sameNote.heading, "Conclusion")

        let other = LinkedNoteResolver.splitTarget("Other Note#Section")
        XCTAssertEqual(other.note, "Other Note")
        XCTAssertEqual(other.heading, "Section")

        XCTAssertEqual(LinkedNoteResolver.splitTarget("Note#H1#H2").heading, "H2")
        XCTAssertEqual(LinkedNoteResolver.splitTarget("Note#^abc").note, "Note")
        XCTAssertNil(LinkedNoteResolver.splitTarget("Note#^abc").heading)
        XCTAssertNil(LinkedNoteResolver.splitTarget("#").note)
        XCTAssertNil(LinkedNoteResolver.splitTarget("#").heading)
        XCTAssertEqual(LinkedNoteResolver.normalizedTarget("Plain Note"), "Plain Note")
    }

    func testSameNoteHeadingNeverOpensANoteNamedAfterIt() throws {
        let vault = try makeTemporaryDirectory()
        let conclusion = vault.appendingPathComponent("Conclusion.md")
        try "# Conclusion\n".write(to: conclusion, atomically: true, encoding: .utf8)
        let resolver = LinkedNoteResolver(roots: [vault])

        XCTAssertNil(resolver.resolve("#Conclusion"))
        XCTAssertNil(resolver.resolve("%23Conclusion"))
        XCTAssertEqual(resolver.resolve("Conclusion#Intro"), conclusion.standardizedFileURL)
    }

    // MARK: F113 resolver walk

    func testNestedRootsResolveTheSameFiles() throws {
        let vault = try makeTemporaryDirectory()
        let notes = vault.appendingPathComponent("Notes")
        let deep = notes.appendingPathComponent("Deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for folder in ["X", "Y"] {
            try FileManager.default.createDirectory(at: vault.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for path in ["Notes/A.md", "Notes/Deep/B.md", "X/dup.md", "Y/Dup.md"] {
            try "x\n".write(to: vault.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let b = deep.appendingPathComponent("B.md").standardizedFileURL
        let dups = [vault.appendingPathComponent("X/dup.md"), vault.appendingPathComponent("Y/Dup.md")]
            .map(\.standardizedFileURL)

        // The document folder nested in a vault root, as linkedNoteSearchRoots orders them.
        let resolver = LinkedNoteResolver(roots: [notes, vault])
        XCTAssertEqual(resolver.resolve("B"), b)
        XCTAssertEqual(resolver.resolve("Notes/Deep/B.md"), b)
        XCTAssertNil(resolver.resolve("Other/B"), "a path-qualified target must match its folder, not just the name")
        XCTAssertEqual(resolver.resolve("A"), notes.appendingPathComponent("A.md").standardizedFileURL)
        XCTAssertTrue(resolver.resolve("dup").map(dups.contains) ?? false)
        XCTAssertNil(resolver.resolve("Missing"))

        // Parent root first: the nested root is skipped, not lost.
        let reversed = LinkedNoteResolver(roots: [vault, notes])
        XCTAssertEqual(reversed.resolve("B"), b)
        XCTAssertNil(reversed.resolve("Missing"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
