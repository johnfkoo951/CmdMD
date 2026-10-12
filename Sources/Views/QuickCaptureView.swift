import SwiftUI

/// Quick note capture UI, shared by the menu-bar popover and the in-app
/// ⇧⌘M sheet. Captured text can be stashed as a local draft, sent straight to
/// a vault inbox, or auto-routed through the routing rules.
struct QuickCaptureView: View {
    @Environment(AppState.self) private var appState
    var onDone: (() -> Void)?

    @State private var noteText: String = ""
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
                .frame(minHeight: 140, maxHeight: 220)
                .padding(8)

            Divider()

            HStack {
                Text("\(noteText.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // HIG order: Cancel (⎋) beside the prominent default action.
                // ⌘↩ saves — a bare Return must keep inserting newlines.
                Button("Cancel") {
                    onDone?()
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
        onDone?()
    }

    private func sendToVault(_ vault: Vault) {
        guard !noteText.isEmpty else { return }
        let document = capturedDocument()

        Task {
            var options = SendOptions()
            options.targetVault = vault
            options.targetFolder = appState.effectiveSendFolder(for: vault)
            options.conflictResolution = appState.settings.conflictResolution
            options.injectFrontmatter = appState.settings.injectFrontmatterByDefault

            do {
                // Pass the document explicitly — quick capture has no active tab,
                // so routing through currentDocument would silently drop the note.
                try await appState.sendToVault(document: document, options: options)
                await MainActor.run {
                    noteText = ""
                    onDone?()
                }
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }

    /// Routes the capture through the routing rules (tags/content conditions),
    /// falling back to the default vault inbox when nothing matches.
    private func autoRoute() {
        guard !noteText.isEmpty else { return }
        let document = capturedDocument()

        guard let rule = appState.matchingRoutingRule(for: document),
              let vault = appState.vaults.first(where: { $0.id == rule.targetVaultId }) else {
            if let fallback = appState.defaultVault {
                sendToVault(fallback)
            }
            return
        }

        Task {
            var options = SendOptions()
            options.targetVault = vault
            options.targetFolder = rule.targetFolder
            options.injectFrontmatter = rule.injectFrontmatter
            options.conflictResolution = appState.settings.conflictResolution

            do {
                try await appState.sendToVault(document: document, options: options, quiet: true)
                await MainActor.run {
                    appState.showToast("Routed to \(vault.displayName)/\(rule.targetFolder)")
                    noteText = ""
                    onDone?()
                }
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }

    private func extractTitle(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
        }

        if let firstLine = lines.first, !firstLine.isEmpty {
            return String(firstLine.prefix(50))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Quick Note \(formatter.string(from: Date()))"
    }
}

#if !SWIFT_PACKAGE
#Preview {
    QuickCaptureView()
        .environment(AppState())
}
#endif
