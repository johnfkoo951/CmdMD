import XCTest
@testable import CmdMD

final class VaultPipelineTests: XCTestCase {
    // MARK: Templates

    func testTemplateFilenamePlaceholders() {
        let template = VaultTemplate(name: "Daily", filenamePattern: "{{date}} {{title}}")
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 6, day: 12, hour: 9, minute: 30).date!

        XCTAssertEqual(template.generateFilename(title: "Standup", date: date), "2026-06-12 Standup")
    }

    func testTemplateEmptyPatternFallsBackToTitle() {
        let template = VaultTemplate(name: "T", filenamePattern: "")
        XCTAssertEqual(template.generateFilename(title: "Note"), "Note")
    }

    func testTemplateContentPlaceholderReceivesBody() {
        let template = VaultTemplate(name: "Wrap", content: "## Context\n\n{{content}}\n\n## Next")
        let document = MarkdownDocument(title: "X", content: "the body")

        let rendered = template.renderContent(for: document)
        XCTAssertTrue(rendered.contains("## Context\n\nthe body\n\n## Next"))
    }

    func testTemplateWithoutContentPlaceholderAppendsBody() {
        let template = VaultTemplate(name: "Header only", content: "# {{title}}")
        let document = MarkdownDocument(title: "My Note", content: "body text")

        let rendered = template.renderContent(for: document)
        XCTAssertTrue(rendered.hasPrefix("# My Note"))
        XCTAssertTrue(rendered.hasSuffix("body text"), "user content must never be dropped by a template")
    }

    func testEmptyTemplateContentPassesBodyThrough() {
        let template = VaultTemplate(name: "Empty")
        let document = MarkdownDocument(title: "X", content: "unchanged")
        XCTAssertEqual(template.renderContent(for: document), "unchanged")
    }

    // MARK: Routing conditions

    func testTagConditionMatchesFrontmatterTags() {
        let condition = RoutingCondition(type: .tag, value: "meeting", matchType: .equals)
        let frontmatter = Frontmatter(tags: ["Meeting", "work"])
        let document = MarkdownDocument(title: "X", content: "", frontmatter: frontmatter)

        XCTAssertTrue(condition.matches(document: document))
    }

    func testContentRegexCondition() {
        let condition = RoutingCondition(type: .content, value: #"\bTODO\b"#, matchType: .regex)
        XCTAssertTrue(condition.matches(document: MarkdownDocument(content: "a TODO item")))
        XCTAssertFalse(condition.matches(document: MarkdownDocument(content: "TODOS are different")))
    }

    func testFilenamePrefixCondition() {
        let condition = RoutingCondition(type: .filenamePrefix, value: "2026-", matchType: .startsWith)
        let url = URL(fileURLWithPath: "/tmp/2026-06-12 note.md")
        XCTAssertTrue(condition.matches(document: MarkdownDocument(title: "x", content: "", fileURL: url)))
    }

    // MARK: Obsidian URLs

    func testObsidianURLUsesFolderNameNotAlias() throws {
        let vault = Vault(name: "My Pretty Alias", rootPath: URL(fileURLWithPath: "/Users/x/Vaults/RealFolder"))
        let url = try XCTUnwrap(vault.obsidianURL())
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "vault" })?.value, "RealFolder")
    }

    // MARK: Send-folder resolution (global default + per-vault priority)

    func testSendFolderPrefersVaultInboxWhenSet() {
        XCTAssertEqual(
            AppState.resolveSendFolder(vaultInbox: "Daily", globalDefault: "00 Inbox"),
            "Daily",
            "an explicit per-vault Inbox must win over the global default"
        )
    }

    func testSendFolderFallsBackToGlobalWhenVaultInboxEmpty() {
        XCTAssertEqual(
            AppState.resolveSendFolder(vaultInbox: "", globalDefault: "00 Inbox"),
            "00 Inbox",
            "an empty vault Inbox must fall back to the app-wide default send folder"
        )
    }

    func testSendFolderUltimateFallbackIsInbox() {
        XCTAssertEqual(AppState.resolveSendFolder(vaultInbox: "   ", globalDefault: ""), "Inbox")
    }

    func testVaultDefaultsToEmptyInboxSoGlobalApplies() {
        let vault = Vault(name: "V", rootPath: URL(fileURLWithPath: "/tmp/V"))
        XCTAssertEqual(vault.inboxPath, "", "new vaults default to the global send folder")
    }

    func testDefaultSendFolderSurvivesSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.defaultSendFolder = "10 Notes"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.defaultSendFolder, "10 Notes")
    }

    // MARK: Filename sanitizing & uniquifying

    func testSanitizedFilenameStripsPathHostileCharacters() {
        XCTAssertEqual(AppState.sanitizedFilename("a/b:c?d"), "a-b-c-d")
        XCTAssertEqual(AppState.sanitizedFilename("   "), "Untitled")
    }

    func testUniquifiedAvoidsClobberingExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("Untitled.md")
        try "existing content".write(to: original, atomically: true, encoding: .utf8)

        let unique = original.uniquified()
        XCTAssertEqual(unique.lastPathComponent, "Untitled (1).md")
        XCTAssertNotEqual(unique, original, "creating a new file must never reuse an occupied name")
    }
}
