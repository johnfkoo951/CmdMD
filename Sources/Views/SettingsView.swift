import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            EditorSettingsView()
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }

            PreviewSettingsView()
                .tabItem {
                    Label("Preview", systemImage: "eye")
                }

            ShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            VaultSettingsView()
                .tabItem {
                    Label("Vaults", systemImage: "folder")
                }
        }
        .frame(width: 560, height: 500)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Appearance") {
                Picker("Theme", selection: $state.settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            }

            Section("Saving") {
                Toggle("Autosave", isOn: $state.settings.autosaveEnabled)

                if appState.settings.autosaveEnabled {
                    Picker("Autosave interval", selection: $state.settings.autosaveInterval) {
                        Text("10 seconds").tag(TimeInterval(10))
                        Text("30 seconds").tag(TimeInterval(30))
                        Text("1 minute").tag(TimeInterval(60))
                        Text("5 minutes").tag(TimeInterval(300))
                    }
                }

                Toggle("Confirm before closing unsaved tabs", isOn: $state.settings.confirmBeforeClosingDirtyTabs)
            }

            Section {
                HStack {
                    Text("Default width")
                    Slider(value: $state.settings.defaultWindowWidth, in: 720...2000, step: 20)
                    Text("\(Int(appState.settings.defaultWindowWidth)) px")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("Default height")
                    Slider(value: $state.settings.defaultWindowHeight, in: 480...1400, step: 20)
                    Text("\(Int(appState.settings.defaultWindowHeight)) px")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                Button("Fit to Markdown layout") {
                    // Preview column (max-width) + sidebar + ribbon + padding chrome.
                    state.settings.defaultWindowWidth = appState.settings.previewSettings.maxWidth + 360
                }
            } header: {
                Text("Window")
            } footer: {
                Text("Sets the launch size and resizes the current window. “Fit to Markdown layout” matches the preview’s max-width.")
                    .font(.caption)
            }

            Section("Session") {
                Toggle("Restore last session on launch", isOn: $state.settings.restoreLastSession)

                Text("Reopens the files, folder, and view mode from your previous session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Drafts") {
                LabeledContent("Storage") {
                    Text("\(appState.drafts.count) drafts, stored locally")
                        .foregroundStyle(.secondary)
                }

                Text("Drafts live in Application Support and persist across launches. Your Markdown files are never uploaded anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: AppInfo.versionLabel)
                LabeledContent("Made by", value: AppInfo.maker)
                Link(destination: AppInfo.website) {
                    Label("cmdspace.work", systemImage: "globe")
                }
                Link(destination: AppInfo.github) {
                    Label("GitHub repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button("About CmdMD…") { appState.showAbout = true }
            } header: {
                Text("About")
            } footer: {
                Text("CmdMD · © 2026 CMDSPACE · MIT License")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }
}

struct EditorSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Theme") {
                Picker("Editor theme", selection: $state.settings.editorTheme) {
                    ForEach(EditorTheme.selectableCases, id: \.self) { theme in
                        HStack {
                            Circle()
                                .fill(theme.backgroundColor)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                            Text(theme.rawValue)
                        }
                        .tag(theme)
                    }
                }

                EditorThemePreview(theme: appState.settings.editorTheme)
            }

            Section("Display") {
                Toggle("Show line numbers", isOn: $state.settings.showLineNumbers)
                Toggle("Soft wrap", isOn: $state.settings.softWrap)
                Toggle("Highlight current line", isOn: $state.settings.highlightCurrentLine)
            }

            Section("Font") {
                Picker("Font", selection: $state.settings.fontName) {
                    Text("SF Mono").tag("SF Mono")
                    Text("Menlo").tag("Menlo")
                    Text("Monaco").tag("Monaco")
                    Text("Courier New").tag("Courier New")
                    Text("JetBrains Mono").tag("JetBrains Mono")
                    Text("Fira Code").tag("Fira Code")
                }

                HStack {
                    Text("Size")
                    Slider(value: $state.settings.fontSize, in: 10...24, step: 1)
                    Text("\(Int(appState.settings.fontSize)) pt")
                        .frame(width: 50)
                }

                Stepper("Tab size: \(appState.settings.tabSize)", value: $state.settings.tabSize, in: 2...8)
                Toggle("Insert spaces when pressing Tab", isOn: $state.settings.insertSpacesInsteadOfTabs)
            }

            Section("Editing") {
                Toggle("Wiki-link and tag autocompletion", isOn: $state.settings.enableAutocompletion)

                Text("Type [[ to complete note names from your open folder and vaults, # to complete known tags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Interface") {
                Toggle("Show tab bar", isOn: $state.settings.showTabBar)
                Toggle("Show status bar", isOn: $state.settings.showStatusBar)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }
}

struct EditorThemePreview: View {
    let theme: EditorTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("# Heading")
                .foregroundColor(theme.headingColor)
            Text("Normal text with **bold** and *italic*")
                .foregroundColor(theme.textColor)
            Text("// Comment")
                .foregroundColor(theme.commentColor)
            Text("\"String value\"")
                .foregroundColor(theme.stringColor)
            Text("[Link](url) and [[Wiki Link]]")
                .foregroundColor(theme.linkColor)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.backgroundColor)
        .cornerRadius(6)
    }
}

struct PreviewSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Theme") {
                Picker("Preview theme", selection: $state.settings.previewTheme) {
                    ForEach(PreviewTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme.rawValue)
                    }
                }
            }

            Section("Typography") {
                HStack {
                    Text("Line height")
                    Slider(value: $state.settings.previewSettings.lineHeight, in: 1.2...2.4, step: 0.1)
                    Text(String(format: "%.1f", appState.settings.previewSettings.lineHeight))
                        .frame(width: 40)
                }

                HStack {
                    Text("Font size")
                    Slider(value: $state.settings.previewSettings.fontSize, in: 12...24, step: 1)
                    Text("\(Int(appState.settings.previewSettings.fontSize)) px")
                        .frame(width: 50)
                }

                HStack {
                    Text("Max width")
                    Slider(value: $state.settings.previewSettings.maxWidth, in: 600...1200, step: 50)
                    Text("\(Int(appState.settings.previewSettings.maxWidth)) px")
                        .frame(width: 60)
                }

                Picker("Font family", selection: $state.settings.previewSettings.fontFamily) {
                    Text("System UI").tag("system-ui")
                    Text("Georgia").tag("Georgia, serif")
                    Text("Times New Roman").tag("Times New Roman, serif")
                    Text("Inter").tag("Inter, sans-serif")
                    Text("SF Pro Text").tag("SF Pro Text, sans-serif")
                }

                HStack {
                    Text("Letter spacing (자간)")
                    Slider(value: $state.settings.previewSettings.letterSpacing, in: -0.05...0.3, step: 0.01)
                    Text(String(format: "%.2f em", appState.settings.previewSettings.letterSpacing))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }

                HStack {
                    Text("Character width (장평)")
                    Slider(value: $state.settings.previewSettings.charWidth, in: 0.8...1.2, step: 0.01)
                    Text(String(format: "%.0f%%", appState.settings.previewSettings.charWidth * 100))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }

                HStack {
                    Text("Word spacing (단어 간격)")
                    Slider(value: $state.settings.previewSettings.wordSpacing, in: 0...1, step: 0.05)
                    Text(String(format: "%.2f em", appState.settings.previewSettings.wordSpacing))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }

            Section("Headings") {
                HStack {
                    Text("Scale")
                    Slider(value: $state.settings.previewSettings.headingScale, in: 0.8...1.5, step: 0.1)
                    Text(String(format: "%.1fx", appState.settings.previewSettings.headingScale))
                        .frame(width: 40)
                }

                HStack {
                    Text("Top margin")
                    Slider(value: $state.settings.previewSettings.headingMarginTop, in: 12...48, step: 4)
                    Text("\(Int(appState.settings.previewSettings.headingMarginTop)) px")
                        .frame(width: 50)
                }
            }

            Section("Code Blocks") {
                Toggle("Syntax highlighting in preview", isOn: $state.settings.enablePreviewCodeHighlight)

                if appState.settings.enablePreviewCodeHighlight {
                    Picker("Highlight theme", selection: $state.settings.previewSettings.codeBlockTheme) {
                        Text("GitHub (auto light/dark)").tag("github")
                        Text("Atom One Dark").tag("atom-one-dark")
                        Text("Atom One Light").tag("atom-one-light")
                        Text("Monokai").tag("monokai")
                        Text("Nord").tag("nord")
                        Text("Tokyo Night Dark").tag("tokyo-night-dark")
                    }
                }
            }

            Section("Obsidian Compatibility") {
                Toggle("Wiki links [[...]] and #tags", isOn: $state.settings.enableWikiLinks)
                Toggle("Callouts > [!note]", isOn: $state.settings.enableCallouts)
                Toggle("Mermaid diagrams", isOn: $state.settings.enableMermaid)
                Toggle("KaTeX math ($...$, $$...$$)", isOn: $state.settings.enableKaTeX)

                Text("Mermaid, KaTeX, and code highlighting load from a CDN — they degrade gracefully when offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom CSS") {
                TextEditor(text: $state.settings.previewSettings.customCSS)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )

                Text("Injected after the theme styles — overrides anything above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }
}

struct VaultSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddVault = false
    @State private var defaultVaultFolders: [String] = []

    var body: some View {
        @Bindable var state = appState

        Form {
            Section {
                ForEach(appState.vaults) { vault in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(vault.displayName)
                                    .font(.headline)

                                if vault.id == appState.settings.defaultVaultId {
                                    Text("Default")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.cmdsAccent.opacity(0.18))
                                        .foregroundStyle(Color.cmdsAccent)
                                        .clipShape(Capsule())
                                }
                            }

                            Text(vault.rootPath.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            appState.removeVault(vault)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Connected Vaults")
                    Spacer()
                    Button("Add Vault…") {
                        showAddVault = true
                    }
                }
            }

            if appState.vaults.isEmpty {
                ContentUnavailableView("No Vaults", systemImage: "folder.badge.plus", description: Text("Connect an Obsidian vault to get started"))
            }

            Section {
                Picker("Default vault for Send", selection: Binding(
                    get: { appState.settings.defaultVaultId },
                    set: { appState.settings.defaultVaultId = $0; loadDefaultVaultFolders() }
                )) {
                    Text("None").tag(nil as UUID?)
                    ForEach(appState.vaults) { vault in
                        Text(vault.displayName).tag(vault.id as UUID?)
                    }
                }

                // App-wide default send folder. Type any name (created on send if
                // missing), or pick from the default vault's existing folders.
                LabeledContent("Default send folder") {
                    HStack(spacing: 6) {
                        TextField("Default send folder", text: $state.settings.defaultSendFolder, prompt: Text("Inbox"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        if !defaultVaultFolders.isEmpty {
                            Menu {
                                ForEach(defaultVaultFolders, id: \.self) { folder in
                                    Button(folder) { state.settings.defaultSendFolder = folder }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }

                Picker("File conflict resolution", selection: $state.settings.conflictResolution) {
                    ForEach(FileConflictResolution.allCases, id: \.self) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }

                Toggle("Inject frontmatter by default", isOn: $state.settings.injectFrontmatterByDefault)
            } header: {
                Text("Sending")
            } footer: {
                Text("Per-vault Inbox folders take priority over the default send folder.")
                    .font(.caption)
            }

            Section {
                Button("Manage Vaults, Templates & Rules…") {
                    appState.showVaultManager = true
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddVault) {
            AddVaultSheet()
        }
        .onAppear { loadDefaultVaultFolders() }
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }

    /// Loads the default vault's folders so the default-send-folder picker shows
    /// real destinations. Falls back to a free-text field when none load.
    private func loadDefaultVaultFolders() {
        guard let vault = appState.defaultVault else {
            defaultVaultFolders = []
            return
        }
        let vaultService = VaultService(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD"))
        Task {
            var folders = (try? await vaultService.listFolders(in: vault)) ?? []
            let current = appState.settings.defaultSendFolder
            if !current.isEmpty, !folders.contains(current) { folders.insert(current, at: 0) }
            if !folders.contains("Inbox") { folders.insert("Inbox", at: 0) }
            await MainActor.run { defaultVaultFolders = folders }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                ForEach(AppShortcut.allCases) { shortcut in
                    ShortcutRow(shortcut: shortcut)
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new key combination. Defaults mirror your Obsidian vault where possible. Press ⎋ to cancel.")
                    .font(.caption)
            }

            Section {
                Button("Reset all to defaults", role: .destructive) {
                    appState.settings.keyBindings = [:]
                    appState.saveUserData()
                }
                .disabled(appState.settings.keyBindings.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRow: View {
    @Environment(AppState.self) private var appState
    let shortcut: AppShortcut

    @State private var recording = false
    @State private var monitor: Any?

    private var binding: KeyBinding { appState.keyBinding(for: shortcut) }
    private var isCustom: Bool { appState.settings.keyBindings[shortcut.rawValue] != nil }

    var body: some View {
        HStack {
            Text(shortcut.title)
            Spacer()
            Button(recording ? "Press keys…" : binding.displayString) {
                toggleRecord()
            }
            .monospaced()
            .foregroundStyle(recording ? Color.cmdsAccent : .primary)
            .frame(minWidth: 96)

            Button {
                reset()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
            .opacity(isCustom ? 1 : 0)
            .disabled(!isCustom)
        }
        .onDisappear { stop() }
    }

    private func toggleRecord() {
        if recording { stop(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
            return nil   // swallow while recording
        }
    }

    private func capture(_ event: NSEvent) {
        defer { stop() }
        if event.keyCode == 53 { return }   // Escape cancels

        let flags = event.modifierFlags
        let key: String
        switch event.keyCode {
        case 123: key = "ArrowLeft"
        case 124: key = "ArrowRight"
        case 126: key = "ArrowUp"
        case 125: key = "ArrowDown"
        case 49:  key = "Space"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  chars.count == 1 else { return }
            key = chars
        }

        var b = KeyBinding(key: key)
        b.command = flags.contains(.command)
        b.shift = flags.contains(.shift)
        b.option = flags.contains(.option)
        b.control = flags.contains(.control)

        appState.settings.keyBindings[shortcut.rawValue] = b
        appState.saveUserData()
    }

    private func reset() {
        appState.settings.keyBindings[shortcut.rawValue] = nil
        appState.saveUserData()
    }

    private func stop() {
        recording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    SettingsView()
        .environment(AppState())
}
#endif
