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
            
            VaultSettingsView()
                .tabItem {
                    Label("Vaults", systemImage: "folder")
                }
            
            SyncSettingsView()
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

            RemoteControlSettingsView()
                .tabItem {
                    Label("Remote", systemImage: "antenna.radiowaves.left.and.right")
                }
        }
        .frame(width: 500, height: 450)
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
            }
            
            Section("Default Vault") {
                Picker("Default vault for Send", selection: Binding(
                    get: { appState.settings.defaultVaultId },
                    set: { appState.settings.defaultVaultId = $0 }
                )) {
                    Text("None").tag(nil as UUID?)
                    ForEach(appState.vaults) { vault in
                        Text(vault.displayName).tag(vault.id as UUID?)
                    }
                }
                
                Picker("File conflict resolution", selection: $state.settings.conflictResolution) {
                    ForEach(FileConflictResolution.allCases, id: \.self) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                
                Toggle("Inject frontmatter by default", isOn: $state.settings.injectFrontmatterByDefault)
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
                    ForEach(EditorTheme.allCases, id: \.self) { theme in
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
                Toggle("Show invisibles (tabs, spaces)", isOn: $state.settings.showInvisibles)
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
                Toggle("Use spaces instead of tabs", isOn: $state.settings.insertSpacesInsteadOfTabs)
            }
            
            Section("Editing") {
                Toggle("Enable autocompletion", isOn: $state.settings.enableAutocompletion)
                Toggle("Bracket matching", isOn: $state.settings.bracketMatching)
            }
            
            Section("Interface") {
                Toggle("Show tab bar", isOn: $state.settings.showTabBar)
                Toggle("Show status bar", isOn: $state.settings.showStatusBar)
                Toggle("Restore last session on launch", isOn: $state.settings.restoreLastSession)
                Toggle("Confirm before closing dirty tabs", isOn: $state.settings.confirmBeforeClosingDirtyTabs)
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
            Text("[Link](url)")
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
            
            Section("Obsidian Compatibility") {
                Toggle("Enable wiki links [[...]]", isOn: $state.settings.enableWikiLinks)
                Toggle("Enable callouts > [!...]", isOn: $state.settings.enableCallouts)
                Toggle("Enable Mermaid diagrams", isOn: $state.settings.enableMermaid)
                Toggle("Enable KaTeX math", isOn: $state.settings.enableKaTeX)
            }
            
            Section("Custom CSS") {
                TextEditor(text: $state.settings.previewSettings.customCSS)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                
                Text("Add custom CSS to override preview styles")
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
    
    var body: some View {
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
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                            
                            Text(vault.rootPath.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    Text("Registered Vaults")
                    Spacer()
                    Button("Add Vault") {
                        showAddVault = true
                    }
                }
            }
            
            if appState.vaults.isEmpty {
                ContentUnavailableView("No Vaults", systemImage: "folder.badge.plus", description: Text("Add an Obsidian vault to get started"))
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddVault) {
            AddVaultSheet()
        }
    }
}

struct SyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var iCloudStatus: String = "Checking..."
    
    var body: some View {
        @Bindable var state = appState
        
        Form {
            Section("iCloud") {
                LabeledContent("Status") {
                    Text(iCloudStatus)
                        .foregroundStyle(iCloudStatus == "Available" ? .green : .secondary)
                }
                
                Toggle("Enable cloud sync for drafts", isOn: $state.settings.cloudSyncEnabled)
                    .disabled(iCloudStatus != "Available")
            }
            
            Section("About Sync") {
                Text("When enabled, drafts will sync between your Mac and iPhone using iCloud. Your Markdown files remain local and are not uploaded to any cloud service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await checkiCloudStatus()
        }
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }
    
    private func checkiCloudStatus() async {
        let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        await MainActor.run {
            iCloudStatus = container != nil ? "Available" : "Not available"
        }
    }
}

struct RemoteControlSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Server") {
                Toggle("Enable remote control", isOn: $state.settings.remoteControlEnabled)

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $state.settings.remoteControlPort, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                .disabled(!appState.settings.remoteControlEnabled)

                HStack {
                    Text("API Key")
                    Spacer()
                    SecureField("Optional", text: $state.settings.remoteControlApiKey)
                        .frame(width: 180)
                        .multilineTextAlignment(.trailing)
                }
                .disabled(!appState.settings.remoteControlEnabled)

                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.remoteControlService.isRunning ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text(appState.remoteControlService.isRunning ? "Running on port \(appState.settings.remoteControlPort)" : "Stopped")
                            .foregroundStyle(appState.remoteControlService.isRunning ? .primary : .secondary)
                    }
                }

                if appState.settings.remoteControlEnabled {
                    Button(appState.remoteControlService.isRunning ? "Restart Server" : "Start Server") {
                        appState.restartRemoteControl()
                    }
                }
            }

            Section("Recent Requests") {
                if appState.remoteControlService.recentRequests.isEmpty {
                    Text("No requests yet")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(appState.remoteControlService.recentRequests.prefix(10)) { entry in
                        HStack {
                            Text(entry.method)
                                .font(.system(size: 10, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundStyle(entry.statusCode < 400 ? .green : .red)
                                .frame(width: 45, alignment: .leading)
                            Text(entry.path)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text("\(entry.statusCode)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(entry.statusCode < 400 ? .secondary : .red)
                        }
                    }
                }
            }

            Section("About") {
                Text("Remote control exposes a local HTTP API on the configured port, allowing external tools and scripts to read and modify documents, manage tabs, and control the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.settings.remoteControlEnabled) { _, enabled in
            if enabled {
                appState.startRemoteControl()
            } else {
                appState.stopRemoteControl()
            }
            appState.saveUserData()
        }
        .onChange(of: appState.settings.remoteControlPort) { _, _ in
            appState.saveUserData()
        }
        .onChange(of: appState.settings.remoteControlApiKey) { _, _ in
            appState.saveUserData()
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
