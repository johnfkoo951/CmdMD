import SwiftUI

/// ⇧⌘O everything-search: fuzzy file-name matching over the note index
/// (open folder + registered vaults, recents boosted) plus live full-text
/// matches from the open folder. Enter opens the hit — content matches jump
/// straight to the matched line.
struct OmnisearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    /// Auto-scroll follows keyboard navigation only, so hovering doesn't jump the list.
    @State private var navigatingByKeyboard = false
    @State private var contentResults: [SearchResult] = []
    @State private var isSearchingContent = false
    @State private var contentSearchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    struct Hit: Identifiable {
        enum Kind {
            case file
            case content
        }

        let id = UUID()
        let kind: Kind
        let title: String
        let subtitle: String
        let url: URL
        let line: Int?
    }

    // MARK: Hit assembly

    private var fileHits: [Hit] {
        if query.isEmpty {
            // Bare ⇧⌘O = recent files, most useful default.
            return appState.recentFiles.prefix(8).map { url in
                Hit(
                    kind: .file,
                    title: url.deletingPathExtension().lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path,
                    url: url,
                    line: nil
                )
            }
        }

        let lowered = query.lowercased()
        let recents = Set(appState.recentFiles)

        return appState.linkableNotes
            .compactMap { note -> (VaultNote, Int)? in
                let score = Command.fuzzyScore(query: lowered, in: note.title.lowercased())
                    ?? Command.fuzzyScore(query: lowered, in: note.path.lowercased())
                guard var score else { return nil }
                if recents.contains(note.url) { score += 20 }
                return (note, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.modifiedAt > rhs.0.modifiedAt
            }
            .prefix(10)
            .map { note, _ in
                Hit(kind: .file, title: note.title, subtitle: note.path, url: note.url, line: nil)
            }
    }

    private var contentHits: [Hit] {
        contentResults.prefix(12).map { result in
            Hit(
                kind: .content,
                title: result.fileName,
                subtitle: "L\(result.lineNumber)  \(result.lineContent.trimmingCharacters(in: .whitespaces))",
                url: result.fileURL,
                line: result.lineNumber
            )
        }
    }

    private var allHits: [Hit] {
        fileHits + contentHits
    }

    // MARK: Body

    var body: some View {
        let hits = allHits

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(Color.cmdsAccent)

                TextField("Search file names and contents…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit {
                        open(at: selectedIndex, in: hits)
                    }

                if isSearchingContent {
                    ProgressView()
                        .controlSize(.small)
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

            if hits.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "No Recent Files" : "No Matches", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text(query.isEmpty
                         ? "Open a folder or some files first — they get indexed for search."
                         : "No file names or contents match \"\(query)\"")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: []) {
                            let fileCount = fileHits.count
                            if fileCount > 0 {
                                OmnisearchSectionHeader(title: query.isEmpty ? "Recent" : "Files")
                            }
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                if index == fileCount && !contentHits.isEmpty {
                                    OmnisearchSectionHeader(title: "In-file Matches")
                                }
                                OmnisearchRow(hit: hit, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onHover { hovering in
                                        if hovering {
                                            navigatingByKeyboard = false
                                            selectedIndex = index
                                        }
                                    }
                                    .onTapGesture {
                                        open(at: index, in: hits)
                                    }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        guard navigatingByKeyboard else { return }
                        withAnimation {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Label("\(appState.linkableNotes.count) notes indexed", systemImage: "tray.full")
                if appState.currentFolder == nil {
                    Text("Open a folder (⌥⌘O) to enable content search")
                }
                Spacer()
                Text("↩ open · ↑↓ navigate")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 560, height: 440)
        .tint(.cmdsAccent)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            isSearchFocused = true
        }
        .onDisappear {
            contentSearchTask?.cancel()
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < allHits.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onChange(of: query) { _, newQuery in
            selectedIndex = 0
            scheduleContentSearch(for: newQuery)
        }
    }

    // MARK: Actions

    private func open(at index: Int, in hits: [Hit]) {
        guard index >= 0, index < hits.count else { return }
        let hit = hits[index]
        dismiss()
        appState.openDocument(at: hit.url, inNewTab: true, scrollToLine: hit.line)
    }

    /// Debounced full-text search over the open folder. File-name hits update
    /// instantly; content hits stream in ~250ms after typing pauses.
    private func scheduleContentSearch(for query: String) {
        contentSearchTask?.cancel()
        contentResults = []

        guard query.count >= 2, appState.currentFolder != nil else {
            isSearchingContent = false
            return
        }

        isSearchingContent = true
        contentSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let results = await appState.searchContent(query: query)
            guard !Task.isCancelled else { return }
            contentResults = results
            isSearchingContent = false
        }
    }
}

private struct OmnisearchSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct OmnisearchRow: View {
    let hit: OmnisearchView.Hit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hit.kind == .file ? "doc.text" : "text.magnifyingglass")
                .font(.system(size: 14))
                .frame(width: 22)
                .foregroundStyle(isSelected ? Color.cmdsAccentOn : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn : .primary)

                Text(hit.subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
            }

            Spacer()

            if hit.kind == .content {
                Image(systemName: "arrow.right.to.line")
                    .font(.caption2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.cmdsAccentOn.opacity(0.6)) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Color.cmdsAccent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

#if !SWIFT_PACKAGE
#Preview {
    OmnisearchView()
        .environment(AppState())
}
#endif
