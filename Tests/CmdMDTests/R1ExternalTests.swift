import XCTest
@testable import CmdMD

/// Scratch directory per test for the file-backed cases.
private func makeScratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - Frontmatter round trip (own saves must not change the note)

final class FrontmatterRoundTripTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeScratchDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSaveReloadCyclesDoNotAddBlankLines() async throws {
        let url = try write("---\ntitle: x\n---\nABC", to: "note.md")
        let service = FileService()
        var document = try await service.loadDocument(from: url)
        XCTAssertEqual(document.content, "ABC")

        var savedTexts: [String] = []
        for _ in 0..<3 {
            try await service.saveDocument(document, to: url)
            savedTexts.append(try String(contentsOf: url, encoding: .utf8))
            document = try await service.loadDocument(from: url)
            XCTAssertEqual(document.content, "ABC", "a save/reload cycle must leave the body as it was")
        }
        // The block is written back as the file had it: no blank line added.
        XCTAssertEqual(savedTexts, Array(repeating: "---\ntitle: x\n---\nABC", count: 3))
    }

    func testOwnSaveReadsBackAsTheBaseline() async throws {
        // What the watcher reads after our own atomic save must equal the
        // baseline we stored, or every ⌘S turns into "Reloaded from disk".
        let url = try write("---\ntags:\n  - a\n---\n# H\nbody\n", to: "note.md")
        let service = FileService()
        let document = try await service.loadDocument(from: url)
        try await service.saveDocument(document, to: url)

        let disk = try await service.loadDocumentWithText(from: url)
        XCTAssertTrue(AppState.diskMatches(document.fullText, diskText: disk.text, diskFullText: disk.document.fullText))
        XCTAssertEqual(disk.document.content, document.content)
    }

    func testCRLFBodyKeepsItsLineBreaks() async throws {
        let url = try write("---\r\ntitle: x\r\n---\r\nA\r\nB", to: "crlf.md")
        let service = FileService()
        let document = try await service.loadDocument(from: url)
        XCTAssertEqual(document.frontmatter?.title, "x")
        // LF in memory (one break per line), CRLF again on disk.
        XCTAssertEqual(document.content, "A\nB")
        try await service.saveDocument(document, to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("---\r\ntitle: x\r\n---\r\nA\r\nB".utf8))
    }

    func testOnlyTheSeparatorLineIsDropped() async throws {
        let text = "---\ntitle: x\n---\n\n\nBody"
        let url = try write(text, to: "blank.md")
        let document = try await FileService().loadDocument(from: url)
        XCTAssertEqual(document.content, "\nBody")
        XCTAssertEqual(document.fullText, text, "a note already in canonical form round-trips byte for byte")
    }

    func testLoadDocumentWithTextReturnsTheExactDiskText() async throws {
        let raw = "---\ntitle:   spaced\n---\nBody"
        let url = try write(raw, to: "raw.md")
        let disk = try await FileService().loadDocumentWithText(from: url)
        XCTAssertEqual(disk.text, raw)
        XCTAssertEqual(disk.document.content, "Body")
        XCTAssertEqual(disk.document.fullText, raw, "fullText writes the block back as the file had it")
    }
}

// MARK: - Changed-on-disk detection (watcher + save conflicts)

final class ExternalChangeDetectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeScratchDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOwnSaveIsNotAConflict() {
        XCTAssertFalse(AppState.isSaveConflict(diskText: "A", diskFullText: "A", baseline: "A", pending: "AB"))
    }

    func testExternalEditIsAConflict() {
        XCTAssertTrue(AppState.isSaveConflict(diskText: "theirs", diskFullText: "theirs", baseline: "original", pending: "mine"))
    }

    func testDiskAlreadyHoldingOurTextIsNotAConflict() {
        XCTAssertFalse(AppState.isSaveConflict(diskText: "mine", diskFullText: "mine", baseline: "original", pending: "mine"))
    }

    func testFirstSaveOfAnUntouchedObsidianNoteIsNotAConflict() async throws {
        // Obsidian writes no blank line after the fence, so the raw text never
        // equals the normalized baseline — the parsed comparison must match.
        let url = directory.appendingPathComponent("obsidian.md")
        try "---\ntitle: x\n---\nBody".write(to: url, atomically: true, encoding: .utf8)
        let service = FileService()
        let document = try await service.loadDocument(from: url)
        var edited = document
        edited.content += "\nmore"

        let disk = try await service.loadDocumentWithText(from: url)
        XCTAssertFalse(AppState.isSaveConflict(diskText: disk.text, diskFullText: disk.document.fullText,
                                               baseline: document.fullText, pending: edited.fullText))
    }

    func testExternalEditIsDetectedAndOurSaveResetsTheBaseline() async throws {
        let url = directory.appendingPathComponent("note.md")
        try "---\ntitle: x\n---\nBody".write(to: url, atomically: true, encoding: .utf8)
        let service = FileService()
        let document = try await service.loadDocument(from: url)
        var edited = document
        edited.content = "mine"

        // Another app (Sync, git, an editor) rewrites the file meanwhile.
        try "---\ntitle: x\n---\ntheirs".write(to: url, atomically: true, encoding: .utf8)
        var disk = try await service.loadDocumentWithText(from: url)
        XCTAssertTrue(AppState.isSaveConflict(diskText: disk.text, diskFullText: disk.document.fullText,
                                              baseline: document.fullText, pending: edited.fullText))

        // After Save Anyway the written text is the baseline: no conflict next time.
        try await service.saveDocument(edited, to: url)
        disk = try await service.loadDocumentWithText(from: url)
        var further = edited
        further.content += "!"
        XCTAssertFalse(AppState.isSaveConflict(diskText: disk.text, diskFullText: disk.document.fullText,
                                               baseline: edited.fullText, pending: further.fullText))
    }

    func testDiskReloadKeepsTheDocumentIdentity() {
        let url = URL(fileURLWithPath: "/tmp/note.md", isDirectory: false)
        let existing = MarkdownDocument(title: "note", content: "old", fileURL: url)
        let fresh = MarkdownDocument(
            title: "New Title",
            content: "new",
            fileURL: url,
            modifiedAt: Date(timeIntervalSince1970: 100),
            frontmatter: Frontmatter(title: "New Title")
        )

        let reloaded = AppState.applyingDiskReload(fresh, to: existing)
        XCTAssertEqual(reloaded.id, existing.id, "a new id reads as a document switch (undo, caret and scroll reset)")
        XCTAssertEqual(reloaded.fileURL, url)
        XCTAssertEqual(reloaded.content, "new")
        XCTAssertEqual(reloaded.frontmatter, fresh.frontmatter)
        XCTAssertEqual(reloaded.title, "New Title")
        XCTAssertEqual(reloaded.modifiedAt, fresh.modifiedAt)
    }
}

// MARK: - Renames, moves and deletions

final class ExternalRenameTests: XCTestCase {
    private let old = URL(fileURLWithPath: "/v/2024", isDirectory: true)
    private let new = URL(fileURLWithPath: "/v/archive-2024", isDirectory: false)

    func testFilesInsideARenamedFolderFollowIt() {
        XCTAssertEqual(
            AppState.remappedURL(URL(fileURLWithPath: "/v/2024/a.md", isDirectory: false), from: old, to: new),
            URL(fileURLWithPath: "/v/archive-2024/a.md", isDirectory: false)
        )
        XCTAssertEqual(
            AppState.remappedURL(URL(fileURLWithPath: "/v/2024/sub/b.md", isDirectory: false), from: old, to: new),
            URL(fileURLWithPath: "/v/archive-2024/sub/b.md", isDirectory: false)
        )
    }

    func testExactMatchMapsToTheNewURL() {
        let file = URL(fileURLWithPath: "/v/Idea.md", isDirectory: false)
        let renamed = URL(fileURLWithPath: "/v/Project Idea.md", isDirectory: false)
        XCTAssertEqual(AppState.remappedURL(file, from: file, to: renamed), renamed)
        XCTAssertEqual(AppState.remappedURL(URL(fileURLWithPath: "/v/2024", isDirectory: false), from: old, to: new), new)
    }

    func testSiblingSharingTheNamePrefixIsUntouched() {
        XCTAssertNil(AppState.remappedURL(URL(fileURLWithPath: "/v/2024-old/a.md", isDirectory: false), from: old, to: new))
        XCTAssertNil(AppState.remappedURL(URL(fileURLWithPath: "/w/2024/a.md", isDirectory: false), from: old, to: new))
    }

    func testFolderURLsKeepTheirTrailingSlash() {
        // Sidebar folder URLs carry a trailing slash and expandedFolders
        // membership compares URLs exactly.
        let remapped = AppState.remappedURL(URL(fileURLWithPath: "/v/2024/sub", isDirectory: true), from: old, to: new)
        XCTAssertEqual(remapped, URL(fileURLWithPath: "/v/archive-2024/sub", isDirectory: true))
        XCTAssertEqual(AppState.remappedURL(old, from: old, to: new)?.hasDirectoryPath, true)
    }

    func testTrashDestinationsCountAsDeletions() {
        XCTAssertTrue(AppState.isInTrash(URL(fileURLWithPath: "/Users/me/.Trash/Note.md")))
        XCTAssertTrue(AppState.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/Note.md")))
        XCTAssertTrue(AppState.isInTrash(URL(fileURLWithPath: "/Users/me/Vault/.trash/Note.md")))
        XCTAssertFalse(AppState.isInTrash(URL(fileURLWithPath: "/Users/me/Vault/Trash talk.md")))
        XCTAssertFalse(AppState.isInTrash(URL(fileURLWithPath: "/Users/me/Vault/Archive/Note.md")))
    }

    func testWatchedDescriptorFollowsARename() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Idea.md")
        try "x".write(to: original, atomically: true, encoding: .utf8)
        let descriptor = open(original.path, O_EVTONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        let renamed = directory.appendingPathComponent("Project Idea.md")
        try FileManager.default.moveItem(at: original, to: renamed)

        let followed = try XCTUnwrap(AppState.currentPath(ofWatchedDescriptor: descriptor))
        XCTAssertEqual(followed.resolvingSymlinksInPath().path, renamed.resolvingSymlinksInPath().path)
    }

    func testDeletedOrReplacedFileHasNoCurrentPath() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let deleted = directory.appendingPathComponent("gone.md")
        try "x".write(to: deleted, atomically: true, encoding: .utf8)
        let deletedDescriptor = open(deleted.path, O_EVTONLY)
        defer { close(deletedDescriptor) }
        try FileManager.default.removeItem(at: deleted)
        XCTAssertNil(AppState.currentPath(ofWatchedDescriptor: deletedDescriptor))

        // Another app's atomic save: the watched inode is unlinked and a new
        // file takes its name. F_GETPATH still reports that name.
        let replaced = directory.appendingPathComponent("replaced.md")
        try "1".write(to: replaced, atomically: true, encoding: .utf8)
        let replacedDescriptor = open(replaced.path, O_EVTONLY)
        defer { close(replacedDescriptor) }
        try "2".write(to: replaced, atomically: true, encoding: .utf8)
        XCTAssertNil(AppState.currentPath(ofWatchedDescriptor: replacedDescriptor))
    }
}

// MARK: - Folder refresh on activation

final class FolderRefreshThrottleTests: XCTestCase {
    func testRefreshIsThrottled() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(AppState.shouldRefreshFolderState(last: last, now: last.addingTimeInterval(1), minInterval: 3))
        XCTAssertTrue(AppState.shouldRefreshFolderState(last: last, now: last.addingTimeInterval(3), minInterval: 3))
        XCTAssertTrue(AppState.shouldRefreshFolderState(last: last, now: last.addingTimeInterval(60), minInterval: 3))
    }
}
