import XCTest
import Carbon.HIToolbox
@testable import CmdMD

/// AppStates built here point their whole data layer (settings, session,
/// recents…) at a throwaway directory through CMDMD_DATA_DIR, so these tests
/// never read or write the real Application Support/CmdMD.
class R1AppmiscSandboxTestCase: XCTestCase {
    private(set) var sandbox: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdmd-r1-appmisc-\(UUID().uuidString)", isDirectory: true)
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

    func makeState() -> AppState {
        AppState()
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

// MARK: - Pinch zoom (F015)

final class R1AppmiscPinchZoomTests: XCTestCase {
    func testSlowPinchAccumulatesInsteadOfRoundingAway() {
        // 60 events of +0.37% each used to leave the level at exactly 1.0.
        var zoom = 1.0
        for _ in 0..<60 { zoom = AppState.accumulatedZoom(zoom, magnification: 0.0037) }
        XCTAssertEqual(AppState.clampedZoom(zoom), 1.25)
    }

    func testNormalPinchReachesTheGestureScale() {
        // A 2× pinch used to stop at 1.9.
        var zoom = 1.0
        for _ in 0..<60 { zoom = AppState.accumulatedZoom(zoom, magnification: 0.0116) }
        XCTAssertEqual(AppState.clampedZoom(zoom), 2.0)
    }

    func testSmallDeltasLeaveTheFloor() {
        var zoom = AppState.zoomRange.lowerBound
        for _ in 0..<60 { zoom = AppState.accumulatedZoom(zoom, magnification: 0.004) }
        XCTAssertGreaterThan(AppState.clampedZoom(zoom), AppState.zoomRange.lowerBound)
    }

    func testCeilingClampsSoTheFirstReverseDeltaTakesEffect() {
        let top = AppState.accumulatedZoom(2.9, magnification: 5)
        XCTAssertEqual(top, AppState.zoomRange.upperBound)
        XCTAssertLessThan(AppState.clampedZoom(AppState.accumulatedZoom(top, magnification: -0.01)), 3.0)
    }
}

final class R1AppmiscPinchZoomStateTests: R1AppmiscSandboxTestCase {
    func testPinchAccumulatesAndReseedsAfterKeyboardZoom() {
        let state = makeState()
        XCTAssertEqual(state.settings.zoomLevel, 1.0)

        for _ in 0..<60 { state.adjustZoom(by: 0.0037) }
        XCTAssertEqual(state.settings.zoomLevel, 1.25)

        state.zoomIn()
        XCTAssertEqual(state.settings.zoomLevel, 1.35)
        // The next pinch continues from the ⌘= level, not the stale accumulator.
        state.adjustZoom(by: 0.01)
        XCTAssertEqual(state.settings.zoomLevel, 1.36)
    }
}

// MARK: - Global Quick Capture hotkey (F043)

final class R1AppmiscGlobalHotKeyTests: XCTestCase {
    func testDefaultQuickCaptureBindingIsShiftCommandM() {
        let binding = AppShortcut.quickCapture.defaultBinding
        XCTAssertEqual(GlobalHotKey.carbonKeyCode(for: binding.key), UInt32(kVK_ANSI_M))
        XCTAssertEqual(GlobalHotKey.carbonModifiers(for: binding), UInt32(cmdKey | shiftKey))
        XCTAssertTrue(GlobalHotKey.canRegisterGlobally(binding))
    }

    func testModifierMask() {
        let all = KeyBinding(key: "k", command: true, shift: true, option: true, control: true)
        XCTAssertEqual(GlobalHotKey.carbonModifiers(for: all), UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(GlobalHotKey.carbonModifiers(for: KeyBinding(key: "k", control: true)), UInt32(controlKey))
    }

    func testKeyCodes() {
        XCTAssertEqual(GlobalHotKey.carbonKeyCode(for: "0"), UInt32(kVK_ANSI_0))
        XCTAssertEqual(GlobalHotKey.carbonKeyCode(for: "="), UInt32(kVK_ANSI_Equal))
        // The recorder keeps Shift's effect: ⇧⌘= is stored as "+".
        XCTAssertEqual(GlobalHotKey.carbonKeyCode(for: "+"), UInt32(kVK_ANSI_Equal))
        XCTAssertEqual(GlobalHotKey.carbonKeyCode(for: "ArrowLeft"), UInt32(kVK_LeftArrow))
        XCTAssertEqual(GlobalHotKey.carbonKeyCode(for: "Space"), UInt32(kVK_Space))
        // No fixed key position: never registered rather than bound to a wrong key.
        XCTAssertNil(GlobalHotKey.carbonKeyCode(for: "é"))
        XCTAssertNil(GlobalHotKey.carbonKeyCode(for: "ㅁ"))
    }

    func testOnlyCommandOrControlCombinationsGoGlobal() {
        XCTAssertFalse(GlobalHotKey.canRegisterGlobally(KeyBinding(key: "m")))
        XCTAssertFalse(GlobalHotKey.canRegisterGlobally(KeyBinding(key: "m", shift: true)))
        XCTAssertFalse(GlobalHotKey.canRegisterGlobally(KeyBinding(key: "m", shift: true, option: true)))
        XCTAssertTrue(GlobalHotKey.canRegisterGlobally(KeyBinding(key: "m", control: true)))
        XCTAssertFalse(GlobalHotKey.canRegisterGlobally(KeyBinding(key: "é", command: true)))
    }
}

// MARK: - Find in Folder (F137)

final class R1AppmiscFindInFolderTests: R1AppmiscSandboxTestCase {
    func testFindInFolderOpensAndFocusesTheSearchField() throws {
        let state = makeState()
        state.currentFolder = try make("notes/")
        state.sidebarVisible = false
        state.selectedSidebarTab = .drafts
        let request = state.folderSearchFocusRequest

        state.beginFolderSearch()

        XCTAssertTrue(state.showFolderSearch)
        XCTAssertTrue(state.sidebarVisible)
        XCTAssertEqual(state.selectedSidebarTab, .files)
        XCTAssertEqual(state.folderSearchFocusRequest, request + 1)
    }

    func testFindInFolderWithoutAFolderShowsTheOpenFolderPrompt() {
        let state = makeState()
        XCTAssertNil(state.currentFolder)

        state.beginFolderSearch()

        XCTAssertFalse(state.showFolderSearch)
        XCTAssertTrue(state.sidebarVisible)
        XCTAssertEqual(state.selectedSidebarTab, .files)
    }
}

// MARK: - File tree (F116)

final class R1AppmiscFileTreeTests: R1AppmiscSandboxTestCase {
    private func makeTree() throws -> URL {
        let root = try make("tree/")
        try make("tree/C/")
        try make("tree/A/inner.md")
        try make("tree/b.md")
        try make("tree/a.md")
        try make("tree/Notes.txt")
        try make("tree/image.png")
        try make("tree/.hidden.md")
        return root
    }

    func testListingIsFoldersFirstThenFilesCaseInsensitively() throws {
        let root = try makeTree()
        XCTAssertEqual(try AppState.listFolder(at: root).map(\.name), ["A", "C", "a.md", "b.md", "Notes.txt"])
    }

    func testTogglesReuseCachedListingsAndExpandingRereadsThatFolder() throws {
        let root = try makeTree()
        let state = makeState()
        state.currentFolder = root
        state.loadFileTree()
        let folderA = try XCTUnwrap(state.fileTree.first { $0.name == "A" }).url

        state.toggleFolderExpansion(folderA)
        XCTAssertEqual(state.fileTree.first { $0.name == "A" }?.children.map(\.name), ["inner.md"])
        // A rebuild from cached listings is identical to a full re-list.
        let toggled = state.fileTree
        state.loadFileTree()
        XCTAssertEqual(state.fileTree, toggled)

        // Collapsing does no disk I/O, so a file created meanwhile isn't listed…
        try make("tree/new.md")
        state.toggleFolderExpansion(folderA)
        XCTAssertFalse(state.fileTree.contains { $0.name == "new.md" })
        // …while expanding re-reads the folder being opened…
        try make("tree/A/later.md")
        state.toggleFolderExpansion(folderA)
        XCTAssertEqual(state.fileTree.first { $0.name == "A" }?.children.map(\.name), ["inner.md", "later.md"])
        // …and Refresh re-lists everything.
        state.loadFileTree()
        XCTAssertTrue(state.fileTree.contains { $0.name == "new.md" })
    }
}

// MARK: - Content search (F109, F145)

final class R1AppmiscContentSearchTests: R1AppmiscSandboxTestCase {
    func testScanStopsAtTheLimit() async throws {
        let root = try make("search/")
        for name in ["one", "two", "three"] {
            try make("search/\(name).md", contents: "intro\nFoo \(name)\n")
        }
        let results = await AppState.performSearch(query: "foo", in: [root], limit: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testCRLFLineNumbersAndMatchRangeIndexTheOriginalLine() async throws {
        let root = try make("search/")
        try make("search/crlf.md", contents: "first\r\nsecond\r\nthe foo line\r\n")
        // "İ" lowercases to two scalars, so ranges taken on a lowercased copy
        // don't index the original line.
        try make("search/dotted.md", contents: "İİİ foo")

        let results = await AppState.performSearch(query: "FOO", in: [root])

        XCTAssertEqual(results.first { $0.fileName == "crlf.md" }?.lineNumber, 3)
        let dotted = try XCTUnwrap(results.first { $0.fileName == "dotted.md" })
        XCTAssertEqual(String(dotted.lineContent[dotted.matchRange]), "foo")
    }

    /// The one-file-at-a-time scan `performSearch` replaced (String reads,
    /// per-file standardized dedup). The batched, parallel scan must report
    /// the same lines in the same order.
    static func referenceSearch(query: String, in folders: [URL], limit: Int) -> [String] {
        var results: [String] = []
        var scanned: Set<String> = []
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "md" || ext == "markdown" else { continue }
                guard scanned.insert(fileURL.standardizedFileURL.path).inserted else { continue }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                      content.range(of: query, options: .caseInsensitive) != nil else { continue }
                let text = FileService.normalizingLineEndings(content).text
                let block = FileService.frontmatterBlock(in: text)
                let propertyLines = block.map { text[$0.yaml].split(separator: "\n") } ?? []
                let bodyLines = text[(block?.bodyStart ?? text.startIndex)...]
                    .split(separator: "\n", omittingEmptySubsequences: false)
                let lines = propertyLines.map { (number: Int?.none, text: $0) }
                    + bodyLines.enumerated().map { (number: Int?.some($0.offset + 1), text: $0.element) }
                for line in lines {
                    let lineContent = String(line.text)
                    guard let range = lineContent.range(of: query, options: .caseInsensitive) else { continue }
                    results.append("\(fileURL.path)|\(line.number.map(String.init) ?? "-")|\(lineContent)|\(lineContent[range])")
                    if results.count >= limit { return results }
                }
            }
        }
        return results
    }

    func testBatchedScanReportsTheSameLinesInTheSameOrder() async throws {
        let root = try make("corpus/")
        let nested = try make("corpus/vault/")
        let bodies = [
            "---\ntitle: Foo meeting\ntags: [회의]\n---\n# Notes\nnothing here\n",
            "line one\r\nthe FOO line\r\n회의록 정리\r\n",
            "회의록".decomposedStringWithCanonicalMapping + " 분해형\nfoo and Foo twice\n",
            "plain text without the words\n",
            "Über foo\nstraße\n",
        ]
        for index in 0..<300 {
            let folder = index.isMultiple(of: 4) ? "corpus/vault/sub\(index % 7)" : "corpus/f\(index % 5)"
            try make("\(folder)/n\(index).md", contents: bodies[index % bodies.count])
        }
        // Not UTF-8: skipped by both.
        try Data([0x66, 0x6F, 0x6F, 0xFF, 0xFE]).write(to: root.appendingPathComponent("f0/latin.md"))

        for query in ["foo", "회의록", "FOO LINE", "über", "nowhere-zz"] {
            for limit in [5, 40, 500] {
                let results = await AppState.performSearch(query: query, in: [root, nested], limit: limit)
                let lines = results.map { "\($0.fileURL.path)|\($0.lineNumber.map(String.init) ?? "-")|\($0.lineContent)|\($0.lineContent[$0.matchRange])" }
                XCTAssertEqual(lines, Self.referenceSearch(query: query, in: [root, nested], limit: limit), "\(query) limit \(limit)")
            }
        }
        let korean = await AppState.performSearch(query: "회의록", in: [root], limit: 500)
        XCTAssertGreaterThan(korean.count, 100, "composed query finds composed and decomposed text")
    }

    func testCancelledScanReturnsNothing() async throws {
        let root = try make("corpus/")
        for index in 0..<200 { try make("corpus/n\(index).md", contents: "foo \(index)\n") }
        let task = Task { await AppState.performSearch(query: "foo", in: [root], limit: 500) }
        task.cancel()
        let results = await task.value
        XCTAssertTrue(results.isEmpty)
    }

    func testFilesUnderNestedRootsAreReportedOnce() async throws {
        let root = try make("search/")
        let nested = try make("search/vault/")
        try make("search/vault/n.md", contents: "foo")

        let results = await AppState.performSearch(query: "foo", in: [root, nested])

        XCTAssertEqual(results.filter { $0.fileName == "n.md" }.count, 1)
    }

    func testOmnisearchContentCoversVaultsWithoutAnOpenFolder() async throws {
        let vaultRoot = try make("vault/")
        try make("vault/idea.md", contents: "a foo idea")
        let state = makeState()
        state.vaults = [Vault(name: "Vault", rootPath: vaultRoot)]
        XCTAssertNil(state.currentFolder)

        let results = await state.searchContent(query: "foo", limit: 12)

        XCTAssertEqual(results.map(\.fileName), ["idea.md"])
    }

    func testContentSearchRootsKeepTheOpenFolderFirstWithoutDuplicates() {
        let folder = URL(fileURLWithPath: "/tmp/notes")
        let vault = URL(fileURLWithPath: "/tmp/vault")
        XCTAssertEqual(
            AppState.contentSearchRoots(currentFolder: folder, vaultRoots: [vault, folder]).map(\.path),
            ["/tmp/notes", "/tmp/vault"]
        )
        XCTAssertEqual(AppState.contentSearchRoots(currentFolder: nil, vaultRoots: [vault]).map(\.path), ["/tmp/vault"])
        XCTAssertTrue(AppState.contentSearchRoots(currentFolder: nil, vaultRoots: []).isEmpty)
    }
}

// MARK: - Omnisearch file hits (F105)

final class R1AppmiscOmnisearchHitTests: XCTestCase {
    private func note(_ title: String) -> VaultNote {
        VaultNote(
            path: "notes/\(title).md",
            title: title,
            modifiedAt: .distantPast,
            url: URL(fileURLWithPath: "/vault/notes/\(title).md")
        )
    }

    func testEmptyQueryListsRecentFiles() {
        let recents = (1...10).map { URL(fileURLWithPath: "/vault/r\($0).md") }
        let hits = OmnisearchView.fileHits(query: "", notes: [note("Alpha")], recentFiles: recents)
        XCTAssertEqual(hits.map(\.title), (1...8).map { "r\($0)" })
    }

    func testRankingWithRecentBoost() {
        let notes = [note("Alphabet"), note("Beta Alpha"), note("Alpha")]
        XCTAssertEqual(
            OmnisearchView.fileHits(query: "Alpha", notes: notes, recentFiles: []).map(\.title),
            ["Alpha", "Alphabet", "Beta Alpha"]
        )
        let boosted = OmnisearchView.fileHits(query: "alpha", notes: notes, recentFiles: [notes[1].url])
        XCTAssertEqual(boosted.first?.title, "Beta Alpha")
    }

    func testHitIdentityIsStableAcrossScoringPasses() {
        let notes = [note("Alpha"), note("Alps"), note("Beta")]
        let first = OmnisearchView.fileHits(query: "al", notes: notes, recentFiles: [])
        let second = OmnisearchView.fileHits(query: "al", notes: notes, recentFiles: [])
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    /// The Character-matching ranking `fileHits` replaced (lowercase each
    /// title and path per keystroke, score all, sort). The byte-key version
    /// must pick the same notes in the same order.
    static func referenceFileHits(query: String, notes: [VaultNote], recentFiles: [URL]) -> [String] {
        let lowered = query.lowercased()
        let recents = Set(recentFiles)
        return notes
            .compactMap { note -> (VaultNote, Int)? in
                let score = Command.fuzzyScore(query: lowered, in: note.title.lowercased())
                    ?? Command.fuzzyScore(query: lowered, in: note.path.lowercased())
                guard var score else { return nil }
                if recents.contains(note.url) { score += 20 }
                return (note, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.modifiedAt > rhs.0.modifiedAt
            }
            .prefix(10)
            .map { $0.0.path }
    }

    func testByteKeyRankingMatchesCharacterRanking() {
        // File systems hand back Korean names decomposed (NFD); queries are typed composed.
        let titles = [
            "회의록 2026-10-01", "주간 회의", "회고", "CMDS 회의록", "AI 하네스 기획서",
            "README", "readme-draft", "Read Me Later", "cmds-pele", "CmdMD Notes", "cmd/space",
            "Claude Code 세팅", "claude-skills", "Über Notes", "naïve café", "PKM for AI Agent",
            "a", "ab", "abc", "zzz-abc", "x-y-z", "회의록", "회의 록", "의회",
        ]
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var notes: [VaultNote] = []
        for (offset, title) in titles.enumerated() {
            let decomposed = title.decomposedStringWithCanonicalMapping
            let folder = offset.isMultiple(of: 3) ? "Projects/회의 기록" : "Inbox"
            notes.append(VaultNote(
                path: "\(folder)/\(decomposed).md".decomposedStringWithCanonicalMapping,
                title: decomposed,
                // Pairs share a date, so ties must keep the index order.
                modifiedAt: base.addingTimeInterval(Double(-(offset / 2) * 60)),
                url: URL(fileURLWithPath: "/vault/\(folder)/\(decomposed).md")
            ))
        }
        let recents = [notes[3].url, notes[10].url]
        XCTAssertEqual(OmnisearchView.fileHits(query: "회의록", notes: notes, recentFiles: []).first?.title,
                       "회의록".decomposedStringWithCanonicalMapping)
        XCTAssertEqual(OmnisearchView.fileHits(query: "cafe", notes: notes, recentFiles: []).count, 0)
        let queries = ["회", "회의", "회의록", "회의 록", "의", "c", "cm", "cmd", "CMDS", "re", "rme",
                       "read me", "-", "/", "x-z", "abc", "über", "cafe", "café", "claude", "기록", "zzzz", "a"]
        for query in queries {
            for recent in [[], recents] {
                XCTAssertEqual(
                    OmnisearchView.fileHits(query: query, notes: notes, recentFiles: recent).map(\.subtitle),
                    Self.referenceFileHits(query: query, notes: notes, recentFiles: recent),
                    "query \(query), recents \(recent.count)"
                )
            }
        }
    }

    func testFileAndContentHitsInOneFileHaveDistinctIDs() {
        let url = URL(fileURLWithPath: "/vault/a.md")
        let file = OmnisearchView.Hit(kind: .file, title: "a", subtitle: "", url: url, line: nil)
        let content = OmnisearchView.Hit(kind: .content, title: "a", subtitle: "", url: url, line: 3)
        XCTAssertNotEqual(file.id, content.id)
    }
}
