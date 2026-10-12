import SwiftUI

/// ⇧⌘O everything-search: fuzzy file-name matching over the note index
/// (open folder + registered vaults, recents boosted) plus live full-text
/// matches from the same folder and vaults. Enter opens the hit — content
/// matches jump straight to the matched line.
/// Reference-type state — the ↑/↓ key monitor is an escaping closure, and mutating
/// @State through a captured View value won't re-render; an @Observable object does.
@Observable final class OmnisearchModel {
    var query = ""
    var selectedIndex = 0
    var navigatingByKeyboard = false
    var contentResults: [SearchResult] = []
    var isSearchingContent = false
    /// File-name hits for `query`, scored once per query (or index) change —
    /// not on every render, arrow key and hovered row.
    var fileHits: [OmnisearchView.Hit] = []
}

struct OmnisearchView: View {
    @Environment(AppState.self) private var appState

    @State private var model = OmnisearchModel()
    @State private var contentSearchTask: Task<Void, Never>?

    /// Presented as an overlay, not a sheet — closing means clearing the flag.
    private func dismiss() {
        appState.showOmnisearch = false
    }

    struct Hit: Identifiable {
        enum Kind {
            case file
            case content
        }

        let kind: Kind
        let title: String
        let subtitle: String
        let url: URL
        let line: Int?
        /// The search result a content hit shows. A match in the properties
        /// has no line, so it is told apart by this.
        var resultID: UUID?

        /// Stable across re-scoring (a fresh UUID per pass made every row new
        /// on every render). A file hit and a content hit in the same file
        /// differ by the line (or result) suffix.
        var id: String {
            line.map { "\(url.path)#\($0)" } ?? resultID.map { "\(url.path)#\($0.uuidString)" } ?? url.path
        }
    }

    /// In-file matches shown — and so the most the content scan collects.
    private static let maxContentHits = 12

    // MARK: Hit assembly

    /// Fuzzy file-name hits for `query`: recent files for an empty query,
    /// otherwise the best-scoring notes (recents boosted).
    static func fileHits(query: String, notes: [VaultNote], recentFiles: [URL]) -> [Hit] {
        if query.isEmpty {
            // Bare ⇧⌘O = recent files, most useful default.
            return recentFiles.prefix(8).map { url in
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
        let recents = Set(recentFiles)

        return notes
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

    private func refreshFileHits() {
        model.fileHits = Self.fileHits(
            query: model.query,
            notes: appState.linkableNotes,
            recentFiles: appState.recentFiles
        )
    }

    /// In-file hits. Titles match file hits (no extension) and subtitles lead
    /// with the note's folder, so same-named notes ("index.md" in two
    /// folders) can be told apart.
    static func contentHits(results: [SearchResult], roots: [URL]) -> [Hit] {
        results.map { result in
            Hit(
                kind: .content,
                title: result.fileURL.deletingPathExtension().lastPathComponent,
                subtitle: "\(folderLabel(for: result.fileURL, roots: roots)) · \(result.lineNumber.map { "L\($0)" } ?? "Properties")  \(result.lineContent.trimmingCharacters(in: .whitespaces))",
                url: result.fileURL,
                line: result.lineNumber,
                resultID: result.id
            )
        }
    }

    /// The file's folder relative to the search root holding it, or the
    /// root's own name for a note at its top level.
    static func folderLabel(for fileURL: URL, roots: [URL]) -> String {
        let folder = fileURL.deletingLastPathComponent().standardizedFileURL.path
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            if folder == rootPath { return root.lastPathComponent }
            if folder.hasPrefix(rootPath + "/") { return String(folder.dropFirst(rootPath.count + 1)) }
        }
        return (folder as NSString).lastPathComponent
    }

    private var contentHits: [Hit] {
        Self.contentHits(results: Array(model.contentResults.prefix(Self.maxContentHits)), roots: appState.contentSearchRoots)
    }

    private var allHits: [Hit] {
        model.fileHits + contentHits
    }

    // MARK: Body

    var body: some View {
        @Bindable var model = model
        let hits = allHits

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(Color.cmdsAccent)

                PaletteTextField(
                    text: $model.query,
                    placeholder: "Search file names and contents…",
                    accessibilityName: "Omnisearch",
                    onMoveUp: { moveSelection(-1) },
                    onMoveDown: { moveSelection(1) },
                    onSubmit: { open(at: model.selectedIndex, in: allHits) },
                    onCancel: { dismiss() }
                )
                .frame(height: 24)

                if model.isSearchingContent {
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

            if hits.isEmpty && model.isSearchingContent {
                // Content hits are still coming — "No Matches" here was premature.
                ProgressView("Searching contents…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hits.isEmpty {
                ContentUnavailableView {
                    Label(model.query.isEmpty ? "No Recent Files" : "No Matches", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text(model.query.isEmpty
                         ? "Open a folder or some files first — they get indexed for search."
                         : searchesContent(model.query)
                            ? "No file names or contents match \"\(model.query)\""
                            : "No file names match \"\(model.query)\"")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            let fileCount = model.fileHits.count
                            if fileCount > 0 {
                                OmnisearchSectionHeader(title: model.query.isEmpty ? "Recent" : "Files")
                            }
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                if index == fileCount && !model.contentResults.isEmpty {
                                    OmnisearchSectionHeader(title: "In-file Matches")
                                }
                                OmnisearchRow(hit: hit, isSelected: index == model.selectedIndex)
                                    .id(index)
                                    .onHover { hovering in
                                        if hovering {
                                            model.navigatingByKeyboard = false
                                            model.selectedIndex = index
                                        }
                                    }
                                    .onTapGesture {
                                        open(at: index, in: hits)
                                    }
                                    .accessibilityAction {
                                        open(at: index, in: hits)
                                    }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.selectedIndex) { _, newIndex in
                        guard model.navigatingByKeyboard else { return }
                        proxy.scrollTo(newIndex, anchor: nil)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Label("\(appState.linkableNotes.count) notes indexed", systemImage: "tray.full")
                if appState.contentSearchRoots.isEmpty {
                    Text("\(appState.shortcutHelp("Open a folder", .openFolder)) to enable content search")
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
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        .onAppear {
            refreshFileHits()
        }
        .onDisappear {
            contentSearchTask?.cancel()
        }
        .onChange(of: model.query) { _, newQuery in
            model.selectedIndex = 0
            refreshFileHits()
            scheduleContentSearch(for: newQuery)
            // What ↩ would open now; with no file hits yet, wait for contents.
            if !(model.fileHits.isEmpty && model.isSearchingContent) {
                VoiceOverAnnouncement.post(VoiceOverAnnouncement.results(allHits.map(\.title)))
            }
        }
        .onChange(of: appState.linkableNotes.count) {
            // The note index can finish building while the panel is open.
            refreshFileHits()
        }
    }

    /// Moves the highlight by `delta`, clamped to the hit list.
    private func moveSelection(_ delta: Int) {
        let hits = allHits
        guard !hits.isEmpty else { return }
        model.navigatingByKeyboard = true
        model.selectedIndex = min(max(model.selectedIndex + delta, 0), hits.count - 1)
        let hit = hits[model.selectedIndex]
        VoiceOverAnnouncement.post(hit.kind == .content ? "\(hit.title), \(hit.subtitle)" : hit.title)
    }

    // MARK: Actions

    private func open(at index: Int, in hits: [Hit]) {
        guard index >= 0, index < hits.count else { return }
        let hit = hits[index]
        dismiss()
        appState.openDocument(at: hit.url, inNewTab: true, scrollToLine: hit.line)
    }

    /// Debounced full-text search over the open folder and registered vaults.
    /// File-name hits update instantly; content hits stream in ~250ms after
    /// typing pauses. The scan stops at the hits shown instead of reading on
    /// to 500 matches.
    private func scheduleContentSearch(for query: String) {
        contentSearchTask?.cancel()
        model.contentResults = []

        guard searchesContent(query) else {
            model.isSearchingContent = false
            return
        }

        model.isSearchingContent = true
        contentSearchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let results = await appState.searchContent(query: query, limit: Self.maxContentHits)
            guard !Task.isCancelled else { return }
            model.contentResults = results
            model.isSearchingContent = false
            if model.fileHits.isEmpty {
                VoiceOverAnnouncement.post(VoiceOverAnnouncement.results(allHits.map(\.title)))
            }
        }
    }

    /// Whether `query` gets a content search, not just file-name matching.
    private func searchesContent(_ query: String) -> Bool {
        query.count >= 2 && !appState.contentSearchRoots.isEmpty
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
                .accessibilityHidden(true)

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
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Color.cmdsAccent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

#if !SWIFT_PACKAGE
#Preview {
    OmnisearchView()
        .environment(AppState())
}
#endif
