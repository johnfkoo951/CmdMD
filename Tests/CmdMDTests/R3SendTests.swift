import XCTest
@testable import CmdMD

final class R3SendTests: XCTestCase {
    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// An AppState whose data layer points at an empty temp directory, so these
    /// tests never read or write the real Application Support data.
    @MainActor
    private func makeIsolatedState() throws -> AppState {
        let dataDir = try makeTempDir()
        let previous = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        setenv("CMDMD_DATA_DIR", dataDir.path, 1)
        defer {
            if let previous { setenv("CMDMD_DATA_DIR", previous, 1) } else { unsetenv("CMDMD_DATA_DIR") }
        }
        return AppState()
    }

    /// A vault with an Inbox folder, plus send options targeting that Inbox.
    private func makeVault() throws -> (root: URL, inbox: URL, options: SendOptions) {
        let root = try makeTempDir()
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var options = SendOptions()
        options.targetVault = Vault(name: "V", rootPath: root)
        options.targetFolder = "Inbox"
        return (root, inbox, options)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Folder batches keep their tree (G003)

    func testBatchTargetFolderKeepsTheRelativePath() throws {
        let root = try makeTempDir()
        let nested = root.appendingPathComponent("2025/q1/a.md")
        let top = root.appendingPathComponent("b.md")
        try write("x", to: nested)
        try write("y", to: top)

        XCTAssertEqual(AppState.batchTargetFolder(for: nested, root: root, base: "Inbox"), "Inbox/2025/q1")
        XCTAssertEqual(AppState.batchTargetFolder(for: nested, root: root, base: ""), "2025/q1")
        XCTAssertEqual(AppState.batchTargetFolder(for: top, root: root, base: "Inbox"), "Inbox")
        XCTAssertEqual(AppState.batchTargetFolder(for: nested, root: nil, base: "Inbox"), "Inbox")
        XCTAssertEqual(
            AppState.batchTargetFolder(for: URL(fileURLWithPath: "/elsewhere/c.md"), root: root, base: "Inbox"),
            "Inbox", "a file outside the batch folder goes to the target folder itself"
        )
    }

    @MainActor
    func testFolderSendKeepsSubfoldersSoSameNamedNotesBothArrive() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        var options = vault.options
        let source = try makeTempDir()
        let older = source.appendingPathComponent("2025/README.md")
        let newer = source.appendingPathComponent("2026/README.md")
        try write("2025 notes", to: older)
        try write("2026 notes", to: newer)

        options.conflictResolution = .overwrite
        options.injectFrontmatter = false
        let result = await state.sendFiles([older, newer], options: options, relativeTo: source)

        XCTAssertEqual(result.sent, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try read(vault.inbox.appendingPathComponent("2025/README.md")), "2025 notes")
        XCTAssertEqual(try read(vault.inbox.appendingPathComponent("2026/README.md")), "2026 notes")
    }

    @MainActor
    func testBatchNeverOverwritesOrSkipsAgainstItsOwnOutput() async throws {
        for resolution in [FileConflictResolution.overwrite, .skip] {
            let state = try makeIsolatedState()
            let vault = try makeVault()
            var options = vault.options
            let source = try makeTempDir()
            let first = source.appendingPathComponent("A/README.md")
            let second = source.appendingPathComponent("B/README.md")
            try write("from A", to: first)
            try write("from B", to: second)

            options.conflictResolution = resolution
            options.injectFrontmatter = false
            // No root: every file targets the one folder.
            let result = await state.sendFiles([first, second], options: options)

            XCTAssertEqual(result.sent, 2, "\(resolution)")
            XCTAssertEqual(try read(vault.inbox.appendingPathComponent("README.md")), "from A", "\(resolution)")
            XCTAssertEqual(try read(vault.inbox.appendingPathComponent("README (1).md")), "from B", "\(resolution)")
        }
    }

    @MainActor
    func testOverwriteStillReplacesANoteFromBeforeTheBatch() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        var options = vault.options
        let existing = vault.inbox.appendingPathComponent("Idea.md")
        try write("old", to: existing)
        let source = try makeTempDir()
        let note = source.appendingPathComponent("Idea.md")
        try write("new", to: note)

        options.conflictResolution = .overwrite
        options.injectFrontmatter = false
        let result = await state.sendFiles([note], options: options, relativeTo: source)

        XCTAssertEqual(result.sent, 1)
        XCTAssertEqual(try read(existing), "new")
    }

    @MainActor
    func testBatchNeverOverwritesAnotherMembersSource() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        var options = vault.options
        // The Inbox's own tree sent flat into the Inbox: A/README.md targets
        // Inbox/README.md, which is the other member's source.
        let nested = vault.inbox.appendingPathComponent("A/README.md")
        let top = vault.inbox.appendingPathComponent("README.md")
        try write("nested", to: nested)
        try write("top", to: top)

        options.conflictResolution = .overwrite
        options.injectFrontmatter = false
        let result = await state.sendFiles([nested, top], options: options)

        XCTAssertEqual(try read(top), "top", "a batch member's own file must never be overwritten")
        XCTAssertEqual(try read(vault.inbox.appendingPathComponent("README (1).md")), "nested")
        XCTAssertEqual(result.sent, 1, "README.md was already in place")
    }

    @MainActor
    func testBatchSendsAnOpenTabsUnsavedText() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        var options = vault.options
        let source = try makeTempDir()
        let note = source.appendingPathComponent("Note.md")
        try write("on disk", to: note)

        let document = MarkdownDocument(title: "Note", content: "on screen", fileURL: note)
        state.documents[document.id] = document
        state.originalContents[document.id] = "on disk"
        state.tabs.append(EditorTab(documentId: document.id, fileURL: note, title: "Note"))

        options.injectFrontmatter = false
        let result = await state.sendFiles([note], options: options, relativeTo: source)

        XCTAssertEqual(result.sent, 1)
        XCTAssertEqual(try read(vault.inbox.appendingPathComponent("Note.md")), "on screen")
    }

    func testSendPathKeyIgnoresCaseAndUnicodeNormalization() {
        let precomposed = URL(fileURLWithPath: "/Vault/Inbox/회의.md")
        let decomposed = URL(fileURLWithPath: "/Vault/Inbox/" + "회의".decomposedStringWithCanonicalMapping + ".md")
        XCTAssertEqual(AppState.sendPathKey(precomposed), AppState.sendPathKey(decomposed))
        XCTAssertEqual(
            AppState.sendPathKey(URL(fileURLWithPath: "/Vault/Inbox/Note.md")),
            AppState.sendPathKey(URL(fileURLWithPath: "/Vault/inbox/./note.md"))
        )
    }

    // MARK: Cancelling a batch (G091)

    @MainActor
    func testCancelledBatchSendsNothingMore() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        var options = vault.options
        let source = try makeTempDir()
        var urls: [URL] = []
        for index in 1...3 {
            let url = source.appendingPathComponent("n\(index).md")
            try write("\(index)", to: url)
            urls.append(url)
        }
        options.injectFrontmatter = false

        // The task can't start before this test suspends, so it runs cancelled.
        let task = Task { @MainActor in
            await state.sendFiles(urls, options: options, relativeTo: source)
        }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.sent, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.inbox.path), [])
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor
    func testBatchReportsProgressPerFile() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        var options = vault.options
        let source = try makeTempDir()
        var urls: [URL] = []
        for index in 1...3 {
            let url = source.appendingPathComponent("n\(index).md")
            try write("\(index)", to: url)
            urls.append(url)
        }
        options.injectFrontmatter = false

        var reported: [Int] = []
        let result = await state.sendFiles(urls, options: options, progress: { reported.append($0) })

        XCTAssertEqual(result.sent, 3)
        XCTAssertEqual(reported, [1, 2, 3])
    }

    // MARK: Moving a draft (G009)

    @MainActor
    func testMovingADraftTakesItOutOfDraftsAndLeavesACleanTab() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        var options = vault.options
        state.createNewDraft()
        state.updateContent("# Idea\nbody")
        let id = try XCTUnwrap(state.currentDocument?.id)

        options.action = .move
        let outcome = try await state.sendToVault(options: options)

        guard case .sent(let url) = outcome else {
            return XCTFail("expected sent, got \(outcome)")
        }
        XCTAssertTrue(try read(url).contains("body"))
        XCTAssertFalse(state.drafts.contains { $0.id == id }, "Move takes the draft out of Drafts")
        XCTAssertEqual(state.currentDocument?.isDraft, false)
        XCTAssertEqual(state.activeTab?.isDirty, false, "the vault holds the text, so nothing is unsaved")
    }

    @MainActor
    func testCopyingADraftKeepsIt() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        state.createNewDraft()
        state.updateContent("# Idea\nbody")
        let id = try XCTUnwrap(state.currentDocument?.id)

        _ = try await state.sendToVault(options: vault.options)

        XCTAssertTrue(state.drafts.contains { $0.id == id })
        XCTAssertEqual(state.currentDocument?.isDraft, true)
    }

    // MARK: Vault file name (G089, G109)

    func testSendKeepsTheNotesFilenameNotItsTitleProperty() {
        let document = MarkdownDocument(
            title: "Weekly sync",
            content: "notes",
            fileURL: URL(fileURLWithPath: "/tmp/2026-10-11.md"),
            frontmatter: Frontmatter(title: "Weekly sync")
        )
        XCTAssertEqual(AppState.sendFilename(for: document, template: nil), "2026-10-11.md")

        let template = VaultTemplate(name: "T", filenamePattern: "{{title}}")
        XCTAssertEqual(
            AppState.sendFilename(for: document, template: template), "Weekly sync.md",
            "a template's pattern still names the file"
        )

        let capture = MarkdownDocument(title: "Idea", content: "x", isDraft: true)
        XCTAssertEqual(AppState.sendFilename(for: capture, template: nil), "Idea.md", "no file: named after the title")
    }

    @MainActor
    func testSentNoteKeepsItsFilename() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        let source = vault.root.appendingPathComponent("2026-10-11.md")
        try write("notes", to: source)
        let document = MarkdownDocument(
            title: "Weekly sync",
            content: "notes",
            fileURL: source,
            frontmatter: Frontmatter(title: "Weekly sync")
        )

        let outcome = try await state.sendToVault(document: document, options: vault.options, quiet: true)

        guard case .sent(let url) = outcome else {
            return XCTFail("expected sent, got \(outcome)")
        }
        XCTAssertEqual(url.lastPathComponent, "2026-10-11.md")
    }

    func testPreviewNameFollowsTheTemplatePattern() {
        let date = DateComponents(calendar: .current, year: 2026, month: 10, day: 11, hour: 9).date!
        let template = VaultTemplate(name: "Daily", filenamePattern: "{{date}} {{title}}")
        let document = MarkdownDocument(title: "Why?", content: "x", isDraft: true)

        XCTAssertEqual(AppState.sendFilename(for: document, template: template, date: date), "2026-10-11 Why-.md")
        XCTAssertEqual(AppState.sendFilename(for: document, template: nil), "Why-.md")
    }

    // MARK: Filename length (G111)

    func testLongHangulTitleIsCappedToAWritableName() throws {
        let name = AppState.sanitizedFilename(String(repeating: "정", count: 120))

        XCTAssertFalse(name.isEmpty)
        XCTAssertLessThanOrEqual(name.decomposedStringWithCanonicalMapping.utf16.count, AppState.maxFilenameUnits)
        XCTAssertTrue(name.allSatisfy { $0 == "정" }, "only whole syllables")

        // Room is left for the extension and the conflict suffixes.
        let url = try makeTempDir().appendingPathComponent(name + "_20261011-123456 (12).md")
        XCTAssertNoThrow(try "x".write(to: url, atomically: true, encoding: .utf8))
    }

    func testCapNeverSplitsAnEmojiAndLeavesShortNamesAlone() {
        let name = AppState.sanitizedFilename(String(repeating: "👍🏽", count: 100))
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.allSatisfy { $0 == "👍🏽" })
        XCTAssertLessThanOrEqual(name.decomposedStringWithCanonicalMapping.utf16.count, AppState.maxFilenameUnits)

        XCTAssertEqual(AppState.sanitizedFilename("회의 메모"), "회의 메모")
        let ascii = String(repeating: "a", count: AppState.maxFilenameUnits)
        XCTAssertEqual(AppState.sanitizedFilename(ascii), ascii)
    }

    // MARK: Default vault "None" (G096)

    @MainActor
    func testDefaultVaultNoneMeansNoDefault() throws {
        let state = try makeIsolatedState()
        let work = Vault(name: "Work", rootPath: try makeTempDir())
        let personal = Vault(name: "Personal", rootPath: try makeTempDir())
        state.vaults = [work, personal]

        state.settings.defaultVaultId = nil
        XCTAssertNil(state.defaultVault, "None must not fall back to the first vault")

        state.settings.defaultVaultId = personal.id
        XCTAssertEqual(state.defaultVault?.id, personal.id)

        state.removeVault(personal)
        XCTAssertNil(state.settings.defaultVaultId, "disconnecting the default vault clears the setting")
        XCTAssertNil(state.defaultVault)
    }

    // MARK: Vault folder moved or missing (G087)

    @MainActor
    func testSendFollowsAVaultFolderMovedSinceItWasConnected() async throws {
        let state = try makeIsolatedState()
        let parent = try makeTempDir()
        let old = parent.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        let bookmark = try old.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let vault = Vault(name: "", rootPath: old, bookmarkData: bookmark)
        state.vaults = [vault]

        // Renamed outside the app, as Obsidian's "Rename vault…" or Finder does.
        let renamed = parent.appendingPathComponent("Brain", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: renamed)

        var options = SendOptions()
        options.targetVault = vault // the stale copy a sheet or rule holds
        options.targetFolder = "Inbox"
        options.injectFrontmatter = false
        let capture = MarkdownDocument(title: "Idea", content: "body", isDraft: true)
        let outcome = try await state.sendToVault(document: capture, options: options, quiet: true)

        guard case .sent(let url) = outcome else {
            return XCTFail("expected sent, got \(outcome)")
        }
        XCTAssertEqual(
            url.resolvingSymlinksInPath().path,
            renamed.appendingPathComponent("Inbox/Idea.md").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(try read(url), "body")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "the old path must not come back as a phantom folder")
        XCTAssertEqual(
            state.vaults.first?.rootPath.resolvingSymlinksInPath().path,
            renamed.resolvingSymlinksInPath().path,
            "the new location is saved"
        )
    }

    @MainActor
    func testSendRefusesAMissingVaultFolderInsteadOfRecreatingIt() async throws {
        let state = try makeIsolatedState()
        let gone = try makeTempDir().appendingPathComponent("Gone", isDirectory: true)
        var options = SendOptions()
        options.targetVault = Vault(name: "Gone", rootPath: gone)
        options.targetFolder = "Inbox"
        let capture = MarkdownDocument(title: "Idea", content: "body", isDraft: true)

        do {
            _ = try await state.sendToVault(document: capture, options: options, quiet: true)
            XCTFail("a send into a missing vault must fail")
        } catch SendError.vaultFolderMissing(let name) {
            XCTAssertEqual(name, "Gone")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))

        let source = try makeTempDir().appendingPathComponent("n.md")
        try write("x", to: source)
        let result = await state.sendFiles([source], options: options)
        XCTAssertEqual(result.sent, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    }

    // MARK: Free-text folder (G112)

    func testNormalizedSendFolder() {
        XCTAssertEqual(AppState.normalizedSendFolder(" /Clients/Acme/ "), "Clients/Acme")
        XCTAssertEqual(AppState.normalizedSendFolder("Inbox//Daily"), "Inbox/Daily")
        XCTAssertEqual(AppState.normalizedSendFolder(""), "", "empty means the vault root")
        XCTAssertEqual(AppState.normalizedSendFolder("./"), "")
        XCTAssertNil(AppState.normalizedSendFolder("../Elsewhere"))
        XCTAssertNil(AppState.normalizedSendFolder("Inbox/../../x"))
    }

    @MainActor
    func testEmptyFolderSendsToTheVaultRoot() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        var options = vault.options
        options.targetFolder = ""
        options.injectFrontmatter = false
        let capture = MarkdownDocument(title: "Idea", content: "body", isDraft: true)

        let outcome = try await state.sendToVault(document: capture, options: options, quiet: true)

        guard case .sent = outcome else {
            return XCTFail("expected sent, got \(outcome)")
        }
        XCTAssertEqual(try read(vault.root.appendingPathComponent("Idea.md")), "body")
    }
}
