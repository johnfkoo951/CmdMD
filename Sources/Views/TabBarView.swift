import SwiftUI

struct TabBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appState.tabs) { tab in
                        TabItemView(tab: tab)
                            .id(tab.id)
                    }

                    NewTabButton()

                    // Catch-all drop zone: without it a tab could never be
                    // dragged past the last position.
                    Spacer(minLength: 24)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { items, _ in
                            guard let idString = items.first,
                                  let sourceId = UUID(uuidString: idString) else { return false }
                            appState.moveTabToEnd(id: sourceId)
                            return true
                        }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
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
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .contextMenu {
            TabContextMenu(tab: tab)
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // Drag-to-reorder: dropping tab A onto tab B inserts A before B.
            guard let idString = items.first, let sourceId = UUID(uuidString: idString) else { return false }
            appState.moveTab(id: sourceId, before: tab.id)
            return true
        }
    }

    private func closeTab(_ tab: EditorTab) {
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
            appState.closeTab(tab)
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
