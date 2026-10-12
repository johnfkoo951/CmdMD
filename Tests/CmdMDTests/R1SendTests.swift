import XCTest
@testable import CmdMD

final class R1SendTests: XCTestCase {
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

    // MARK: Sending into the note's own folder (F076)

    @MainActor
    func testSendIntoTheNotesOwnFolderLeavesItUntouched() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        let inbox = vault.inbox
        var options = vault.options
        let source = inbox.appendingPathComponent("Idea.md")
        try "body".write(to: source, atomically: true, encoding: .utf8)

        // As FileService loads it: no frontmatter title, so the title is the filename.
        let document = MarkdownDocument(title: "Idea", content: "body", fileURL: source)
        options.action = .move

        for resolution in FileConflictResolution.allCases {
            options.conflictResolution = resolution
            let outcome = try await state.sendToVault(document: document, options: options, quiet: true)

            guard case .alreadyInPlace = outcome else {
                return XCTFail("\(resolution): expected alreadyInPlace, got \(outcome)")
            }
            XCTAssertEqual(try read(source), "body", "\(resolution) must neither rewrite nor delete the note")
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: inbox.path), ["Idea.md"],
                "\(resolution) must not leave a renamed copy behind"
            )
        }
    }

    @MainActor
    func testCaseOnlyDifferentTargetCountsAsTheSameNote() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        let inbox = vault.inbox
        var options = vault.options
        let caseSensitive = try inbox.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        try XCTSkipIf(caseSensitive, "the temp volume is case-sensitive")

        let source = inbox.appendingPathComponent("idea.md")
        try "body".write(to: source, atomically: true, encoding: .utf8)
        // A frontmatter title of "Idea" makes the candidate "Idea.md": the same file here.
        let document = MarkdownDocument(title: "Idea", content: "body", fileURL: source, frontmatter: Frontmatter(title: "Idea"))
        options.action = .move
        options.conflictResolution = .overwrite
        options.injectFrontmatter = false

        let outcome = try await state.sendToVault(document: document, options: options, quiet: true)
        guard case .alreadyInPlace = outcome else {
            return XCTFail("expected alreadyInPlace, got \(outcome)")
        }
        XCTAssertEqual(try read(source), "body")
    }

    @MainActor
    func testSkipReportsSkippedAndLeavesBothFiles() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        let (root, inbox) = (vault.root, vault.inbox)
        var options = vault.options
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let source = notes.appendingPathComponent("Idea.md")
        try "new".write(to: source, atomically: true, encoding: .utf8)
        let existing = inbox.appendingPathComponent("Idea.md")
        try "old".write(to: existing, atomically: true, encoding: .utf8)

        options.action = .move
        options.conflictResolution = .skip
        let document = MarkdownDocument(title: "Idea", content: "new", fileURL: source)
        let outcome = try await state.sendToVault(document: document, options: options, quiet: true)

        guard case .skipped(let url) = outcome else {
            return XCTFail("expected skipped, got \(outcome)")
        }
        XCTAssertEqual(url.lastPathComponent, "Idea.md")
        XCTAssertEqual(try read(source), "new", "a skipped Move must keep the source")
        XCTAssertEqual(try read(existing), "old", "a skipped send must keep the target")
    }

    @MainActor
    func testCopyWritesTheTargetAndReportsSent() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        let (root, inbox) = (vault.root, vault.inbox)
        var options = vault.options
        let source = root.appendingPathComponent("Idea.md")
        try "body".write(to: source, atomically: true, encoding: .utf8)

        options.injectFrontmatter = false
        let document = MarkdownDocument(title: "Idea", content: "body", fileURL: source)
        let outcome = try await state.sendToVault(document: document, options: options, quiet: true)

        guard case .sent(let url) = outcome else {
            return XCTFail("expected sent, got \(outcome)")
        }
        XCTAssertEqual(url.lastPathComponent, "Idea.md")
        XCTAssertEqual(try read(inbox.appendingPathComponent("Idea.md")), "body")
        XCTAssertEqual(try read(source), "body", "Copy keeps the source")
    }

    func testUnsentMessagesNameTheFile() {
        let url = URL(fileURLWithPath: "/Vault/Inbox/Idea.md")
        XCTAssertNil(SendOutcome.sent(url).unsentMessage)
        XCTAssertEqual(SendOutcome.skipped(url).unsentMessage, "Skipped: Idea.md already exists")
        XCTAssertEqual(SendOutcome.alreadyInPlace(url).unsentMessage, "Idea.md is already in Inbox")
    }

    func testIsSameFile() throws {
        let dir = try makeTempDir()
        let note = dir.appendingPathComponent("idea.md")
        try "x".write(to: note, atomically: true, encoding: .utf8)
        let other = dir.appendingPathComponent("other.md")
        try "y".write(to: other, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: note)

        XCTAssertTrue(AppState.isSameFile(note, URL(fileURLWithPath: dir.path + "/./idea.md")))
        XCTAssertTrue(AppState.isSameFile(link, note))
        XCTAssertFalse(AppState.isSameFile(note, other))
        XCTAssertFalse(AppState.isSameFile(note, dir.appendingPathComponent("missing.md")))
    }

    // MARK: Template without injection (F087)

    func testTemplateWithoutInjectionKeepsTheNotesFrontmatter() {
        let document = MarkdownDocument(
            title: "M",
            content: "notes",
            frontmatter: Frontmatter(tags: ["work"], aliases: ["m"])
        )
        let template = VaultTemplate(name: "Meeting", content: "## Meeting\n{{content}}")

        let output = AppState.sendContent(for: document, template: template, injectFrontmatter: false, sourceLink: nil)
        XCTAssertTrue(output.hasPrefix("---\n"), "the note's own properties must survive a templated send")
        XCTAssertTrue(output.contains("work"))
        XCTAssertTrue(output.contains("aliases"))
        XCTAssertTrue(output.hasSuffix("## Meeting\nnotes"))
    }

    func testTemplateWithoutFrontmatterIsJustTheRenderedBody() {
        let document = MarkdownDocument(title: "M", content: "notes")
        let template = VaultTemplate(name: "Meeting", content: "## Meeting\n{{content}}")
        XCTAssertEqual(
            AppState.sendContent(for: document, template: template, injectFrontmatter: false, sourceLink: nil),
            "## Meeting\nnotes"
        )
    }

    func testNoTemplateNoInjectionShipsTheFileAsIs() {
        let document = MarkdownDocument(title: "M", content: "notes", frontmatter: Frontmatter(tags: ["work"]))
        XCTAssertEqual(
            AppState.sendContent(for: document, template: nil, injectFrontmatter: false, sourceLink: nil),
            document.fullText
        )
    }

    func testInjectionKeepsTagsAndAddsTitleAndSource() {
        let document = MarkdownDocument(title: "M", content: "notes", frontmatter: Frontmatter(tags: ["work"]))
        let output = AppState.sendContent(
            for: document,
            template: nil,
            injectFrontmatter: true,
            sourceLink: URL(fileURLWithPath: "/tmp/M.md")
        )
        XCTAssertTrue(output.contains("title: M"))
        XCTAssertTrue(output.contains("work"))
        XCTAssertTrue(output.contains("source: /tmp/M.md"))
        XCTAssertTrue(output.hasSuffix("\n\nnotes"))
    }

    // MARK: Tag conditions and inline tags (F142)

    func testTagConditionMatchesInlineTag() {
        let condition = RoutingCondition(type: .tag, value: "meeting", matchType: .equals)
        XCTAssertTrue(condition.matches(document: MarkdownDocument(content: "#meeting with Kim re budget")))
    }

    func testTagConditionValueMayCarryLeadingHash() {
        let condition = RoutingCondition(type: .tag, value: "#meeting", matchType: .equals)
        XCTAssertTrue(condition.matches(document: MarkdownDocument(content: "", frontmatter: Frontmatter(tags: ["meeting"]))))
        XCTAssertTrue(condition.matches(document: MarkdownDocument(content: "notes #meeting")))
    }

    func testFrontmatterTagStoredWithHashStillMatches() {
        let condition = RoutingCondition(type: .tag, value: "meeting", matchType: .equals)
        XCTAssertTrue(condition.matches(document: MarkdownDocument(content: "", frontmatter: Frontmatter(tags: ["#meeting"]))))
    }

    func testTagsInCodeAndHeadingsDoNotCount() {
        let content = "# meeting\n```c\n#include <x>\n```\nsee `#todo` and a`code`#glued"
        XCTAssertEqual(MarkdownDocument.inlineTags(in: content), [])
        for value in ["meeting", "include", "todo", "glued"] {
            let condition = RoutingCondition(type: .tag, value: value, matchType: .equals)
            XCTAssertFalse(condition.matches(document: MarkdownDocument(content: content)), value)
        }
    }

    func testInlineTagGrammarMatchesThePreview() {
        let content = "#a/b-c_d, #x\nsee https://x.io/#frag (#paren) #1984\n~~~\n#fenced\n~~~\nafter #y"
        XCTAssertEqual(MarkdownDocument.inlineTags(in: content), ["a/b-c_d", "x", "y"])
    }

    @MainActor
    func testHarvestedTagsSkipCodeAndDropLeadingHash() throws {
        let state = try makeIsolatedState()
        let document = MarkdownDocument(
            content: "#idea\n```\n#define X\n```",
            frontmatter: Frontmatter(tags: ["#work"])
        )
        state.harvestTags(from: document)
        XCTAssertEqual(state.knownTags, ["idea", "work"])
    }

    // MARK: Link-safe filenames (F147)

    func testSanitizedFilenameDropsLinkHostileCharacters() {
        XCTAssertEqual(AppState.sanitizedFilename("Invoice #42 follow-up"), "Invoice 42 follow-up")
        XCTAssertEqual(AppState.sanitizedFilename("[[Link]] ^ref"), "Link ref")
        XCTAssertEqual(AppState.sanitizedFilename("## Sub"), "Sub")
        XCTAssertEqual(AppState.sanitizedFilename("a # b"), "a b")
        XCTAssertEqual(AppState.sanitizedFilename(".hidden"), "hidden")
        XCTAssertEqual(AppState.sanitizedFilename("###"), "Untitled")
        XCTAssertEqual(AppState.sanitizedFilename("회의 메모"), "회의 메모")
        XCTAssertEqual(AppState.sanitizedFilename("a/b:c?d"), "a-b-c-d", "path-hostile characters still become hyphens")
    }

    // MARK: Routing regex budget (F064)

    func testCatastrophicRegexGivesUpWithinBudget() {
        let condition = RoutingCondition(type: .content, value: #"(\w+\s?)+:"#, matchType: .regex)
        let content = Array(repeating: "word", count: 30).joined(separator: " ") + "!"

        let start = Date()
        XCTAssertFalse(condition.matches(document: MarkdownDocument(content: content)))
        XCTAssertLessThan(Date().timeIntervalSince(start), RoutingCondition.regexTimeBudget + 1.5)
    }

    func testRegexStillMatchesAtTheEndOfALargeNote() {
        let condition = RoutingCondition(type: .content, value: #"\bTODO\b"#, matchType: .regex)
        let content = String(repeating: "lorem ipsum dolor sit amet ", count: 50_000) + "TODO"
        XCTAssertTrue(condition.matches(document: MarkdownDocument(content: content)))
    }

    // MARK: Quick Capture conflicts (F077)

    func testCaptureConflictResolutionIsNeverDestructive() {
        XCTAssertEqual(FileConflictResolution.skip.nonDestructive, .rename)
        XCTAssertEqual(FileConflictResolution.overwrite.nonDestructive, .rename)
        XCTAssertEqual(FileConflictResolution.rename.nonDestructive, .rename)
        XCTAssertEqual(FileConflictResolution.timestamp.nonDestructive, .timestamp)
    }

    @MainActor
    func testCaptureNamedLikeAnExistingNoteKeepsBoth() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        let inbox = vault.inbox
        var options = vault.options
        let existing = inbox.appendingPathComponent("TODO.md")
        try "unrelated".write(to: existing, atomically: true, encoding: .utf8)

        options.conflictResolution = FileConflictResolution.overwrite.nonDestructive
        options.injectFrontmatter = false
        let capture = MarkdownDocument(title: "TODO", content: "TODO\nbuy milk", isDraft: true)
        let outcome = try await state.sendToVault(document: capture, options: options, quiet: true)

        guard case .sent(let url) = outcome else {
            return XCTFail("expected sent, got \(outcome)")
        }
        XCTAssertEqual(url.lastPathComponent, "TODO (1).md")
        XCTAssertEqual(try read(existing), "unrelated")
        XCTAssertEqual(try read(url), "TODO\nbuy milk")
    }

    // MARK: Batch failures (F089)

    @MainActor
    func testBatchSendReportsEachFailedFile() async throws {
        let state = try makeIsolatedState()
        let vault = try makeVault()
        let (root, inbox) = (vault.root, vault.inbox)
        var options = vault.options
        let good = root.appendingPathComponent("good.md")
        try "ok".write(to: good, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("missing.md")

        options.injectFrontmatter = false
        let result = await state.sendFiles([good, missing], options: options)

        XCTAssertEqual(result.sent, 1)
        XCTAssertEqual(result.failures.map { $0.url }, [missing])
        XCTAssertFalse(result.failures.first?.message.isEmpty ?? true, "each failure carries its reason")
        XCTAssertEqual(try read(inbox.appendingPathComponent("good.md")), "ok")
    }
}
