import XCTest
@testable import CmdMD

/// Points CMDMD_DATA_DIR at a fresh temp directory for each test, so the
/// AppState instances created here never read or write the real app data.
class IsolatedDataDirTestCase: XCTestCase {
    var dataDir: URL!
    private var previousOverride: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousOverride = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMD-R1Persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        setenv("CMDMD_DATA_DIR", dataDir.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousOverride {
            setenv("CMDMD_DATA_DIR", previousOverride, 1)
        } else {
            unsetenv("CMDMD_DATA_DIR")
        }
        try? FileManager.default.removeItem(at: dataDir)
        try super.tearDownWithError()
    }

    func write(_ text: String, to filename: String) throws {
        try Data(text.utf8).write(to: dataDir.appendingPathComponent(filename))
    }

    func backups(of base: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(base).corrupt-") }
    }

    func decodeDataFile<T: Decodable>(_ type: T.Type, _ filename: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: dataDir.appendingPathComponent(filename)))
    }
}

// MARK: - Data files: decode failures never lead to an overwrite (F078)

final class DataFileRecoveryTests: IsolatedDataDirTestCase {
    func testMissingFileLoadsAsNilWithoutBackup() throws {
        let result = AppState.loadDataList(Draft.self, named: "drafts.json", in: dataDir)
        XCTAssertNil(result.value)
        XCTAssertNil(result.backup)
        XCTAssertTrue(try backups(of: "drafts").isEmpty)
    }

    func testTruncatedFileIsMovedAsideWithItsOriginalBytes() throws {
        let truncated = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","body":"my only copy"#
        try write(truncated, to: "drafts.json")

        let result = AppState.loadDataList(Draft.self, named: "drafts.json", in: dataDir)

        XCTAssertNil(result.value)
        let backup = try XCTUnwrap(result.backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), truncated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("drafts.json").path),
                       "the unreadable file must not stay where the next save would overwrite it")
    }

    func testOneBadEntryCostsOnlyItselfAndTheFileIsCopiedAside() throws {
        let json = #"[{"body":"first"}, {"body":5}, {"body":"third"}]"#
        try write(json, to: "drafts.json")

        let result = AppState.loadDataList(Draft.self, named: "drafts.json", in: dataDir)

        XCTAssertEqual(result.value?.map(\.body), ["first", "third"])
        let backup = try XCTUnwrap(result.backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), json)
    }

    func testLossyListStepsOverNullsAndForeignValues() throws {
        let json = #"[{"body":"a"}, null, 7, [1, 2], "x", {"body":"b"}]"#
        let list = try JSONDecoder().decode(LossyList<Draft>.self, from: Data(json.utf8))
        XCTAssertEqual(list.elements.map(\.body), ["a", "b"])
        XCTAssertEqual(list.skippedCount, 4)
    }

    func testNonListFileIsMovedAside() throws {
        try write(#"{"body":"not a list"}"#, to: "rules.json")
        let result = AppState.loadDataList(RoutingRule.self, named: "rules.json", in: dataDir)
        XCTAssertNil(result.value)
        XCTAssertNotNil(result.backup)
    }

    func testAppStateKeepsCorruptDraftsAndTellsTheUser() throws {
        let truncated = #"[{"body":"draft text","title":"Ide"#
        try write(truncated, to: "drafts.json")

        let appState = AppState()

        XCTAssertTrue(appState.drafts.isEmpty)
        XCTAssertTrue(appState.errorMessage?.contains("drafts.corrupt-") == true)
        let backup = try XCTUnwrap(try backups(of: "drafts").first)

        // The next save writes a fresh, valid file — the backup is untouched.
        appState.saveUserData()
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), truncated)
        XCTAssertEqual(try decodeDataFile([Draft].self, "drafts.json"), [])
    }

    func testAppStateRecoversTheReadableRules() throws {
        let vaultId = UUID()
        let json = """
        [
          {"name":"Keep","conditions":[],"targetVaultId":"\(vaultId)","targetFolder":"Inbox","action":"Copy"},
          {"name":"Future","conditions":[{"type":"Weekday","value":"Mon","matchType":"Equals"}],
           "targetVaultId":"\(vaultId)","targetFolder":"Inbox","action":"Move"}
        ]
        """
        try write(json, to: "rules.json")

        let appState = AppState()

        XCTAssertEqual(appState.routingRules.map(\.name), ["Keep"])
        XCTAssertEqual(try backups(of: "rules").count, 1)
        XCTAssertNotNil(appState.errorMessage)
    }

    func testSaveUserDataWritesDecodableFiles() throws {
        let appState = AppState()
        appState.drafts = [Draft(title: "T", body: "B", sourceDevice: "Mac")]
        appState.saveUserData()

        XCTAssertEqual(try decodeDataFile([Draft].self, "drafts.json").map(\.body), ["B"])
        XCTAssertNoThrow(try decodeDataFile(AppSettings.self, "settings.json"))
        XCTAssertTrue(try backups(of: "drafts").isEmpty)
    }
}

// MARK: - Resilient decoding of persisted models (F078)

final class PersistedModelDecodingTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(T.self, from: encoder.encode(value)), value)
    }

    func testDraftMissingKeysFallBackToDefaults() throws {
        let draft = try decode(Draft.self, #"{"body":"kept"}"#)
        XCTAssertEqual(draft.body, "kept")
        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.tags, [])
        XCTAssertEqual(draft.status, .active)
        XCTAssertEqual(draft.attachments, [])
    }

    func testDraftWithUnknownStatusIsKeptAsActive() throws {
        let draft = try decode(Draft.self, #"{"body":"x","status":"Pinned"}"#)
        XCTAssertEqual(draft.status, .active)
        XCTAssertEqual(draft.body, "x")
    }

    func testVaultNeedsOnlyItsRootFolder() throws {
        let vault = try decode(Vault.self, #"{"name":"Notes","rootPath":"file:///tmp/Notes/"}"#)
        XCTAssertEqual(vault.name, "Notes")
        XCTAssertEqual(vault.rootPath.path, "/tmp/Notes")
        XCTAssertEqual(vault.inboxPath, "")
        XCTAssertFalse(vault.isDefault)
        XCTAssertThrowsError(try decode(Vault.self, #"{"name":"No root"}"#))
    }

    func testTemplateMissingKeysFallBackToDefaults() throws {
        let template = try decode(VaultTemplate.self, #"{"name":"Daily"}"#)
        XCTAssertEqual(template.filenamePattern, "{{title}}")
        XCTAssertEqual(template.content, "")
    }

    func testRoutingRuleDefaultsDescriptiveKeysOnly() throws {
        let vaultId = UUID()
        let rule = try decode(RoutingRule.self, """
        {"conditions":[],"targetVaultId":"\(vaultId)","targetFolder":"Daily","action":"Copy"}
        """)
        XCTAssertEqual(rule.priority, 0)
        XCTAssertTrue(rule.isEnabled)
        XCTAssertTrue(rule.injectFrontmatter)
        XCTAssertEqual(rule.targetVaultId, vaultId)

        // Without its action the rule must not run on a guessed (destructive) default.
        XCTAssertThrowsError(try decode(RoutingRule.self, """
        {"conditions":[],"targetVaultId":"\(vaultId)","targetFolder":"Daily"}
        """))
        // Without its conditions it would silently become a catch-all.
        XCTAssertThrowsError(try decode(RoutingRule.self, """
        {"targetVaultId":"\(vaultId)","targetFolder":"Daily","action":"Copy"}
        """))
    }

    func testRoutingConditionWithoutValueIsRejected() {
        // An empty value would make a `contains` condition match every note.
        XCTAssertThrowsError(try decode(RoutingCondition.self, #"{"type":"Tag","matchType":"Contains"}"#))
    }

    func testFavoriteNeedsOnlyItsURL() throws {
        let favorite = try decode(FavoriteItem.self, #"{"url":"file:///tmp/a.md"}"#)
        XCTAssertEqual(favorite.url.path, "/tmp/a.md")
        XCTAssertNil(favorite.alias)
    }

    func testPersistedModelsRoundTrip() throws {
        try roundTrip(Draft(title: "T", body: "B", createdAt: fixedDate, updatedAt: fixedDate,
                            sourceDevice: "Mac", tags: ["a"], status: .archived))
        try roundTrip(Vault(name: "V", rootPath: URL(fileURLWithPath: "/tmp/V", isDirectory: true),
                            inboxPath: "In", templateId: UUID(), bookmarkData: Data([1, 2]),
                            createdAt: fixedDate, isDefault: true))
        try roundTrip(VaultTemplate(name: "T", content: "{{content}}", filenamePattern: "{{date}} {{title}}"))
        try roundTrip(RoutingRule(name: "R", isEnabled: false,
                                  conditions: [RoutingCondition(type: .tag, value: "x", matchType: .regex)],
                                  targetVaultId: UUID(), targetFolder: "F", action: .copy,
                                  injectFrontmatter: false, priority: 7))
        try roundTrip(FavoriteItem(url: URL(fileURLWithPath: "/tmp/a.md"), addedAt: fixedDate, alias: "A"))
    }
}

// MARK: - Favorites and recents on unmounted volumes (F084)

final class UnreachableEntriesTests: IsolatedDataDirTestCase {
    private func unmountedURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/CmdMD-Missing-\(UUID().uuidString)/Notes/\(name)")
    }

    func testIsDefinitelyMissing() throws {
        let existing = dataDir.appendingPathComponent("here.md")
        try "x".write(to: existing, atomically: true, encoding: .utf8)

        XCTAssertFalse(AppState.isDefinitelyMissing(existing))
        XCTAssertTrue(AppState.isDefinitelyMissing(dataDir.appendingPathComponent("deleted.md")))
        XCTAssertFalse(AppState.isDefinitelyMissing(unmountedURL("a.md")),
                       "a file whose volume isn't mounted isn't known to be gone")
    }

    func testUnmountedEntriesSurviveLaunchAndSave() throws {
        let existing = dataDir.appendingPathComponent("here.md")
        try "x".write(to: existing, atomically: true, encoding: .utf8)
        let deleted = dataDir.appendingPathComponent("deleted.md")
        let unmounted = unmountedURL("away.md")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([existing, deleted, unmounted]).write(to: dataDir.appendingPathComponent("recents.json"))
        try encoder.encode([existing, deleted, unmounted].map { FavoriteItem(url: $0) })
            .write(to: dataDir.appendingPathComponent("favorites.json"))

        let appState = AppState()
        XCTAssertEqual(appState.recentFiles, [existing], "only reachable recents are offered")
        XCTAssertEqual(appState.favorites.map(\.url), [existing, unmounted])

        appState.saveUserData()
        XCTAssertEqual(try decodeDataFile([URL].self, "recents.json"), [existing, unmounted])
        XCTAssertEqual(try decodeDataFile([FavoriteItem].self, "favorites.json").map(\.url), [existing, unmounted])

        appState.clearRecentFiles()
        XCTAssertEqual(try decodeDataFile([URL].self, "recents.json"), [])
    }
}

// MARK: - Autosave saves every dirty file tab (F082)

final class AutosaveTests: IsolatedDataDirTestCase {
    @MainActor
    func testAutosaveSavesEveryDirtyFileTabNotJustTheActiveOne() async throws {
        let appState = AppState()
        appState.settings.autosaveEnabled = true

        let fileA = dataDir.appendingPathComponent("a.md")
        try "old".write(to: fileA, atomically: true, encoding: .utf8)
        var docA = MarkdownDocument(title: "a", content: "old", fileURL: fileA)
        appState.originalContents[docA.id] = docA.fullText
        docA.content = "edited in a background tab"
        appState.documents[docA.id] = docA
        let tabA = EditorTab(documentId: docA.id, fileURL: fileA, title: "a")

        let untitled = MarkdownDocument(title: "Untitled", content: "")
        appState.originalContents[untitled.id] = untitled.fullText
        appState.documents[untitled.id] = MarkdownDocument(id: untitled.id, content: "unsaved, no file")
        let untitledTab = EditorTab(documentId: untitled.id)

        appState.tabs = [tabA, untitledTab]
        appState.refreshStoredDirty(forTabId: tabA.id)
        appState.refreshStoredDirty(forTabId: untitledTab.id)
        appState.activeTabId = untitledTab.id

        await appState.performAutosave()

        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "edited in a background tab")
        XCTAssertFalse(appState.tabs[0].isDirty)
        XCTAssertTrue(appState.tabs[1].isDirty, "untitled tabs are left for an explicit Save")
        appState.tabs.forEach { appState.closeTab($0) }
    }

    @MainActor
    func testAutosaveDoesNothingWhenDisabled() async throws {
        let appState = AppState()
        appState.settings.autosaveEnabled = false

        let file = dataDir.appendingPathComponent("b.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let doc = MarkdownDocument(title: "b", content: "new", fileURL: file)
        appState.originalContents[doc.id] = "old"
        appState.documents[doc.id] = doc
        appState.tabs = [EditorTab(documentId: doc.id, fileURL: file, title: "b")]

        await appState.performAutosave()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
    }
}

// MARK: - Session restore (F112)

final class SessionRestoreTests: IsolatedDataDirTestCase {
    func testRestoredActiveURLIndexesTheSavedList() {
        let files = ["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/\($0).md") }
        XCTAssertEqual(AppState.restoredActiveURL(openFiles: files, activeIndex: 1), files[1])
        XCTAssertNil(AppState.restoredActiveURL(openFiles: files, activeIndex: nil))
        XCTAssertNil(AppState.restoredActiveURL(openFiles: files, activeIndex: 3))
        XCTAssertNil(AppState.restoredActiveURL(openFiles: files, activeIndex: -1))
    }

    @MainActor
    func testRestoreActivatesTheSavedFileEvenAfterAnEarlierOneWasDeleted() async throws {
        let deleted = dataDir.appendingPathComponent("gone.md")
        let b = dataDir.appendingPathComponent("b.md")
        let c = dataDir.appendingPathComponent("c.md")
        try "# B".write(to: b, atomically: true, encoding: .utf8)
        try "# C".write(to: c, atomically: true, encoding: .utf8)
        var session = SessionState()
        session.openFiles = [deleted, b, c]
        session.activeFileIndex = 1   // b
        try JSONEncoder().encode(session).write(to: dataDir.appendingPathComponent("session.json"))

        let appState = AppState()
        let deadline = Date().addingTimeInterval(5)
        while appState.tabs.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(appState.tabs.map(\.fileURL), [b, c])
        XCTAssertEqual(appState.activeTab?.fileURL, b)
        XCTAssertFalse(appState.tabs.contains(where: \.isDirty))
        XCTAssertTrue(appState.recentFiles.isEmpty, "restoring reopens files; it doesn't re-record them")
        appState.tabs.forEach { appState.closeTab($0) }
    }
}

// MARK: - Logging privacy (F061)

final class LogPrivacyTests: XCTestCase {
    func testComposedMessageAppendsDetail() {
        XCTAssertEqual(Log.composedMessage("opened", detail: "a.md"), "opened a.md")
        XCTAssertEqual(Log.composedMessage("zoom 150%", detail: nil), "zoom 150%")
        XCTAssertEqual(Log.composedMessage("x", detail: ""), "x")
    }

    func testFileLogLineStillCarriesTheDetail() {
        let line = Log.formatLine(date: Date(), level: "INFO", category: .file,
                                  message: Log.composedMessage("export HTML:", detail: "Meeting Notes"))
        XCTAssertTrue(line.hasSuffix("[INFO] [file] export HTML: Meeting Notes\n"))
    }
}

// MARK: - CMDMD_DATA_DIR isolation (F094)

final class DataDirectoryTests: IsolatedDataDirTestCase {
    func testOverrideCoversDataAndLogs() {
        XCTAssertEqual(AppState.dataDirectory.standardizedFileURL, dataDir.standardizedFileURL)
        XCTAssertEqual(Log.logsDirectory.standardizedFileURL,
                       dataDir.appendingPathComponent("logs").standardizedFileURL)
    }

    func testDefaultIsApplicationSupport() {
        unsetenv("CMDMD_DATA_DIR")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertEqual(AppState.dataDirectory, appSupport.appendingPathComponent("CmdMD"))
    }
}
