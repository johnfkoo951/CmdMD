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
    /// The running send, so Cancel can stop a batch instead of only hiding it.
    @State private var sendTask: Task<Void, Never>?
    /// Files a running batch has finished, for "Sending n of N…".
    @State private var filesDone = 0

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
                        }
                    }

                    // Editable, so a send can also target the vault root or a
                    // new folder (created on send), not only existing folders.
                    LabeledContent("Folder") {
                        HStack(spacing: 6) {
                            TextField("Folder", text: $targetFolder, prompt: Text("Vault root"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Menu {
                                Button("Vault root") { targetFolder = "" }
                                if !availableFolders.isEmpty {
                                    Divider()
                                    ForEach(availableFolders, id: \.self) { folder in
                                        // Indent nested folders so the vault hierarchy reads
                                        // as a tree instead of a flat path soup.
                                        Button(indentedLabel(for: folder)) { targetFolder = folder }
                                    }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("Choose Folder")
                            .help("Choose an existing folder, or type a new one (created on send)")
                        }
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
                        // The source key rides on injected frontmatter; without
                        // injection the note ships unchanged.
                        .disabled(!injectFrontmatter)
                        .help("Adds a source property with the original file's path. Requires Inject frontmatter.")

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
                                // With its subfolder, which the send keeps.
                                Text("· \(batchLabel(for: url))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if appState.batchSendURLs.count > 5 {
                                Text("… and \(appState.batchSendURLs.count - 5) more")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        } else if let document = appState.currentDocument {
                            // Named exactly as sendToVault will name it.
                            Text("File: \(AppState.sendFilename(for: document, template: selectedTemplate))")
                                .font(.callout)
                        }

                        if let vault = selectedVault {
                            let folder = AppState.normalizedSendFolder(targetFolder) ?? targetFolder
                            Text("To: \(vault.displayName)/\(folder.isEmpty ? "" : folder + "/")")
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
                    Text(isBatch ? "Sending \(min(filesDone + 1, appState.batchSendURLs.count)) of \(appState.batchSendURLs.count)…" : "Sending…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                Button("Cancel") {
                    // Stops a running batch after the file in progress; files
                    // already sent stay sent, and a toast says how many.
                    sendTask?.cancel()
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
            }
        }
        // One load per selected vault. Switching vaults cancels the previous
        // load, so a slower list for the old vault can't replace this one's.
        .task(id: selectedVault?.id) {
            if let vault = selectedVault {
                await loadFolders(for: vault)
            } else {
                availableFolders = []
            }
        }
    }

    private func indentedLabel(for folder: String) -> String {
        let depth = folder.components(separatedBy: "/").count - 1
        return String(repeating: "    ", count: depth) + (folder.components(separatedBy: "/").last ?? folder)
    }

    /// A batch file as the preview lists it: its path below the batch folder.
    private func batchLabel(for url: URL) -> String {
        let subfolder = AppState.batchTargetFolder(for: url, root: appState.batchSendRoot, base: "")
        return subfolder.isEmpty ? url.lastPathComponent : subfolder + "/" + url.lastPathComponent
    }

    private var selectedTemplate: VaultTemplate? {
        applyTemplate ? appState.templates.first(where: { $0.id == selectedTemplateId }) : nil
    }

    private func loadFolders(for vault: Vault) async {
        let vaultService = VaultService(dataDirectory: AppState.dataDirectory)
        let effective = appState.effectiveSendFolder(for: vault)
        var folders = (try? await vaultService.listFolders(in: vault)) ?? []
        if !folders.contains(effective) {
            folders.insert(effective, at: 0)
        }
        // Superseded by another vault's load while listing: drop it.
        guard !Task.isCancelled, selectedVault?.id == vault.id else { return }
        availableFolders = folders
    }

    private func buildOptions(vault: Vault, folder: String) -> SendOptions {
        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = folder
        options.action = action
        options.conflictResolution = conflictResolution
        options.injectFrontmatter = injectFrontmatter
        options.addSourceLink = addSourceLink && injectFrontmatter
        options.openAfterSend = openAfterSend && !isBatch
        options.applyTemplate = applyTemplate
        options.templateId = applyTemplate ? selectedTemplateId : nil
        return options
    }

    private func send() {
        guard let vault = selectedVault else { return }
        // The folder is free text now; it must stay inside the vault.
        guard let folder = AppState.normalizedSendFolder(targetFolder) else {
            errorMessage = "The folder can't contain \u{201C}..\u{201D}. Use a path inside the vault."
            return
        }

        isSending = true
        errorMessage = nil
        filesDone = 0
        let options = buildOptions(vault: vault, folder: folder)

        sendTask = Task {
            do {
                if isBatch {
                    let result = await appState.sendFiles(
                        appState.batchSendURLs,
                        options: options,
                        relativeTo: appState.batchSendRoot,
                        progress: { filesDone = $0 }
                    )
                    // Cancelled: the sheet is already gone, and touching the
                    // queue could clobber a batch started since.
                    if Task.isCancelled { return }
                    if !result.failures.isEmpty {
                        // Stay open with only the failed files queued, so the
                        // user sees which didn't go and why, and can retry them.
                        await MainActor.run {
                            appState.batchSendURLs = result.failures.map { $0.url }
                            errorMessage = failureSummary(result.failures)
                            isSending = false
                        }
                        return
                    }
                } else {
                    try await appState.sendToVault(options: options)
                    if Task.isCancelled { return }
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

    /// Names the files a batch couldn't send, with the reason for each.
    private func failureSummary(_ failures: [(url: URL, message: String)]) -> String {
        let limit = 5
        var lines = [failures.count == 1 ? "1 file couldn't be sent:" : "\(failures.count) files couldn't be sent:"]
        lines += failures.prefix(limit).map { "\($0.url.lastPathComponent): \($0.message)" }
        if failures.count > limit { lines.append("… and \(failures.count - limit) more") }
        return lines.joined(separator: "\n")
    }
}

#if !SWIFT_PACKAGE
#Preview {
    SendToVaultSheet()
        .environment(AppState())
}
#endif
