import SwiftUI

/// Unified manager for everything Send-related: vault connections, content
/// templates, and routing rules. (Templates and rules existed as persisted
/// models for a long time but had no UI and were never evaluated — both are
/// now live.)
struct VaultManagerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum ManagerSection: String, CaseIterable {
        case vaults = "Vaults"
        case templates = "Templates"
        case rules = "Routing Rules"

        var icon: String {
            switch self {
            case .vaults: return "folder"
            case .templates: return "doc.on.doc"
            case .rules: return "arrow.triangle.branch"
            }
        }
    }

    @State private var section: ManagerSection = .vaults

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $section) {
                    ForEach(ManagerSection.allCases, id: \.self) { section in
                        Label(section.rawValue, systemImage: section.icon).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 400)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(.bar)

            Divider()

            switch section {
            case .vaults:
                VaultsManagerPane()
            case .templates:
                TemplatesManagerPane()
            case .rules:
                RulesManagerPane()
            }
        }
        .frame(width: 760, height: 540)
        .tint(.cmdsAccent)
    }
}

// MARK: - Vaults

struct VaultsManagerPane: View {
    @Environment(AppState.self) private var appState
    @State private var selectedVault: Vault?
    @State private var isAddingVault = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedVault) {
                    ForEach(appState.vaults) { vault in
                        VaultListRow(vault: vault)
                            .tag(vault)
                    }
                }
                .listStyle(.inset)

                Divider()

                HStack {
                    Button {
                        isAddingVault = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add Vault")

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 260)

            Group {
                if let vault = selectedVault, appState.vaults.contains(where: { $0.id == vault.id }) {
                    VaultDetailView(vault: vault)
                } else {
                    ContentUnavailableView(
                        "Select a Vault",
                        systemImage: "folder",
                        description: Text("Choose a vault from the list or add a new one")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $isAddingVault) {
            AddVaultSheet()
        }
    }
}

struct VaultListRow: View {
    @Environment(AppState.self) private var appState
    let vault: Vault

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(vault.displayName)
                    .font(.headline)

                if vault.id == appState.settings.defaultVaultId {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }

            Text(vault.rootPath.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct VaultDetailView: View {
    @Environment(AppState.self) private var appState
    let vault: Vault

    @State private var editedName: String = ""
    @State private var editedInboxPath: String = ""
    @State private var isDefault: Bool = false
    @State private var availableFolders: [String] = []
    @State private var noteCount: Int?
    @State private var confirmingDisconnect = false

    private var isObsidianVault: Bool {
        ObsidianLocator.isObsidianVault(vault.rootPath)
    }

    var body: some View {
        Form {
            Section {
                // Header card: brand mark + name + at-a-glance status.
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Color.cmdsAccent, Color.cmdsAccent.opacity(0.65)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "shippingbox.fill").foregroundStyle(.white))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(vault.displayName)
                            .font(.headline)
                        HStack(spacing: 8) {
                            if isObsidianVault {
                                Label("Obsidian", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(Color.cmdsAccent)
                            }
                            if let noteCount {
                                Label("\(noteCount) notes", systemImage: "doc.text")
                                    .foregroundStyle(.secondary)
                            }
                            if vault.id == appState.settings.defaultVaultId {
                                Label("Default", systemImage: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .font(.caption)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("General") {
                TextField("Name", text: $editedName)

                LabeledContent("Path") {
                    Text(vault.rootPath.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Toggle("Default Vault", isOn: $isDefault)
                    .onChange(of: isDefault) { _, newValue in
                        if newValue {
                            appState.settings.defaultVaultId = vault.id
                            appState.saveUserData()
                        } else if appState.settings.defaultVaultId == vault.id {
                            appState.settings.defaultVaultId = nil
                            appState.saveUserData()
                        }
                    }
            }

            Section {
                LabeledContent("Inbox folder") {
                    HStack(spacing: 6) {
                        TextField("Inbox folder", text: $editedInboxPath, prompt: Text("Use default send folder"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Menu {
                            Button("Use default send folder") { editedInboxPath = "" }
                            if !availableFolders.isEmpty {
                                Divider()
                                ForEach(availableFolders, id: \.self) { folder in
                                    Button(indentedLabel(for: folder)) { editedInboxPath = folder }
                                }
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            } header: {
                Text("Inbox")
            } footer: {
                Text("Type any folder name (created on send if missing), or leave empty to follow the app-wide default send folder.")
                    .font(.caption)
            }

            Section {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([vault.rootPath])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                Button {
                    if let url = vault.obsidianURL() { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open in Obsidian", systemImage: "arrow.up.forward.app")
                }

                Button(role: .destructive) {
                    confirmingDisconnect = true
                } label: {
                    Label("Disconnect Vault", systemImage: "minus.circle")
                }
                .confirmationDialog(
                    "Disconnect \u{201C}\(vault.displayName)\u{201D}?",
                    isPresented: $confirmingDisconnect,
                    titleVisibility: .visible
                ) {
                    Button("Disconnect", role: .destructive) {
                        appState.removeVault(vault)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Routing rules targeting this vault are removed too. Files in the vault are not touched.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .onChange(of: vault.id) { _, _ in reload() }
        .onChange(of: editedName) { _, _ in saveChanges() }
        .onChange(of: editedInboxPath) { _, _ in saveChanges() }
    }

    private func indentedLabel(for folder: String) -> String {
        let depth = folder.components(separatedBy: "/").count - 1
        return String(repeating: "   ", count: depth) + (folder.components(separatedBy: "/").last ?? folder)
    }

    private func reload() {
        editedName = vault.name
        editedInboxPath = vault.inboxPath
        isDefault = appState.settings.defaultVaultId == vault.id
        noteCount = nil
        loadFoldersAndStats()
    }

    private func loadFoldersAndStats() {
        let vaultService = VaultService(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD"))
        Task {
            var folders = (try? await vaultService.listFolders(in: vault)) ?? []
            if !vault.inboxPath.isEmpty, !folders.contains(vault.inboxPath) {
                folders.insert(vault.inboxPath, at: 0)
            }
            let count = await vaultService.noteCount(in: vault)
            await MainActor.run {
                availableFolders = folders
                noteCount = count
            }
        }
    }

    private func saveChanges() {
        if let index = appState.vaults.firstIndex(where: { $0.id == vault.id }) {
            var updated = appState.vaults[index]
            updated.name = editedName
            updated.inboxPath = editedInboxPath
            appState.vaults[index] = updated
            appState.saveUserData()
        }
    }
}

// MARK: - Templates

struct TemplatesManagerPane: View {
    @Environment(AppState.self) private var appState
    @State private var editingTemplate: VaultTemplate?

    var body: some View {
        VStack(spacing: 0) {
            if appState.templates.isEmpty {
                ContentUnavailableView {
                    Label("No Templates", systemImage: "doc.on.doc")
                } description: {
                    Text("Templates shape filenames and wrap content when sending to a vault.\nPlaceholders: {{title}}, {{date}}, {{time}}, {{timestamp}}, {{content}}")
                } actions: {
                    Button("New Template") {
                        editingTemplate = VaultTemplate(name: "New Template", content: "", filenamePattern: "{{title}}")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(appState.templates) { template in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name)
                                    .font(.headline)
                                Text("Filename: \(template.filenamePattern.isEmpty ? "{{title}}" : template.filenamePattern)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                editingTemplate = template
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                appState.templates.removeAll { $0.id == template.id }
                                appState.saveUserData()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    editingTemplate = VaultTemplate(name: "New Template", content: "", filenamePattern: "{{title}}")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Template")

                Spacer()

                Text("Placeholders: {{title}} {{date}} {{time}} {{timestamp}} {{content}}")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditorSheet(template: template)
        }
    }
}

struct TemplateEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State var template: VaultTemplate

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Template" : "Edit Template")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding()
            .background(.bar)

            Form {
                Section("Template") {
                    TextField("Name", text: $template.name)
                    TextField("Filename pattern", text: $template.filenamePattern, prompt: Text("{{title}}"))
                }

                Section("Content") {
                    TextEditor(text: $template.content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 180)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    Text("Use {{content}} where the document body should go. Without it, the body is appended after the template.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Save Template") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 520, height: 480)
        .tint(.cmdsAccent)
    }

    private var isNew: Bool {
        !appState.templates.contains(where: { $0.id == template.id })
    }

    private func save() {
        if let index = appState.templates.firstIndex(where: { $0.id == template.id }) {
            appState.templates[index] = template
        } else {
            appState.templates.append(template)
        }
        appState.saveUserData()
        dismiss()
    }
}

// MARK: - Routing Rules

struct RulesManagerPane: View {
    @Environment(AppState.self) private var appState
    @State private var editingRule: RoutingRule?

    private var sortedRules: [RoutingRule] {
        appState.routingRules.sorted { $0.priority > $1.priority }
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.vaults.isEmpty {
                ContentUnavailableView(
                    "Add a Vault First",
                    systemImage: "folder.badge.plus",
                    description: Text("Routing rules send documents to a vault — register one in the Vaults tab.")
                )
            } else if appState.routingRules.isEmpty {
                ContentUnavailableView {
                    Label("No Routing Rules", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Rules route documents to a vault automatically based on tags, filename, or content.\nUse Vault → Auto-Route Send (⌃⌘T) to apply them.")
                } actions: {
                    Button("New Rule") {
                        editingRule = newRule()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(sortedRules) { rule in
                        RuleRow(rule: rule) {
                            editingRule = rule
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    editingRule = newRule()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(appState.vaults.isEmpty)
                .help("New Rule")

                Spacer()

                Text("Higher priority wins. A rule with no conditions matches everything.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorSheet(rule: rule)
        }
    }

    private func newRule() -> RoutingRule? {
        guard let vault = appState.defaultVault else { return nil }
        return RoutingRule(name: "New Rule", targetVaultId: vault.id, targetFolder: appState.effectiveSendFolder(for: vault))
    }
}

struct RuleRow: View {
    @Environment(AppState.self) private var appState
    let rule: RoutingRule
    let onEdit: () -> Void

    private var targetVaultName: String {
        appState.vaults.first(where: { $0.id == rule.targetVaultId })?.displayName ?? "Missing vault"
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    if let index = appState.routingRules.firstIndex(where: { $0.id == rule.id }) {
                        appState.routingRules[index].isEnabled = newValue
                        appState.saveUserData()
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text(conditionSummary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                    Text("\(targetVaultName)/\(rule.targetFolder)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text("P\(rule.priority)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                appState.routingRules.removeAll { $0.id == rule.id }
                appState.saveUserData()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .opacity(rule.isEnabled ? 1 : 0.5)
    }

    private var conditionSummary: String {
        if rule.conditions.isEmpty {
            return "Always"
        }
        return rule.conditions
            .map { "\($0.type.rawValue) \($0.matchType.rawValue.lowercased()) \"\($0.value)\"" }
            .joined(separator: " · ")
    }
}

struct RuleEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State var rule: RoutingRule

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Routing Rule")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding()
            .background(.bar)

            Form {
                Section("Rule") {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.isEnabled)
                    Stepper("Priority: \(rule.priority)", value: $rule.priority, in: 0...100)
                }

                Section("Conditions (all must match)") {
                    if rule.conditions.isEmpty {
                        Text("No conditions — this rule matches every document.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach($rule.conditions) { $condition in
                        HStack {
                            Picker("", selection: $condition.type) {
                                ForEach(RoutingCondition.ConditionType.allCases, id: \.self) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)

                            Picker("", selection: $condition.matchType) {
                                ForEach(RoutingCondition.MatchType.allCases, id: \.self) { match in
                                    Text(match.rawValue).tag(match)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)

                            TextField("value", text: $condition.value)

                            Button {
                                rule.conditions.removeAll { $0.id == condition.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button {
                        rule.conditions.append(RoutingCondition(type: .tag, value: ""))
                    } label: {
                        Label("Add Condition", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }

                Section("Destination") {
                    Picker("Vault", selection: $rule.targetVaultId) {
                        ForEach(appState.vaults) { vault in
                            Text(vault.displayName).tag(vault.id)
                        }
                    }

                    TextField("Folder", text: $rule.targetFolder)

                    Picker("Action", selection: $rule.action) {
                        Text("Copy").tag(SendAction.copy)
                        Text("Move").tag(SendAction.move)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Inject frontmatter", isOn: $rule.injectFrontmatter)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Save Rule") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 560, height: 520)
        .tint(.cmdsAccent)
    }

    private func save() {
        if let index = appState.routingRules.firstIndex(where: { $0.id == rule.id }) {
            appState.routingRules[index] = rule
        } else {
            appState.routingRules.append(rule)
        }
        appState.saveUserData()
        dismiss()
    }
}

// MARK: - Add Vault

struct AddVaultSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedURL: URL?
    @State private var inboxPath: String = ""
    @State private var isDefault: Bool = false
    @State private var errorMessage: String?
    @State private var isAdding: Bool = false
    @State private var detectedVaults: [DetectedObsidianVault] = []
    @State private var availableFolders: [String] = []

    /// Detected vaults Obsidian knows about that aren't already connected here.
    private var unconnectedDetected: [DetectedObsidianVault] {
        let known = Set(appState.vaults.map { $0.rootPath.standardizedFileURL.path })
        return detectedVaults.filter { !known.contains($0.path.standardizedFileURL.path) }
    }

    private var isObsidianVault: Bool {
        guard let url = selectedURL else { return false }
        return ObsidianLocator.isObsidianVault(url)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect a Vault")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding()
            .background(.bar)

            Form {
                if !unconnectedDetected.isEmpty {
                    Section {
                        ForEach(unconnectedDetected) { detected in
                            Button {
                                choose(detected.path)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "shippingbox.fill")
                                        .foregroundStyle(Color.cmdsAccent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(detected.name)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.primary)
                                        Text(detected.path.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    if selectedURL?.standardizedFileURL == detected.path.standardizedFileURL {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.cmdsAccent)
                                    } else {
                                        Text("Connect")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(Color.cmdsAccent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label("Detected Obsidian Vaults", systemImage: "sparkles")
                    } footer: {
                        Text("Found in your Obsidian app. Pick one to connect instantly.")
                            .font(.caption)
                    }
                }

                Section("Vault Folder") {
                    HStack {
                        if let url = selectedURL {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(.headline)
                                Text(url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Label(
                                    isObsidianVault ? "Obsidian vault detected" : "Not an Obsidian vault (will still work)",
                                    systemImage: isObsidianVault ? "checkmark.seal.fill" : "info.circle"
                                )
                                .font(.caption)
                                .foregroundStyle(isObsidianVault ? Color.cmdsAccent : .secondary)
                            }
                        } else {
                            Text("No folder selected")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Choose…") { selectFolder() }
                    }
                }

                Section("Settings") {
                    TextField("Name (optional)", text: $name)
                        .help("Leave empty to use the folder name")

                    LabeledContent("Inbox folder") {
                        HStack(spacing: 6) {
                            TextField("Inbox folder", text: $inboxPath, prompt: Text("Use default send folder"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Menu {
                                Button("Use default send folder") { inboxPath = "" }
                                if !availableFolders.isEmpty {
                                    Divider()
                                    ForEach(availableFolders, id: \.self) { folder in
                                        Button(folder) { inboxPath = folder }
                                    }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    .help("Type any folder name, or pick an existing one — empty uses the default send folder")

                    Toggle("Set as default vault", isOn: $isDefault)
                }

                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Connect Vault") { addVault() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedURL == nil || isAdding)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 480, height: 480)
        .tint(.cmdsAccent)
        .onAppear { detectedVaults = ObsidianLocator.detectedVaults() }
    }

    private func choose(_ url: URL) {
        selectedURL = url
        if name.isEmpty { name = url.lastPathComponent }
        loadFolders(at: url)
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            choose(url)
        }
    }

    /// Lists immediate + nested subfolders so the Inbox can be picked from what
    /// actually exists in the vault rather than typed blind.
    private func loadFolders(at url: URL) {
        var folders: [String] = ["Inbox"]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            let names = contents
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { $0.lastPathComponent }
                .filter { $0 != ".obsidian" }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            folders.append(contentsOf: names)
        }
        availableFolders = Array(NSOrderedSet(array: folders)) as? [String] ?? folders
        // Keep "" (use default send folder) valid; only reset an explicit pick
        // that no longer exists in the folder list.
        if !inboxPath.isEmpty, !availableFolders.contains(inboxPath) { inboxPath = "" }
    }

    private func addVault() {
        guard let url = selectedURL else { return }

        isAdding = true
        errorMessage = nil

        Task {
            let vaultService = VaultService(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD"))

            do {
                var vault = try await vaultService.registerVault(name: name, at: url, inboxPath: inboxPath)
                vault.isDefault = isDefault

                await MainActor.run {
                    appState.addVault(vault)

                    if isDefault {
                        appState.settings.defaultVaultId = vault.id
                        appState.saveUserData()
                    }

                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAdding = false
                }
            }
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VaultManagerView()
        .environment(AppState())
}
#endif
