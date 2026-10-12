import XCTest
@testable import CmdMD

/// Wiki links and rendering details: dotted note names resolve (G040),
/// folder-qualified links keep their folder (G045), a target is decoded once
/// (G046), TOC slugs match the preview's anchors (G059), 장평 and spacing
/// apply once and stay out of code (G127), and preview fonts fall back to the
/// system font (G104).
final class R3bLinksTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDLinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeNote(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    private func render(_ markdown: String, configure: (inout MarkdownRenderOptions) -> Void = { _ in }) -> String {
        var options = MarkdownRenderOptions()
        configure(&options)
        return MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
    }

    // MARK: - G040 dotted note names

    func testDottedNamesResolveDirectlyNotToTheirTruncatedSibling() throws {
        let daily = try makeNote("2024.05.01.md")
        try makeNote("2024.05.md")
        let python = try makeNote("Python 3.12.md")
        let version = try makeNote("v1.2.md")
        let resolver = LinkedNoteResolver(roots: [root])

        XCTAssertEqual(resolver.resolve(normalizedTarget: "2024.05.01"), daily, "opened 2024.05.md")
        XCTAssertEqual(resolver.resolveDirectCandidate(named: "2024.05.01"), daily)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "Python 3.12"), python)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "v1.2"), version)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "2024.05.01.md"), daily)
    }

    func testDottedNamesResolveInSubfolders() throws {
        let weekly = try makeNote("Reports/주간보고 2024.05.01.md")
        let nodeJS = try makeNote("Tech/Node.js.md")
        let node = try makeNote("Tech/Node.md")
        let sketch = try makeNote("Drawings/Sketch.excalidraw.md")
        let resolver = LinkedNoteResolver(roots: [root])

        XCTAssertEqual(resolver.resolve(normalizedTarget: "주간보고 2024.05.01"), weekly)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "Node.js"), nodeJS, "opened Node.md")
        XCTAssertEqual(resolver.resolve(normalizedTarget: "Node"), node)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "Sketch.excalidraw"), sketch)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "Tech/Node.js"), nodeJS)
    }

    func testAFolderIsNeverTheLinkedNote() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Archive.2023"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Only.2023"), withIntermediateDirectories: true)
        let archive = try makeNote("Archive.2023.md")
        let resolver = LinkedNoteResolver(roots: [root])

        let resolved = resolver.resolve(normalizedTarget: "Archive.2023")
        XCTAssertEqual(resolved, archive)
        XCTAssertEqual(resolved?.hasDirectoryPath, false, "a folder's trailing slash must not stick to the note")
        XCTAssertNil(resolver.resolve(normalizedTarget: "Only.2023"))
        XCTAssertNil(resolver.resolveDirectCandidate(named: "Only.2023"))
    }

    func testAttachmentAndUppercaseExtensionsStillResolve() throws {
        let pdf = try makeNote("a.pdf")
        let upper = try makeNote("Upper.MD")
        let resolver = LinkedNoteResolver(roots: [root])

        XCTAssertEqual(resolver.resolve(normalizedTarget: "a.pdf"), pdf)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "Upper.MD"), upper)
    }

    // MARK: - G045 folder-qualified links

    func testFolderQualifiedLinkOpensThatFoldersNote() throws {
        let a = try makeNote("Work/ProjectA/README.md")
        let b = try makeNote("Work/ProjectB/README.md")
        let daily = root.appendingPathComponent("Daily")
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        // Linked from a daily note: neither README is a direct candidate.
        let resolver = LinkedNoteResolver(roots: [daily, root])

        // Asking for both catches a name-only match whatever the walk order.
        XCTAssertEqual(resolver.resolve(normalizedTarget: "ProjectB/README"), b)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "ProjectA/README"), a)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "projectb/readme"), b)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "ProjectB/README.md"), b)
        XCTAssertNil(resolver.resolve(normalizedTarget: "Other/README"), "a moved note's link is unresolved, as in Obsidian")
        XCTAssertTrue([a, b].contains(resolver.resolve(normalizedTarget: "README")))
    }

    func testVaultRelativeLinkResolvesWhenOnlyASubfolderIsARoot() throws {
        let a = try makeNote("Work/ProjectA/README.md")
        let b = try makeNote("Work/ProjectB/README.md")
        let resolver = LinkedNoteResolver(roots: [root.appendingPathComponent("Work")])

        XCTAssertEqual(resolver.resolve(normalizedTarget: "Work/ProjectB/README"), b)
        XCTAssertEqual(resolver.resolve(normalizedTarget: "Work/ProjectA/README"), a)
    }

    // MARK: - G046 decoded once

    func testPercentInANoteNameSurvivesThePreviewLink() throws {
        let note = try makeNote("100% Done.md")
        let html = render("[[100% Done#Plan]]")
        guard let start = html.range(of: "href=\"cmdmd://open?note=")?.lowerBound else {
            return XCTFail("no wiki link in \(html)")
        }
        let hrefStart = html.index(start, offsetBy: "href=\"".count)
        let href = String(html[hrefStart...].prefix { $0 != "\"" })
        // As AppState.openInternalURL reads it: the query value, decoded once.
        let value = try XCTUnwrap(URLComponents(string: href)?.queryItems?.first { $0.name == "note" }?.value)

        let (target, heading) = LinkedNoteResolver.splitTarget(value)
        XCTAssertEqual(target, "100% Done")
        XCTAssertEqual(heading, "Plan")
        XCTAssertEqual(LinkedNoteResolver(roots: [root]).resolve(value), note)
    }

    func testTargetIsNotDecodedAgain() {
        XCTAssertEqual(LinkedNoteResolver.normalizedTarget("a%20b"), "a%20b")
        XCTAssertEqual(LinkedNoteResolver.normalizedTarget("CPU 100% 이슈"), "CPU 100% 이슈")
    }

    // MARK: - G059 TOC slugs match the preview's anchors

    func testHeadingsWithLinksMarksAndTagsKeepMatchingAnchors() {
        let markdown = """
        ## Related [[Project X]]

        ## See [Docs](https://example.com/guide)

        ## Status ==blocked==

        ## Sprint review #planning

        ## A [[Target|Alias]]

        ## Use `run()` & <kbd>Cmd</kbd>

        ## Related [[Project X]]
        """
        let html = render(markdown)
        let headings = TOCBuilder.extractHeadings(from: markdown)

        XCTAssertEqual(headings.map(\.slug), [
            "related-project-x", "see-docs", "status-blocked", "sprint-review-planning",
            "a-alias", "use-run-cmd", "related-project-x-1"
        ])
        for heading in headings {
            XCTAssertTrue(html.contains("id=\"\(heading.slug)\""), "renderer must emit anchor for TOC slug \(heading.slug)")
        }
        XCTAssertEqual(headings.first?.text, "Related Project X", "the TOC row shows the heading as the preview does")
        XCTAssertEqual(headings[1].text, "See Docs")
    }

    func testKoreanHeadingWithATagKeepsItsAnchor() {
        // Final review: the tag span used to leak into the heading id
        // ("회의-span-classtag-…"), so the TOC row and [[#회의]] links missed it.
        let markdown = "# 회의 #회의록"
        let html = render(markdown)
        let heading = TOCBuilder.extractHeadings(from: markdown).first
        XCTAssertEqual(heading?.slug, "회의-회의록")
        XCTAssertTrue(html.contains("id=\"회의-회의록\""), html)
    }

    func testTOCFollowsThePreviewsOptions() {
        let markdown = "## A [[Target|Alias]]\n\n## Energy $x<y>z$"
        let configure: (inout MarkdownRenderOptions) -> Void = {
            $0.enableWikiLinks = false
            $0.enableKaTeX = true
        }
        var options = MarkdownRenderOptions()
        configure(&options)
        let html = render(markdown, configure: configure)
        let headings = TOCBuilder.extractHeadings(from: markdown, options: options)

        XCTAssertEqual(headings.count, 2)
        for heading in headings {
            XCTAssertTrue(html.contains("id=\"\(heading.slug)\""), "renderer must emit anchor for TOC slug \(heading.slug)")
        }
    }

    func testPlainHeadingsAreUnchanged() {
        let headings = TOCBuilder.extractHeadings(from: "# 한국어 제목\n## Setup Guide ##\n### C#")

        XCTAssertEqual(headings.map(\.text), ["한국어 제목", "Setup Guide", "C#"])
        XCTAssertEqual(headings.map(\.slug), ["한국어-제목", "setup-guide", "c"])
    }

    func testTOCLinesAreLineFeedLines() {
        // U+2028 and VT are no line breaks to the editor, search or the parser.
        let headings = TOCBuilder.extractHeadings(from: "intro\u{2028}more\u{0B}text\r\n\n## H")
        XCTAssertEqual(headings.first?.lineNumber, 3)
    }

    // MARK: - G127 Korean typography

    /// The selector list of the rule that declares `declaration`.
    private func selectors(ofRuleDeclaring declaration: String, in html: String) -> String? {
        guard let hit = html.range(of: declaration),
              let open = html[..<hit.lowerBound].lastIndex(of: "{") else { return nil }
        let before = html[..<open]
        let start = before.lastIndex(of: "}").map { before.index(after: $0) } ?? before.startIndex
        return String(before[start...])
    }

    func testCharWidthScalesEachTextBlockOnceAndFitsTheColumn() throws {
        let html = render("- a\n\n  b\n\n> q", configure: { $0.preview.charWidth = 0.9 })
        let rule = try XCTUnwrap(selectors(ofRuleDeclaring: "transform: scaleX(0.900)", in: html))

        XCTAssertTrue(rule.contains(".markdown-body p"))
        XCTAssertTrue(rule.contains(".markdown-body h1"))
        XCTAssertFalse(rule.contains(" li"), "list text is in a <p>: scaling li too scaled it twice")
        XCTAssertFalse(rule.contains("blockquote"), "quoted text is in a <p>: scaling the quote too scaled it twice")
        XCTAssertTrue(html.contains("width: calc(100% / 0.900)"))
        XCTAssertTrue(html.contains("box-sizing: border-box"), "padding must not push the scaled box past the column")
    }

    func testSpacingStaysOutOfCodeOnlyWhenSet() throws {
        let html = render("```\na  b\n```", configure: { $0.preview.wordSpacing = 0.3 })
        let rule = try XCTUnwrap(selectors(ofRuleDeclaring: "word-spacing: normal", in: html))
        XCTAssertTrue(rule.contains(".markdown-body pre"))
        XCTAssertTrue(rule.contains(".markdown-body code"))

        let letterSpaced = render("x", configure: { $0.preview.letterSpacing = -0.02 })
        XCTAssertTrue(letterSpaced.contains("letter-spacing: normal"))

        let defaults = render("x")
        XCTAssertFalse(defaults.contains("scaleX("))
        XCTAssertFalse(defaults.contains("word-spacing: normal"))
    }

    // MARK: - G104 preview fonts

    func testPreviewFontsFallBackToTheSystemFont() {
        XCTAssertFalse(render("x").contains("'SF Pro Text', -apple-system"), "the default theme must not declare the stack itself")
        let sfPro = render("x", configure: { $0.preview.fontFamily = "SF Pro Text, sans-serif" })
        XCTAssertTrue(sfPro.contains("font-family: 'SF Pro Text', -apple-system, BlinkMacSystemFont, sans-serif;"))

        let inter = render("x", configure: { $0.preview.fontFamily = "Inter, sans-serif" })
        XCTAssertTrue(inter.contains("font-family: Inter, -apple-system, BlinkMacSystemFont, sans-serif;"))

        let georgia = render("x", configure: { $0.preview.fontFamily = "Georgia, serif" })
        XCTAssertTrue(georgia.contains("font-family: Georgia, serif;"))
    }
}
