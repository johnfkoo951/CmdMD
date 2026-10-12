import SwiftUI

/// The capture window for the global Quick Capture hotkey when another app is
/// frontmost. A non-activating floating panel (Spotlight-style): it takes
/// keyboard focus without pulling CmdMD's main window over the user's work,
/// and it works when that window is closed — where the in-window ⇧⌘M sheet has
/// nothing to attach to. Closing it hands focus straight back to that app.
final class QuickCapturePanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    /// What is typed in the panel, kept while it is hidden (title-bar close):
    /// quitting turns it into a draft and the hot key brings the panel back.
    private(set) var pendingText = ""
    var hasUnsentText: Bool { !pendingText.isEmpty }

    func show(appState: AppState) {
        let panel = self.panel ?? makePanel(appState: appState)
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        panel?.close()
    }

    /// The title-bar close button (and ⌘W) only hides the panel, keeping what
    /// was typed for the next hot key press; it used to throw the text away.
    /// Cancel, Save and Send close it through `close()`, which starts fresh.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // The next capture starts from a fresh, empty view.
        panel = nil
        pendingText = ""
    }

    private func makePanel(appState: AppState) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "Quick Capture"
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Show on whichever Space is active, including over full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let hostingView = NSHostingView(
            rootView: QuickCaptureView(
                onDone: { [weak self] in self?.close() },
                onTextChange: { [weak self] in self?.pendingText = $0 }
            )
                .environment(appState)
                .tint(.cmdsAccent)
        )
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        panel.center()
        return panel
    }
}
