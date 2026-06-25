import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    /// True when the highlight last moved via the keyboard. Auto-scroll only
    /// follows keyboard navigation, so hovering never yanks the list under the cursor.
    @State private var navigatingByKeyboard = false
    @FocusState private var isSearchFocused: Bool

    var filteredCommands: [Command] {
        let allCommands = Command.allCommands(appState: appState)
        guard !searchText.isEmpty else { return allCommands }

        return allCommands
            .compactMap { command -> (Command, Int)? in
                guard let score = command.matchScore(for: searchText) else { return nil }
                return (command, score)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Type a command or file name...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit {
                        executeSelectedCommand()
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("ESC")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding()
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                            CommandRow(
                                command: command,
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    navigatingByKeyboard = false
                                    selectedIndex = index
                                }
                            }
                            .onTapGesture {
                                selectedIndex = index
                                executeSelectedCommand()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    guard navigatingByKeyboard else { return }
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 520, height: 420)
        .tint(.cmdsAccent)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            isSearchFocused = true
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                navigatingByKeyboard = true
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredCommands.count - 1 {
                navigatingByKeyboard = true
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
    }

    private func executeSelectedCommand() {
        guard selectedIndex < filteredCommands.count else { return }
        let command = filteredCommands[selectedIndex]
        dismiss()
        command.action()
    }
}

struct CommandRow: View {
    let command: Command
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.icon)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(isSelected ? Color.cmdsAccentOn : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn : .primary)

                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.cmdsAccent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
    }
}

struct Command: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    let keywords: [String]
    let action: () -> Void

    /// Fuzzy subsequence score: every query character must appear in order in
    /// the title or a keyword. Consecutive runs and word-start hits rank higher,
    /// so "otv" finds "Open in Obsidian: TOC View" style entries sensibly.
    func matchScore(for query: String) -> Int? {
        let candidates = [title] + keywords + [subtitle ?? ""]
        var best: Int?
        for candidate in candidates {
            if let score = Self.fuzzyScore(query: query.lowercased(), in: candidate.lowercased()) {
                best = max(best ?? Int.min, score)
            }
        }
        return best
    }

    static func fuzzyScore(query: String, in candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        var score = 0
        var lastMatchIndex: String.Index?
        var searchStart = candidate.startIndex

        for char in query {
            guard let found = candidate[searchStart...].firstIndex(of: char) else { return nil }

            if let last = lastMatchIndex, candidate.index(after: last) == found {
                score += 8 // consecutive run
            } else if found == candidate.startIndex {
                score += 10 // start of string
            } else {
                let before = candidate[candidate.index(before: found)]
                score += (before == " " || before == "/" || before == "-") ? 6 : 1
            }

            lastMatchIndex = found
            searchStart = candidate.index(after: found)
        }

        // Shorter candidates with the same hits rank higher.
        score -= candidate.count / 8
        return score
    }

    static func allCommands(appState: AppState) -> [Command] {
        var commands: [Command] = [
            Command(
                title: "New Draft",
                subtitle: "Create a new draft document",
                icon: "square.and.pencil",
                shortcut: "⌘N",
                keywords: ["new", "create", "draft", "note"]
            ) {
                appState.createNewDraft()
            },

            Command(
                title: "Open File",
                subtitle: "Open a Markdown file",
                icon: "doc.badge.plus",
                shortcut: "⌘O",
                keywords: ["open", "file", "browse"]
            ) {
                appState.openFile()
            },

            Command(
                title: "Open Folder",
                subtitle: "Open a folder of Markdown files",
                icon: "folder.badge.plus",
                shortcut: "⌥⌘O",
                keywords: ["open", "folder", "directory"]
            ) {
                appState.openFolder()
            },

            Command(
                title: "Omnisearch",
                subtitle: "Search file names and contents everywhere",
                icon: "sparkle.magnifyingglass",
                shortcut: "⇧⌘O",
                keywords: ["omnisearch", "search", "find", "everywhere", "quick", "switcher"]
            ) {
                appState.showOmnisearch = true
            },

            Command(
                title: "Save",
                subtitle: "Save the current document",
                icon: "square.and.arrow.down",
                shortcut: "⌘S",
                keywords: ["save", "write"]
            ) {
                Task { await appState.saveCurrentDocument() }
            },

            Command(
                title: "Reload from Disk",
                subtitle: "Discard in-memory changes and reload",
                icon: "arrow.clockwise",
                shortcut: "⌥⌘R",
                keywords: ["reload", "refresh", "revert"]
            ) {
                appState.reloadCurrentDocument()
            },

            Command(
                title: "Quick Capture",
                subtitle: "Capture a quick note",
                icon: "bolt",
                shortcut: "⇧⌘M",
                keywords: ["quick", "capture", "note", "scratch"]
            ) {
                appState.showQuickCapture = true
            },

            Command(
                title: "Send to Vault",
                subtitle: "Send current file to an Obsidian vault",
                icon: "paperplane",
                shortcut: "⇧⌘T",
                keywords: ["send", "vault", "obsidian", "route"]
            ) {
                appState.showSendToVault = true
            },

            Command(
                title: "Auto-Route Send",
                subtitle: "Send using routing rules, no dialog",
                icon: "arrow.triangle.branch",
                shortcut: "⌃⌘T",
                keywords: ["auto", "route", "send", "rule"]
            ) {
                appState.autoRouteCurrentDocument()
            },

            Command(
                title: "Manage Vaults, Templates & Rules",
                subtitle: "Configure vault connections",
                icon: "folder.badge.gearshape",
                shortcut: nil,
                keywords: ["vault", "manage", "configure", "template", "rule"]
            ) {
                appState.showVaultManager = true
            },

            Command(
                title: "Source View",
                subtitle: "Show source code only",
                icon: "text.alignleft",
                shortcut: "⌘1",
                keywords: ["view", "source", "edit", "code"]
            ) {
                appState.viewMode = .source
            },

            Command(
                title: "Split View",
                subtitle: "Show editor and preview side by side",
                icon: "rectangle.split.2x1",
                shortcut: "⌘2",
                keywords: ["view", "split", "side"]
            ) {
                appState.viewMode = .split
            },

            Command(
                title: "Preview",
                subtitle: "Show rendered preview only",
                icon: "eye",
                shortcut: "⌘3",
                keywords: ["view", "preview", "render"]
            ) {
                appState.viewMode = .preview
            },

            Command(
                title: "Toggle Sidebar",
                subtitle: "Show or hide the sidebar",
                icon: "sidebar.left",
                shortcut: "⌃⌘B",
                keywords: ["sidebar", "toggle", "hide", "show"]
            ) {
                appState.sidebarVisible.toggle()
            },

            Command(
                title: "Toggle Inspector",
                subtitle: "Show or hide the inspector panel",
                icon: "sidebar.right",
                shortcut: "⌥⌘I",
                keywords: ["inspector", "toggle", "info", "details", "toc", "properties"]
            ) {
                appState.inspectorVisible.toggle()
            },

            Command(
                title: "Toggle Line Numbers",
                subtitle: nil,
                icon: "list.number",
                shortcut: nil,
                keywords: ["line", "numbers", "gutter"]
            ) {
                appState.settings.showLineNumbers.toggle()
                appState.saveUserData()
            },

            Command(
                title: "Toggle Scroll Sync",
                subtitle: "Sync editor and preview scrolling in split view",
                icon: "link",
                shortcut: nil,
                keywords: ["scroll", "sync", "split"]
            ) {
                appState.settings.scrollSyncEnabled.toggle()
                appState.saveUserData()
            },

            Command(
                title: "Export as HTML",
                subtitle: "Save document as HTML file",
                icon: "doc.richtext",
                shortcut: "⇧⌘E",
                keywords: ["export", "html", "save"]
            ) {
                appState.exportAsHTML()
            },

            Command(
                title: "Export as PDF",
                subtitle: "Save document as PDF file",
                icon: "doc.fill",
                shortcut: nil,
                keywords: ["export", "pdf", "save", "print"]
            ) {
                appState.exportAsPDF()
            },

            Command(
                title: "Copy as HTML",
                subtitle: "Copy rendered HTML to clipboard",
                icon: "doc.on.doc",
                shortcut: nil,
                keywords: ["copy", "html", "clipboard"]
            ) {
                appState.copyAsHTML()
            }
        ]

        for theme in EditorTheme.allCases {
            commands.append(Command(
                title: "Editor Theme: \(theme.rawValue)",
                subtitle: nil,
                icon: "paintpalette",
                shortcut: nil,
                keywords: ["theme", "editor", "color", theme.rawValue]
            ) {
                appState.settings.editorTheme = theme
                appState.saveUserData()
            })
        }

        for theme in PreviewTheme.allCases {
            commands.append(Command(
                title: "Preview Theme: \(theme.rawValue)",
                subtitle: nil,
                icon: "paintbrush",
                shortcut: nil,
                keywords: ["theme", "preview", theme.rawValue]
            ) {
                appState.settings.previewTheme = theme.rawValue
                appState.saveUserData()
            })
        }

        for file in appState.recentFiles.prefix(8) {
            commands.append(Command(
                title: file.deletingPathExtension().lastPathComponent,
                subtitle: file.deletingLastPathComponent().path,
                icon: "doc.text",
                shortcut: nil,
                keywords: ["recent", "file", file.lastPathComponent]
            ) {
                appState.openDocument(at: file)
            })
        }

        for vault in appState.vaults {
            commands.append(Command(
                title: "Send to \(vault.displayName)",
                subtitle: "Send current file to \(vault.displayName) inbox",
                icon: "folder",
                shortcut: nil,
                keywords: ["send", "vault", vault.name]
            ) {
                Task {
                    var options = SendOptions()
                    options.targetVault = vault
                    options.targetFolder = appState.effectiveSendFolder(for: vault)
                    options.conflictResolution = appState.settings.conflictResolution
                    options.injectFrontmatter = appState.settings.injectFrontmatterByDefault
                    try? await appState.sendToVault(options: options)
                }
            })
        }

        return commands
    }
}

#if !SWIFT_PACKAGE
#Preview {
    CommandPaletteView()
        .environment(AppState())
}
#endif
