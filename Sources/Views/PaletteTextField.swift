import SwiftUI
import AppKit

/// An NSTextField that reliably claims first-responder once it's in a window —
/// `makeNSView` runs before the sheet's window exists, so a one-shot async focus
/// can race and lose. Grabbing focus in `viewDidMoveToWindow` is deterministic.
final class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// A search field for command palettes that intercepts ↑/↓/Return/Escape at the
/// field-editor level (`doCommandBy:`). A plain SwiftUI TextField swallows the
/// arrow keys for cursor movement, so list navigation must be handled here —
/// this is the reliable AppKit pattern. Auto-focuses when it enters a window.
struct PaletteTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// What VoiceOver calls the field ("Command Palette"); the placeholder
    /// alone disappears once typing starts.
    var accessibilityName: String?
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = AutoFocusTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityName)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteTextField

        init(_ parent: PaletteTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                // Keep focus in the palette. Tab used to move it to the editor
                // behind the scrim, so typing edited the note.
                return true
            default:
                return false
            }
        }
    }
}

/// Speaks list highlights for VoiceOver. In the palettes and the completion
/// popup ↑/↓ move a highlight while focus stays in the text, so nothing
/// would be read otherwise. `text` is only built while VoiceOver runs.
enum VoiceOverAnnouncement {
    static func post(_ text: @autoclosure () -> String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        AccessibilityNotification.Announcement(text()).post()
    }

    /// "3 results, Export as PDF…": the count and the top row, which ↩ opens.
    static func results(_ titles: [String]) -> String {
        guard let top = titles.first else { return "No matches" }
        return "\(titles.count == 1 ? "1 result" : "\(titles.count) results"), \(top)"
    }
}
