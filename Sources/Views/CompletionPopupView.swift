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
    
    /// The popup has no internal scrolling, so more rows than this would clip
    /// (and ↓ could select an invisible item). Ranked items degrade gracefully.
    private static let maxVisibleItems = 8

    func show(items allItems: [CompletionItem], at point: NSPoint, in parentWindow: NSWindow?, onSelect: @escaping (CompletionItem) -> Void) {
        guard !allItems.isEmpty else {
            dismiss()
            return
        }

        let items = Array(allItems.prefix(Self.maxVisibleItems))
        self.items = items
        self.selectedIndex = 0
        self.onSelect = onSelect

        let popupView = CompletionPopupView(
            items: items,
            selectedIndex: Binding(get: { [weak self] in self?.selectedIndex ?? 0 },
                                   set: { [weak self] in self?.selectedIndex = $0 }),
            onSelect: { [weak self] item in
                self?.selectItem(item)
            }
        )

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

        hostingView = NSHostingView(rootView: popupView)
        window?.contentView = hostingView

        // Measure the actual content height instead of assuming a row height —
        // rows with a detail line are taller than bare ones.
        let height = hostingView?.fittingSize.height ?? CGFloat(items.count) * 44
        let origin = NSPoint(x: point.x, y: point.y - height)
        window?.setFrame(NSRect(origin: origin, size: NSSize(width: 300, height: height)), display: true)

        if let parentWindow = parentWindow {
            parentWindow.addChildWindow(window!, ordered: .above)
        }

        window?.orderFront(nil)
    }
    
    func dismiss() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        items = []
        selectedIndex = 0
    }

    /// Repositions the popup (top-left anchor) — used to track the caret while
    /// the editor scrolls underneath.
    func move(to point: NSPoint) {
        guard let window, window.isVisible else { return }
        window.setFrameOrigin(NSPoint(x: point.x, y: point.y - window.frame.height))
    }
    
    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        updateView()
    }
    
    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = min(items.count - 1, selectedIndex + 1)
        updateView()
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
        let popupView = CompletionPopupView(
            items: items,
            selectedIndex: Binding(get: { [weak self] in self?.selectedIndex ?? 0 },
                                   set: { [weak self] in self?.selectedIndex = $0 }),
            onSelect: { [weak self] item in
                self?.selectItem(item)
            }
        )
        hostingView?.rootView = popupView
    }
    
    var isVisible: Bool {
        window?.isVisible ?? false
    }
}
