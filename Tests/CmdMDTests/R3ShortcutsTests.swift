import XCTest
import AppKit
@testable import CmdMD

// MARK: - Recorder (G092)

final class R3ShortcutRecorderTests: XCTestCase {
    func testEscapeCancelsAndDeleteClears() {
        XCTAssertEqual(KeyBinding.recorded(keyCode: 53, characters: "\u{1b}", modifiers: []), .cancel)
        XCTAssertEqual(KeyBinding.recorded(keyCode: 51, characters: "\u{7F}", modifiers: []), .clear)
        XCTAssertEqual(KeyBinding.recorded(keyCode: 117, characters: "\u{F728}", modifiers: [.command]), .clear)
    }

    func testReturnAndTabAreStoredByName() {
        let returnKey = KeyBinding.recorded(keyCode: 36, characters: "\r", modifiers: [.command])
        XCTAssertEqual(returnKey, .binding(KeyBinding(key: "Return", command: true)))
        if case .binding(let b) = returnKey {
            XCTAssertEqual(b.displayString, "⌘↩")
            XCTAssertNotNil(b.keyEquivalent)
        }
        XCTAssertEqual(KeyBinding.recorded(keyCode: 76, characters: "\u{3}", modifiers: [.control]),
                       .binding(KeyBinding(key: "Return", control: true)))
        XCTAssertEqual(KeyBinding.recorded(keyCode: 48, characters: "\t", modifiers: [.control]),
                       .binding(KeyBinding(key: "Tab", control: true)))
    }

    func testShortcutNeedsCommandOrControl() {
        XCTAssertEqual(KeyBinding.recorded(keyCode: 17, characters: "t", modifiers: []), .rejected)
        XCTAssertEqual(KeyBinding.recorded(keyCode: 17, characters: "T", modifiers: [.shift]), .rejected)
        XCTAssertEqual(KeyBinding.recorded(keyCode: 17, characters: "t", modifiers: [.option]), .rejected)
        XCTAssertEqual(KeyBinding.recorded(keyCode: 17, characters: "t", modifiers: [.command]),
                       .binding(KeyBinding(key: "t", command: true)))
        XCTAssertEqual(KeyBinding.recorded(keyCode: 17, characters: "T", modifiers: [.command, .shift]),
                       .binding(KeyBinding(key: "t", command: true, shift: true)))
        XCTAssertEqual(KeyBinding.recorded(keyCode: 123, characters: "\u{F702}", modifiers: [.command, .control]),
                       .binding(KeyBinding(key: "ArrowLeft", command: true, control: true)))
    }

    func testFunctionAndControlCharactersAreRejected() {
        // F1 arrives as a private-use character; Home as another.
        XCTAssertEqual(KeyBinding.recorded(keyCode: 122, characters: "\u{F704}", modifiers: [.command]), .rejected)
        XCTAssertEqual(KeyBinding.recorded(keyCode: 115, characters: "\u{F729}", modifiers: [.control]), .rejected)
        XCTAssertEqual(KeyBinding.recorded(keyCode: 999, characters: nil, modifiers: [.command]), .rejected)
    }

    func testUnboundBindingIsInertAndLabelled() {
        XCTAssertTrue(KeyBinding.unbound.isUnbound)
        XCTAssertNil(KeyBinding.unbound.keyEquivalent)
        XCTAssertEqual(KeyBinding.unbound.displayString, "None")
    }
}

// MARK: - Conflicts (G026, G093)

final class R3ShortcutConflictTests: XCTestCase {
    func testFixedMenuShortcutsAreReported() {
        XCTAssertEqual(AppShortcut.omnisearch.conflict(for: KeyBinding(key: "o", command: true), overrides: [:]), "Open…")
        XCTAssertEqual(AppShortcut.toggleSidebar.conflict(for: KeyBinding(key: "b", command: true), overrides: [:]), "Bold")
        XCTAssertEqual(AppShortcut.zoomIn.conflict(for: KeyBinding(key: "q", command: true), overrides: [:]), "Quit CmdMD")
        XCTAssertEqual(AppShortcut.save.conflict(for: KeyBinding(key: "3", command: true, control: true), overrides: [:]), "Tab 3")
    }

    func testOtherActionsAreReported() {
        XCTAssertEqual(AppShortcut.saveAs.conflict(for: KeyBinding(key: "s", command: true), overrides: [:]), "Save")
        XCTAssertEqual(AppShortcut.zoomIn.conflict(for: KeyBinding(key: "p", command: true), overrides: [:]), "Command Palette")
        XCTAssertNil(AppShortcut.omnisearch.conflict(for: KeyBinding(key: "o", command: true, control: true), overrides: [:]))
    }

    func testOwnBindingIsNoConflict() {
        XCTAssertNil(AppShortcut.save.conflict(for: KeyBinding(key: "s", command: true), overrides: [:]))
    }

    func testConflictsFollowRemapsAndUnbinding() {
        let moved = [AppShortcut.save.rawValue: KeyBinding(key: "s", command: true, option: true)]
        XCTAssertNil(AppShortcut.saveAs.conflict(for: KeyBinding(key: "s", command: true), overrides: moved))
        XCTAssertEqual(AppShortcut.saveAs.conflict(for: KeyBinding(key: "s", command: true, option: true), overrides: moved), "Save")

        let cleared = [AppShortcut.save.rawValue: KeyBinding.unbound]
        XCTAssertNil(AppShortcut.saveAs.conflict(for: KeyBinding(key: "s", command: true), overrides: cleared))
        XCTAssertNil(AppShortcut.saveAs.conflict(for: .unbound, overrides: [:]))
    }

    func testSameComboComparesThePhysicalKey() {
        // The recorder stores ⇧-affected characters ("+", "}"); menus use "=", "]".
        XCTAssertTrue(KeyBinding(key: "+", command: true, shift: true).isSameCombo(as: KeyBinding(key: "=", command: true, shift: true)))
        XCTAssertTrue(KeyBinding(key: "}", command: true, shift: true).isSameCombo(as: KeyBinding(key: "]", command: true, shift: true)))
        XCTAssertTrue(KeyBinding(key: "O", command: true).isSameCombo(as: KeyBinding(key: "o", command: true)))
        XCTAssertFalse(KeyBinding(key: "o", command: true).isSameCombo(as: KeyBinding(key: "o", command: true, shift: true)))
        XCTAssertFalse(KeyBinding.unbound.isSameCombo(as: .unbound))

        guard case .binding(let nextTab) = KeyBinding.recorded(keyCode: 30, characters: "}", modifiers: [.command, .shift]) else {
            return XCTFail("⇧⌘] should record")
        }
        XCTAssertEqual(AppShortcut.save.conflict(for: nextTab, overrides: [:]), "Next Tab")
    }

    /// The defaults must not trip the recorder's own warning.
    func testNoDefaultConflictsWithAnotherDefaultOrAFixedShortcut() {
        for shortcut in AppShortcut.allCases {
            XCTAssertNil(shortcut.conflict(for: shortcut.defaultBinding, overrides: [:]), "\(shortcut)")
        }
    }

    func testZoomInAlternateMatchesOnlyCommandPlus() {
        XCTAssertTrue(KeyBinding.isZoomInAlternate(characters: "+", command: true, option: false, control: false))
        // "=" is the menu item's own key — handling it too would zoom twice.
        XCTAssertFalse(KeyBinding.isZoomInAlternate(characters: "=", command: true, option: false, control: false))
        XCTAssertFalse(KeyBinding.isZoomInAlternate(characters: "+", command: false, option: false, control: false))
        XCTAssertFalse(KeyBinding.isZoomInAlternate(characters: "+", command: true, option: true, control: false))
        XCTAssertFalse(KeyBinding.isZoomInAlternate(characters: "+", command: true, option: false, control: true))
        XCTAssertFalse(KeyBinding.isZoomInAlternate(characters: nil, command: true, option: false, control: false))
    }
}

// MARK: - Settings decoding (G041, G092, G103)

final class R3SettingsDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testOneUnreadableValueResetsOnlyItself() throws {
        let settings = try decode("""
        {"fontSize":18,"hasCompletedOnboarding":true,"editorTheme":"Solarized Light",
         "conflictResolution":"Rename with Suffix","tabSize":"4",
         "keyBindings":{"zoomIn":{"key":"=","command":true}}}
        """)
        let defaults = AppSettings()
        XCTAssertEqual(settings.fontSize, 18)
        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertEqual(settings.editorTheme, defaults.editorTheme)
        XCTAssertEqual(settings.conflictResolution, defaults.conflictResolution)
        XCTAssertEqual(settings.tabSize, defaults.tabSize)
        XCTAssertEqual(settings.keyBindings["zoomIn"], KeyBinding(key: "=", command: true))
    }

    func testPreviewSettingsFallBackPerField() throws {
        let settings = try decode(#"{"previewSettings":{"fontSize":"big","maxWidth":900}}"#)
        XCTAssertEqual(settings.previewSettings.fontSize, PreviewSettings().fontSize)
        XCTAssertEqual(settings.previewSettings.maxWidth, 900)
    }

    func testBadBindingsFallBackOneByOne() throws {
        // 1.4.8's recorder stored raw Return / F-key characters.
        let settings = try decode(#"""
        {"keyBindings":{"save":{"key":"\r","command":true},
                        "copyFilePath":{"key":"","command":true},
                        "newDraft":{"key":"n","command":true,"option":true},
                        "omnisearch":{"key":"k","command":true}}}
        """#)
        XCTAssertNil(settings.keyBindings["save"])
        XCTAssertNil(settings.keyBindings["copyFilePath"])
        XCTAssertEqual(settings.keyBindings["newDraft"], KeyBinding(key: "n", command: true, option: true))
        // Missing modifiers mean "off" instead of failing the file.
        XCTAssertEqual(settings.keyBindings["omnisearch"], KeyBinding(key: "k", command: true))
    }

    func testRemovedShortcutRoundTrips() throws {
        var settings = AppSettings()
        settings.keyBindings[AppShortcut.copyFilePath.rawValue] = .unbound
        settings.keyBindings[AppShortcut.save.rawValue] = KeyBinding(key: "Return", command: true)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.keyBindings, settings.keyBindings)
    }

    func testHiddenCMDSLightIsStoredAsCMDS() throws {
        XCTAssertEqual(try decode(#"{"editorTheme":"CMDS Light"}"#).editorTheme, .cmds)
        XCTAssertEqual(try decode(#"{"editorTheme":"Nord"}"#).editorTheme, .nord)
        // What the Settings preview now draws for CMDS in light mode.
        XCTAssertEqual(EditorTheme.cmds.resolved(forDark: false), .cmdsLight)
    }

    /// Persisted raw values are file format: renaming one resets the setting
    /// (or empties a routing rule) for anyone who saved it.
    func testPersistedRawValuesStayDecodable() {
        func assertKeeps<E: CaseIterable & RawRepresentable>(_ type: E.Type, _ frozen: [String], line: UInt = #line) where E.RawValue == String {
            let current = Set(type.allCases.map(\.rawValue))
            XCTAssertTrue(Set(frozen).isSubset(of: current), "\(type) lost \(Set(frozen).subtracting(current))", line: line)
        }
        assertKeeps(AppTheme.self, ["System", "Light", "Dark"])
        assertKeeps(EditorTheme.self, ["One Dark", "Dracula", "GitHub", "Nord", "Tokyo Night", "Gruvbox",
                                       "Solarized Dark", "Material Dark", "CMDS", "CMDS Light"])
        assertKeeps(FileConflictResolution.self, ["Rename with suffix", "Add timestamp", "Overwrite", "Skip"])
        assertKeeps(SendAction.self, ["Copy", "Move"])
        assertKeeps(RoutingCondition.ConditionType.self, ["Tag", "Frontmatter Key", "Filename Prefix",
                                                          "Filename Suffix", "Source Device", "Content"])
        assertKeeps(RoutingCondition.MatchType.self, ["Equals", "Contains", "Starts With", "Ends With", "Regex"])
        assertKeeps(ViewMode.self, ["Source", "Split", "Preview"])
    }
}

// MARK: - Omnisearch content hits (G035) and announcements (G119)

final class R3OmnisearchTests: XCTestCase {
    private func result(_ path: String, line: Int = 12, text: String = "  match here") -> SearchResult {
        SearchResult(fileURL: URL(fileURLWithPath: path), lineNumber: line, lineContent: text,
                     matchRange: text.startIndex..<text.endIndex)
    }

    func testSameNamedNotesShowTheirFolders() {
        let root = URL(fileURLWithPath: "/v", isDirectory: true)
        let hits = OmnisearchView.contentHits(
            results: [result("/v/Daily/A/index.md"), result("/v/B/index.md"), result("/v/top.md", line: 3)],
            roots: [root]
        )
        XCTAssertEqual(hits.map(\.title), ["index", "index", "top"])
        XCTAssertEqual(hits[0].subtitle, "Daily/A · L12  match here")
        XCTAssertEqual(hits[1].subtitle, "B · L12  match here")
        XCTAssertEqual(hits[2].subtitle, "v · L3  match here")
        XCTAssertEqual(Set(hits.map(\.id)).count, 3)
    }

    func testFolderOutsideEveryRootUsesItsName() {
        XCTAssertEqual(OmnisearchView.folderLabel(for: URL(fileURLWithPath: "/elsewhere/Notes/x.md"),
                                                  roots: [URL(fileURLWithPath: "/v")]), "Notes")
        // A sibling whose name merely starts with the root's is not inside it.
        XCTAssertEqual(OmnisearchView.folderLabel(for: URL(fileURLWithPath: "/vault2/x.md"),
                                                  roots: [URL(fileURLWithPath: "/vault")]), "vault2")
    }

    func testResultsAnnouncement() {
        XCTAssertEqual(VoiceOverAnnouncement.results([]), "No matches")
        XCTAssertEqual(VoiceOverAnnouncement.results(["Save"]), "1 result, Save")
        XCTAssertEqual(VoiceOverAnnouncement.results(["Export as HTML", "Export as PDF"]), "2 results, Export as HTML")
    }
}

// MARK: - AppState: hints, overlays, ⌘+ (G025, G027, G079, G131, G103, G119)

/// AppStates here read and write a throwaway CMDMD_DATA_DIR, never the real
/// Application Support/CmdMD.
final class R3ShortcutAppStateTests: XCTestCase {
    private var sandbox: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdmd-r3-shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        previousDataDir = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        setenv("CMDMD_DATA_DIR", sandbox.path, 1)
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

    private func paletteHint(_ title: String, in state: AppState) -> String? {
        Command.allCommands(appState: state).first { $0.title == title }?.shortcut
    }

    func testPaletteHintsFollowRemaps() {
        let state = AppState()
        let rows: [(String, AppShortcut)] = [
            ("New Draft", .newDraft), ("Open Folder", .openFolder), ("Omnisearch", .omnisearch),
            ("Save", .save), ("Reload from Disk", .reloadFromDisk), ("Quick Capture", .quickCapture),
            ("Send to Vault", .sendToVault), ("Auto-Route Send", .autoRoute), ("Source View", .sourceMode),
            ("Split View", .splitMode), ("Preview", .previewMode), ("Toggle Sidebar", .toggleSidebar),
            ("Toggle Inspector", .toggleInspector), ("Zoom In", .zoomIn), ("Zoom Out", .zoomOut),
            ("Actual Size", .resetZoom),
        ]
        for (title, shortcut) in rows {
            XCTAssertEqual(paletteHint(title, in: state), shortcut.defaultBinding.displayString, title)
        }

        state.settings.keyBindings[AppShortcut.sendToVault.rawValue] = KeyBinding(key: "s", command: true, option: true)
        state.settings.keyBindings[AppShortcut.previewMode.rawValue] = KeyBinding(key: "p", command: true, control: true)
        state.settings.keyBindings[AppShortcut.newDraft.rawValue] = .unbound
        XCTAssertEqual(paletteHint("Send to Vault", in: state), "⌥⌘S")
        XCTAssertEqual(paletteHint("Preview", in: state), "⌃⌘P")
        XCTAssertNil(paletteHint("New Draft", in: state))
    }

    func testHelpTextFollowsRemaps() {
        let state = AppState()
        XCTAssertEqual(state.shortcutHelp("Open Folder", .openFolder), "Open Folder (⌥⌘O)")
        XCTAssertEqual(state.shortcutHelp("Change view mode", .sourceMode, .splitMode, .previewMode),
                       "Change view mode (⌘1 / ⌘2 / ⌘3)")

        state.settings.keyBindings[AppShortcut.openFolder.rawValue] = KeyBinding(key: "o", command: true, control: true)
        state.settings.keyBindings[AppShortcut.splitMode.rawValue] = .unbound
        XCTAssertEqual(state.shortcutHelp("Open Folder", .openFolder), "Open Folder (⌃⌘O)")
        XCTAssertEqual(state.shortcutHelp("Change view mode", .sourceMode, .splitMode, .previewMode),
                       "Change view mode (⌘1 / ⌘3)")
        XCTAssertNil(state.shortcutHint(for: .splitMode))
        XCTAssertEqual(state.shortcutHelp("Split", .splitMode), "Split")
    }

    func testPaletteOffersOnlyPickerThemes() {
        let titles = Command.allCommands(appState: AppState()).map(\.title)
        XCTAssertTrue(titles.contains("Editor Theme: CMDS"))
        XCTAssertFalse(titles.contains("Editor Theme: CMDS Light"))
    }

    func testPaletteAndOmnisearchAreExclusive() {
        let state = AppState()
        state.showCommandPalette = true
        state.showOmnisearch = true
        XCTAssertFalse(state.showCommandPalette)
        XCTAssertTrue(state.showOmnisearch)

        state.showCommandPalette = true
        XCTAssertFalse(state.showOmnisearch)

        // Closing one never reopens the other.
        state.showCommandPalette = false
        XCTAssertFalse(state.showOmnisearch)
    }

    func testCommandPlusZoomsOnlyWhileZoomInKeepsItsDefault() {
        let state = AppState()
        XCTAssertTrue(state.acceptsZoomInAlternate)

        state.recordingShortcut = .save
        XCTAssertFalse(state.acceptsZoomInAlternate, "the recorder gets ⇧⌘= first")
        state.recordingShortcut = nil

        state.settings.keyBindings[AppShortcut.zoomIn.rawValue] = KeyBinding(key: "i", command: true, control: true)
        XCTAssertFalse(state.acceptsZoomInAlternate)
        state.settings.keyBindings[AppShortcut.zoomIn.rawValue] = .unbound
        XCTAssertFalse(state.acceptsZoomInAlternate)
        state.settings.keyBindings[AppShortcut.zoomIn.rawValue] = nil

        // An action bound to "+" itself owns the key.
        state.settings.keyBindings[AppShortcut.resetZoom.rawValue] = KeyBinding(key: "+", command: true, shift: true)
        XCTAssertFalse(state.acceptsZoomInAlternate)
    }
}
