import SwiftUI

/// Menu-bar extra content: quick capture plus shortcuts into the main app.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    /// The menu-bar extra's window, so a finished capture can close it.
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            // Cancel (⎋), Discard, Save as Draft and a sent note close the
            // panel. Without a handler, Cancel and ⎋ did nothing here.
            QuickCaptureView {
                // Next turn, so a closing confirmation dialog finishes first.
                DispatchQueue.main.async { hostWindow?.close() }
            }

            Divider()

            HStack {
                Button {
                    openWindow(id: AppWindowPolicy.mainSceneID)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open CmdMD", systemImage: "macwindow")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()

                Text("\(appState.drafts.count) drafts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .background(WindowAccessor(window: $hostWindow))
    }
}

#if !SWIFT_PACKAGE
#Preview {
    MenuBarView()
        .environment(AppState())
}
#endif
