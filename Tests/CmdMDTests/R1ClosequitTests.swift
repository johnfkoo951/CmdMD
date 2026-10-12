import XCTest
@testable import CmdMD

/// Close / quit save flow: saving a specific (background) tab, Save All
/// reporting failure so quit can be cancelled, the stored dirty flag after a
/// baseline change, and the context menu's group close. Paths that end in an
/// NSAlert or NSSavePanel need a user and are left out; what they decide on is
/// covered here.
final class R1ClosequitTests: XCTestCase {
    private var tempDir: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDCloseQuit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Closing tabs writes session.json. Point AppState's data layer at the
        // temp dir so tests never touch the real Application Support folder
        // (and no restored session adds tabs mid-test).
        previousDataDir = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        setenv("CMDMD_DATA_DIR", tempDir.appendingPathComponent("data").path, 1)
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
                        pinned: Bool = false) -> EditorTab {
        let document = MarkdownDocument(content: current, fileURL: url)
        let tab = EditorTab(documentId: document.id, fileURL: url, isPinned: pinned)
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

    /// The parent folder doesn't exist, so every write to it throws.
    private func unwritableURL() -> URL {
        tempDir.appendingPathComponent("missing-\(UUID().uuidString)/note.md")
    }

    private func storedDirty(_ state: AppState, _ tab: EditorTab) -> Bool? {
        state.tabs.first { $0.id == tab.id }?.isDirty
    }

    // MARK: - Per-tab save (close prompt → Save)

    @MainActor
    func testSaveTabWritesThatTabNotTheActiveOne() async throws {
        let state = AppState()
        let aURL = try writeFile("a.md", "A on disk")
        let bURL = try writeFile("b.md", "B on disk")
        let a = addTab(state, url: aURL, saved: "A on disk", current: "A edited")
        let b = addTab(state, url: bURL, saved: "B on disk", current: "B edited")
        state.activeTabId = a.id

        let saved = await state.save(tab: b)

        XCTAssertTrue(saved)
        XCTAssertEqual(try read(bURL), "B edited")
        XCTAssertEqual(try read(aURL), "A on disk", "the active tab must not be written instead")
        XCTAssertFalse(state.isTabDirty(b))
        XCTAssertEqual(storedDirty(state, b), false)
        XCTAssertTrue(state.isTabDirty(a))
        XCTAssertEqual(state.activeTabId, a.id)
    }

    @MainActor
    func testSaveTabReportsFailedWriteAndKeepsEdits() async {
        let state = AppState()
        let tab = addTab(state, url: unwritableURL(), saved: "old", current: "new")

        let saved = await state.save(tab: tab)

        XCTAssertFalse(saved, "a close must not go ahead after a failed save")
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.documents[tab.documentId]?.content, "new")
        XCTAssertTrue(state.isTabDirty(tab))
        XCTAssertEqual(storedDirty(state, tab), true)
    }

    @MainActor
    func testSaveCurrentDocumentStillSavesTheActiveTab() async throws {
        let state = AppState()
        let url = try writeFile("c.md", "old")
        let tab = addTab(state, url: url, saved: "old", current: "new")
        state.activeTabId = tab.id

        await state.saveCurrentDocument()

        XCTAssertEqual(try read(url), "new")
        XCTAssertEqual(storedDirty(state, tab), false)
    }

    // MARK: - Quit → Save All

    @MainActor
    func testSaveAllDirtyTabsReportsFailureAndFrontsTheFailingTab() async throws {
        let state = AppState()
        let goodURL = try writeFile("good.md", "old")
        let good = addTab(state, url: goodURL, saved: "old", current: "new")
        let bad = addTab(state, url: unwritableURL(), saved: "old", current: "new")
        state.activeTabId = good.id

        let saved = await state.saveAllDirtyTabs()

        XCTAssertFalse(saved, "the quit must be cancelled when a save fails")
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.activeTabId, bad.id)
        XCTAssertTrue(state.isTabDirty(bad))
        XCTAssertEqual(try read(goodURL), "new")
        XCTAssertFalse(state.isTabDirty(good))
    }

    @MainActor
    func testSaveAllDirtyTabsSucceedsOnceEverythingIsWritten() async throws {
        let state = AppState()
        let oneURL = try writeFile("one.md", "1")
        let twoURL = try writeFile("two.md", "2")
        let one = addTab(state, url: oneURL, saved: "1", current: "1 edited")
        addTab(state, url: twoURL, saved: "2", current: "2")

        let saved = await state.saveAllDirtyTabs()

        XCTAssertTrue(saved)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(try read(oneURL), "1 edited")
        XCTAssertEqual(try read(twoURL), "2")
        XCTAssertEqual(storedDirty(state, one), false)
        XCTAssertFalse(state.hasAnyDirtyTabs)
    }

    // MARK: - Stored dirty flag after a new baseline (Save As, ⌥⌘R)

    func testNewBaselineRefreshesStoredDirtyFlag() {
        let state = AppState()
        state.createNewTab()
        state.updateContent("hello")
        XCTAssertEqual(state.activeTab?.isDirty, true)

        // Save As order: the document (now file-backed) first, then the baseline.
        var document = state.currentDocument!
        document.fileURL = tempDir.appendingPathComponent("saved.md")
        state.currentDocument = document
        state.originalContent = document.fullText
        XCTAssertEqual(state.activeTab?.isDirty, false)

        // ⌥⌘R order: what was read from disk first, then the baseline.
        state.currentDocument = MarkdownDocument(content: "disk")
        XCTAssertEqual(state.activeTab?.isDirty, true)
        state.originalContent = "disk"
        XCTAssertEqual(state.activeTab?.isDirty, false)
    }

    // MARK: - Context menu group close

    func testContextMenuCloseTabClosesACleanTabRightAway() {
        let state = AppState()
        let a = addTab(state, url: nil, saved: "a", current: "a")
        let b = addTab(state, url: nil, saved: "b", current: "b")
        state.activeTabId = b.id

        state.closeTabsWithConfirmation([b])

        XCTAssertEqual(state.tabs.map(\.id), [a.id])
        XCTAssertNil(state.documents[b.documentId])
        XCTAssertEqual(state.activeTabId, a.id)
    }

    func testCloseOtherTabsClosesCleanTabsAndKeepsPinned() {
        let state = AppState()
        let pinned = addTab(state, url: nil, saved: "p", current: "p", pinned: true)
        let keep = addTab(state, url: nil, saved: "k", current: "k")
        addTab(state, url: nil, saved: "x", current: "x")
        addTab(state, url: nil, saved: "y", current: "y")
        state.activeTabId = keep.id

        state.closeOtherTabs(except: keep)

        XCTAssertEqual(state.tabs.map(\.id), [pinned.id, keep.id])
        XCTAssertEqual(state.documents.count, 2)
        XCTAssertEqual(state.originalContents.count, 2)
    }

    func testGroupCloseHonorsConfirmationToggleOff() {
        // With "Confirm before closing unsaved tabs" off, closing dirty tabs
        // discards them without a prompt, the same as ⌘W and the tab ✕.
        let state = AppState()
        state.settings.confirmBeforeClosingDirtyTabs = false
        let a = addTab(state, url: nil, saved: "a", current: "a")
        addTab(state, url: nil, saved: "b", current: "b edited")
        addTab(state, url: nil, saved: "c", current: "c edited")
        state.activeTabId = a.id

        state.closeTabsToRight(of: a)

        XCTAssertEqual(state.tabs.map(\.id), [a.id])
        XCTAssertEqual(state.documents.count, 1)
        XCTAssertEqual(state.originalContents.count, 1)
    }
}
