import AppKit

/// Keeps the editor window wide enough for the side panes it shows.
///
/// With the sidebar and the inspector both open, a window narrower than the
/// split views' combined minimum never settles: SwiftUI re-reports a column's
/// minimum on every update-constraints pass until AppKit gives up and aborts
/// the app. Showing the inspector in a ~800 pt window, or restoring a session
/// into a narrow saved frame, did exactly that. So before a pane appears the
/// window grows to fit it, and when the screen can't hold that, the other pane
/// closes — never letting the layout reach an unsatisfiable state.
enum PaneRoom {
    enum Pane { case sidebar, inspector }

    struct Panes: Hashable {
        var sidebar: Bool
        var inspector: Bool
    }

    /// What to do so `wanted` fits.
    struct Plan: Equatable {
        /// The panes that end up visible.
        var panes: Panes
        /// A window width to grow to first, if any.
        var growTo: CGFloat?
    }

    /// Window minimums measured on the 1.5.0 layout (sidebar + detail +
    /// inspector) with a little headroom. Reading `contentMinSize` live is no
    /// substitute: while a pane is appearing it still reports the old layout.
    static let fallbackMinimum: [Panes: CGFloat] = [
        Panes(sidebar: true, inspector: true): 960,
        Panes(sidebar: false, inspector: true): 710,
        Panes(sidebar: true, inspector: false): 400,
        Panes(sidebar: false, inspector: false): 0,
    ]

    static func requiredWidth(for panes: Panes) -> CGFloat {
        fallbackMinimum[panes] ?? 0
    }

    /// Decides how to show `wanted` in a window `windowWidth` wide on a
    /// screen that offers `availableWidth`. `keep` is the pane the user just
    /// asked for: when both can't fit, the other one closes.
    static func plan(
        wanted: Panes,
        keep: Pane,
        windowWidth: CGFloat,
        availableWidth: CGFloat,
        required: (Panes) -> CGFloat
    ) -> Plan {
        var candidates = [wanted]
        if wanted.sidebar && wanted.inspector {
            candidates.append(keep == .inspector
                ? Panes(sidebar: false, inspector: true)
                : Panes(sidebar: true, inspector: false))
        }
        for panes in candidates {
            let need = required(panes)
            if need <= windowWidth { return Plan(panes: panes, growTo: nil) }
            if need <= availableWidth { return Plan(panes: panes, growTo: need) }
        }
        return Plan(panes: Panes(sidebar: false, inspector: false), growTo: nil)
    }

    /// Grows `window` to `width`, keeping it on its screen.
    static func grow(_ window: NSWindow, to width: CGFloat) {
        var frame = window.frame
        frame.size.width = width
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame = WindowFrameClamp.clamped(frame, to: visible)
        }
        window.setFrame(frame, display: true, animate: false)
    }
}
