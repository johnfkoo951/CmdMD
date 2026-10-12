import XCTest
@testable import CmdMD

final class R3bFmsendTests: XCTestCase {
    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func load(_ text: String) -> MarkdownDocument {
        let parsed = FileService.parseFrontmatter(from: text)
        return MarkdownDocument(title: "Note", content: parsed.body, frontmatter: parsed.frontmatter, frontmatterSource: parsed.source)
    }

    /// The text of `line` in `body` as the editor finds it (LineIndex counts
    /// LF line breaks only).
    private func editorLine(_ line: Int, in body: String) -> String {
        let index = LineIndex()
        let text = body as NSString
        index.rebuild(from: text)
        let start = index.startLocation(ofLine: line)
        let end = line < index.lineCount ? index.startLocation(ofLine: line + 1) - 1 : text.length
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    private func fenceCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { $0 == "---" }.count
    }

    // MARK: Search hits use the editor's line numbers (G001, G019)

    func testHitsAreNumberedInTheBodyTheEditorShows() async throws {
        let root = try makeTempDir()
        let note = root.appendingPathComponent("note.md")
        try "---\ntitle: A\ntags: [foo]\n---\n\n# H\nalpha\nthe foo line\n".write(to: note, atomically: true, encoding: .utf8)

        let results = await AppState.performSearch(query: "foo", in: [root])

        XCTAssertEqual(results.map(\.lineNumber), [nil, 3], "the tags match is a property; the body match is body line 3")
        XCTAssertEqual(results.first?.lineContent, "tags: [foo]")
        let document = try await FileService().loadDocument(from: note)
        XCTAssertEqual(editorLine(try XCTUnwrap(results.last?.lineNumber), in: document.content), "the foo line")
        let heading = TOCBuilder.extractHeadings(from: document.content).last { $0.lineNumber <= 3 }
        XCTAssertEqual(heading?.text, "H", "Preview scrolls to the heading above the match")
    }

    func testCRLFNotesWithFrontmatterUseEditorLines() async throws {
        let root = try makeTempDir()
        let note = root.appendingPathComponent("crlf.md")
        try "---\r\ntitle: A\r\n---\r\nfirst\r\nthe foo line\r\n".write(to: note, atomically: true, encoding: .utf8)

        let results = await AppState.performSearch(query: "foo", in: [root])

        XCTAssertEqual(results.map(\.lineNumber), [2])
        XCTAssertEqual(results.first?.lineContent, "the foo line")
        let document = try await FileService().loadDocument(from: note)
        XCTAssertEqual(editorLine(2, in: document.content), "the foo line")
    }

    func testOnlyLineFeedsSeparateLinesAndUnclosedFencesAreBody() async throws {
        let root = try makeTempDir()
        // The editor shows an unclosed block as text, and a line separator
        // or vertical tab inside a line doesn't start a new one there.
        try "---\nnot closed\nfoo here\n".write(to: root.appendingPathComponent("open.md"), atomically: true, encoding: .utf8)
        try "a\u{2028}b\u{000B}c\nfoo".write(to: root.appendingPathComponent("ls.md"), atomically: true, encoding: .utf8)

        let results = await AppState.performSearch(query: "foo", in: [root])

        XCTAssertEqual(results.first { $0.fileName == "open.md" }?.lineNumber, 3)
        XCTAssertEqual(results.first { $0.fileName == "ls.md" }?.lineNumber, 2)
    }

    func testPropertyHitsInOneFileHaveDistinctIDs() {
        let url = URL(fileURLWithPath: "/vault/a.md")
        let file = OmnisearchView.Hit(kind: .file, title: "a", subtitle: "", url: url, line: nil)
        let first = OmnisearchView.Hit(kind: .content, title: "a", subtitle: "", url: url, line: nil, resultID: UUID())
        let second = OmnisearchView.Hit(kind: .content, title: "a", subtitle: "", url: url, line: nil, resultID: UUID())
        let body = OmnisearchView.Hit(kind: .content, title: "a", subtitle: "", url: url, line: 1, resultID: UUID())
        XCTAssertEqual(Set([file, first, second, body].map(\.id)).count, 4)
        XCTAssertEqual(body.id, "\(url.path)#1", "line hits keep their stable ID")
    }

    // MARK: Fences and line separators (G042, G049)

    func testOnlyAThreeDashLineAtColumnZeroIsAFence() {
        let fourDashes = "----\nAuthor: Kim\n---\nBody text"
        let parsed = FileService.parseFrontmatter(from: fourDashes)
        XCTAssertNil(parsed.source)
        XCTAssertEqual(parsed.body, fourDashes)

        let blockScalar = "---\nsummary: |\n  Part one\n  ---\n  Part two\ntags: [a, b]\n---\nBody"
        XCTAssertEqual(FileService.parseFrontmatter(from: blockScalar).frontmatter?.tags, ["a", "b"])
        XCTAssertEqual(FileService.parseFrontmatter(from: blockScalar).body, "Body")
        XCTAssertEqual(FileService.parseFrontmatter(from: "--- \ntitle: T\n--- \nX").frontmatter?.title, "T")
    }

    func testOtherLineSeparatorsInTheBodySurviveLoadAndSave() async throws {
        let text = "---\ntitle: T\n---\n| a |\n|---|\n| x\u{2028}y |\nA\u{000B}B\u{000C}C\u{0085}D\u{2029}E"
        let url = try makeTempDir().appendingPathComponent("seps.md")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let document = try await FileService().loadDocument(from: url)

        XCTAssertEqual(document.frontmatter?.title, "T")
        XCTAssertEqual(document.content, "| a |\n|---|\n| x\u{2028}y |\nA\u{000B}B\u{000C}C\u{0085}D\u{2029}E")
        XCTAssertEqual(document.fullText, text)
    }

    // MARK: A template's frontmatter joins the note's (G008, G043)

    func testTemplateBlockAndInjectedKeysAreOneBlock() throws {
        let document = MarkdownDocument(title: "X", content: "Hello")
        let template = VaultTemplate(name: "Inbox", content: "---\ntags: [inbox]\ncreated: {{date}}\n---\n{{content}}")

        let output = AppState.sendContent(for: document, template: template, injectFrontmatter: true, sourceLink: nil)

        XCTAssertEqual(fenceCount(output), 2, output)
        XCTAssertTrue(output.hasPrefix("---\ntags: [inbox]\ncreated: "), "the template's lines are kept as written")
        let parsed = FileService.parseFrontmatter(from: output)
        let frontmatter = try XCTUnwrap(parsed.frontmatter)
        XCTAssertEqual(frontmatter.tags, ["inbox"])
        XCTAssertEqual(frontmatter.title, "X")
        XCTAssertNotNil(frontmatter.date, "a note without properties of its own is dated, as without a template")
        XCTAssertNotNil(frontmatter.custom["created"]?.displayString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression))
        XCTAssertEqual(parsed.body, "Hello")
    }

    func testTemplateTitleIsWrittenAsYAML() throws {
        let title = #"Re: Q3, Bob's "plan" #1"#
        let template = VaultTemplate(name: "T", content: """
            ---
            title: {{title}}
            aliases: [{{title}}]
            quoted: "{{title}}"
            single: 'Note {{title}}'
            summary: |
              About {{title}}
            ---
            {{content}}
            """)
        let document = MarkdownDocument(title: title, content: "body")

        let parts = template.renderParts(for: document)
        let frontmatter = try XCTUnwrap(parts.frontmatter?.parsed, parts.frontmatter?.yaml ?? "no block")
        XCTAssertEqual(frontmatter.title, title)
        XCTAssertEqual(frontmatter.aliases, [title])
        XCTAssertEqual(frontmatter.custom["quoted"], .string(title))
        XCTAssertEqual(frontmatter.custom["single"], .string("Note \(title)"))
        XCTAssertEqual(frontmatter.custom["summary"], .string("About \(title)\n"))
        XCTAssertEqual(parts.body, "body")

        // Without injection the template's block is the only one, and valid.
        let output = AppState.sendContent(for: document, template: template, injectFrontmatter: false, sourceLink: nil)
        XCTAssertEqual(fenceCount(output), 2)
        XCTAssertEqual(FileService.parseFrontmatter(from: output).frontmatter?.title, title)
    }

    func testPlainTitlesAndNumbersStayReadable() throws {
        let template = VaultTemplate(name: "T", content: "---\ntitle: {{title}}\n---\n")
        let plain = template.renderParts(for: MarkdownDocument(title: "회의록 정리", content: ""))
        XCTAssertEqual(plain.frontmatter?.yaml, "title: 회의록 정리\n")
        let year = template.renderParts(for: MarkdownDocument(title: "2024", content: ""))
        XCTAssertEqual(year.frontmatter?.parsed?.title, "2024")
    }

    func testTemplateBlockMergesIntoTheNotesOwnBlock() throws {
        let document = load("---\ntitle: Meeting\ntags: [meeting]\n# keep me\nstatus: done\n---\nBody\n")
        let template = VaultTemplate(name: "T", content: "---\ntags: [inbox]\nstatus: todo\ncreated: 2026-10-11\n---\n## Notes\n{{content}}")

        let output = AppState.sendContent(for: document, template: template, injectFrontmatter: false, sourceLink: nil)

        XCTAssertEqual(fenceCount(output), 2, output)
        XCTAssertTrue(output.contains("title: Meeting\n"))
        XCTAssertTrue(output.contains("# keep me\nstatus: done\n"), "the note's own lines and values win")
        XCTAssertTrue(output.contains("created: 2026-10-11\n"), "a missing key is added as the template writes it")
        XCTAssertFalse(output.contains("todo"))
        let parsed = FileService.parseFrontmatter(from: output)
        XCTAssertEqual(parsed.frontmatter?.tags, ["meeting", "inbox"])
        XCTAssertEqual(parsed.body, "## Notes\nBody\n")
    }

    func testInspectorOnlyPropertiesJoinTheTemplateBlock() throws {
        let document = MarkdownDocument(title: "M", content: "notes", frontmatter: Frontmatter(tags: ["work"], custom: ["type": .string("call")]))
        let template = VaultTemplate(name: "T", content: "---\ntype: meeting\ntags: [inbox]\nstatus: todo\n---\n{{content}}")

        let output = AppState.sendContent(for: document, template: template, injectFrontmatter: false, sourceLink: nil)

        XCTAssertEqual(fenceCount(output), 2, output)
        let frontmatter = try XCTUnwrap(FileService.parseFrontmatter(from: output).frontmatter)
        XCTAssertEqual(frontmatter.custom["type"], .string("call"))
        XCTAssertEqual(frontmatter.custom["status"], .string("todo"))
        XCTAssertEqual(Set(frontmatter.tags), ["work", "inbox"])
    }

    func testDraftTypedFrontmatterGainsTheInjectedKeys() throws {
        let draft = MarkdownDocument(title: "D", content: "---\ntags: [x]\n---\nBody", isDraft: true)

        let output = AppState.sendContent(for: draft, template: nil, injectFrontmatter: true, sourceLink: nil)

        XCTAssertEqual(fenceCount(output), 2, output)
        let parsed = FileService.parseFrontmatter(from: output)
        XCTAssertEqual(parsed.frontmatter?.tags, ["x"])
        XCTAssertEqual(parsed.frontmatter?.title, "D")
        XCTAssertEqual(parsed.body, "Body")

        // Without injection the draft's text ships as typed.
        XCTAssertEqual(AppState.sendContent(for: draft, template: nil, injectFrontmatter: false, sourceLink: nil), draft.content)
    }

    func testRuleAndTextAtTheTopOfADraftStayBodyText() {
        let draft = MarkdownDocument(title: "D", content: "---\nSome text\n---\nBody", isDraft: true)
        let output = AppState.sendContent(for: draft, template: nil, injectFrontmatter: true, sourceLink: nil)
        XCTAssertTrue(output.hasPrefix("---\ntitle: D\n"))
        XCTAssertTrue(output.hasSuffix("---\n\n---\nSome text\n---\nBody"), "not a YAML map, so not properties")
    }

    func testUnreadableTemplateBlockIsTheOnlyBlock() {
        // A title inside a longer plain value is pasted as is, which here
        // makes the YAML invalid: kept as written, not stacked under a
        // second, injected block.
        let template = VaultTemplate(name: "T", content: "---\ntitle: Book - {{title}}\n---\n{{content}}")
        let document = MarkdownDocument(title: "Re: X", content: "Hello")

        let output = AppState.sendContent(for: document, template: template, injectFrontmatter: true, sourceLink: nil)

        XCTAssertEqual(output, "---\ntitle: Book - Re: X\n---\nHello")
    }
}
