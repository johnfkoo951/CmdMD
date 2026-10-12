import SwiftUI
import AppKit
import WebKit

extension Notification.Name {
    /// A Find menu command while the rendered preview is the visible pane.
    /// Object: its `NSTextFinder.Action`. Observed by `PreviewFindBar`.
    static let previewFindCommand = Notification.Name("previewFindCommand")
    /// The preview find bar asking the preview to search.
    /// Object: a `PreviewFindRequest`.
    static let findInPreview = Notification.Name("findInPreview")
    /// The search ended: clear the highlighted match. Object: a Bool, whether
    /// the preview should take keyboard focus (Esc / Done).
    static let endFindInPreview = Notification.Name("endFindInPreview")
    /// Use Selection for Find asking the preview for the text selected on
    /// the page. Object: a `PreviewSelectionRequest`.
    static let previewSelectionForFind = Notification.Name("previewSelectionForFind")
}

/// Routes Find › Find in Document / Find Next / Find Previous to the pane the
/// user is looking at. In Preview mode — the default — the source editor is
/// hidden but still mounted: its find bar opened unseen there, and Esc then
/// gave the hidden text keyboard focus, so typing edited the document
/// invisibly. Split and Source keep the editor's native find bar.
enum DocumentFind {
    static func notificationName(for viewMode: ViewMode) -> Notification.Name {
        viewMode == .preview ? .previewFindCommand : .showDocumentSearch
    }

    static func perform(_ action: NSTextFinder.Action, in viewMode: ViewMode) {
        NotificationCenter.default.post(name: notificationName(for: viewMode), object: action)
    }
}

/// Asks the preview for its selected text, "" when nothing is selected.
struct PreviewSelectionRequest {
    var completion: (String) -> Void
}

/// One search of the rendered preview.
struct PreviewFindRequest {
    var query: String
    var backwards = false
    /// Search from the start of the current match instead of after it, so
    /// typing extends the match in place rather than skipping ahead.
    var fromCurrentMatch = false
    /// Called with whether a match was found.
    var completion: ((Bool) -> Void)?

    /// Case-insensitive and wrapping at either end, like the source find bar.
    var configuration: WKFindConfiguration {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        return configuration
    }
}

/// Find bar over the rendered preview (Safari-style, top trailing): search as
/// you type, Return / ⇧Return or ⌘G / ⇧⌘G for next / previous, Esc to close.
/// WebKit selects each match and scrolls it into view. Preview mode only.
struct PreviewFindBar: View {
    @Environment(AppState.self) private var appState
    @State private var isVisible = false
    @State private var query = ""
    @State private var noMatch = false
    /// Bumped to focus the field and select its text (⌘F while open).
    @State private var focusRequest = 0
    /// Only the latest search may report "No results".
    @State private var searchGeneration = 0

    var body: some View {
        // Always mounted (empty while hidden) so menu commands reach it.
        ZStack(alignment: .topTrailing) {
            if isVisible {
                bar
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .previewFindCommand)) { note in
            handle(note.object as? NSTextFinder.Action ?? .showFindInterface)
        }
        .onChange(of: appState.viewMode) { _, mode in
            if mode != .preview { close(focusPreview: false) }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            PreviewFindField(
                text: $query,
                focusRequest: focusRequest,
                onSubmit: { backwards in search(backwards: backwards) },
                onCancel: { close(focusPreview: true) }
            )
            .frame(width: 200)

            if noMatch {
                Text("No results")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 2) {
                Button {
                    search(backwards: true)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Find Previous (⇧⌘G)")
                .accessibilityLabel("Find Previous")

                Button {
                    search(backwards: false)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Find Next (⌘G)")
                .accessibilityLabel("Find Next")
            }
            .disabled(query.isEmpty)

            Button("Done") {
                close(focusPreview: true)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .padding(10)
        // Search as you type, after a short pause; the match grows in place.
        .task(id: query) {
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            search(backwards: false, fromCurrentMatch: true)
        }
        .onChange(of: query) { _, newQuery in
            if newQuery.isEmpty { endSearch(focusPreview: false) }
        }
        .onChange(of: appState.currentDocument?.id) { _, _ in
            noMatch = false
        }
    }

    private func handle(_ action: NSTextFinder.Action) {
        if action == .setSearchString {
            // Use Selection for Find, as in the source find bar: the
            // selection becomes the query (searched if the bar is open), and
            // ⌘G / ⇧⌘G step through it.
            let request = PreviewSelectionRequest { selection in
                let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { query = text }
            }
            NotificationCenter.default.post(name: .previewSelectionForFind, object: request)
            return
        }
        isVisible = true
        if action == .nextMatch || action == .previousMatch, !query.isEmpty {
            search(backwards: action == .previousMatch)
        } else {
            focusRequest += 1
        }
    }

    private func search(backwards: Bool, fromCurrentMatch: Bool = false) {
        guard !query.isEmpty else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let request = PreviewFindRequest(
            query: query,
            backwards: backwards,
            fromCurrentMatch: fromCurrentMatch,
            completion: { found in
                if generation == searchGeneration { noMatch = !found }
            }
        )
        NotificationCenter.default.post(name: .findInPreview, object: request)
    }

    private func close(focusPreview: Bool) {
        guard isVisible else { return }
        isVisible = false
        endSearch(focusPreview: focusPreview)
    }

    private func endSearch(focusPreview: Bool) {
        searchGeneration += 1
        noMatch = false
        NotificationCenter.default.post(name: .endFindInPreview, object: focusPreview)
    }
}

/// The find bar's search field. Return / ⇧Return and Esc are handled at the
/// field-editor level (`doCommandBy:`), as in PaletteTextField; Esc closes
/// the bar instead of just clearing the field.
struct PreviewFindField: NSViewRepresentable {
    @Binding var text: String
    /// Bumped to focus the field and select its text.
    var focusRequest: Int
    var onSubmit: (_ backwards: Bool) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = FindSearchField()
        field.delegate = context.coordinator
        field.placeholderString = "Find in Preview"
        field.stringValue = text
        context.coordinator.focusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            field.selectText(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PreviewFindField
        var focusRequest = 0

        init(_ parent: PreviewFindField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// The field's clear (x) button.
        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Takes keyboard focus (text selected) once it's in a window — `makeNSView`
/// runs before the window exists, as with AutoFocusTextField.
private final class FindSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.selectText(nil)
        }
    }
}
