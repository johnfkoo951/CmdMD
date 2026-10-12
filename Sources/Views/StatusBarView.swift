import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 16) {
            if let document = appState.currentDocument {
                if appState.viewMode != .preview {
                    CursorPositionView()

                    Divider()
                        .frame(height: 12)
                }

                DocumentStatsView(document: document)
            }

            Spacer()

            if appState.updateAvailable {
                UpdateBadge()

                Divider()
                    .frame(height: 12)
            }

            // Stored flag — recomputing fullText equality here ran a full
            // document compare on every status-bar render.
            if appState.activeTab?.isDirty == true {
                HStack(spacing: 4) {
                    Circle()
                        .fill(CMDSBrand.develop)
                        .frame(width: 6, height: 6)
                    Text("Edited")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .transition(.opacity)
            }

            if appState.settings.zoomLevel != 1.0 {
                ZoomIndicator()
                    .transition(.opacity)
            }

            ViewModeIndicator()
        }
        .animation(.easeOut(duration: 0.15), value: appState.settings.zoomLevel == 1.0)
        .animation(.easeOut(duration: 0.15), value: appState.activeTab?.isDirty == true)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

/// Word / character / reading-time counters, recomputed at most once per typing
/// pause (250ms debounce via `.task(id:)`) instead of three full-document scans
/// per keystroke on the main thread.
struct DocumentStatsView: View {
    let document: MarkdownDocument

    @State private var wordCount = 0
    @State private var characterCount = 0
    @State private var hasCounted = false

    private var readingTimeMinutes: Int {
        max(1, wordCount / 200)
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "text.word.spacing")
                    .font(.system(size: 10))
                Text("\(wordCount.formatted()) words")
                    .font(.system(size: 11).monospacedDigit())
            }

            Divider()
                .frame(height: 12)

            HStack(spacing: 4) {
                Image(systemName: "character")
                    .font(.system(size: 10))
                Text("\(characterCount.formatted()) chars")
                    .font(.system(size: 11).monospacedDigit())
            }

            if wordCount > 0 {
                Divider()
                    .frame(height: 12)

                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text("\(readingTimeMinutes) min read")
                        .font(.system(size: 11).monospacedDigit())
                }
            }
        }
        .foregroundColor(.secondary)
        .opacity(hasCounted ? 1 : 0)
        .task(id: document.content) {
            // First pass (document open / tab switch) counts immediately;
            // subsequent keystrokes wait out the debounce.
            if hasCounted {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            let content = document.content
            let counts = await Task.detached(priority: .userInitiated) {
                (Self.countWords(in: content), content.count)
            }.value
            guard !Task.isCancelled else { return }
            wordCount = counts.0
            characterCount = counts.1
            hasCounted = true
        }
    }

    nonisolated static func countWords(in content: String) -> Int {
        content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// A subtle "update available" pill in the status bar that opens the release page.
struct UpdateBadge: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url = appState.updateURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 10))
                Text(appState.latestVersion.map { "Update \($0)" } ?? "Update available")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.cmdsAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(isHovering ? Color.cmdsAccentSoft : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .help("A new version is available — click to open the download page")
    }
}

struct CursorPositionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Text("Ln \(appState.cursorLine), Col \(appState.cursorColumn)")
            .font(.system(size: 11).monospacedDigit())
            .foregroundColor(.secondary)
    }
}

/// Shown only while zoomed away from 100%; clicking resets to actual size.
struct ZoomIndicator: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        Button {
            appState.resetZoom()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.settings.zoomLevel > 1
                      ? "plus.magnifyingglass" : "minus.magnifyingglass")
                    .font(.system(size: 10))
                Text("\(Int((appState.settings.zoomLevel * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
            }
            .foregroundColor(isHovering ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isHovering ? Color.secondary.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .help("Zoom level — click to reset to 100% (⌘0)")
    }
}

struct ViewModeIndicator: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        @Bindable var state = appState

        Menu {
            Picker("View Mode", selection: $state.viewMode) {
                Label("Source", systemImage: "text.alignleft").tag(ViewMode.source)
                Label("Split", systemImage: "rectangle.split.2x1").tag(ViewMode.split)
                Label("Preview", systemImage: "eye").tag(ViewMode.preview)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModeIcon)
                    .font(.system(size: 10))
                Text(appState.viewMode.rawValue)
                    .font(.system(size: 11))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundColor(isHovering ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isHovering ? Color.secondary.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .help("Change view mode (⌘1 / ⌘2 / ⌘3)")
    }

    private var viewModeIcon: String {
        switch appState.viewMode {
        case .source:
            return "text.alignleft"
        case .split:
            return "rectangle.split.2x1"
        case .preview:
            return "eye"
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VStack {
        Spacer()
        StatusBarView()
    }
    .frame(width: 600, height: 100)
    .environment(AppState())
}
#endif
