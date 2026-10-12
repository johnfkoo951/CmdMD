import XCTest
@testable import CmdMD

/// AppStates built here keep their whole data layer in a throwaway directory
/// (CMDMD_DATA_DIR), so these tests never touch the real Application Support.
class R3SidebarSandboxTestCase: XCTestCase {
    private(set) var sandbox: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdmd-r3-sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        previousDataDir = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        setenv("CMDMD_DATA_DIR", sandbox.appendingPathComponent("data").path, 1)
    }

    override func tearDownWithError() throws {
        if let previousDataDir {
            setenv("CMDMD_DATA_DIR", previousDataDir, 1)
        } else {
            unsetenv("CMDMD_DATA_DIR")
        }
        try? FileManager.default.removeItem(at: sandbox)
        try super.tearDownWithError()
    }

    /// Creates `path` under the sandbox — a folder when it ends in "/",
    /// otherwise a file holding `contents` — and returns its URL.
    @discardableResult
    func make(_ path: String, contents: String = "") throws -> URL {
        let url = sandbox.appendingPathComponent(path)
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Yields the main actor until `condition` holds (or the timeout passes).
    @MainActor
    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

// MARK: - Folders never open as documents (G057)

final class R3SidebarFolderOpenTests: R3SidebarSandboxTestCase {
    func testIsFolderFollowsSymlinksAndRejectsFilesAndMissingPaths() throws {
        let folder = try make("notes/Projects/")
        let file = try make("notes/a.md", contents: "# A")
        let link = sandbox.appendingPathComponent("notes/Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        XCTAssertTrue(AppState.isFolder(at: folder))
        XCTAssertTrue(AppState.isFolder(at: link))
        XCTAssertFalse(AppState.isFolder(at: file))
        XCTAssertFalse(AppState.isFolder(at: sandbox.appendingPathComponent("notes/missing")))
    }

    @MainActor
    func testOpeningAFolderShowsAToastInsteadOfTheFailedToOpenAlert() async throws {
        let folder = try make("notes/Projects/")
        let state = AppState()

        state.openDocument(at: folder)
        try await waitUntil { state.toastMessage != nil }

        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertEqual(state.toastMessage, "\u{201C}Projects\u{201D} is a folder")
    }

    @MainActor
    func testDroppingAFolderWithAFileOpensOnlyTheFile() async throws {
        let folder = try make("notes/Projects/")
        let file = try make("notes/a.md", contents: "# A")
        let state = AppState()

        state.openDocuments(at: [folder, file])
        try await waitUntil { !state.tabs.isEmpty }

        XCTAssertEqual(state.tabs.map(\.fileURL), [file])
        XCTAssertNil(state.errorMessage)
        state.tabs.forEach { state.closeTab($0) }
    }
}

// MARK: - Folder search (G014, G076, G121)

final class R3SidebarFolderSearchTests: R3SidebarSandboxTestCase {
    @MainActor
    func testClearCancelsARunningSearchSoItsResultsNeverReappear() async throws {
        let root = try make("search/")
        for index in 0..<40 {
            try make("search/note\(index).md", contents: "intro\nthe needle \(index)\n")
        }
        let state = AppState()
        state.currentFolder = root
        state.folderSearchText = "needle"

        state.searchInFolder(query: "needle")
        XCTAssertTrue(state.isSearching)
        XCTAssertEqual(state.searchedQuery, "needle")
        state.clearSearch()

        // Long enough for the scan to finish and try to publish.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertFalse(state.isSearching)
        XCTAssertNil(state.searchedQuery)
        XCTAssertEqual(state.folderSearchText, "")
    }

    @MainActor
    func testANewerSearchReplacesAnOlderOne() async throws {
        let root = try make("search/")
        try make("search/a.md", contents: "alpha line\n")
        try make("search/b.md", contents: "beta line\n")
        let state = AppState()
        state.currentFolder = root

        state.searchInFolder(query: "alpha")
        state.searchInFolder(query: "beta")
        try await waitUntil { !state.isSearching }
        // Give a stale "alpha" scan the chance to land, which it must not.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state.searchedQuery, "beta")
        XCTAssertEqual(state.searchResults.map(\.fileName), ["b.md"])
    }

    @MainActor
    func testAnEmptyQueryStopsTheSpinnerAndForgetsTheSearch() async throws {
        let root = try make("search/")
        try make("search/a.md", contents: "alpha line\n")
        let state = AppState()
        state.currentFolder = root

        state.searchInFolder(query: "alpha")
        state.searchInFolder(query: "")
        XCTAssertFalse(state.isSearching)
        XCTAssertNil(state.searchedQuery)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(state.isSearching)
        XCTAssertTrue(state.searchResults.isEmpty)
    }

    func testFolderSearchCoversOnlyTheFilesSection() throws {
        let state = AppState()
        state.currentFolder = try make("notes/")
        state.selectedSidebarTab = .drafts

        state.beginFolderSearch()
        XCTAssertTrue(state.isFolderSearchVisible)

        // The ribbon's other sections show normally…
        state.selectedSidebarTab = .favorites
        XCTAssertFalse(state.isFolderSearchVisible)
        XCTAssertTrue(state.showFolderSearch)

        // …and coming back to Files brings the open search back.
        state.selectedSidebarTab = .files
        XCTAssertTrue(state.isFolderSearchVisible)
    }
}

// MARK: - New file/folder at the root (G078)

final class R3SidebarRootCreationTests: R3SidebarSandboxTestCase {
    @MainActor
    func testNewFileAndFolderLandAtTheRootOfTheOpenFolder() async throws {
        let root = try make("empty/")
        let state = AppState()
        state.currentFolder = root
        state.loadFileTree()
        XCTAssertTrue(state.fileTree.isEmpty)

        state.createNewFile(in: root)
        state.createNewFile(in: root)
        state.createNewFolder(in: root)

        XCTAssertEqual(Set(state.fileTree.map(\.name)), ["New Folder", "Untitled.md", "Untitled (1).md"])
        XCTAssertEqual(state.fileTree.first?.name, "New Folder")
        try await waitUntil { state.tabs.count == 2 }
        XCTAssertEqual(state.tabs.count, 2)
        state.tabs.forEach { state.closeTab($0) }
    }
}

// MARK: - Drafts in the command palette (G120)

final class R3SidebarPaletteDraftTests: R3SidebarSandboxTestCase {
    func testPaletteListsActiveDraftsAndOpensThem() {
        let state = AppState()
        let alpha = Draft(title: "Alpha", body: "a")
        let beta = Draft(title: "Beta", body: "b")
        state.drafts = [alpha, beta, Draft(title: "Old", body: "o", status: .archived)]

        let draftCommands = Command.allCommands(appState: state).filter { $0.title.hasPrefix("Open Draft: ") }
        XCTAssertEqual(draftCommands.map(\.title), ["Open Draft: Alpha", "Open Draft: Beta"])

        draftCommands[1].action()
        XCTAssertEqual(state.activeTab?.documentId, beta.id)

        // Running it again activates the same tab instead of adding one.
        draftCommands[1].action()
        XCTAssertEqual(state.tabs.count, 1)
    }
}
