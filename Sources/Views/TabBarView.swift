import SwiftUI
import UniformTypeIdentifiers

/// What a tab carries while it is dragged to reorder the bar. Not its UUID as
/// a String: that is plain text, so a tab released over the editor dropped
/// "3F2504E0-…" into the note (and onto the Desktop, a text clipping).
struct TabDragItem: Codable, Transferable {
    let id: UUID

    /// A private type that text views, the preview and Finder don't read. A
    /// dynamic type (from a private MIME type) rather than `exportedAs:`: AppKit
    /// routes a drag to SwiftUI drop destinations only when its type conforms to
    /// public.data, and an exported type the Info.plist doesn't declare
    /// conforms to nothing, so no tab could be reordered.
    static let contentType = UTType(mimeType: "application/x-cmdmd-tab", conformingTo: .data) ?? .data

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

struct TabBarView: View {
    @Environment(AppState.self) private var appState
    @State private var barWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.tabs) { tab in
                        TabItemView(tab: tab)
                            // Natural width: the row is now offered the whole
                            // bar (below), which would stretch every tab.
                            .fixedSize(horizontal: true, vertical: false)
                            .id(tab.id)
                    }

                    NewTabButton()

                    // Catch-all drop zone: without it a tab could never be
                    // dragged past the last position. It fills the rest of the
                    // bar (at least 24 pt once the tabs overflow) and the row's
                    // height: a Spacer has none, so the target was 0 pt tall.
                    Spacer(minLength: 24)
                        .frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .dropDestination(for: TabDragItem.self) { items, _ in
                            guard let sourceId = items.first?.id else { return false }
                            appState.moveTabToEnd(id: sourceId)
                            return true
                        }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                // A horizontal scroll view offers its content no width, so the
                // zone above shrank to its 24 pt minimum; make the row span the bar.
                .frame(minWidth: barWidth, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            .onChange(of: appState.activeTabId) { _, newId in
                // Keyboard tab switches must not leave the active tab offscreen.
                guard let newId else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newId, anchor: nil)
                }
            }
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct TabItemView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var controlActiveState
    let tab: EditorTab

    @State private var isHovering = false

    private var isActive: Bool {
        appState.activeTabId == tab.id
    }

    private var isFavorited: Bool {
        guard let url = tab.fileURL else { return false }
        return appState.favorites.contains(where: { $0.url == url })
    }

    var body: some View {
        HStack(spacing: 5) {
            // Native document-tab idiom: one leading 16pt slot that shows the
            // dirty dot at rest and swaps to the close button on hover —
            // instead of a trailing ✕ stacking next to the dot.
            ZStack {
                if isHovering {
                    Button {
                        closeTab(tab)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close Tab")
                    // VoiceOver gets the Close Tab action below instead; merged
                    // into the tab, this hover-only button would turn activating
                    // a tab under the pointer into closing it.
                    .accessibilityHidden(true)
                } else if tab.isDirty {
                    Circle()
                        .fill(CMDSBrand.develop)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())

            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            if isFavorited {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.yellow)
            }

            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                // Native tabs clamp width; one long filename must not produce
                // a tab wider than the window.
                .frame(maxWidth: 180, alignment: .leading)
                .foregroundColor(isActive ? .primary : .secondary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive
                      ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                      : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        // Native chrome dims when the window resigns key; hand-rolled tabs
        // staying fully saturated is a constant "not really native" tell.
        .opacity(controlActiveState == .inactive ? 0.6 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.activeTabId = tab.id
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        // The label replaces the merged children, so the dirty dot, pin and
        // star are spoken here; the close button is hover-only, hence the action.
        .accessibilityValue(Self.accessibilityStatus(isDirty: tab.isDirty, isPinned: tab.isPinned, isFavorited: isFavorited))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction {
            appState.activeTabId = tab.id
        }
        .accessibilityAction(named: "Close Tab") {
            closeTab(tab)
        }
        .contextMenu {
            TabContextMenu(tab: tab)
        }
        .draggable(TabDragItem(id: tab.id))
        .dropDestination(for: TabDragItem.self) { items, _ in
            // Drag-to-reorder: dropping tab A onto tab B inserts A before B.
            guard let sourceId = items.first?.id else { return false }
            appState.moveTab(id: sourceId, before: tab.id)
            return true
        }
    }

    /// VoiceOver's value for a tab: the states its glyphs show, e.g. "Edited, Pinned".
    static func accessibilityStatus(isDirty: Bool, isPinned: Bool, isFavorited: Bool) -> String {
        [isDirty ? "Edited" : nil, isPinned ? "Pinned" : nil, isFavorited ? "Favorite" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func closeTab(_ tab: EditorTab) {
        // Commit a syllable still being composed, then re-read the dirty flag
        // it may have set.
        appState.commitPendingComposition()
        let tab = appState.tabs.first(where: { $0.id == tab.id }) ?? tab
        if tab.isDirty && appState.settings.confirmBeforeClosingDirtyTabs {
            appState.closeTabWithConfirmation(tab)
        } else {
            appState.closeTab(tab)
        }
    }
}

struct TabContextMenu: View {
    @Environment(AppState.self) private var appState
    let tab: EditorTab

    private var isFavorited: Bool {
        guard let url = tab.fileURL else { return false }
        return appState.favorites.contains(where: { $0.url == url })
    }

    var body: some View {
        Button {
            appState.closeTabsWithConfirmation([tab])
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }

        Button {
            appState.closeOtherTabs(except: tab)
        } label: {
            Label("Close Other Tabs", systemImage: "xmark.square")
        }

        Button {
            appState.closeTabsToRight(of: tab)
        } label: {
            Label("Close Tabs to the Right", systemImage: "arrow.right.to.line")
        }

        Divider()

        Button {
            appState.toggleTabPin(tab)
        } label: {
            if tab.isPinned {
                Label("Unpin Tab", systemImage: "pin.slash")
            } else {
                Label("Pin Tab", systemImage: "pin")
            }
        }

        if let url = tab.fileURL {
            if isFavorited {
                Button {
                    if let favorite = appState.favorites.first(where: { $0.url == url }) {
                        appState.removeFromFavorites(favorite)
                    }
                } label: {
                    Label("Remove from Favorites", systemImage: "star.slash")
                }
            } else {
                Button {
                    appState.addToFavorites(url)
                } label: {
                    Label("Add to Favorites", systemImage: "star")
                }
            }
        }

        Divider()

        if let url = tab.fileURL {
            Button {
                appState.openInObsidian(fileURL: url)
            } label: {
                Label("Open in Obsidian", systemImage: "arrow.up.forward.app")
            }

            Button {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url.path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }
}

struct NewTabButton: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        Button {
            appState.createNewTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .help("New Tab (⌘T)")
        .accessibilityLabel("New Tab")
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VStack(spacing: 0) {
        TabBarView()
        Spacer()
    }
    .frame(width: 600, height: 400)
    .environment(AppState())
}
#endif
