import XCTest
@testable import CmdMD

final class R3VaultTests: XCTestCase {
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

    /// A vault registered (with its bookmark) at `<dir>/Old Vault`, which is
    /// then renamed to `<dir>/New Vault` the way Obsidian's Rename vault does.
    private func makeRenamedVault() async throws -> (vault: Vault, old: URL, new: URL) {
        let dir = try makeTempDir()
        let old = dir.appendingPathComponent("Old Vault", isDirectory: true)
        let new = dir.appendingPathComponent("New Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        let service = VaultService(dataDirectory: try makeTempDir())
        let vault = try await service.registerVault(name: "Old Vault", at: old)
        await service.releaseVaultAccess(for: vault)
        try FileManager.default.moveItem(at: old, to: new)
        return (vault, old, new)
    }

    private func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Renamed or moved vaults (G038)

    @MainActor
    func testSendToAMissingVaultFolderThrowsAndNeverRecreatesIt() async throws {
        let state = try makeIsolatedState()
        let root = try makeTempDir().appendingPathComponent("Gone", isDirectory: true)
        var options = SendOptions()
        options.targetVault = Vault(name: "Gone", rootPath: root)
        options.targetFolder = "Inbox"

        do {
            _ = try await state.sendToVault(document: MarkdownDocument(title: "Note", content: "x"), options: options, quiet: true)
            XCTFail("a send into a vault whose folder is gone must fail")
        } catch SendError.vaultFolderMissing(let name) {
            XCTAssertEqual(name, "Gone")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "the old vault folder must not be recreated")
    }

    @MainActor
    func testSendFolderCannotEscapeTheVault() async throws {
        // A routing rule (or auto-route / Quick Capture) skips the Send sheet's
        // own check, so sendToVault must contain the folder itself.
        let state = try makeIsolatedState()
        let parent = try makeTempDir()
        let root = parent.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var options = SendOptions()
        options.targetVault = Vault(name: "Vault", rootPath: root)
        options.targetFolder = "../Escaped"

        do {
            _ = try await state.sendToVault(document: MarkdownDocument(title: "Note", content: "x"), options: options, quiet: true)
            XCTFail("a folder outside the vault must be refused")
        } catch SendError.invalidFolder(let folder) {
            XCTAssertEqual(folder, "../Escaped")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Escaped").path),
                       "nothing may be created next to the vault")
    }

    @MainActor
    func testADraftNeverOverwritesAnUnrelatedNoteOfTheSameName() async throws {
        // Final review: a draft is named after its first line, and with the
        // Overwrite setting it replaced an unrelated vault note sharing it.
        let state = try makeIsolatedState()
        let root = try makeTempDir()
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let existing = inbox.appendingPathComponent("Ideas.md")
        try "precious unrelated note".write(to: existing, atomically: true, encoding: .utf8)
        var options = SendOptions()
        options.targetVault = Vault(name: "V", rootPath: root)
        options.targetFolder = "Inbox"
        options.conflictResolution = .overwrite

        let draft = MarkdownDocument(title: "Ideas", content: "Ideas\nnew draft text", isDraft: true)
        _ = try await state.sendToVault(document: draft, options: options, quiet: true)

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "precious unrelated note")
        let names = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
        XCTAssertEqual(names.count, 2, "the draft lands next to it under a new name: \(names)")
    }

    @MainActor
    func testRenamedVaultFollowsItsBookmark() async throws {
        let state = try makeIsolatedState()
        let renamed = try await makeRenamedVault()
        state.vaults = [renamed.vault]

        await state.reconcileVaultLocations()

        let vault = try XCTUnwrap(state.vaults.first)
        XCTAssertEqual(vault.id, renamed.vault.id)
        XCTAssertTrue(samePath(vault.rootPath, renamed.new), "rootPath must follow the rename, got \(vault.rootPath.path)")
        XCTAssertEqual(vault.name, "New Vault", "a name that was the folder's name follows it")
        XCTAssertNotNil(vault.bookmarkData)
    }

    @MainActor
    func testSendFromStaleOptionsLandsInTheRenamedVault() async throws {
        let state = try makeIsolatedState()
        let renamed = try await makeRenamedVault()
        state.vaults = [renamed.vault]
        var options = SendOptions()
        options.targetVault = renamed.vault   // the copy taken before the rename
        options.targetFolder = "Inbox"
        options.injectFrontmatter = false

        let outcome = try await state.sendToVault(document: MarkdownDocument(title: "Note", content: "body"), options: options, quiet: true)

        guard case .sent(let url) = outcome else { return XCTFail("expected sent, got \(outcome)") }
        XCTAssertTrue(samePath(url, renamed.new.appendingPathComponent("Inbox/Note.md")), "sent to \(url.path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.old.path), "the old vault folder must not be recreated")
    }

    @MainActor
    func testRelocatingKeepsRulesAndACustomName() throws {
        let state = try makeIsolatedState()
        let dir = try makeTempDir()
        let vault = Vault(name: "Work", rootPath: dir.appendingPathComponent("A"))
        state.vaults = [vault]
        state.routingRules = [RoutingRule(name: "R", targetVaultId: vault.id)]

        state.relocateVault(id: vault.id, to: dir.appendingPathComponent("B"), bookmarkData: nil)

        XCTAssertEqual(state.vaults.first?.rootPath.lastPathComponent, "B")
        XCTAssertEqual(state.vaults.first?.name, "Work", "a name the user chose stays")
        XCTAssertEqual(state.routingRules.map(\.targetVaultId), [vault.id], "rules targeting the vault survive")
    }

    func testOnlyExistingFoldersOutsideTheTrashAreFollowed() throws {
        let dir = try makeTempDir()
        XCTAssertTrue(AppState.isUsableVaultFolder(dir))
        XCTAssertFalse(AppState.isUsableVaultFolder(dir.appendingPathComponent("missing")))

        let trashed = dir.appendingPathComponent(".Trash/Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        XCTAssertFalse(AppState.isUsableVaultFolder(trashed), "a vault thrown away must not become the send target")
    }

    // MARK: Folder picker order (G100)

    func testFolderPathsSortAsATree() {
        let folders = ["Daily/2026", "Daily Notes", "archive", "Daily", "Projects-old", "Projects/Sub", "Projects", "Daily Notes/2026"]
        XCTAssertEqual(
            folders.sorted(by: VaultService.folderPathPrecedes),
            ["archive", "Daily", "Daily/2026", "Daily Notes", "Daily Notes/2026", "Projects", "Projects/Sub", "Projects-old"]
        )
    }

    func testFolderPathsSortNumbersNaturally() {
        XCTAssertEqual(["10 Notes", "2 Inbox", "Area/10", "Area/9"].sorted(by: VaultService.folderPathPrecedes),
                       ["2 Inbox", "10 Notes", "Area/9", "Area/10"])
    }

    // MARK: Routing conditions (G004)

    private let meeting = MarkdownDocument(
        title: "x",
        content: "",
        fileURL: URL(fileURLWithPath: "/v/2026-10-11 Meeting-notes.md"),
        frontmatter: Frontmatter(title: "Kickoff", tags: ["work"], custom: ["status": .string("done")])
    )

    func testFrontmatterKeyConditionToleratesSpacesAndCase() {
        XCTAssertTrue(RoutingCondition(type: .frontmatterKey, value: "status: done", matchType: .equals).matches(document: meeting))
        XCTAssertTrue(RoutingCondition(type: .frontmatterKey, value: "Status:done", matchType: .equals).matches(document: meeting))
        XCTAssertFalse(RoutingCondition(type: .frontmatterKey, value: "status: open", matchType: .equals).matches(document: meeting))
        XCTAssertFalse(RoutingCondition(type: .frontmatterKey, value: "missing: done", matchType: .equals).matches(document: meeting))
    }

    func testFrontmatterKeyConditionSeesParsedKeys() {
        XCTAssertTrue(RoutingCondition(type: .frontmatterKey, value: "title: kickoff", matchType: .equals).matches(document: meeting))
        XCTAssertTrue(RoutingCondition(type: .frontmatterKey, value: "tags: work", matchType: .contains).matches(document: meeting))
    }

    func testFilenameConditionsApplyThePickedMatch() {
        XCTAssertTrue(RoutingCondition(type: .filenamePrefix, value: #"^\d{4}-"#, matchType: .regex).matches(document: meeting))
        XCTAssertTrue(RoutingCondition(type: .filenameSuffix, value: "2026-10-11 meeting-notes", matchType: .equals).matches(document: meeting))
    }

    func testLegacyContainsFilenameConditionsKeepTheirTestCaseInsensitively() {
        XCTAssertTrue(RoutingCondition(type: .filenamePrefix, value: "2026-10-11 meeting", matchType: .contains).matches(document: meeting))
        XCTAssertTrue(RoutingCondition(type: .filenameSuffix, value: "NOTES", matchType: .contains).matches(document: meeting))
        XCTAssertFalse(RoutingCondition(type: .filenamePrefix, value: "meeting", matchType: .contains).matches(document: meeting),
                       "under Contains a prefix condition still tests the start of the name")
    }

    func testNewConditionsStartWithAMatchThatFitsTheirType() {
        XCTAssertEqual(RoutingCondition.ConditionType.tag.defaultMatchType, .equals)
        XCTAssertEqual(RoutingCondition.ConditionType.frontmatterKey.defaultMatchType, .equals)
        XCTAssertEqual(RoutingCondition.ConditionType.filenamePrefix.defaultMatchType, .startsWith)
        XCTAssertEqual(RoutingCondition.ConditionType.filenameSuffix.defaultMatchType, .endsWith)
        XCTAssertEqual(RoutingCondition.ConditionType.content.defaultMatchType, .contains)

        let tagged = MarkdownDocument(title: "x", content: "", frontmatter: Frontmatter(tags: ["smart"]))
        let art = RoutingCondition(type: .tag, value: "art", matchType: RoutingCondition.ConditionType.tag.defaultMatchType)
        XCTAssertFalse(art.matches(document: tagged), "a new Tag condition for 'art' must not route #smart")
    }

    // MARK: Rule editor validation (G095)

    func testConditionsThatCanNeverMatchAreFlagged() {
        XCTAssertNotNil(RoutingCondition(type: .content, value: "[meeting", matchType: .regex).validationError)
        XCTAssertNotNil(RoutingCondition(type: .tag, value: "  ").validationError)
        XCTAssertNotNil(RoutingCondition(type: .frontmatterKey, value: "status").validationError)
        XCTAssertNotNil(RoutingCondition(type: .frontmatterKey, value: ": done").validationError)
        XCTAssertNotNil(RoutingCondition(type: .frontmatterKey, value: "status: [", matchType: .regex).validationError)
    }

    func testUsableConditionsPassValidation() {
        XCTAssertNil(RoutingCondition(type: .frontmatterKey, value: "status: done").validationError)
        XCTAssertNil(RoutingCondition(type: .content, value: #"\bTODO\b"#, matchType: .regex).validationError)
        XCTAssertNil(RoutingCondition(type: .tag, value: "#work", matchType: .equals).validationError)
    }

    // MARK: Obsidian links (G056)

    func testObsidianFileLinkOpensByAbsolutePath() throws {
        let vault = Vault(name: "Notes", rootPath: URL(fileURLWithPath: "/Users/x/Work/Notes"))
        let url = try XCTUnwrap(vault.obsidianURL(forFile: URL(fileURLWithPath: "/Users/x/Work/Notes/Inbox/Note.md")))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        // vault=Notes opened whichever "Notes" vault Obsidian listed first.
        XCTAssertEqual(components.queryItems?.map(\.name), ["path"])
        XCTAssertEqual(components.queryItems?.first?.value, "/Users/x/Work/Notes/Inbox/Note.md")
    }

    // MARK: Dates in filenames (G126)

    func testFixedFormatDatesAreGregorianWithASCIIDigitsInLocalTime() throws {
        let formatter = DateFormatter.fixedFormat("yyyy-MM-dd HH:mm")
        XCTAssertEqual(formatter.calendar.identifier, .gregorian)
        XCTAssertEqual(formatter.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(formatter.timeZone, TimeZone.current)

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let date = try XCTUnwrap(DateComponents(calendar: gregorian, year: 2026, month: 10, day: 11, hour: 15, minute: 26).date)
        XCTAssertEqual(formatter.string(from: date), "2026-10-11 15:26")
    }

    func testTimestampPlaceholderIsLocalTime() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let date = try XCTUnwrap(DateComponents(calendar: gregorian, year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5).date)
        let template = VaultTemplate(name: "T", filenamePattern: "{{date}} {{time}} {{timestamp}}")
        XCTAssertEqual(template.generateFilename(title: "x", date: date), "2026-01-02 03:04 030405")
    }

    // MARK: Connecting the same folder twice (G107)

    func testVaultRootMatchesEveryWayOfSpellingItsFolder() throws {
        let dir = try makeTempDir()
        let root = dir.appendingPathComponent("v", isDirectory: true)
        let sibling = dir.appendingPathComponent("w", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let vault = Vault(name: "", rootPath: root)

        XCTAssertTrue(vault.hasRoot(URL(fileURLWithPath: root.path + "/")))
        XCTAssertTrue(vault.hasRoot(dir.appendingPathComponent("w/../v")))
        XCTAssertTrue(vault.hasRoot(link))
        XCTAssertFalse(vault.hasRoot(sibling))
    }
}
