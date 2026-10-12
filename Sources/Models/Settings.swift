import Foundation

// MARK: - Preview Settings

struct PreviewSettings: Codable, Equatable {
    var lineHeight: CGFloat = 1.6
    var headingScale: CGFloat = 1.0
    /// Empty (or the legacy "#333333" default) means "use the theme's color".
    var headingColor: String = ""
    var headingMarginTop: CGFloat = 24
    var headingMarginBottom: CGFloat = 16
    var codeBlockTheme: String = "github"
    var customCSS: String = ""
    var maxWidth: CGFloat = 800
    var fontFamily: String = "system-ui"
    var fontSize: CGFloat = 16
    /// 자간 — letter spacing in em.
    var letterSpacing: CGFloat = 0
    /// 단어 간격 — word spacing in em.
    var wordSpacing: CGFloat = 0
    /// 장평 — horizontal glyph scale (1.0 = normal). Applied via scaleX since CSS
    /// has no reflow-safe width property for non-variable fonts.
    var charWidth: CGFloat = 1.0

    /// The heading color to inject, or nil to keep the theme default. "#333333"
    /// was an old default that was never applied; honoring it now would break
    /// dark mode for existing installs, so it is treated as "unset".
    var effectiveHeadingColor: String? {
        let trimmed = headingColor.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "#333333" else { return nil }
        return trimmed
    }

    init() {}

    // Resilient decoding: any missing — or present but unreadable — key falls
    // back to its default instead of failing the whole decode (which silently
    // reset every setting whenever a field was added, removed or retyped
    // between app versions).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PreviewSettings()
        lineHeight = (try? c.decodeIfPresent(CGFloat.self, forKey: .lineHeight)) ?? d.lineHeight
        headingScale = (try? c.decodeIfPresent(CGFloat.self, forKey: .headingScale)) ?? d.headingScale
        headingColor = (try? c.decodeIfPresent(String.self, forKey: .headingColor)) ?? d.headingColor
        headingMarginTop = (try? c.decodeIfPresent(CGFloat.self, forKey: .headingMarginTop)) ?? d.headingMarginTop
        headingMarginBottom = (try? c.decodeIfPresent(CGFloat.self, forKey: .headingMarginBottom)) ?? d.headingMarginBottom
        codeBlockTheme = (try? c.decodeIfPresent(String.self, forKey: .codeBlockTheme)) ?? d.codeBlockTheme
        customCSS = (try? c.decodeIfPresent(String.self, forKey: .customCSS)) ?? d.customCSS
        maxWidth = (try? c.decodeIfPresent(CGFloat.self, forKey: .maxWidth)) ?? d.maxWidth
        fontFamily = (try? c.decodeIfPresent(String.self, forKey: .fontFamily)) ?? d.fontFamily
        fontSize = (try? c.decodeIfPresent(CGFloat.self, forKey: .fontSize)) ?? d.fontSize
        letterSpacing = (try? c.decodeIfPresent(CGFloat.self, forKey: .letterSpacing)) ?? d.letterSpacing
        wordSpacing = (try? c.decodeIfPresent(CGFloat.self, forKey: .wordSpacing)) ?? d.wordSpacing
        charWidth = (try? c.decodeIfPresent(CGFloat.self, forKey: .charWidth)) ?? d.charWidth
    }
}

// MARK: - App Settings

struct AppSettings: Codable, Equatable {
    // Appearance
    var theme: AppTheme = .system
    var editorTheme: EditorTheme = .cmds

    // Editor
    var autosaveEnabled: Bool = false
    var autosaveInterval: TimeInterval = 30
    var showLineNumbers: Bool = true
    var softWrap: Bool = true
    var fontSize: CGFloat = 14
    var fontName: String = "SF Mono"
    var tabSize: Int = 4
    var insertSpacesInsteadOfTabs: Bool = true
    var highlightCurrentLine: Bool = true
    var enableAutocompletion: Bool = true
    /// Copy a mouse-drag selection to the clipboard the moment the drag ends,
    /// so rapid successive selections each land in clipboard-history managers.
    var copySelectionOnDrag: Bool = true

    // Zoom — a multiplier applied on top of fontSize (editor) and pageZoom
    // (preview). Deliberately separate from the font-size settings so the
    // Settings sliders keep their 10–24 ranges and exports stay unscaled.
    var zoomLevel: Double = 1.0

    // Preview
    var previewTheme: String = "CMDS"
    var previewSettings: PreviewSettings = PreviewSettings()
    var enableWikiLinks: Bool = true
    var enableCallouts: Bool = true
    var enableMermaid: Bool = true
    var enableKaTeX: Bool = false
    var enablePreviewCodeHighlight: Bool = true

    // Vault & Sync
    var defaultVaultId: UUID?
    /// App-wide default destination folder for Send. Per-vault Inbox takes
    /// priority when set (see `AppState.effectiveSendFolder(for:)`); this is the
    /// fallback applied when a vault has no Inbox of its own.
    var defaultSendFolder: String = "Inbox"
    var conflictResolution: FileConflictResolution = .rename
    var injectFrontmatterByDefault: Bool = true

    // UI
    var showStatusBar: Bool = true
    var showTabBar: Bool = true
    var sidebarWidth: CGFloat = 250
    var restoreLastSession: Bool = true
    var confirmBeforeClosingDirtyTabs: Bool = true
    var scrollSyncEnabled: Bool = true

    // Diagnostics — mirror of Log's file sink (logs/ under Application Support).
    var fileLoggingEnabled: Bool = true

    // Onboarding — false until the first-run setup (appearance choice) is done.
    var hasCompletedOnboarding: Bool = false

    // Window — default launch size. Width defaults to fit the Markdown layout
    // (preview max-width + sidebar/ribbon/padding chrome ≈ 800 + 360).
    var defaultWindowWidth: CGFloat = 1160
    var defaultWindowHeight: CGFloat = 820

    // Keyboard — per-action overrides, keyed by AppShortcut.rawValue. Missing
    // entries fall back to AppShortcut.defaultBinding.
    var keyBindings: [String: KeyBinding] = [:]

    init() {}

    // Per-field fallback as in PreviewSettings: one unreadable value — say an
    // editor theme from a newer build — resets only itself. Enum raw values
    // are what's persisted, so renaming one is a format change.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = (try? c.decodeIfPresent(AppTheme.self, forKey: .theme)) ?? d.theme
        editorTheme = (try? c.decodeIfPresent(EditorTheme.self, forKey: .editorTheme)) ?? d.editorTheme
        // The palette once offered the hidden auto-variant; CMDS resolves to
        // it in light mode anyway, and the Settings picker can show only CMDS.
        if editorTheme == .cmdsLight { editorTheme = .cmds }
        autosaveEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .autosaveEnabled)) ?? d.autosaveEnabled
        autosaveInterval = (try? c.decodeIfPresent(TimeInterval.self, forKey: .autosaveInterval)) ?? d.autosaveInterval
        showLineNumbers = (try? c.decodeIfPresent(Bool.self, forKey: .showLineNumbers)) ?? d.showLineNumbers
        softWrap = (try? c.decodeIfPresent(Bool.self, forKey: .softWrap)) ?? d.softWrap
        fontSize = (try? c.decodeIfPresent(CGFloat.self, forKey: .fontSize)) ?? d.fontSize
        fontName = (try? c.decodeIfPresent(String.self, forKey: .fontName)) ?? d.fontName
        tabSize = (try? c.decodeIfPresent(Int.self, forKey: .tabSize)) ?? d.tabSize
        insertSpacesInsteadOfTabs = (try? c.decodeIfPresent(Bool.self, forKey: .insertSpacesInsteadOfTabs)) ?? d.insertSpacesInsteadOfTabs
        highlightCurrentLine = (try? c.decodeIfPresent(Bool.self, forKey: .highlightCurrentLine)) ?? d.highlightCurrentLine
        enableAutocompletion = (try? c.decodeIfPresent(Bool.self, forKey: .enableAutocompletion)) ?? d.enableAutocompletion
        copySelectionOnDrag = (try? c.decodeIfPresent(Bool.self, forKey: .copySelectionOnDrag)) ?? d.copySelectionOnDrag
        zoomLevel = (try? c.decodeIfPresent(Double.self, forKey: .zoomLevel)) ?? d.zoomLevel
        fileLoggingEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .fileLoggingEnabled)) ?? d.fileLoggingEnabled
        previewTheme = (try? c.decodeIfPresent(String.self, forKey: .previewTheme)) ?? d.previewTheme
        previewSettings = (try? c.decodeIfPresent(PreviewSettings.self, forKey: .previewSettings)) ?? d.previewSettings
        enableWikiLinks = (try? c.decodeIfPresent(Bool.self, forKey: .enableWikiLinks)) ?? d.enableWikiLinks
        enableCallouts = (try? c.decodeIfPresent(Bool.self, forKey: .enableCallouts)) ?? d.enableCallouts
        enableMermaid = (try? c.decodeIfPresent(Bool.self, forKey: .enableMermaid)) ?? d.enableMermaid
        enableKaTeX = (try? c.decodeIfPresent(Bool.self, forKey: .enableKaTeX)) ?? d.enableKaTeX
        enablePreviewCodeHighlight = (try? c.decodeIfPresent(Bool.self, forKey: .enablePreviewCodeHighlight)) ?? d.enablePreviewCodeHighlight
        defaultVaultId = (try? c.decodeIfPresent(UUID.self, forKey: .defaultVaultId)) ?? d.defaultVaultId
        defaultSendFolder = (try? c.decodeIfPresent(String.self, forKey: .defaultSendFolder)) ?? d.defaultSendFolder
        conflictResolution = (try? c.decodeIfPresent(FileConflictResolution.self, forKey: .conflictResolution)) ?? d.conflictResolution
        injectFrontmatterByDefault = (try? c.decodeIfPresent(Bool.self, forKey: .injectFrontmatterByDefault)) ?? d.injectFrontmatterByDefault
        showStatusBar = (try? c.decodeIfPresent(Bool.self, forKey: .showStatusBar)) ?? d.showStatusBar
        showTabBar = (try? c.decodeIfPresent(Bool.self, forKey: .showTabBar)) ?? d.showTabBar
        sidebarWidth = (try? c.decodeIfPresent(CGFloat.self, forKey: .sidebarWidth)) ?? d.sidebarWidth
        restoreLastSession = (try? c.decodeIfPresent(Bool.self, forKey: .restoreLastSession)) ?? d.restoreLastSession
        confirmBeforeClosingDirtyTabs = (try? c.decodeIfPresent(Bool.self, forKey: .confirmBeforeClosingDirtyTabs)) ?? d.confirmBeforeClosingDirtyTabs
        scrollSyncEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .scrollSyncEnabled)) ?? d.scrollSyncEnabled
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        defaultWindowWidth = (try? c.decodeIfPresent(CGFloat.self, forKey: .defaultWindowWidth)) ?? d.defaultWindowWidth
        defaultWindowHeight = (try? c.decodeIfPresent(CGFloat.self, forKey: .defaultWindowHeight)) ?? d.defaultWindowHeight
        // Entry by entry: an unreadable binding falls back to its default alone.
        keyBindings = (try? c.decodeIfPresent(LossyDictionary<KeyBinding>.self, forKey: .keyBindings))?.elements ?? d.keyBindings
    }
}

/// Decodes a JSON object entry by entry, skipping values that fail — the
/// keyed counterpart of `LossyList`.
private struct LossyDictionary<Value: Decodable>: Decodable {
    var elements: [String: Value] = [:]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                elements[key.stringValue] = value
            }
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
