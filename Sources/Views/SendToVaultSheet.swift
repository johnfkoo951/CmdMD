import SwiftUI

struct SendToVaultSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedVault: Vault?
    @State private var targetFolder: String = "Inbox"
    @State private var action: SendAction = .copy
    @State private var conflictResolution: FileConflictResolution = .rename
    @State private var injectFrontmatter: Bool = true
    @State private var addSourceLink: Bool = false
    @State private var openAfterSend: Bool = false
    @State private var applyTemplate: Bool = false
    @State private var selectedTemplateId: UUID?
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    @State private var availableFolders: [String] = []

    /// Batch mode is active when the sidebar queued multiple files
    /// ("Send Folder to Vault…").
    private var isBatch: Bool {
        !appState.batchSendURLs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isBatch ? "Send \(appState.batchSendURLs.count) Files to Vault" : "Send to Vault")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(.bar)

            Form {
                Section("Destination") {
                    Picker("Vault", selection: $selectedVault) {
                        Text("Select a vault...").tag(nil as Vault?)
                        ForEach(appState.vaults) { vault in
                            Text(vault.displayName).tag(vault as Vault?)
                        }
                    }
                    .onChange(of: selectedVault) { _, newVault in
                        if let vault = newVault {
                            targetFolder = appState.effectiveSendFolder(for: vault)
                            loadFolders(for: vault)
                        }
                    }

                    if !availableFolders.isEmpty {
                        Picker("Folder", selection: $targetFolder) {
                            ForEach(availableFolders, id: \.self) { folder in
                                // Indent nested folders so the vault hierarchy reads
                                // as a tree instead of a flat path soup.
                                Text(indentedLabel(for: folder)).tag(folder)
                            }
                        }
                    } else {
                        TextField("Folder", text: $targetFolder)
                    }
                }

                Section("Options") {
                    Picker("Action", selection: $action) {
                        Text("Copy").tag(SendAction.copy)
                        Text("Move").tag(SendAction.move)
                    }
                    .pickerStyle(.segmented)

                    Picker("If file exists", selection: $conflictResolution) {
                        ForEach(FileConflictResolution.allCases, id: \.self) { resolution in
                            Text(resolution.rawValue).tag(resolution)
                        }
                    }

                    Toggle("Inject frontmatter", isOn: $injectFrontmatter)
                    Toggle("Add source path to frontmatter", isOn: $addSourceLink)

                    if !isBatch {
                        Toggle("Open in Obsidian after send", isOn: $openAfterSend)
                    }
                }

                if !appState.templates.isEmpty {
                    Section("Template") {
                        Toggle("Apply template", isOn: $applyTemplate)

                        if applyTemplate {
                            Picker("Template", selection: $selectedTemplateId) {
                                ForEach(appState.templates) { template in
                                    Text(template.name).tag(template.id as UUID?)
                                }
                            }
                        }
                    }
                }

                Section("Preview") {
                    VStack(alignment: .leading, spacing: 4) {
                        if isBatch {
                            Text("\(appState.batchSendURLs.count) Markdown files")
                                .font(.callout)
                            ForEach(appState.batchSendURLs.prefix(5), id: \.self) { url in
                                Text("· \(url.lastPathComponent)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if appState.batchSendURLs.count > 5 {
                                Text("… and \(appState.batchSendURLs.count - 5) more")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        } else if let document = appState.currentDocument {
                            Text("File: \(document.displayTitle).md")
                                .font(.callout)
                        }

                        if let vault = selectedVault {
                            Text("To: \(vault.displayName)/\(targetFolder)/")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            // HIG dialog footer: Cancel sits immediately left of the default
            // action at the trailing edge; ⎋ cancels, ↩ sends.
            HStack(spacing: 12) {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                    Text(isBatch ? "Sending files…" : "Sending…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isBatch ? "Send All" : "Send") {
                    send()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedVault == nil || isSending)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 460, height: isBatch ? 560 : 540)
        .tint(.cmdsAccent)
        .onAppear {
            injectFrontmatter = appState.settings.injectFrontmatterByDefault
            conflictResolution = appState.settings.conflictResolution
            selectedTemplateId = appState.templates.first?.id

            if let vault = appState.defaultVault {
                selectedVault = vault
                targetFolder = appState.effectiveSendFolder(for: vault)
                loadFolders(for: vault)
            }
        }
    }

    private func indentedLabel(for folder: String) -> String {
        let depth = folder.components(separatedBy: "/").count - 1
        return String(repeating: "    ", count: depth) + (folder.components(separatedBy: "/").last ?? folder)
    }

    private func loadFolders(for vault: Vault) {
        Task {
            let vaultService = VaultService(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD"))
            let effective = appState.effectiveSendFolder(for: vault)
            do {
                var folders = try await vaultService.listFolders(in: vault)
                if !folders.contains(effective) {
                    folders.insert(effective, at: 0)
                }
                await MainActor.run { availableFolders = folders }
            } catch {
                await MainActor.run { availableFolders = [effective] }
            }
        }
    }

    private func buildOptions(vault: Vault) -> SendOptions {
        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = targetFolder
        options.action = action
        options.conflictResolution = conflictResolution
        options.injectFrontmatter = injectFrontmatter
        options.addSourceLink = addSourceLink
        options.openAfterSend = openAfterSend && !isBatch
        options.applyTemplate = applyTemplate
        options.templateId = applyTemplate ? selectedTemplateId : nil
        return options
    }

    private func send() {
        guard let vault = selectedVault else { return }

        isSending = true
        errorMessage = nil
        let options = buildOptions(vault: vault)

        Task {
            do {
                if isBatch {
                    _ = await appState.sendFiles(appState.batchSendURLs, options: options)
                } else {
                    try await appState.sendToVault(options: options)
                }

                await MainActor.run {
                    appState.batchSendURLs = []
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    SendToVaultSheet()
        .environment(AppState())
}
#endif
