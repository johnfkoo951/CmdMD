import XCTest
@testable import CmdMD

/// Tabs and documents: Save As landing in the tab it was started from, one
/// tab per file (and a watcher that updates its own tab), the pinned-tab
/// prefix, drafts that read clean because they persist themselves, opens
/// racing session restore, and Open Recent. Paths that end in an NSSavePanel
/// or NSAlert need a user and are left out; what they decide on is covered.
final class R3TabsTests: XCTestCase {
    private var tempDir: URL!
    private var dataDir: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTabs-\(UUID().uuidString)", isDirectory: true)
        dataDir = tempDir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        // Opening and closing tabs writes session.json and the data files:
        // keep AppState away from the real Application Support folder.
        previousDataDir = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        setenv("CMDMD_DATA_DIR", dataDir.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousDataDir {
            setenv("CMDMD_DATA_DIR", previousDataDir, 1)
        } else {
            unsetenv("CMDMD_DATA_DIR")
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Adds a tab whose document reads `current` against a baseline of
    /// `saved`, bypassing the async loader.
    @discardableResult
    private func addTab(_ state: AppState, url: URL?, saved: String, current: String,
                        isDraft: Bool = false) -> EditorTab {
        let document = MarkdownDocument(content: current, fileURL: url, isDraft: isDraft)
        let tab = EditorTab(documentId: document.id, fileURL: url)
        state.documents[document.id] = document
        state.originalContents[document.id] = saved
        state.tabs.append(tab)
        state.refreshStoredDirty(forTabId: tab.id)
        return tab
    }

    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func tab(_ state: AppState, _ tab: EditorTab) -> EditorTab? {
        state.tabs.first { $0.id == tab.id }
    }

    /// Polls (letting main-queue and main-actor work run) until `condition`
    /// holds or `timeout` passes.
    @MainActor
    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func writeSession(_ files: [URL], activeIndex: Int?) throws {
        var session = SessionState()
        session.openFiles = files
        session.activeFileIndex = activeIndex
        try JSONEncoder().encode(session).write(to: dataDir.appendingPathComponent("session.json"))
    }

    // MARK: - Save As writes into its own tab (G005)

    @MainActor
    func testSaveAsLandsInTheTabItWasStartedFromNotTheActiveOne() async throws {
        let state = AppState()
        let cURL = try writeFile("c.md", "C on disk")
        let a = addTab(state, url: nil, saved: "", current: "A text")
        let c = addTab(state, url: cURL, saved: "C on disk", current: "C edited")
        // Another tab came forward while the Save panel was up.
        state.activeTabId = c.id
        let destination = tempDir.appendingPathComponent("a.md")

        let saved = await state.saveAs(tab: a, to: destination)

        XCTAssertTrue(saved)
        XCTAssertEqual(try read(destination), "A text")
        XCTAssertEqual(tab(state, a)?.fileURL, destination)
        XCTAssertEqual(state.documents[a.documentId]?.fileURL, destination)
        XCTAssertEqual(tab(state, a)?.isDirty, false)
        // The active tab keeps its own document, file and unsaved edits.
        XCTAssertEqual(state.documents[c.documentId]?.content, "C edited")
        XCTAssertEqual(state.originalContents[c.documentId], "C on disk")
        XCTAssertEqual(tab(state, c)?.fileURL, cURL)
        XCTAssertEqual(tab(state, c)?.isDirty, true)
        XCTAssertEqual(try read(cURL), "C on disk")
        XCTAssertEqual(state.activeTabId, c.id)
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testSaveAsGraduatesADraftIntoACleanFileTab() async throws {
        let state = AppState()
        let draft = Draft(body: "draft text")
        state.drafts = [draft]
        state.openDraft(draft)
        let tabBefore = try XCTUnwrap(state.activeTab)
        let destination = tempDir.appendingPathComponent("draft.md")

        let saved = await state.saveAs(tab: tabBefore, to: destination)

        XCTAssertTrue(saved)
        XCTAssertEqual(try read(destination), "draft text")
        XCTAssertFalse(state.drafts.contains { $0.id == draft.id })
        XCTAssertEqual(state.documents[tabBefore.documentId]?.isDraft, false)
        XCTAssertEqual(tab(state, tabBefore)?.fileURL, destination)
        XCTAssertEqual(tab(state, tabBefore)?.isDirty, false)
        state.tabs.forEach { state.closeTab($0) }
    }

    // MARK: - One tab per file (G006, G024)

    @MainActor
    func testSaveAsRefusesAFileThatIsOpenInAnotherTab() async throws {
        let state = AppState()
        let notes = try writeFile("Notes.md", "their text")
        let untitled = addTab(state, url: nil, saved: "", current: "mine")
        addTab(state, url: notes, saved: "their text", current: "their text")

        let saved = await state.saveAs(tab: untitled, to: notes)

        XCTAssertFalse(saved)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(try read(notes), "their text")
        XCTAssertNil(tab(state, untitled)?.fileURL)
        XCTAssertEqual(tab(state, untitled)?.isDirty, true)
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testTwoOpensOfTheSameFileInFlightMakeOneTab() async throws {
        let state = AppState()
        let url = try writeFile("twice.md", "# Twice")

        // Both pass the "already open?" check before either load finishes.
        state.openDocument(at: url, inNewTab: true)
        state.openDocument(at: url, inNewTab: true)
        try await wait { !state.tabs.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the second load land

        XCTAssertEqual(state.tabs.filter { $0.fileURL == url }.count, 1)
        XCTAssertEqual(state.activeTab?.fileURL, url)
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testEachWatcherUpdatesItsOwnTabWhenTwoTabsShowOneFile() async throws {
        let state = AppState()
        let url = try writeFile("shared.md", "v1")
        let a = addTab(state, url: url, saved: "v1", current: "v1")
        let b = addTab(state, url: url, saved: "v1", current: "v1")
        // A save arms the tab's file watcher when it has none.
        let savedA = await state.save(tab: a)
        let savedB = await state.save(tab: b)
        XCTAssertTrue(savedA)
        XCTAssertTrue(savedB)
        try await Task.sleep(nanoseconds: 400_000_000)   // B's write re-armed A's watcher

        // Another app replaces the file (atomic write: a new inode).
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try await wait {
            state.documents[a.documentId]?.content == "v2" && state.documents[b.documentId]?.content == "v2"
        }

        XCTAssertEqual(state.documents[a.documentId]?.content, "v2")
        XCTAssertEqual(state.documents[b.documentId]?.content, "v2", "the second tab on the file went stale")
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testFileOpenedDuringSessionRestoreStaysInFront() async throws {
        let a = try writeFile("a.md", "# A")
        let b = try writeFile("b.md", "# B")
        let opened = try writeFile("opened.md", "# Opened")
        try writeSession([a, b], activeIndex: 0)

        let state = AppState()
        // A Finder double-click that launched the app arrives while restore loads.
        state.openDocument(at: opened, inNewTab: true)
        try await wait { state.tabs.count == 3 }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(Set(state.tabs.compactMap(\.fileURL)), [a, b, opened])
        XCTAssertEqual(state.activeTab?.fileURL, opened)
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testFinderOpenOfASessionFileDuringRestoreMakesOneTabAndKeepsItInFront() async throws {
        let a = try writeFile("a.md", "# A")
        let b = try writeFile("b.md", "# B")
        try writeSession([a, b], activeIndex: 1)

        let state = AppState()
        state.openDocument(at: a, inNewTab: true)
        try await wait { state.tabs.count >= 2 }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state.tabs.filter { $0.fileURL == a }.count, 1)
        XCTAssertEqual(state.tabs.filter { $0.fileURL == b }.count, 1)
        XCTAssertEqual(state.activeTab?.fileURL, a)
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testRestoreStillActivatesTheSavedTabWhenNothingElseOpened() async throws {
        let a = try writeFile("a.md", "# A")
        let b = try writeFile("b.md", "# B")
        try writeSession([a, b], activeIndex: 0)

        let state = AppState()
        try await wait { state.tabs.count == 2 && state.activeTabId != nil }

        XCTAssertEqual(state.tabs.map(\.fileURL), [a, b])
        XCTAssertEqual(state.activeTab?.fileURL, a)
        state.tabs.forEach { state.closeTab($0) }
    }

    // MARK: - Pinned tabs stay a prefix (G012)

    private func titles(_ state: AppState) -> [String] {
        state.tabs.map(\.displayTitle)
    }

    private func pinnedArePrefix(_ state: AppState) -> Bool {
        state.tabs.drop(while: \.isPinned).allSatisfy { !$0.isPinned }
    }

    func testUnpinningMovesTheTabOutOfThePinnedRun() {
        let state = AppState()
        let a = EditorTab(title: "A"), b = EditorTab(title: "B"), c = EditorTab(title: "C")
        state.tabs = [a, b, c]

        state.toggleTabPin(b)
        state.toggleTabPin(c)
        XCTAssertEqual(titles(state), ["B", "C", "A"])

        state.toggleTabPin(b)   // unpin: lands right after the pinned run
        XCTAssertEqual(titles(state), ["C", "B", "A"])
        XCTAssertEqual(state.tabs.filter(\.isPinned).map(\.displayTitle), ["C"])
        XCTAssertTrue(pinnedArePrefix(state))
    }

    func testDragsCannotInterleavePinnedAndUnpinnedTabsAfterAnUnpin() {
        let state = AppState()
        let p1 = EditorTab(title: "P1", isPinned: true)
        let p2 = EditorTab(title: "P2", isPinned: true)
        let u3 = EditorTab(title: "U3")
        state.tabs = [p1, p2, u3]

        state.toggleTabPin(p1)
        XCTAssertEqual(titles(state), ["P2", "P1", "U3"])

        // An unpinned tab dropped onto the pinned run is clamped after it.
        state.moveTab(id: u3.id, before: p2.id)
        XCTAssertEqual(titles(state), ["P2", "U3", "P1"])
        state.toggleTabPin(u3)
        XCTAssertEqual(titles(state), ["P2", "U3", "P1"])
        XCTAssertTrue(pinnedArePrefix(state))
        state.moveTabToEnd(id: p2.id)
        XCTAssertTrue(pinnedArePrefix(state))
    }

    // MARK: - Drafts save themselves (G070, G030)

    func testTypingInADraftKeepsItClean() {
        let state = AppState()
        state.createNewDraft()

        state.updateContent("hello")

        XCTAssertEqual(state.drafts.first?.body, "hello")
        XCTAssertEqual(state.activeTab?.isDirty, false)
        XCTAssertFalse(state.hasAnyDirtyTabs)
        state.tabs.forEach { state.closeTab($0) }
    }

    func testDraftPropertiesPersistWithTheDraftSoTheTabStaysClean() {
        let state = AppState()
        state.createNewDraft()
        state.updateContent("hello")

        // Inspector › Add Properties goes through updateFrontmatter, which also
        // writes the properties into the draft entry (drafts.json): like the
        // body, they are kept without a save, so the tab isn't dirty.
        state.updateFrontmatter(Frontmatter(title: "Title"))

        XCTAssertEqual(state.activeTab?.isDirty, false)
        let draft = state.drafts.first { $0.id == state.currentDocument?.id }
        XCTAssertEqual(draft?.frontmatter?.title, "Title")
        state.tabs.forEach { state.closeTab($0) }
    }

    func testUntitledTabWithTextStillReadsAsUnsaved() {
        let state = AppState()
        state.createNewTab()

        state.updateContent("not saved anywhere")

        XCTAssertEqual(state.activeTab?.isDirty, true)
        XCTAssertTrue(state.hasAnyDirtyTabs)
        state.tabs.forEach { state.closeTab($0) }
    }

    @MainActor
    func testOpeningAFileDoesNotReplaceTheActiveDraftTab() async throws {
        let state = AppState()
        let url = try writeFile("note.md", "# Note")
        state.createNewDraft()
        state.updateContent("work in progress")
        let draftTab = try XCTUnwrap(state.activeTab)

        state.openDocument(at: url)   // a sidebar click: replace-in-place mode
        try await wait { state.tabs.count == 2 }

        XCTAssertNotNil(tab(state, draftTab))
        XCTAssertEqual(state.activeTab?.fileURL, url)
        state.tabs.forEach { state.closeTab($0) }
    }

    // MARK: - Open Recent (G033)

    func testRecentMenuTitlesNameTheFolderOnlyForRepeatedNames() {
        let urls = ["/a/README.md", "/b/README.md", "/a/x.md"].map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(AppState.recentMenuTitles(urls), ["README.md \u{2014} a", "README.md \u{2014} b", "x.md"])
        XCTAssertEqual(AppState.recentMenuTitles([URL(fileURLWithPath: "/a/x.md")]), ["x.md"])
        XCTAssertEqual(AppState.recentMenuTitles([]), [])
    }

    @MainActor
    func testOpeningADeletedRecentFileDropsItFromTheList() async throws {
        let state = AppState()
        let kept = try writeFile("kept.md", "# Kept")
        let gone = tempDir.appendingPathComponent("gone.md")   // folder exists, file doesn't
        state.recentFiles = [gone, kept]

        state.openDocument(at: gone, inNewTab: true)
        try await wait { state.errorMessage != nil }

        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.recentFiles, [kept])
        XCTAssertTrue(state.tabs.isEmpty)
    }
}
