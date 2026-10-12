import XCTest
@testable import CmdMD

// MARK: - Inspector TOC: stable heading ids (F104)

final class R2InspectorTOCTests: XCTestCase {
    func testIDsAreStableAcrossParsesOfTheSameText() {
        let markdown = "# Title\n\nBody\n\n## Section\n\n### Detail\n"
        let first = TOCBuilder.extractHeadings(from: markdown)
        let second = TOCBuilder.extractHeadings(from: markdown)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first, second, "re-parsing unchanged text must not yield a 'new' list (rows would rebuild)")
    }

    func testIDsAreUniqueWhereSlugsCollide() {
        // The slugger gives "intro-1" to both the second "Intro" and "Intro 1",
        // which is why the slug can't be the row identity.
        let headings = TOCBuilder.extractHeadings(from: "# Intro\n# Intro\n# Intro 1")

        XCTAssertEqual(headings.count, 3)
        XCTAssertEqual(Set(headings.map(\.id)).count, 3)
    }

    func testIDsFollowDocumentOrder() {
        let headings = TOCBuilder.extractHeadings(from: "# A\ntext\n## B\n### C")

        XCTAssertEqual(headings.map(\.id), [0, 1, 2])
        XCTAssertEqual(headings.map(\.text), ["A", "B", "C"])
    }

    func testBodyEditKeepsTheHeadingListEqual() {
        let before = TOCBuilder.extractHeadings(from: "# A\nsome text\n## B")
        let after = TOCBuilder.extractHeadings(from: "# A\nsome longer text, same line\n## B")

        XCTAssertEqual(before, after, "typing in a paragraph must not touch the TOC rows")
    }

    func testInsertedHeadingLeavesEarlierRowsIdentical() {
        let before = TOCBuilder.extractHeadings(from: "# A\n## B\n## C")
        let after = TOCBuilder.extractHeadings(from: "# A\n## New\n## B\n## C")

        XCTAssertEqual(after.first, before.first)
        XCTAssertEqual(after.map(\.id), [0, 1, 2, 3])
    }
}

// MARK: - Reading positions: bounded LRU (F141)

final class R2ReadingPositionsTests: XCTestCase {
    func testRecordsAndLooksUpByKey() {
        var store = ReadingPositions()
        XCTAssertNil(store.offset(forKey: "/notes/a.md"))

        XCTAssertTrue(store.record(420, forKey: "/notes/a.md"))
        XCTAssertEqual(store.offset(forKey: "/notes/a.md"), 420)
        XCTAssertNil(store.offset(forKey: "/notes/b.md"))
    }

    func testEvictsTheLeastRecentlyUsedBeyondCapacity() {
        var store = ReadingPositions(capacity: 3)
        store.record(10, forKey: "a")
        store.record(20, forKey: "b")
        store.record(30, forKey: "c")
        store.record(11, forKey: "a")   // a is now the most recent
        store.record(40, forKey: "d")   // so b, not a, is evicted

        XCTAssertEqual(store.entries.map(\.key), ["c", "a", "d"])
        XCTAssertNil(store.offset(forKey: "b"))
        XCTAssertEqual(store.offset(forKey: "a"), 11)
    }

    func testStaysBoundedAcrossManyFiles() {
        var store = ReadingPositions()
        for i in 0..<1_000 {
            store.record(Double(i + 1), forKey: "/notes/\(i).md")
        }

        XCTAssertEqual(store.entries.count, ReadingPositions.defaultCapacity)
        XCTAssertEqual(store.entries.last?.key, "/notes/999.md")
        XCTAssertNil(store.offset(forKey: "/notes/0.md"))
    }

    func testTopOfThePageForgetsTheKey() {
        var store = ReadingPositions()
        store.record(300, forKey: "a")

        XCTAssertTrue(store.record(0, forKey: "a"))
        XCTAssertNil(store.offset(forKey: "a"))
        XCTAssertFalse(store.record(0, forKey: "never-recorded"), "nothing to forget, nothing to save")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testUnchangedNewestPositionNeedsNoSave() {
        var store = ReadingPositions()
        store.record(120.4, forKey: "a")
        XCTAssertFalse(store.record(120, forKey: "a"), "same rounded offset on the newest key")

        store.record(50, forKey: "b")
        XCTAssertTrue(store.record(120, forKey: "a"), "an older key is touched to most recent")
        XCTAssertEqual(store.entries.map(\.key), ["b", "a"])
    }

    func testRejectsNonFiniteOffsets() {
        var store = ReadingPositions()

        XCTAssertFalse(store.record(.nan, forKey: "a"))
        XCTAssertFalse(store.record(.infinity, forKey: "a"))
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPersistedEntriesAreDedupedFilteredAndTrimmed() {
        let persisted: [ReadingPositions.Entry] = [
            .init(key: "a", offset: 1),
            .init(key: "b", offset: 2),
            .init(key: "a", offset: 3),   // later duplicate wins
            .init(key: "c", offset: 0),   // top of page: nothing to restore
            .init(key: "d", offset: 4),
            .init(key: "e", offset: 5),
        ]
        let store = ReadingPositions(entries: persisted, capacity: 3)

        XCTAssertEqual(store.entries.map(\.key), ["a", "d", "e"])
        XCTAssertEqual(store.offset(forKey: "a"), 3)
    }

    func testKeyIsTheStandardizedPathOfAFile() {
        let url = URL(fileURLWithPath: "/notes/sub/../a.md")
        let firstOpen = MarkdownDocument(fileURL: url)
        let reopened = MarkdownDocument(fileURL: url)   // every open mints a new id

        XCTAssertEqual(ReadingPositions.key(for: firstOpen), "/notes/a.md")
        XCTAssertEqual(ReadingPositions.key(for: firstOpen), ReadingPositions.key(for: reopened))
    }

    func testKeyOfADocumentWithoutAFileIsItsID() {
        let draft = Draft(body: "# Draft").toDocument()

        XCTAssertEqual(ReadingPositions.key(for: draft), draft.id.uuidString)
    }
}

// MARK: - Reading positions: persisted with the user data (F141)

final class R2ReadingPositionPersistenceTests: IsolatedDataDirTestCase {
    func testPositionsSurviveARelaunch() {
        let first = AppState()
        first.recordReadingPosition(840, forKey: "/notes/a.md")
        first.recordReadingPosition(120, forKey: "/notes/b.md")
        first.saveUserData()   // the quit flush

        let relaunched = AppState()
        XCTAssertEqual(relaunched.readingPosition(forKey: "/notes/a.md"), 840)
        XCTAssertEqual(relaunched.readingPosition(forKey: "/notes/b.md"), 120)
    }

    func testNoFileYetMeansNoPositions() {
        let state = AppState()

        XCTAssertNil(state.readingPosition(forKey: "/notes/a.md"))
        XCTAssertNil(state.errorMessage)
    }

    func testABadEntryCostsOnlyItselfAndRaisesNoAlert() throws {
        try write(#"[{"key":"/notes/a.md","offset":12}, {"key":5}, {"key":"/notes/b.md","offset":34}]"#,
                  to: "reading-positions.json")

        let state = AppState()

        XCTAssertEqual(state.readingPosition(forKey: "/notes/a.md"), 12)
        XCTAssertEqual(state.readingPosition(forKey: "/notes/b.md"), 34)
        XCTAssertNil(state.errorMessage, "a damaged position cache isn't worth an alert")
    }

    func testUnreadableFileStartsEmpty() throws {
        try write("[{", to: "reading-positions.json")

        let state = AppState()

        XCTAssertNil(state.readingPosition(forKey: "/notes/a.md"))
        XCTAssertNil(state.errorMessage)
    }
}

// MARK: - Open in Obsidian as a command (F139)

final class R2OpenInObsidianTests: XCTestCase {
    private let vault = Vault(name: "Display Alias", rootPath: URL(fileURLWithPath: "/Users/me/Vaults/Main"))

    private func query(_ url: URL?) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "obsidian")
        XCTAssertEqual(components.host, "open")
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testFileInAVaultOpensByAbsolutePath() throws {
        // Obsidian resolves `path=` to the most specific vault containing the
        // file, so two vaults sharing a folder name can't be confused (G056).
        let file = URL(fileURLWithPath: "/Users/me/Vaults/Main/Notes/회의록 1.md")

        let items = try query(AppState.obsidianOpenURL(for: file, vaults: [vault]))

        XCTAssertEqual(items, ["path": "/Users/me/Vaults/Main/Notes/회의록 1.md"])
    }

    func testFileOutsideEveryVaultFallsBackToItsPath() throws {
        let file = URL(fileURLWithPath: "/Users/me/Downloads/spec.md")

        let items = try query(AppState.obsidianOpenURL(for: file, vaults: [vault]))

        XCTAssertEqual(items, ["path": "/Users/me/Downloads/spec.md"])
    }

    func testSiblingFolderSharingTheVaultPrefixIsNotInTheVault() throws {
        let file = URL(fileURLWithPath: "/Users/me/Vaults/MainArchive/x.md")

        let items = try query(AppState.obsidianOpenURL(for: file, vaults: [vault]))

        XCTAssertEqual(items, ["path": "/Users/me/Vaults/MainArchive/x.md"])
    }

    func testCommandHasARemappableDefaultShortcut() {
        XCTAssertTrue(AppShortcut.allCases.contains(.openInObsidian), "listed in Settings › Keyboard")
        XCTAssertEqual(AppShortcut.openInObsidian.title, "Open in Obsidian")
        XCTAssertEqual(AppShortcut.openInObsidian.defaultBinding.displayString, "⌥⌘J")
    }
}
