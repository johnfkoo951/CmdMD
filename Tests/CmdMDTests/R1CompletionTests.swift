import XCTest
import AppKit
@testable import CmdMD

final class R1CompletionTests: XCTestCase {
    // MARK: Accepting inside an existing link

    /// Runs detection at the "‸" marker, accepts `title`, and returns the edited
    /// text with "‸" marking the resulting caret.
    private func accept(_ title: String, in marked: String) -> String? {
        let caret = (marked as NSString).range(of: "‸").location
        let text = marked.replacingOccurrences(of: "‸", with: "") as NSString
        guard let context = CompletionService.detectContext(in: text, cursorLocation: caret) else { return nil }
        let item = CompletionItem(text: title, displayText: title, detail: nil, type: context.type)
        let edited = text.replacingCharacters(in: context.range, with: context.replacement(for: item)) as NSString
        let newCaret = context.caretLocation(afterAccepting: item, in: edited)
        return edited.replacingCharacters(in: NSRange(location: newCaret, length: 0), with: "‸")
    }

    func testAcceptingInsideExistingLinkDoesNotDuplicateClosingBrackets() {
        XCTAssertEqual(accept("Project Plan", in: "see [[Project P‸]] x"), "see [[Project Plan]]‸ x")
        XCTAssertEqual(accept("Project Plan", in: "[[Proj‸]]"), "[[Project Plan]]‸")
    }

    func testAcceptingMidTargetReplacesTheRestOfTheTarget() {
        // Fixing "[[Projct Plan]]" by typing "e" after "Proj": the old code left
        // the tail behind ("[[Project Plan]]ct Plan]]").
        XCTAssertEqual(accept("Project Plan", in: "[[Proje‸ct Plan]] done"), "[[Project Plan]]‸ done")
    }

    func testAliasHeadingAndBlockSuffixesAreKept() {
        XCTAssertEqual(accept("Project Plan", in: "[[Proj‸|alias]] tail"), "[[Project Plan|alias]]‸ tail")
        XCTAssertEqual(accept("Project Plan", in: "[[Proj‸ect#Intro]]"), "[[Project Plan#Intro]]‸")
        XCTAssertEqual(accept("Project Plan", in: "[[Pro‸j#^abc123]]"), "[[Project Plan#^abc123]]‸")
    }

    func testClosingBracketsOfALaterLinkAreNotReused() {
        XCTAssertEqual(accept("Project Plan", in: "[[Proj‸ and [[B]]"), "[[Project Plan]]‸ and [[B]]")
        // "]]" on the next line belongs to something else.
        XCTAssertEqual(accept("My Note", in: "see [[My No‸\nnext]]"), "see [[My Note]]‸\nnext]]")
    }

    func testExtendedRangeKeepsTriggerLocationAndUTF16Offsets() {
        // The popup is dismissed when range.location changes, so extending the
        // range must not move its start. 😀 is 2 UTF-16 units.
        let text = "😀 [[회의|별칭]]" as NSString
        let caret = text.range(of: "|").location
        let context = CompletionService.detectContext(in: text, cursorLocation: caret)

        XCTAssertEqual(context?.query, "회의")
        XCTAssertEqual(context?.closesExistingLink, true)
        XCTAssertEqual(context?.range, NSRange(location: 3, length: caret - 3))
        XCTAssertEqual(accept("회의록 정리", in: "😀 [[회‸의|별칭]]"), "😀 [[회의록 정리|별칭]]‸")
    }

    func testPlainContextIsUnchangedWithoutTrailingLink() {
        let text = "see [[My No" as NSString
        let context = CompletionService.detectContext(in: text, cursorLocation: text.length)
        XCTAssertEqual(context?.closesExistingLink, false)
        XCTAssertEqual(context?.range, NSRange(location: 4, length: 7))
    }

    // MARK: Wiki-link matching and ranking

    private func items(_ query: String, _ notes: [VaultNote]) -> [String] {
        let context = CompletionContext(type: .wikiLink, query: query, range: NSRange(location: 0, length: 2 + query.utf16.count))
        return CompletionService.completions(for: context, notes: notes, tags: []).map(\.text)
    }

    func testDecomposedTitlesMatchComposedQueries() {
        // FileManager often returns NFD names (e.g. Korean); typed queries are NFC.
        let title = "회의록 정리".decomposedStringWithCanonicalMapping
        let notes = [VaultNote(path: "회의/\(title).md".decomposedStringWithCanonicalMapping, title: title, modifiedAt: Date())]

        XCTAssertEqual(items("회의", notes), [title])
        XCTAssertEqual(items("정리", notes), [title])
        XCTAssertEqual(items("회의".decomposedStringWithCanonicalMapping, notes), [title])
        XCTAssertEqual(VaultNote.searchKey(for: title), VaultNote.searchKey(for: "회의록 정리"))
    }

    func testRanksTitlePrefixThenTitleSubstringThenPathOnlyRegardlessOfInputOrder() {
        let notes = [
            VaultNote(path: "CMDS/Weekly.md", title: "Weekly", modifiedAt: Date(timeIntervalSince1970: 400)),
            VaultNote(path: "a/My CMDS notes.md", title: "My CMDS notes", modifiedAt: Date(timeIntervalSince1970: 300)),
            VaultNote(path: "b/cmds old.md", title: "cmds old", modifiedAt: Date(timeIntervalSince1970: 100)),
            VaultNote(path: "c/Unrelated.md", title: "Unrelated", modifiedAt: Date(timeIntervalSince1970: 500)),
            VaultNote(path: "d/CMDS Plan.md", title: "CMDS Plan", modifiedAt: Date(timeIntervalSince1970: 200))
        ]

        XCTAssertEqual(items("cmds", notes), ["CMDS Plan", "cmds old", "My CMDS notes", "Weekly"])
    }

    func testBareTriggerListsMostRecentNotesRegardlessOfInputOrder() {
        let notes = (0..<30).map { i in
            VaultNote(path: "n\(i).md", title: "n\(i)", modifiedAt: Date(timeIntervalSince1970: Double((i * 7) % 30)))
        }
        let expected = notes.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(CompletionService.maxResults).map(\.title)
        XCTAssertEqual(items("", notes), Array(expected))
    }

    func testBoundedSelectionMatchesAFullSort() {
        // Deterministic pseudo-random index; compare with the naive full sort.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let words = ["alpha", "Beta", "gamma", "Delta", "plan", "회의", "notes", "Proj"]
        let notes = (0..<600).map { i -> VaultNote in
            let title = "\(words[next(words.count)]) \(words[next(words.count)]) \(i)"
            return VaultNote(path: "\(words[next(words.count)])/\(title).md", title: title,
                             modifiedAt: Date(timeIntervalSince1970: Double(next(10_000))))
        }

        for query in ["", "a", "Pl", "회", "notes ", "zzz", "beta g"] {
            let q = query.lowercased()
            func rank(_ n: VaultNote) -> Int? {
                let title = n.title.lowercased()
                if title.hasPrefix(q) { return 0 }
                if title.contains(q) { return 1 }
                if n.path.lowercased().contains(q) { return 2 }
                return nil
            }
            // Equal dates may tie in either order, so compare (rank, date) sequences.
            func signature(_ note: VaultNote) -> String {
                "\(rank(note) ?? -1)@\(note.modifiedAt.timeIntervalSince1970)"
            }
            let expected = notes
                .filter { rank($0) != nil }
                .sorted { rank($0)! != rank($1)! ? rank($0)! < rank($1)! : $0.modifiedAt > $1.modifiedAt }
                .prefix(CompletionService.maxResults)
                .map(signature)
            let byTitle = Dictionary(uniqueKeysWithValues: notes.map { ($0.title, $0) })
            let actual = items(query, notes).compactMap { byTitle[$0] }.map(signature)

            XCTAssertEqual(actual, expected, "query \"\(query)\"")
        }
    }

    // MARK: Index truncation

    private func makeRoot(_ name: String, notes: [String: TimeInterval]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for (title, mtime) in notes {
            let url = root.appendingPathComponent("\(title).md")
            try "# \(title)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path)
        }
        return root
    }

    func testIndexCapDoesNotStarveLaterRootsAndKeepsMostRecent() throws {
        let rootA = try makeRoot("A", notes: ["a1": 1_000, "a2": 2_000, "a3": 3_000, "a4": 4_000, "a5": 5_000])
        let rootB = try makeRoot("B", notes: ["b1": 9_000, "b2": 8_000])

        let capped = NoteIndexService.buildIndex(roots: [rootA, rootB], limit: 3)
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(Array(capped.map(\.title).prefix(2)), ["b1", "b2"], "the later root's newer notes must survive the cap")
        XCTAssertEqual(capped.map(\.modifiedAt), capped.map(\.modifiedAt).sorted(by: >))

        let all = NoteIndexService.buildIndex(roots: [rootA, rootB])
        XCTAssertEqual(all.map(\.title), ["b1", "b2", "a5", "a4", "a3", "a2", "a1"])
        XCTAssertEqual(all.first?.path, "b1.md")
    }

    // MARK: Popup placement

    private let screen = NSRect(x: 0, y: 80, width: 1440, height: 795) // Dock below, menu bar above
    private let popup = NSSize(width: 300, height: 200)

    func testPopupOpensBelowTheCaretLineWhenThereIsRoom() {
        let caret = NSRect(x: 200, y: 500, width: 1, height: 17)
        let frame = CompletionWindowController.popupFrame(size: popup, caretRect: caret, visibleFrame: screen)
        XCTAssertEqual(frame, NSRect(x: 200, y: 296, width: 300, height: 200))
    }

    func testPopupFlipsAboveTheCaretNearTheBottomOfTheScreen() {
        let caret = NSRect(x: 200, y: 150, width: 1, height: 17)
        let frame = CompletionWindowController.popupFrame(size: popup, caretRect: caret, visibleFrame: screen)
        XCTAssertEqual(frame.minY, caret.maxY + 4, "bottom edge sits just above the caret line")
        XCTAssertTrue(screen.contains(frame))
    }

    func testPopupIsClampedHorizontallyIntoTheVisibleFrame() {
        let right = CompletionWindowController.popupFrame(
            size: popup, caretRect: NSRect(x: 1400, y: 500, width: 1, height: 17), visibleFrame: screen)
        XCTAssertEqual(right.maxX, screen.maxX)

        let left = CompletionWindowController.popupFrame(
            size: popup, caretRect: NSRect(x: -40, y: 500, width: 1, height: 17), visibleFrame: screen)
        XCTAssertEqual(left.minX, screen.minX)
    }

    func testPopupStaysOnScreenWhenNeitherSideFits() {
        let short = NSRect(x: 0, y: 0, width: 800, height: 300)
        let caret = NSRect(x: 100, y: 160, width: 1, height: 17)
        let frame = CompletionWindowController.popupFrame(size: popup, caretRect: caret, visibleFrame: short)
        XCTAssertTrue(short.contains(frame))
    }

    func testPopupWithoutScreenInfoKeepsBelowPlacement() {
        let caret = NSRect(x: 10, y: 20, width: 1, height: 17)
        let frame = CompletionWindowController.popupFrame(size: popup, caretRect: caret, visibleFrame: nil)
        XCTAssertEqual(frame.origin, NSPoint(x: 10, y: 20 - 4 - 200))
    }
}
