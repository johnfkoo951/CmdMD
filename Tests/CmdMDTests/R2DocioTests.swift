import XCTest
@testable import CmdMD

/// Temp files for the file-backed cases, one directory per test.
class R2ScratchFileTestCase: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func writeData(_ data: Data, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func write(_ text: String, to name: String) throws -> URL {
        try writeData(Data(text.utf8), to: name)
    }

    /// Loads the file and saves it back without edits; returns what's on disk.
    @discardableResult
    func roundTrip(_ url: URL, times: Int = 1) async throws -> Data {
        let service = FileService()
        for _ in 0..<times {
            let document = try await service.loadDocument(from: url)
            try await service.saveDocument(document, to: url)
        }
        return try Data(contentsOf: url)
    }

    func assertByteExactRoundTrip(_ text: String, times: Int = 3, file: StaticString = #filePath, line: UInt = #line) async throws {
        let url = try write(text, to: "note-\(UUID().uuidString).md")
        let saved = try await roundTrip(url, times: times)
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), text, file: file, line: line)
    }
}

// MARK: - Byte-exact round trips (F065, F069, F071, F129)

final class R2FrontmatterFidelityTests: R2ScratchFileTestCase {
    func testCRLFWithFrontmatterRoundTripsByteForByte() async throws {
        let text = "---\r\ntitle: x\r\ntags:\r\n  - a\r\n---\r\n\r\n| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n\r\n```\r\ncode\r\n```\r\n"
        let url = try write(text, to: "crlf.md")
        let document = try await FileService().loadDocument(from: url)
        XCTAssertFalse(document.content.contains("\r"), "the editor and renderer see one LF per line break")
        XCTAssertEqual(document.content, "| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n```\n")
        XCTAssertEqual(document.fileFormat?.lineEnding, .crlf)
        let saved = try await roundTrip(url, times: 3)
        XCTAssertEqual(saved, Data(text.utf8))
    }

    func testCRLFWithoutFrontmatterIsNormalizedInMemory() async throws {
        let url = try write("- [ ] a\r\n- [ ] b\r\n", to: "tasks.md")
        let document = try await FileService().loadDocument(from: url)
        XCTAssertEqual(document.content, "- [ ] a\n- [ ] b\n", "task line numbers count one break per line")
        let saved = try await roundTrip(url)
        XCTAssertEqual(saved, Data("- [ ] a\r\n- [ ] b\r\n".utf8))
    }

    func testUTF8ByteOrderMarkIsKept() async throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("---\ntitle: x\n---\nBody\n".utf8)
        let url = try writeData(bytes, to: "bom.md")
        let document = try await FileService().loadDocument(from: url)
        XCTAssertEqual(document.frontmatter?.title, "x", "the BOM doesn't hide the frontmatter")
        XCTAssertEqual(document.content, "Body\n")
        let saved = try await roundTrip(url, times: 2)
        XCTAssertEqual(saved, bytes)
    }

    func testUTF16WithByteOrderMarkRoundTrips() async throws {
        let text = "---\ntitle: 회의록\n---\n본문\n"
        var bytes = Data([0xFF, 0xFE])
        bytes.append(text.data(using: .utf16LittleEndian)!)
        let url = try writeData(bytes, to: "utf16.md")
        let document = try await FileService().loadDocument(from: url)
        XCTAssertEqual(document.frontmatter?.title, "회의록")
        let saved = try await roundTrip(url)
        XCTAssertEqual(saved, bytes)
    }

    func testCommentsKeyOrderAndQuotingSurviveASave() async throws {
        try await assertByteExactRoundTrip("""
        ---
        # Synced from Obsidian
        zeta: 'single quoted'
        alpha: "double quoted"
        tags: [2024, project]   # flow list
        aliases:
          - Plan
        cssclasses: [wide, cards]
        ---
        # Body

        text
        """)
    }

    func testDatesTimestampsAndYAML11ScalarsSurviveASave() async throws {
        try await assertByteExactRoundTrip("""
        ---
        created: 2024-01-15
        date: 2024-01-15T08:30
        updated: 2024-01-01T08:00:00+09:00
        status:
        meeting-time: 14:00
        zip: 0123
        answer: yes
        ---
        Body
        """)
    }

    func testNestedMapsSurviveASave() async throws {
        try await assertByteExactRoundTrip("""
        ---
        title: Note
        cover:
          alt: Alt text
          url: https://example.com/a.png
        links:
          - name: a
            url: b
        inline: {a: 1, b: [x, y]}
        ---
        Body
        """)
    }

    func testInvalidYAMLIsKeptVerbatim() async throws {
        let blocks = [
            "---\ntitle: Re: Q3 planning\ntags: [work]\n---\nBody\n",
            "---\nauthor: @john\n---\nBody\n",
            "---\ntags:\n\t- a\n---\nBody\n",
            "---\ntitle: \"Hello\" world\n---\nBody\n",
        ]
        for text in blocks {
            let url = try write(text, to: "invalid-\(UUID().uuidString).md")
            let document = try await FileService().loadDocument(from: url)
            XCTAssertNil(document.frontmatter, text)
            XCTAssertNotNil(document.frontmatterSource, text)
            XCTAssertEqual(document.content, "Body\n", text)
            XCTAssertEqual(document.fullText, text)
            let saved = try await roundTrip(url, times: 2)
            XCTAssertEqual(String(decoding: saved, as: UTF8.self), text)
        }
    }

    func testNonMappingEmptyAndCommentOnlyBlocksAreKept() async throws {
        try await assertByteExactRoundTrip("---\nIntro paragraph\n---\nMore\n")
        try await assertByteExactRoundTrip("---\n# TODO add properties\n---\nBody\n")
        try await assertByteExactRoundTrip("---\n---\nBody\n")
        try await assertByteExactRoundTrip("---\ntitle: x\n---")
    }

    func testTemplateFrontmatterDoesNotCrashAndRoundTrips() async throws {
        // Unquoted {{date}} is a map with a map as its key, which Yams'
        // constructor force-unwraps.
        let text = "---\ntitle: {{title}}\ncreated: {{date}}\nday: {{date:YYYY-MM-DD}}\nkind: template\n---\nBody\n"
        let url = try write(text, to: "Template.md")
        let document = try await FileService().loadDocument(from: url)
        XCTAssertEqual(document.frontmatter?.custom["kind"], .string("template"), "the readable keys are still properties")
        XCTAssertNil(document.frontmatter?.custom["created"])
        XCTAssertEqual(document.fullText, text)
        let saved = try await roundTrip(url)
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), text)
    }

    func testInputsThatTrappedYamsLoadAreKept() async throws {
        let blocks = [
            "---\n{{date}}: x\n---\nBody\n",
            "---\n? [a, b]\n: v\n---\nBody\n",
            "---\nx: !foo {{a}}\n---\nBody\n",
            "---\nduration: 999999999999999999:00\nid: 1:00:00:00:00:00:00:00:00:00:00\n---\nBody\n",
        ]
        for text in blocks {
            try await assertByteExactRoundTrip(text, times: 1)
        }
        let url = try write("---\nduration: 999999999999999999:00\n---\nBody\n", to: "sexagesimal.md")
        let document = try await FileService().loadDocument(from: url)
        XCTAssertEqual(document.frontmatter?.custom["duration"], .string("999999999999999999:00"))
    }

    func testDeeplyNestedYAMLDoesNotOverflowTheStack() async throws {
        for depth in [300, 900] {
            let text = "---\nk: " + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "\n---\nBody\n"
            try await assertByteExactRoundTrip(text, times: 1)
        }
    }

    func testAliasBombIsNotExpanded() async throws {
        var yaml = "a0: &a0 [lol, lol, lol, lol, lol, lol, lol, lol, lol]\n"
        for level in 1...9 {
            let refs = Array(repeating: "*a\(level - 1)", count: 9).joined(separator: ", ")
            yaml += "a\(level): &a\(level) [\(refs)]\n"
        }
        let keyBomb = "---\n" + yaml + "z: {*a9: 1}\n---\nBody\n"
        let valueBomb = "---\n" + yaml + "---\nBody\n"
        for text in [valueBomb, keyBomb] {
            let start = Date()
            let url = try write(text, to: "bomb-\(UUID().uuidString).md")
            let document = try await FileService().loadDocument(from: url)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "parsing must stay bounded")
            XCTAssertNil(document.frontmatter)
            XCTAssertEqual(document.fullText, text)
        }
    }

    func testOversizedFrontmatterIsKeptWithoutParsing() async throws {
        let text = "---\nnote: " + String(repeating: "x", count: FileService.maxFrontmatterBytes) + "\n---\nBody\n"
        let url = try write(text, to: "big.md")
        let document = try await FileService().loadDocument(from: url)
        XCTAssertNil(document.frontmatter)
        XCTAssertEqual(document.fullText, text)
    }

    func testRepeatedSavesAreStable() async throws {
        let text = "\u{FEFF}---\r\n# comment\r\ncreated: 2024-01-15\r\nstatus:\r\ntags: [a, b]\r\n---\r\n\r\n\r\n# H\r\nbody\r\n"
        let url = try write(text, to: "stable.md")
        let saved = try await roundTrip(url, times: 10)
        XCTAssertEqual(saved, Data(text.utf8))
    }

    func testIndentedFenceInsideABlockScalarDoesNotEndTheBlock() async throws {
        let text = "---\ndesc: |\n  ---\n  text\ntitle: x\n---\nBody\n"
        let parsed = FileService.parseFrontmatter(from: text)
        XCTAssertEqual(parsed.body, "Body\n")
        XCTAssertEqual(parsed.frontmatter?.title, "x")
        XCTAssertEqual(parsed.frontmatter?.custom["desc"], .string("---\ntext\n"))
        try await assertByteExactRoundTrip(text)
    }

    func testBlankSeparatorIsNotAddedOrRemoved() async throws {
        try await assertByteExactRoundTrip("---\ntitle: x\n---\n\n# Heading\n", times: 5)
        try await assertByteExactRoundTrip("---\ntitle: x\n---\n# Heading\n", times: 5)
    }

    func testTypesFollowTheYAMLCoreSchema() {
        let parsed = FileService.parseFrontmatter(from: """
        ---
        time: 14:00
        zip: 0123
        answer: yes
        flag: true
        count: 4
        ratio: 1.5
        empty:
        quoted: "42"
        tags: [2024, project]
        ---
        Body
        """)
        let custom = parsed.frontmatter?.custom ?? [:]
        XCTAssertEqual(custom["time"], .string("14:00"))
        XCTAssertEqual(custom["zip"], .string("0123"))
        XCTAssertEqual(custom["answer"], .string("yes"))
        XCTAssertEqual(custom["flag"], .bool(true))
        XCTAssertEqual(custom["count"], .int(4))
        XCTAssertEqual(custom["ratio"], .double(1.5))
        XCTAssertEqual(custom["empty"], .string(""))
        XCTAssertEqual(custom["quoted"], .string("42"))
        XCTAssertEqual(parsed.frontmatter?.tags, ["2024", "project"], "a list of numbers is still the note's tags")
    }
}

// MARK: - Property edits patch only their own lines (F065, F093)

final class R2FrontmatterPatchTests: XCTestCase {
    private let original = """
    ---
    # Synced from Obsidian
    title: "Plan: Q3"
    created: 2024-01-15
    status: draft
    tags:
      - work
    cover:
      alt: A
    related: [Note A, Note B]
    rating: 4
    published: false
    ---
    Body

    """

    private func load(_ text: String) -> MarkdownDocument {
        let parsed = FileService.parseFrontmatter(from: text)
        return MarkdownDocument(content: parsed.body, frontmatter: parsed.frontmatter, frontmatterSource: parsed.source)
    }

    private func changedLines(_ old: String, _ new: String) -> (removed: [String], added: [String]) {
        let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
        return (oldLines.filter { !newLines.contains($0) }, newLines.filter { !oldLines.contains($0) })
    }

    func testEditingOnePropertyLeavesEveryOtherLineAlone() {
        var document = load(original)
        XCTAssertEqual(document.fullText, original)
        document.frontmatter?.custom["status"] = .string("done")

        let saved = document.fullText
        let change = changedLines(original, saved)
        XCTAssertEqual(change.removed, ["status: draft"])
        XCTAssertEqual(change.added, ["status: done"])
        XCTAssertTrue(saved.hasPrefix("---\n# Synced from Obsidian\ntitle: \"Plan: Q3\"\ncreated: 2024-01-15\nstatus: done\n"))
        XCTAssertEqual(load(saved).frontmatter?.custom["status"], .string("done"))
    }

    func testAddingAndRemovingProperties() {
        var document = load(original)
        document.frontmatter?.tags.append("Q3")
        document.frontmatter?.custom.removeValue(forKey: "rating")
        document.frontmatter?.custom["owner"] = .string("요한")

        let saved = document.fullText
        let change = changedLines(original, saved)
        XCTAssertEqual(change.removed, ["  - work", "rating: 4"])
        XCTAssertEqual(Set(change.added), ["- work", "- Q3", "owner: 요한"], "Korean is written as is, not \\u escaped")
        XCTAssertTrue(saved.contains("cover:\n  alt: A\n"), "a nested map nobody edited is untouched")
        let reloaded = load(saved)
        XCTAssertEqual(reloaded.frontmatter?.tags, ["work", "Q3"])
        XCTAssertNil(reloaded.frontmatter?.custom["rating"])
        XCTAssertEqual(reloaded.frontmatter?.custom["owner"], .string("요한"))
    }

    func testRevertingAnEditRestoresTheOriginalBytes() {
        var document = load(original)
        document.frontmatter?.custom["rating"] = .int(5)
        XCTAssertNotEqual(document.fullText, original)
        document.frontmatter?.custom["rating"] = .int(4)
        XCTAssertEqual(document.fullText, original, "the tab is clean again")
    }

    func testInspectorEditsKeepTheValueType() {
        var document = load(original)
        let related = document.frontmatter?.custom["related"]
        document.frontmatter?.custom["related"] = .edited("Note A, Note B, Note C", keeping: related)
        document.frontmatter?.custom["published"] = .edited("true", keeping: .bool(false))
        document.frontmatter?.custom["rating"] = .edited("5", keeping: .int(4))

        let reloaded = load(document.fullText)
        XCTAssertEqual(reloaded.frontmatter?.custom["related"], .list(["Note A", "Note B", "Note C"]))
        XCTAssertEqual(reloaded.frontmatter?.custom["published"], .bool(true))
        XCTAssertEqual(reloaded.frontmatter?.custom["rating"], .int(5))
    }

    func testEditedValueRules() {
        XCTAssertEqual(FrontmatterValue.edited("a, b,, c", keeping: .list(["x"])), .list(["a", "b", "c"]))
        XCTAssertEqual(FrontmatterValue.edited("FALSE", keeping: .bool(true)), .bool(false))
        XCTAssertEqual(FrontmatterValue.edited("fals", keeping: .bool(true)), .string("fals"))
        XCTAssertEqual(FrontmatterValue.edited("2.5", keeping: .int(1)), .double(2.5))
        XCTAssertEqual(FrontmatterValue.edited("n/a", keeping: .double(1)), .string("n/a"))
        XCTAssertEqual(FrontmatterValue.edited("true", keeping: .string("x")), .string("true"))
        XCTAssertEqual(FrontmatterValue.edited("x", keeping: nil), .string("x"))
    }

    func testSendInjectionReplacesAnEmptyTitleInsteadOfAddingASecond() {
        let text = "---\ntitle:\nsource: old\n# keep me\nstatus: draft\n---\nnotes\n"
        let document = load(text)
        XCTAssertNil(document.frontmatter?.title)

        let output = AppState.sendContent(for: document, template: nil, injectFrontmatter: true,
                                          sourceLink: URL(fileURLWithPath: "/tmp/M.md"))
        let lines = output.components(separatedBy: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("title:") }.count, 1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("source:") }, ["source: /tmp/M.md"])
        XCTAssertTrue(output.contains("# keep me\nstatus: draft\n---\nnotes\n"))
    }

    func testSendKeepsAnUnreadableBlockAsItIs() {
        let text = "---\ntitle: Re: Q3\n---\nnotes\n"
        let output = AppState.sendContent(for: load(text), template: nil, injectFrontmatter: true, sourceLink: nil)
        XCTAssertEqual(output, text, "no second block is stacked on a block that couldn't be read")
    }

    func testDiskReloadCarriesTheSourceAndFormat() {
        let existing = MarkdownDocument(title: "n", content: "old")
        var fresh = load(original)
        fresh.fileFormat = TextFileFormat(lineEnding: .crlf)
        let reloaded = AppState.applyingDiskReload(fresh, to: existing)
        XCTAssertEqual(reloaded.fullText, original)
        XCTAssertEqual(reloaded.fileFormat?.lineEnding, .crlf)
    }
}

// MARK: - Encodings and binary files (F075)

final class R2TextEncodingTests: R2ScratchFileTestCase {
    func testEUCKRFileRoundTripsInItsEncoding() async throws {
        let text = "# 회의록\n\n- 안건: 예산 검토\n- 참석자: 홍길동\n"
        let bytes = try XCTUnwrap(text.data(using: FileService.cp949))
        let url = try writeData(bytes, to: "legacy.md")

        let service = FileService()
        var document = try await service.loadDocument(from: url)
        XCTAssertEqual(document.content, text)
        let untouched = try await roundTrip(url)
        XCTAssertEqual(untouched, bytes, "an untouched save keeps the bytes")

        document.content += "- 결정: 승인\n"
        try await service.saveDocument(document, to: url)
        let edited = try Data(contentsOf: url)
        XCTAssertEqual(String(data: edited, encoding: FileService.cp949), document.content, "written back as CP949, not UTF-8")
    }

    func testTextTheLegacyEncodingCannotHoldFailsLoudly() async throws {
        let bytes = try XCTUnwrap("# 회의록\n".data(using: FileService.cp949))
        let url = try writeData(bytes, to: "legacy.md")
        let service = FileService()
        var document = try await service.loadDocument(from: url)
        document.content += "🙂\n"
        do {
            try await service.saveDocument(document, to: url)
            XCTFail("an emoji can't be written in CP949")
        } catch let error as TextFileError {
            XCTAssertEqual(error, .unrepresentable(fileName: "legacy.md", encoding: String.localizedName(of: FileService.cp949)))
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the file is left alone")
        XCTAssertEqual(document.fileFormat?.inUTF8.stringEncoding, .utf8, "Save As writes a UTF-8 copy")
    }

    func testBinaryFilesAreRefused() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        let url = try writeData(png, to: "image.md")
        do {
            _ = try await FileService().loadDocument(from: url)
            XCTFail("a binary file must not open as text")
        } catch let error as TextFileError {
            XCTAssertEqual(error, .binary(fileName: "image.md"))
        }
    }

    func testAmbiguousBytesAreNotGuessed() async throws {
        // UTF-8 with one stray byte, and Latin-1 German: both used to open as
        // UTF-16 garbage that a save wrote back as UTF-8.
        let stray = Data("# 회의록 ".utf8) + Data([0xFF]) + Data(" 끝\n".utf8)
        let latin1 = try XCTUnwrap("Ärger über Größe\n".data(using: .isoLatin1))
        for (name, bytes) in [("stray.md", stray), ("latin1.md", latin1)] {
            let url = try writeData(bytes, to: name)
            do {
                _ = try await FileService().loadDocument(from: url)
                XCTFail("\(name) must not be decoded by guesswork")
            } catch let error as TextFileError {
                XCTAssertEqual(error, .unreadableEncoding(fileName: name))
            }
        }
    }

    func testDeclaredEncodingIsHonored() async throws {
        let text = "Ärger über Größe\n"
        let bytes = try XCTUnwrap(text.data(using: .isoLatin1))
        let url = try writeData(bytes, to: "declared.md")
        let value = "ISO-8859-1;513"
        XCTAssertEqual(setxattr(url.path, "com.apple.TextEncoding", value, value.utf8.count, 0, 0), 0)
        let document = try await FileService().loadDocument(from: url)
        XCTAssertEqual(document.content, text)
        let saved = try await roundTrip(url)
        XCTAssertEqual(saved, bytes)
    }
}

// MARK: - Saving in place keeps the file's identity (F074)

final class R2SaveInPlaceTests: R2ScratchFileTestCase {
    func testSaveKeepsExtendedAttributesAndCreationDate() async throws {
        let url = try write("---\ntitle: x\n---\nBody\n", to: "tagged.md")
        let created = Date(timeIntervalSince1970: 1_577_836_800)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        let attribute = "com.cmdmd.test"
        XCTAssertEqual(setxattr(url.path, attribute, "kept", 4, 0, 0), 0)

        let service = FileService()
        var document = try await service.loadDocument(from: url)
        document.content += "more\n"
        try await service.saveDocument(document, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "---\ntitle: x\n---\nBody\nmore\n")
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(getxattr(url.path, attribute, &buffer, buffer.count, 0, 0), 4, "the extended attribute survives")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.creationDate] as? Date, created)
    }

    func testSavingThroughASymlinkUpdatesItsTarget() async throws {
        let realDirectory = directory.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let target = realDirectory.appendingPathComponent("target.md")
        try Data("old\n".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let service = FileService()
        var document = try await service.loadDocument(from: link)
        document.content = "new\n"
        try await service.saveDocument(document, to: link)

        let linkAttributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(linkAttributes[.type] as? FileAttributeType, .typeSymbolicLink, "the link stays a link")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new\n")
    }

    func testReadOnlyFileIsNotOverwritten() async throws {
        let url = try write("locked\n", to: "readonly.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let service = FileService()
        var document = try await service.loadDocument(from: url)
        document.content = "changed\n"
        do {
            try await service.saveDocument(document, to: url)
            XCTFail("a read-only file must not be replaced")
        } catch let error as TextFileError {
            XCTAssertEqual(error, .readOnly(fileName: "readonly.md"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "locked\n")
    }
}

final class R2AutosaveFailureTests: IsolatedDataDirTestCase {
    @MainActor
    func testAFailingAutosaveAlertsOnceNotEveryRound() async throws {
        let appState = AppState()
        appState.settings.autosaveEnabled = true

        let file = dataDir.appendingPathComponent("locked.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let doc = MarkdownDocument(title: "locked", content: "new", fileURL: file)
        appState.originalContents[doc.id] = "old"
        appState.documents[doc.id] = doc
        appState.tabs = [EditorTab(documentId: doc.id, fileURL: file, title: "locked")]

        await appState.performAutosave()
        XCTAssertNotNil(appState.errorMessage, "the first failure is shown")
        appState.errorMessage = nil
        await appState.performAutosave()
        XCTAssertNil(appState.errorMessage, "the same failure isn't raised again every interval")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
        appState.tabs.forEach { appState.closeTab($0) }
    }
}

// MARK: - Dates and titles (F085, F115)

final class R2DateAndTitleTests: XCTestCase {
    func testGeneratedDateIsTheLocalCalendarDay() throws {
        // 08:30 in Seoul on 2026-10-11 is still 2026-10-10 in UTC.
        let seoul = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 8, minute: 30)))

        let day = Frontmatter.calendarDay(morning, in: seoul)
        XCTAssertEqual(Frontmatter.dateString(day), "2026-10-11")
        XCTAssertEqual(Frontmatter(date: day).toYAML(), "---\ndate: 2026-10-11\n---")
    }

    func testParsedDatesWriteBackAsTheSameDay() {
        let parsed = FileService.parseFrontmatter(from: "---\ndate: 2024-01-15\n---\n")
        let date = parsed.frontmatter?.date
        XCTAssertEqual(date.map(Frontmatter.dateString), "2024-01-15")
        XCTAssertEqual(date.map { Frontmatter.calendarDay($0, in: TimeZone(secondsFromGMT: 0)!) }, date)
    }

    func testDisplayTitleFindsTheFirstHeadingNearTheTop() {
        XCTAssertEqual(MarkdownDocument(content: "intro\r\n  # Heading  \n# Second").displayTitle, "Heading")
        // The spaces after `#` aren't part of the title (G002).
        XCTAssertEqual(MarkdownDocument(content: "#hashtag\n#  Spaced").displayTitle, "Spaced")
        let deep = String(repeating: "line\n", count: 5_000) + "# Too deep"
        XCTAssertEqual(MarkdownDocument(content: deep).displayTitle, "Untitled", "a long text isn't scanned to the end")
        XCTAssertEqual(MarkdownDocument(content: "plain", fileURL: URL(fileURLWithPath: "/tmp/Note.md")).displayTitle, "Note")
    }

    func testDraftTitleIsItsFirstLine() {
        XCTAssertEqual(Draft(body: "First line\nsecond").displayTitle, "First line")
        XCTAssertEqual(Draft(body: String(repeating: "가", count: 80)).displayTitle, String(repeating: "가", count: 50))
        // A leading blank line is skipped (G039); a body of blank lines is untitled.
        XCTAssertEqual(Draft(body: "\nsecond").displayTitle, "second")
        XCTAssertEqual(Draft(body: "\n \n").displayTitle, "Untitled Draft")
    }
}
