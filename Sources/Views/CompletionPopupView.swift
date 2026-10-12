import SwiftUI

struct CompletionPopupView: View {
    let items: [CompletionItem]
    @Binding var selectedIndex: Int
    let onSelect: (CompletionItem) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                CompletionRowView(
                    item: item,
                    isSelected: index == selectedIndex
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { selectedIndex = index }
                }
                .onTapGesture {
                    onSelect(item)
                }
                .accessibilityAction {
                    onSelect(item)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

struct CompletionRowView: View {
    let item: CompletionItem
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForType(item.type))
                .foregroundStyle(isSelected ? Color.cmdsAccentOn : colorForType(item.type))
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayText)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn : .primary)
                    .lineLimit(1)

                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.cmdsAccent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private func iconForType(_ type: CompletionContext.Kind) -> String {
        switch type {
        case .wikiLink: return "doc.text"
        case .tag: return "tag"
        }
    }

    private func colorForType(_ type: CompletionContext.Kind) -> Color {
        switch type {
        case .wikiLink: return .cmdsAccent
        case .tag: return CMDSBrand.connect
        }
    }
}

class CompletionWindowController: NSObject {
    private var window: NSWindow?
    private var hostingView: NSHostingView<CompletionPopupView>?
    private var items: [CompletionItem] = []
    private var selectedIndex: Int = 0
    private var onSelect: ((CompletionItem) -> Void)?
    /// The top row last spoken to VoiceOver.
    private var announcedTopText: String?
    
    /// The popup has no internal scrolling, so more rows than this would clip
    /// (and ↓ could select an invisible item). Ranked items degrade gracefully.
    private static let maxVisibleItems = 8
    /// Gap between the caret line and the popup.
    private static let caretGap: CGFloat = 4

    /// `caretRect` is the caret's line rect in screen coordinates.
    func show(items allItems: [CompletionItem], at caretRect: NSRect, in parentWindow: NSWindow?, onSelect: @escaping (CompletionItem) -> Void) {
        guard !allItems.isEmpty else {
            dismiss()
            return
        }

        let items = Array(allItems.prefix(Self.maxVisibleItems))
        let wasVisible = isVisible
        self.items = items
        self.selectedIndex = 0
        self.onSelect = onSelect

        if window == nil {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.level = .floating
            window?.hasShadow = true
        }

        // One hosting view for the popup's lifetime: this runs on every
        // keystroke, and building a fresh NSHostingView each time cost a frame.
        if let hostingView {
            hostingView.rootView = makePopupView()
        } else {
            let hostingView = NSHostingView(rootView: makePopupView())
            self.hostingView = hostingView
            window?.contentView = hostingView
        }

        // Measure the actual content height instead of assuming a row height —
        // rows with a detail line are taller than bare ones.
        let height = hostingView?.fittingSize.height ?? CGFloat(items.count) * 44
        let frame = Self.popupFrame(
            size: NSSize(width: 300, height: height),
            caretRect: caretRect,
            visibleFrame: Self.visibleFrame(for: caretRect, fallback: parentWindow)
        )
        window?.setFrame(frame, display: true)

        if let parentWindow = parentWindow {
            parentWindow.addChildWindow(window!, ordered: .above)
        }

        window?.orderFront(nil)

        // VoiceOver stays in the editor while Return/Tab insert the top row,
        // so say what that row is whenever it changes.
        if !wasVisible {
            VoiceOverAnnouncement.post("\(items.count == 1 ? "1 suggestion" : "\(items.count) suggestions"), \(items[0].displayText)")
        } else if items[0].text != announcedTopText {
            VoiceOverAnnouncement.post(items[0].displayText)
        }
        announcedTopText = items[0].text
    }

    func dismiss() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        items = []
        selectedIndex = 0
        announcedTopText = nil
    }

    /// Repositions the popup against the caret's line rect (screen coordinates)
    /// — used to track the caret while the editor scrolls underneath.
    func move(to caretRect: NSRect) {
        guard let window, window.isVisible else { return }
        let frame = Self.popupFrame(
            size: window.frame.size,
            caretRect: caretRect,
            visibleFrame: Self.visibleFrame(for: caretRect, fallback: window.parent)
        )
        window.setFrameOrigin(frame.origin)
    }

    /// Popup frame for a caret line: just below it, flipped above when the
    /// space below (menu bar/Dock-aware `visibleFrame`) is too short and the
    /// space above is larger, then clamped so no row ends up off screen.
    static func popupFrame(size: NSSize, caretRect: NSRect, visibleFrame: NSRect?) -> NSRect {
        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - caretGap - size.height)
        guard let visible = visibleFrame else { return NSRect(origin: origin, size: size) }

        let roomBelow = caretRect.minY - caretGap - visible.minY
        let roomAbove = visible.maxY - (caretRect.maxY + caretGap)
        if roomBelow < size.height, roomAbove > roomBelow {
            origin.y = caretRect.maxY + caretGap
        }
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        return NSRect(origin: origin, size: size)
    }

    /// Visible frame of the screen showing the caret (the editor window can
    /// span displays), falling back to the editor window's screen.
    private static func visibleFrame(for caretRect: NSRect, fallback window: NSWindow?) -> NSRect? {
        let caret = NSPoint(x: caretRect.minX, y: caretRect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(caret) } ?? window?.screen ?? NSScreen.main
        return screen?.visibleFrame
    }
    
    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        updateView()
        VoiceOverAnnouncement.post(items[selectedIndex].displayText)
    }

    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = min(items.count - 1, selectedIndex + 1)
        updateView()
        VoiceOverAnnouncement.post(items[selectedIndex].displayText)
    }
    
    func confirmSelection() {
        guard selectedIndex < items.count else { return }
        selectItem(items[selectedIndex])
    }
    
    private func selectItem(_ item: CompletionItem) {
        onSelect?(item)
        dismiss()
    }
    
    private func updateView() {
        hostingView?.rootView = makePopupView()
    }

    private func makePopupView() -> CompletionPopupView {
        CompletionPopupView(
            items: items,
            selectedIndex: Binding(get: { [weak self] in self?.selectedIndex ?? 0 },
                                   set: { [weak self] in self?.hoverSelect($0) }),
            onSelect: { [weak self] item in
                self?.selectItem(item)
            }
        )
    }

    /// Hover writes through the view's binding. SwiftUI doesn't observe this
    /// plain property, so repaint explicitly — otherwise the highlighted row and
    /// the row Return/Tab inserts silently diverge.
    private func hoverSelect(_ index: Int) {
        guard index != selectedIndex, items.indices.contains(index) else { return }
        selectedIndex = index
        updateView()
    }
    
    var isVisible: Bool {
        window?.isVisible ?? false
    }
}
