import XCTest
import AppKit
@testable import CmdMD

/// AppStates built here keep their data (favorites, recents, session) in a
/// throwaway directory through CMDMD_DATA_DIR, never the real
/// Application Support/CmdMD.
class R3RenameSandboxTestCase: XCTestCase {
    private(set) var sandbox: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdmd-r3-rename-\(UUID().uuidString)", isDirectory: true)
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
}

// MARK: - Rename prompt (G122, G065)

final class R3RenamePromptTests: XCTestCase {
    private func parts(_ path: String, isDirectory: Bool) -> [String] {
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
        let parts = AppState.renameParts(for: url, isDirectory: isDirectory)
        return [parts.base, parts.ext]
    }

    func testFoldersAreEditedWholeWithNoExtension() {
        // deletingPathExtension() cut these to "74", "Release", "회의록 2024", "v1".
        XCTAssertEqual(parts("/v/74. Projects", isDirectory: true), ["74. Projects", ""])
        XCTAssertEqual(parts("/v/Release.v2", isDirectory: true), ["Release.v2", ""])
        XCTAssertEqual(parts("/v/회의록 2024.10", isDirectory: true), ["회의록 2024.10", ""])
        XCTAssertEqual(parts("/v/v1.5", isDirectory: true), ["v1.5", ""])
    }

    func testExtensionlessFilesAreEditedWhole() {
        XCTAssertEqual(parts("/v/Ch. 3 Notes", isDirectory: false), ["Ch. 3 Notes", ""])
        XCTAssertEqual(parts("/v/README", isDirectory: false), ["README", ""])
    }

    func testFilesKeepTheirExtension() {
        XCTAssertEqual(parts("/v/Notes.md", isDirectory: false), ["Notes", "md"])
        XCTAssertEqual(parts("/v/2024.10.11 Meeting.md", isDirectory: false), ["2024.10.11 Meeting", "md"])
    }

    func testRenamedNameKeepsTheExtensionWithoutDoublingIt() {
        XCTAssertEqual(AppState.renamedFileName("Plan 2", keeping: "md"), "Plan 2.md")
        XCTAssertEqual(AppState.renamedFileName("Plan.md", keeping: "md"), "Plan.md")
        XCTAssertEqual(AppState.renamedFileName("Plan.MD", keeping: "md"), "Plan.MD")
        // Folders: nothing is appended, so "Release v3" doesn't become "Release v3.v2".
        XCTAssertEqual(AppState.renamedFileName("Release v3", keeping: ""), "Release v3")
        XCTAssertEqual(AppState.renamedFileName("75. Projects", keeping: ""), "75. Projects")
    }
}

// MARK: - Case-only rename (G010, G065)

final class R3CaseOnlyRenameTests: R3RenameSandboxTestCase {
    private func skipUnlessCaseInsensitive() throws {
        let values = try sandbox.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try XCTSkipIf(values.volumeSupportsCaseSensitiveNames != false, "needs a case-insensitive volume")
    }

    func testCapitalizingAFileIsNotACollisionWithItself() throws {
        try skipUnlessCaseInsensitive()
        let lower = try make("case/meeting notes.md")
        let upper = lower.deletingLastPathComponent().appendingPathComponent("Meeting Notes.md")
        // The false "already exists": the new name finds the file itself.
        XCTAssertTrue(FileManager.default.fileExists(atPath: upper.path))
        XCTAssertTrue(AppState.isCaseOnlyRename(from: lower, to: upper))

        try FileManager.default.moveItem(at: lower, to: upper)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: upper.deletingLastPathComponent().path), ["Meeting Notes.md"])
    }

    func testCapitalizingAFolderIsNotACollisionWithItself() throws {
        try skipUnlessCaseInsensitive()
        // Sidebar folder URLs carry a trailing slash; the new name doesn't.
        let folder = URL(fileURLWithPath: try make("case/notes/").path, isDirectory: true)
        XCTAssertTrue(AppState.isCaseOnlyRename(from: folder, to: folder.deletingLastPathComponent().appendingPathComponent("Notes")))
    }

    func testAnotherFileIsStillACollision() throws {
        let a = try make("case/a.md")
        let b = try make("case/b.md")
        XCTAssertFalse(AppState.isCaseOnlyRename(from: a, to: b))
        // Same letters, different file: "A.md" here is a new name, not "a.md".
        let elsewhere = try make("other/A.md")
        XCTAssertFalse(AppState.isCaseOnlyRename(from: a, to: elsewhere))
    }
}

// MARK: - Trash bookkeeping (G064)

final class R3TrashBookkeepingTests: R3RenameSandboxTestCase {
    func testTrashingAFolderForgetsEverythingInsideIt() {
        let state = AppState()
        let dir = sandbox.appendingPathComponent("v/Dir", isDirectory: true)
        let inside = dir.appendingPathComponent("a.md")
        let sub = dir.appendingPathComponent("Sub", isDirectory: true)
        // Shares "Dir" as a name prefix but is not inside it.
        let sibling = sandbox.appendingPathComponent("v/Dir 2/b.md")
        let siblingDir = sandbox.appendingPathComponent("v/Dir-old", isDirectory: true)
        state.favorites = [FavoriteItem(url: dir), FavoriteItem(url: inside), FavoriteItem(url: sibling)]
        state.recentFiles = [inside, sibling]
        state.expandedFolders = [dir, sub, siblingDir]

        state.forgetTrashedItem(at: dir)

        XCTAssertEqual(state.favorites.map(\.url), [sibling])
        XCTAssertEqual(state.recentFiles, [sibling])
        XCTAssertEqual(state.expandedFolders, [siblingDir])
    }

    func testTrashedFavoriteStaysGoneAfterRelaunch() {
        // Neither file exists, nor its folder — loading keeps such entries
        // (unmounted volume), so only a saved removal makes them go away.
        let trashed = sandbox.appendingPathComponent("gone/Plan.md")
        let kept = sandbox.appendingPathComponent("away/Roadmap.md")
        let state = AppState()
        state.favorites = [FavoriteItem(url: trashed), FavoriteItem(url: kept)]
        state.recentFiles = [trashed, kept]
        state.saveUserData()

        state.forgetTrashedItem(at: trashed)

        let relaunched = AppState()
        XCTAssertEqual(relaunched.favorites.map(\.url), [kept])
        XCTAssertFalse(relaunched.recentFiles.contains(trashed))
    }
}

// MARK: - Clear Recents (G015)

final class R3ClearRecentsTests: R3RenameSandboxTestCase {
    func testClearRecentsAlsoClearsTheSystemRecentDocuments() throws {
        let state = AppState()
        let url = try make("recent/a.md")
        state.recentFiles = [url]
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        state.clearRecentFiles()

        XCTAssertTrue(state.recentFiles.isEmpty)
        XCTAssertTrue(NSDocumentController.shared.recentDocumentURLs.isEmpty)
    }
}

// MARK: - Favorites (G134)

final class R3FavoritesTests: R3RenameSandboxTestCase {
    func testFolderFavoritesShowTheirWholeName() {
        XCTAssertEqual(FavoriteItem(url: URL(fileURLWithPath: "/v/70. Outputs", isDirectory: true)).displayName, "70. Outputs")
        XCTAssertEqual(FavoriteItem(url: URL(fileURLWithPath: "/v/v1.2", isDirectory: true)).displayName, "v1.2")
        XCTAssertEqual(FavoriteItem(url: URL(fileURLWithPath: "/v/Ch. 3 Notes")).displayName, "Ch. 3 Notes")
        XCTAssertEqual(FavoriteItem(url: URL(fileURLWithPath: "/v/Note.md")).displayName, "Note")
        XCTAssertEqual(FavoriteItem(url: URL(fileURLWithPath: "/v/v1.2", isDirectory: true), alias: "Release").displayName, "Release")
    }

    func testFolderFavoriteNameSurvivesFavoritesJSON() throws {
        let favorite = FavoriteItem(url: URL(fileURLWithPath: "/v/70. Outputs", isDirectory: true))
        let decoded = try JSONDecoder().decode(FavoriteItem.self, from: JSONEncoder().encode(favorite))
        XCTAssertEqual(decoded.displayName, "70. Outputs")
    }

    func testOpeningAFolderFavoriteMakesItTheFilesRoot() throws {
        let folder = try make("vault/70. Outputs/")
        try make("vault/70. Outputs/a.md")
        let state = AppState()
        state.selectedSidebarTab = .favorites

        state.openFavorite(FavoriteItem(url: folder))

        XCTAssertEqual(state.currentFolder, folder)
        XCTAssertEqual(state.selectedSidebarTab, .files)
        XCTAssertEqual(state.fileTree.map(\.name), ["a.md"])
        // It used to be opened as a document: "Failed to open file".
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.tabs.isEmpty)
    }

    func testOpeningAMissingFavoriteSaysSo() {
        let state = AppState()
        let before = state.currentFolder

        state.openFavorite(FavoriteItem(url: sandbox.appendingPathComponent("gone/Plan.md")))

        XCTAssertNotNil(state.toastMessage)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.currentFolder, before)
        XCTAssertTrue(state.tabs.isEmpty)
    }
}

// MARK: - Symlinked folders (G077)

final class R3SymlinkedFolderTests: R3RenameSandboxTestCase {
    /// vault/ holds a linked folder, a dangling link, links back to itself and
    /// to its parent, a linked note, and a note of its own.
    private func makeVault() throws -> URL {
        let root = try make("vault/")
        try make("vault/own.md")
        try make("elsewhere/Shared/inside.md")
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("Shared"), withDestinationURL: sandbox.appendingPathComponent("elsewhere/Shared"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Dangling"), withDestinationURL: sandbox.appendingPathComponent("nowhere"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Loop"), withDestinationURL: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Up"), withDestinationURL: sandbox)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked.md"), withDestinationURL: sandbox.appendingPathComponent("elsewhere/Shared/inside.md"))
        return root
    }

    func testLinkedFoldersAreListedAsFolders() throws {
        let root = try makeVault()
        let listing = try AppState.listFolder(at: root)

        // Dangling links and links that would nest the tree in itself stay out.
        XCTAssertEqual(listing.map(\.name), ["Shared", "linked.md", "own.md"])
        let shared = try XCTUnwrap(listing.first { $0.name == "Shared" })
        XCTAssertTrue(shared.isDirectory)
        XCTAssertTrue(shared.url.hasDirectoryPath)
        XCTAssertEqual(try AppState.listFolder(at: shared.url).map(\.name), ["inside.md"])
    }

    func testLinkedFolderExpandsInTheTree() throws {
        let root = try makeVault()
        let state = AppState()
        state.currentFolder = root
        state.loadFileTree()
        let shared = try XCTUnwrap(state.fileTree.first { $0.name == "Shared" })

        state.toggleFolderExpansion(shared.url)

        XCTAssertEqual(state.fileTree.first { $0.name == "Shared" }?.children.map(\.name), ["inside.md"])
        XCTAssertNil(state.errorMessage)
    }
}
