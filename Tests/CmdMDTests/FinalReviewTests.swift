import XCTest
@testable import CmdMD

/// Regressions found by the post-merge adversarial review.
final class FinalReviewTests: XCTestCase {
    private func render(_ markdown: String) -> String {
        MarkdownRenderer().renderToHTML(markdown: markdown, baseURL: nil, options: MarkdownRenderOptions())
    }

    func testHexColorInsideRawHTMLIsNotATag() {
        // The #tag pass used to rewrite `#3b82f6` inside the style attribute,
        // breaking the element into literal text.
        let html = render("<span style=\"color: #3b82f6\">blue</span> and #real")
        XCTAssertFalse(html.contains("data-tag=\"3b82f6\""), html)
        XCTAssertTrue(html.contains("data-tag=\"real\""), "a tag in the text is still a tag")
        XCTAssertTrue(html.contains("#3b82f6"), "the color survives")
    }

    func testKoreanHeadingsWithMarksAndAliasesKeepTheirAnchors() {
        let markdown = "# 회의록 ==중요==\n\n## [[Note|별칭]]"
        let html = render(markdown)
        for heading in TOCBuilder.extractHeadings(from: markdown) {
            XCTAssertTrue(html.contains("id=\"\(heading.slug)\""), "TOC slug \(heading.slug) must be an anchor: \(html)")
        }
    }

    func testUTF16WithoutAByteOrderMarkOpensWhenItsEncodingIsDeclared() throws {
        // TextEdit's "UTF-16 Little-Endian" writes no BOM but declares it in
        // com.apple.TextEncoding; the NUL-byte binary test refused it.
        let data = try XCTUnwrap("# 제목\nbody".data(using: .utf16LittleEndian))

        let decoded = try FileService.decodeText(data, declaredEncoding: .utf16LittleEndian, fileName: "u16.md")

        XCTAssertEqual(decoded.text, "# 제목\nbody")
        XCTAssertEqual(decoded.encoding, .utf16LittleEndian)
        XCTAssertThrowsError(try FileService.decodeText(data, declaredEncoding: nil, fileName: "u16.md"),
                             "undeclared NUL bytes are still refused as binary")
    }

    func testSavingAnLFFileNeverWritesMixedLineBreaks() throws {
        // Pasted CRLF in an LF note used to be written as-is.
        let data = try FileService.encodedData("a\r\nb\rc\nd", format: TextFileFormat(), fileName: "n.md")
        XCTAssertEqual(String(data: data, encoding: .utf8), "a\nb\nc\nd")

        let crlf = try FileService.encodedData("a\nb\r\nc", format: TextFileFormat(lineEnding: .crlf), fileName: "n.md")
        XCTAssertEqual(String(data: crlf, encoding: .utf8), "a\r\nb\r\nc")
    }

    func testIndexWalkSkipsToolOutputFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinalReview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modules = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "# Note".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        try "# Readme".write(to: modules.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let notes = NoteIndexService.buildIndex(roots: [root])

        XCTAssertEqual(notes.map(\.title), ["Note"])
    }
}

/// Preview checkbox clicks carry the line as their page rendered it.
final class FinalReviewTaskToggleTests: IsolatedDataDirTestCase {
    func testToggleWhenTheRenderedLineStillMatches() {
        let state = AppState()
        state.createNewTab()
        state.updateContent("- [ ] a\n- [ ] b")

        state.toggleTask(atLine: 2, checked: true, expectedLine: "- [ ] b")

        XCTAssertEqual(state.currentDocument?.content, "- [ ] a\n- [x] b")
        state.tabs.forEach { state.closeTab($0) }
    }

    func testRefuseWhenTheLineChangedSinceTheRender() {
        // An edit shifted the lines after the page rendered: line 2 is now a
        // different task, and the click must not flip it.
        let state = AppState()
        state.createNewTab()
        state.updateContent("- [ ] new\n- [ ] a\n- [ ] b")

        state.toggleTask(atLine: 2, checked: true, expectedLine: "- [ ] b")

        XCTAssertEqual(state.currentDocument?.content, "- [ ] new\n- [ ] a\n- [ ] b")
        state.tabs.forEach { state.closeTab($0) }
    }
}

/// Data-integrity regressions from the post-merge review.
final class FinalReviewDataTests: IsolatedDataDirTestCase {
    func testRemovingABlockScalarKeyTakesItsIndentedHashLines() {
        // "# run twice" is content of script's `|` block; removing script left
        // it behind inside setup's block, changing setup's value.
        let text = "---\nsetup: |\n  npm i\nscript: |\n  echo hi\n  # run twice\ndone: true\n---\nBody\n"
        let parsed = FileService.parseFrontmatter(from: text)
        var document = MarkdownDocument(content: parsed.body, frontmatter: parsed.frontmatter, frontmatterSource: parsed.source)

        document.frontmatter?.custom.removeValue(forKey: "script")

        XCTAssertFalse(document.fullText.contains("# run twice"), document.fullText)
        XCTAssertTrue(document.fullText.contains("setup: |\n  npm i\ndone: true"), document.fullText)
    }

    func testAutosaveNeverOverwritesAVersionItCannotRead() async throws {
        let appState = AppState()
        appState.settings.autosaveEnabled = true
        let file = dataDir.appendingPathComponent("note.md")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let doc = MarkdownDocument(title: "note", content: "original\nmy edit\n", fileURL: file)
        appState.originalContents[doc.id] = "original\n"
        appState.documents[doc.id] = doc
        appState.tabs = [EditorTab(documentId: doc.id, fileURL: file, title: "note")]
        // Another app rewrites it as Latin-1, which CmdMD won't guess at.
        let latin1 = Data("rewritten by another app: caf".utf8) + Data([0xE9, 0x0A])
        try latin1.write(to: file)

        await appState.performAutosave()

        XCTAssertEqual(try Data(contentsOf: file), latin1, "the unreadable external version is kept")
        appState.tabs.forEach { appState.closeTab($0) }
    }

    func testAutosaveKeepsALineEndingChangeMadeElsewhere() async throws {
        let appState = AppState()
        appState.settings.autosaveEnabled = true
        let file = dataDir.appendingPathComponent("crlf.md")
        // Opened as CRLF, then a formatter rewrote the same text as LF.
        try "a\nb\nc\n".write(to: file, atomically: true, encoding: .utf8)
        var doc = MarkdownDocument(title: "crlf", content: "a\nb\nc\nd\n", fileURL: file)
        doc.fileFormat = TextFileFormat(lineEnding: .crlf)
        appState.originalContents[doc.id] = "a\nb\nc\n"
        appState.documents[doc.id] = doc
        appState.tabs = [EditorTab(documentId: doc.id, fileURL: file, title: "crlf")]

        await appState.performAutosave()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "a\nb\nc\nd\n", "written with the LF the file has now")
        appState.tabs.forEach { appState.closeTab($0) }
    }
}
