import SwiftUI

/// Quick note capture UI, shared by the menu-bar popover and the in-app
/// ⇧⌘M sheet. Captured text can be stashed as a local draft, sent straight to
/// a vault inbox, or auto-routed through the routing rules.
struct QuickCaptureView: View {
    @Environment(AppState.self) private var appState
    var onDone: (() -> Void)?
    /// Reports the typed text as it changes; the floating panel keeps it so a
    /// hidden capture survives quitting and comes back on the next hot key.
    var onTextChange: ((String) -> Void)? = nil

    @State private var noteText: String = ""
    @State private var confirmingDiscard = false
    /// Shown in the panel itself: the app-wide alert and toasts live in the
    /// editor window, which the menu-bar capture can't count on.
    @State private var errorMessage: String?
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.cmdsAccent)

                Text("Quick Capture")
                    .font(.headline)

                Spacer()

                if !appState.vaults.isEmpty {
                    Menu {
                        if !appState.routingRules.isEmpty {
                            Button {
                                autoRoute()
                            } label: {
                                Label("Auto-Route", systemImage: "arrow.triangle.branch")
                            }
                            Divider()
                        }
                        ForEach(appState.vaults) { vault in
                            Button("\(vault.displayName) → \(appState.effectiveSendFolder(for: vault))") {
                                sendToVault(vault)
                            }
                        }
                    } label: {
                        Label("Send", systemImage: "paperplane")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(noteText.isEmpty)
                }
            }
            .padding(12)

            Divider()

            TextEditor(text: $noteText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isTextFieldFocused)
                .onChange(of: noteText) { _, text in onTextChange?(text) }
                .frame(minHeight: 140, maxHeight: 220)
                .padding(8)

            Divider()

            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(errorMessage)
                } else {
                    Text("\(noteText.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // HIG order: Cancel (⎋) beside the prominent default action.
                // ⌘↩ saves — a bare Return must keep inserting newlines.
                Button("Cancel") {
                    // A reflexive ⎋ must not silently throw typed text away.
                    if noteText.isEmpty {
                        onDone?()
                    } else {
                        confirmingDiscard = true
                    }
                }
                .keyboardShortcut(.cancelAction)

                Button("Save as Draft") {
                    saveDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(noteText.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .frame(width: 360)
        .tint(.cmdsAccent)
        .confirmationDialog(
            "Discard this note?",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Save as Draft") { saveDraft() }
            Button("Discard", role: .destructive) {
                noteText = ""
                errorMessage = nil
                onDone?()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("It hasn't been saved or sent.")
        }
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func capturedDocument() -> MarkdownDocument {
        MarkdownDocument(
            title: extractTitle(from: noteText),
            content: noteText,
            isDraft: true
        )
    }

    private func saveDraft() {
        guard !noteText.isEmpty else { return }

        let draft = Draft(
            title: "",
            body: noteText,
            sourceDevice: Host.current().localizedName ?? "Mac"
        )
        appState.addDraft(draft)
        appState.showToast("Saved to Drafts")
        noteText = ""
        errorMessage = nil
        onDone?()
    }

    private func sendToVault(_ vault: Vault) {
        guard !noteText.isEmpty else { return }
        let document = capturedDocument()
        errorMessage = nil

        Task {
            var options = SendOptions()
            options.targetVault = vault
            options.targetFolder = appState.effectiveSendFolder(for: vault)
            options.conflictResolution = appState.settings.conflictResolution.nonDestructive
            options.injectFrontmatter = appState.settings.injectFrontmatterByDefault

            do {
                // Pass the document explicitly — quick capture has no active tab,
                // so routing through currentDocument would silently drop the note.
                let outcome = try await appState.sendToVault(document: document, options: options)
                // Only a written note may clear the capture.
                guard case .sent = outcome else { return }
                await MainActor.run {
                    noteText = ""
                    onDone?()
                }
            } catch {
                showError(error)
            }
        }
    }

    /// Routes the capture through the routing rules (tags/content conditions),
    /// falling back to the default vault inbox when nothing matches.
    private func autoRoute() {
        guard !noteText.isEmpty else { return }
        let document = capturedDocument()
        errorMessage = nil

        guard let rule = appState.matchingRoutingRule(for: document),
              let vault = appState.vaults.first(where: { $0.id == rule.targetVaultId }) else {
            if let fallback = appState.defaultVault {
                sendToVault(fallback)
            } else {
                // Default vault "None": don't guess one. The text stays.
                errorMessage = "No routing rule matches — choose a vault from Send"
            }
            return
        }

        Task {
            var options = SendOptions()
            options.targetVault = vault
            options.targetFolder = rule.targetFolder
            options.injectFrontmatter = rule.injectFrontmatter
            options.conflictResolution = appState.settings.conflictResolution.nonDestructive

            do {
                let outcome = try await appState.sendToVault(document: document, options: options, quiet: true)
                await MainActor.run {
                    if let message = outcome.unsentMessage {
                        // Nothing was written: say so and keep the text.
                        errorMessage = message
                        return
                    }
                    appState.showToast("Routed to \(vault.displayName)/\(rule.targetFolder)")
                    noteText = ""
                    onDone?()
                }
            } catch {
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        Log.error("quick capture send failed", .send, detail: error.localizedDescription)
        errorMessage = error.localizedDescription
    }

    private func extractTitle(from text: String) -> String {
        // The draft-title rules: a `# ` heading near the top, else the first
        // line without Markdown markers. A typed `---` properties block is
        // skipped; it used to name the note "---.md".
        if let title = MarkdownDocument.contentTitle(of: text, firstLine: true) {
            return title
        }

        let formatter = DateFormatter.fixedFormat("yyyy-MM-dd HH:mm")
        return "Quick Note \(formatter.string(from: Date()))"
    }
}

extension FileConflictResolution {
    /// For a brand-new note such as a capture: Skip would throw the typed text
    /// away and Overwrite would replace whatever unrelated note shares its
    /// first line, so both fall back to Rename.
    var nonDestructive: FileConflictResolution {
        switch self {
        case .rename, .timestamp: return self
        case .overwrite, .skip: return .rename
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    QuickCaptureView()
        .environment(AppState())
}
#endif
