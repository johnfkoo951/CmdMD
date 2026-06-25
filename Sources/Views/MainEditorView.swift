import SwiftUI

struct MainEditorView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if appState.settings.showTabBar && !appState.tabs.isEmpty {
                TabBarView()
            }

            if let document = appState.currentDocument, let fileURL = document.fileURL {
                SimpleBreadcrumbView(fileURL: fileURL, folderURL: appState.currentFolder)
            }

            Group {
                if let document = appState.currentDocument {
                    // The editor + preview panes persist across tab switches and
                    // update in place (keyed by document id inside the panes), so a
                    // switch no longer tears down the NSTextView / spawns a new
                    // WKWebView — that recreation was the tab-switch delay. Undo,
                    // scroll, and selection are reset on a real document switch.
                    DocumentEditorView(document: document)
                } else {
                    WelcomeView()
                }
            }

            if appState.settings.showStatusBar, appState.currentDocument != nil {
                StatusBarView()
            }
        }
    }
}

// MARK: - Breadcrumb

struct SimpleBreadcrumbView: View {
    @Environment(AppState.self) private var appState
    let fileURL: URL
    let folderURL: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let parts = computePathParts()
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 3) {
                        Image(systemName: index == parts.count - 1 ? "doc.text" : "folder")
                            .font(.system(size: 10))
                        Text(part)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .foregroundStyle(index == parts.count - 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fileURL.path, forType: .string)
                appState.showToast("Path copied")
            }
        }
    }

    private func computePathParts() -> [String] {
        var parts: [String] = []
        var currentURL = fileURL.deletingLastPathComponent()

        if let folderURL = folderURL {
            while currentURL.path != "/" && currentURL.path.hasPrefix(folderURL.path) {
                parts.insert(currentURL.lastPathComponent, at: 0)
                currentURL = currentURL.deletingLastPathComponent()
            }
        } else {
            for _ in 0..<2 {
                if currentURL.path == "/" { break }
                parts.insert(currentURL.lastPathComponent, at: 0)
                currentURL = currentURL.deletingLastPathComponent()
            }
        }

        parts.append(fileURL.lastPathComponent)
        return parts
    }
}

// MARK: - Editor / Preview layout

/// Keeps BOTH panes mounted at all times and switches modes by moving them,
/// not by rebuilding them. Tearing down the WKWebView (and its web process) on
/// every Source↔Preview toggle was what made mode switching feel slow; now the
/// preview stays warm — pre-rendered in the background while you type — so the
/// toggle is instant. Source↔Preview keeps each pane at full width (offset
/// offscreen instead of resized), so even text reflow is avoided.
struct DocumentEditorView: View {
    @Environment(AppState.self) private var appState
    let document: MarkdownDocument

    private static let minPaneWidth: CGFloat = 280

    var body: some View {
        @Bindable var state = appState
        let mode = appState.viewMode

        GeometryReader { geometry in
            let total = max(1, geometry.size.width)
            let height = geometry.size.height
            let minFraction = min(0.5, Self.minPaneWidth / total)
            let fraction = min(max(appState.splitFraction, minFraction), 1 - minFraction)
            let editorWidth: CGFloat = mode == .split ? (total * fraction).rounded() : total
            let previewWidth: CGFloat = mode == .split ? total - editorWidth : total

            ZStack(alignment: .topLeading) {
                EditorPane()
                    .frame(width: editorWidth, height: height)
                    .offset(x: mode == .preview ? -total : 0)
                    .opacity(mode == .preview ? 0 : 1)
                    .allowsHitTesting(mode != .preview)

                PreviewPane()
                    .frame(width: previewWidth, height: height)
                    .offset(x: mode == .source ? total : (mode == .split ? editorWidth : 0))
                    .opacity(mode == .source ? 0 : 1)
                    .allowsHitTesting(mode != .source)

                if mode == .split {
                    SplitDividerHandle(
                        fraction: $state.splitFraction,
                        totalWidth: total,
                        minFraction: minFraction
                    )
                    .frame(height: height)
                    .offset(x: editorWidth - 4)

                    HStack {
                        Spacer()
                        ScrollSyncButton()
                        Spacer()
                    }
                }
            }
            .clipped()
        }
        .onChange(of: appState.viewMode) { _, newMode in
            // The hidden editor must not keep keyboard focus, or typing in
            // preview mode would edit the document invisibly.
            if newMode == .preview {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }
}

/// Draggable divider for the persistent split layout.
struct SplitDividerHandle: View {
    @Binding var fraction: CGFloat
    let totalWidth: CGFloat
    let minFraction: CGFloat

    @State private var dragStartFraction: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 9)
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartFraction ?? fraction
                        dragStartFraction = start
                        let proposed = start + value.translation.width / totalWidth
                        fraction = min(max(proposed, minFraction), 1 - minFraction)
                    }
                    .onEnded { _ in
                        dragStartFraction = nil
                    }
            )
    }
}

struct ScrollSyncButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Button {
            state.settings.scrollSyncEnabled.toggle()
            state.saveUserData()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.settings.scrollSyncEnabled ? "link" : "link.badge.plus")
                    .font(.system(size: 10))
                Text(appState.settings.scrollSyncEnabled ? "Sync" : "Unsynced")
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appState.settings.scrollSyncEnabled ? Color.cmdsAccentSoft : Color(nsColor: .controlBackgroundColor))
            .foregroundStyle(appState.settings.scrollSyncEnabled ? Color.cmdsAccent : Color.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help(appState.settings.scrollSyncEnabled ? "Click to disable scroll sync" : "Click to enable scroll sync")
    }
}

struct EditorPane: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false

    /// Resolves the editor font from settings.fontName, falling back to the
    /// system monospaced font if the named font isn't installed.
    private func editorFont() -> NSFont {
        let size = appState.settings.fontSize
        let name = appState.settings.fontName
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            return custom
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var body: some View {
        let settings = appState.settings
        // CMDS follows the app appearance; other themes are used as chosen.
        let theme = settings.editorTheme.resolved(forDark: colorScheme == .dark)

        MarkdownTextEditor(
            documentID: appState.currentDocument?.id,
            text: Binding(
                get: { appState.currentDocument?.content ?? "" },
                set: { appState.updateContent($0) }
            ),
            font: editorFont(),
            editorTheme: theme,
            softWrap: settings.softWrap,
            showLineNumbers: settings.showLineNumbers,
            highlightCurrentLine: settings.highlightCurrentLine,
            tabSize: settings.tabSize,
            insertSpacesForTab: settings.insertSpacesInsteadOfTabs,
            enableCompletion: settings.enableAutocompletion,
            scrollSyncEnabled: settings.scrollSyncEnabled && appState.viewMode == .split,
            onImageDrop: { imageURL in
                handleImageDrop(imageURL)
            },
            onSelectionChange: { line, column in
                appState.updateCursorPosition(line: line, column: column)
            },
            completionsProvider: { context in
                CompletionService.completions(
                    for: context,
                    notes: appState.linkableNotes,
                    tags: appState.knownTags
                )
            }
        )
        .background(theme.backgroundColor)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.cmdsAccent, lineWidth: 3)
                    .background(Color.cmdsAccent.opacity(0.1))
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            handleImageDrop(url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    private func handleImageDrop(_ imageURL: URL) {
        guard let documentURL = appState.currentDocument?.fileURL else {
            insertImageMarkdown(imageURL, relativePath: imageURL.path)
            return
        }

        let documentFolder = documentURL.deletingLastPathComponent()
        let assetsFolder = documentFolder.appendingPathComponent("assets")

        do {
            if !FileManager.default.fileExists(atPath: assetsFolder.path) {
                try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
            }

            let destinationURL = assetsFolder.appendingPathComponent(imageURL.lastPathComponent).uniquified()
            try FileManager.default.copyItem(at: imageURL, to: destinationURL)

            let relativePath = "assets/\(destinationURL.lastPathComponent)"
            insertImageMarkdown(destinationURL, relativePath: relativePath)
            appState.showToast("Image added")
        } catch {
            insertImageMarkdown(imageURL, relativePath: imageURL.path)
        }
    }

    private func insertImageMarkdown(_ url: URL, relativePath: String) {
        let imageName = url.deletingPathExtension().lastPathComponent
        let markdown = "![\(imageName)](\(relativePath))"

        if var content = appState.currentDocument?.content {
            if content.isEmpty || content.hasSuffix("\n") {
                content += markdown + "\n"
            } else {
                content += "\n" + markdown + "\n"
            }
            appState.updateContent(content)
        }
    }
}

struct PreviewPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        MarkdownPreviewView(
            documentID: appState.currentDocument?.id,
            markdown: appState.currentDocument?.content ?? "",
            baseURL: appState.currentDocument?.fileURL?.deletingLastPathComponent(),
            options: appState.renderOptions(),
            scrollSyncEnabled: appState.settings.scrollSyncEnabled && appState.viewMode == .split
        )
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 48)

                    // Hero
                    VStack(spacing: 14) {
                        BrandLogo(size: 92, showWordmark: true)

                        VStack(spacing: 4) {
                            Text("CmdMD")
                                .font(.system(size: 32, weight: .bold, design: .rounded))

                            Text("Fast Markdown review · Obsidian vault router")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 32)

                    // Actions + recents
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 10) {
                            WelcomeButton(title: "Open File", subtitle: "Review a Markdown file", icon: "doc.badge.plus", shortcut: "⌘O") {
                                appState.openFile()
                            }
                            WelcomeButton(title: "Open Folder", subtitle: "Browse a folder of notes", icon: "folder.badge.plus", shortcut: "⌥⌘O") {
                                appState.openFolder()
                            }
                            WelcomeButton(title: "New Draft", subtitle: "Start writing a quick note", icon: "square.and.pencil", shortcut: "⌘N") {
                                appState.createNewDraft()
                            }
                            WelcomeButton(title: "Add Vault", subtitle: "Connect an Obsidian vault", icon: "folder.badge.gearshape", shortcut: nil) {
                                appState.showVaultManager = true
                            }
                        }
                        .frame(width: 300)

                        if !appState.recentFiles.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Recent")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                ForEach(appState.recentFiles.prefix(7), id: \.self) { url in
                                    Button {
                                        appState.openDocument(at: url)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "doc.text")
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(url.deletingPathExtension().lastPathComponent)
                                                    .font(.system(size: 13))
                                                    .lineLimit(1)
                                                Text(url.deletingLastPathComponent().lastPathComponent)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            .frame(width: 260)
                        }
                    }

                    Spacer(minLength: 24)

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 11))
                        Text("Drop a Markdown file anywhere to open it")
                            .font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
                }
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct WelcomeButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let shortcut: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(Color.cmdsAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1 : 0.7))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovering ? Color.cmdsAccent.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension Notification.Name {
    static let openInternalLink = Notification.Name("openInternalLink")
    static let scrollToHeading = Notification.Name("scrollToHeading")
}

#if !SWIFT_PACKAGE
#Preview {
    MainEditorView()
        .environment(AppState())
        .frame(width: 800, height: 600)
}
#endif
