import XCTest
@testable import CmdMD

// MARK: - Titles follow the document (G002, G039, G063)

final class R3bDocumentTitleTests: XCTestCase {
    func testNewDraftIsTitledByWhatIsTypedIntoIt() {
        var document = Draft().toDocument()
        XCTAssertEqual(document.displayTitle, "Untitled Draft")

        document.content = "# Weekly Review\nnotes"
        XCTAssertEqual(document.displayTitle, "Weekly Review")
        document.content = "Buy milk\nand eggs"
        XCTAssertEqual(document.displayTitle, "Buy milk")
    }

    func testReopenedDraftTitleHasNoMarkdownMarkers() {
        let draft = Draft(body: "# Weekly Review\nnotes")
        XCTAssertEqual(draft.displayTitle, "Weekly Review")
        XCTAssertEqual(draft.toDocument().displayTitle, "Weekly Review")
        XCTAssertEqual(Draft(body: "- [ ] buy milk").displayTitle, "buy milk")
        XCTAssertEqual(Draft(body: "> 1. quoted item").displayTitle, "quoted item")
        XCTAssertEqual(Draft(body: "#idea worth keeping").displayTitle, "#idea worth keeping", "a tag is not a heading")
    }

    func testDraftTitleSkipsPropertiesRulesAndCode() {
        XCTAssertEqual(Draft(body: "---\ntags: [a]\n# a comment\n---\nHello").displayTitle, "Hello")
        XCTAssertEqual(Draft(body: "---\nText after a rule").displayTitle, "Text after a rule")
        XCTAssertEqual(Draft(body: "```sh\n# a comment\n```\nReal title").displayTitle, "Real title")
        XCTAssertEqual(MarkdownDocument(content: "```py\n# a comment\n```\n# Heading").displayTitle, "Heading")
    }

    func testPropertiesTitleWinsAndFollowsEdits() {
        var draft = Draft(body: "# Heading").toDocument()
        draft.frontmatter = Frontmatter(title: "Set in Properties")
        XCTAssertEqual(draft.displayTitle, "Set in Properties")
        draft.frontmatter?.title = nil
        XCTAssertEqual(draft.displayTitle, "Heading")

        // As FileService loads it: the stored title no longer outlives a change.
        var note = MarkdownDocument(title: "Custom", content: "body",
                                    fileURL: URL(fileURLWithPath: "/tmp/draft.md"),
                                    frontmatter: Frontmatter(title: "Custom"))
        note.frontmatter?.title = "Edited"
        XCTAssertEqual(note.displayTitle, "Edited")
        note.frontmatter?.title = nil
        XCTAssertEqual(note.displayTitle, "draft")
        note.fileURL = URL(fileURLWithPath: "/tmp/Final Report.md")
        XCTAssertEqual(note.displayTitle, "Final Report")
    }

    func testGivenTitleStillNamesADocumentWithoutAFile() {
        XCTAssertEqual(MarkdownDocument(title: "A & B", content: "# Other").displayTitle, "A & B")
        XCTAssertEqual(MarkdownDocument(content: "# Heading").displayTitle, "Heading")
        XCTAssertEqual(MarkdownDocument(content: "#   Spaced out  \nbody").displayTitle, "Spaced out")
        XCTAssertEqual(MarkdownDocument(content: "no heading").displayTitle, "Untitled")
    }

    func testPlaceholderIsNotATitleToKeep() {
        // Add Properties seeds the properties' title from this; "Untitled
        // Draft" there would outrank whatever is typed into the draft.
        XCTAssertNil(Draft().toDocument().ownTitle)
        XCTAssertNil(MarkdownDocument().ownTitle)
        XCTAssertEqual(Draft(body: "# Weekly Review").toDocument().ownTitle, "Weekly Review")
        XCTAssertEqual(MarkdownDocument(fileURL: URL(fileURLWithPath: "/tmp/Untitled.md")).ownTitle, "Untitled")
    }

    func testFilenameRuleMatchesADraftByItsTitle() {
        let condition = RoutingCondition(type: .filenamePrefix, value: "Meeting", matchType: .startsWith)
        var draft = Draft().toDocument()
        draft.content = "# Meeting with Kim"
        XCTAssertTrue(condition.matches(document: draft))
    }
}

final class R3bDraftTitleAppTests: IsolatedDataDirTestCase {
    func testDraftTabAndWindowFollowTyping() {
        let state = AppState()
        state.createNewDraft()
        XCTAssertEqual(state.windowTitle, "Untitled Draft")

        state.updateContent("# Project Kickoff\nagenda")

        XCTAssertEqual(state.windowTitle, "Project Kickoff")
        XCTAssertEqual(state.activeTab?.displayTitle, "Project Kickoff")
        XCTAssertEqual(state.drafts.first?.displayTitle, "Project Kickoff")
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testNewDraftIsSentUnderWhatWasTyped() async throws {
        let state = AppState()
        let root = dataDir.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        var options = SendOptions()
        options.targetVault = Vault(name: "V", rootPath: root)
        state.createNewDraft()
        state.updateContent("# Project Kickoff\nagenda")

        let document = try XCTUnwrap(state.currentDocument)
        let outcome = try await state.sendToVault(document: document, options: options, quiet: true)

        guard case .sent(let url) = outcome else {
            return XCTFail("expected sent, got \(outcome)")
        }
        XCTAssertEqual(url.lastPathComponent, "Project Kickoff.md")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("title: Project Kickoff\n"))
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testSaveAsRetitlesTheWindow() async throws {
        let state = AppState()
        state.createNewDraft()
        state.updateContent("# Kickoff")
        let tab = try XCTUnwrap(state.activeTab)

        let saved = await state.saveAs(tab: tab, to: dataDir.appendingPathComponent("Final Name.md"))

        XCTAssertTrue(saved)
        XCTAssertEqual(state.windowTitle, "Final Name")
        state.tabs.forEach { state.closeTab($0) }
    }
}

// MARK: - Inspector edits take the typing path (G062)

final class R3bInspectorEditTests: IsolatedDataDirTestCase {
    func testDraftKeepsPropertiesFromTheInspector() throws {
        let state = AppState()
        state.createNewDraft()
        state.updateContent("hello")
        let properties = Frontmatter(title: "Idea", tags: ["work"])

        state.updateFrontmatter(properties)

        XCTAssertEqual(state.drafts.first?.frontmatter, properties)
        XCTAssertEqual(state.activeTab?.isDirty, false, "a draft keeps its properties itself")
        XCTAssertEqual(state.activeTab?.displayTitle, "Idea")
        state.updateContent("hello again")
        XCTAssertEqual(state.activeTab?.isDirty, false)

        state.persistDrafts()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: dataDir.appendingPathComponent("drafts.json"))
        let reopened = try XCTUnwrap(decoder.decode([Draft].self, from: data).first).toDocument()
        XCTAssertEqual(reopened.frontmatter, properties)
        XCTAssertEqual(reopened.content, "hello again")
        state.tabs.forEach { state.closeTab($0) }
    }

    func testDraftWithoutPropertiesOrWithBadOnesStillDecodes() throws {
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(Draft.self, from: Data(#"{"body":"kept"}"#.utf8)).frontmatter)
        let bad = try decoder.decode(Draft.self, from: Data(#"{"body":"kept","frontmatter":{"tags":"oops"}}"#.utf8))
        XCTAssertEqual(bad.body, "kept")
        XCTAssertNil(bad.frontmatter)
    }

    @MainActor
    func testInspectorEditIsAutosaved() async throws {
        let state = AppState()
        state.settings.autosaveEnabled = true
        state.settings.autosaveInterval = 2
        let url = dataDir.appendingPathComponent("note.md")
        try "body".write(to: url, atomically: true, encoding: .utf8)
        state.openDocument(at: url)
        try await wait { state.currentDocument?.fileURL == url }

        state.updateFrontmatter(Frontmatter(tags: ["autosaved"]))

        try await wait(timeout: 6) { (try? String(contentsOf: url, encoding: .utf8))?.contains("autosaved") == true }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "---\ntags:\n- autosaved\n---\n\nbody")
        XCTAssertEqual(state.activeTab?.isDirty, false)
        state.tabs.forEach { state.closeTab($0) }
    }

    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

// MARK: - Add property with a built-in key (G048, G061)

final class R3bAddPropertyTests: XCTestCase {
    func testBuiltInKeysSetTheirFields() {
        var frontmatter = Frontmatter(title: "Old", tags: ["a"], cssclass: "wide")

        XCTAssertEqual(frontmatter.setProperty("cssclass", to: "narrow"), "cssclass")
        XCTAssertEqual(frontmatter.setProperty("Title", to: " New "), "title")
        XCTAssertEqual(frontmatter.setProperty("TAGS", to: "a, b, b"), "tags")
        XCTAssertEqual(frontmatter.setProperty("aliases", to: "x, y"), "aliases")
        XCTAssertEqual(frontmatter.setProperty("date", to: "2026-10-15"), "date")

        XCTAssertEqual(frontmatter.cssclass, "narrow")
        XCTAssertEqual(frontmatter.title, "New")
        XCTAssertEqual(frontmatter.tags, ["a", "b"])
        XCTAssertEqual(frontmatter.aliases, ["x", "y"])
        XCTAssertEqual(frontmatter.date.map(Frontmatter.dateString), "2026-10-15")
        XCTAssertEqual(frontmatter.custom, [:])
        // One line per key, so the block still reads back as these properties.
        XCTAssertEqual(FileService.parseFrontmatter(from: frontmatter.toYAML() + "\n").frontmatter, frontmatter)
    }

    func testBuiltInKeyRewritesTheLineTheFileHas() throws {
        let parsed = FileService.parseFrontmatter(from: "---\n# layout\ncssclass: wide\nStatus: draft\n---\nBody")
        var document = MarkdownDocument(content: parsed.body, fileURL: URL(fileURLWithPath: "/tmp/note.md"),
                                        frontmatter: parsed.frontmatter, frontmatterSource: parsed.source)
        var properties = try XCTUnwrap(document.frontmatter)

        XCTAssertEqual(properties.setProperty("cssclass", to: "narrow"), "cssclass")
        XCTAssertEqual(properties.setProperty("status", to: "done"), "Status")
        document.frontmatter = properties

        // Each key's own line is rewritten; none is written a second time.
        XCTAssertEqual(document.fullText, "---\n# layout\ncssclass: narrow\nStatus: done\n---\nBody")
    }

    func testUnreadableDateOrEmptyKeyIsRefused() {
        var frontmatter = Frontmatter()
        XCTAssertNil(frontmatter.setProperty("date", to: "next week"))
        XCTAssertNil(frontmatter.setProperty("  ", to: "x"))
        XCTAssertEqual(frontmatter, Frontmatter())
    }

    func testExistingKeyIsEditedInItsTypeAndCase() {
        var frontmatter = Frontmatter(custom: ["Status": .list(["a", "b"]), "done": .bool(false)])

        XCTAssertEqual(frontmatter.setProperty("status", to: "c, d"), "Status")
        XCTAssertEqual(frontmatter.setProperty("done", to: "true"), "done")
        XCTAssertEqual(frontmatter.setProperty("Project", to: "CmdMD"), "Project")

        XCTAssertEqual(frontmatter.custom, ["Status": .list(["c", "d"]), "done": .bool(true), "Project": .string("CmdMD")])
    }
}

// MARK: - Word count (G084)

final class R3bWordCountTests: XCTestCase {
    func testMarkdownMarksAreNotWords() {
        XCTAssertEqual(DocumentStatsView.countWords(in: "- [ ] buy milk"), 2)
        XCTAssertEqual(DocumentStatsView.countWords(in: "| a | b |\n|---|---|"), 2)
        XCTAssertEqual(DocumentStatsView.countWords(in: "## Heading here\n---"), 2)
        XCTAssertEqual(DocumentStatsView.countWords(in: "  \n\n "), 0)
    }

    func testTextWithoutSpacesIsSplitIntoWords() {
        XCTAssertEqual(DocumentStatsView.countWords(in: "오늘은 공원에 산책을 갔다."), 4)
        // Lower bounds: dictionary word breaking may change between OS versions.
        XCTAssertGreaterThan(DocumentStatsView.countWords(in: "吾輩は猫である。名前はまだ無い。"), 5)
        XCTAssertGreaterThan(DocumentStatsView.countWords(in: "我们今天去公园散步了"), 2)
    }
}
