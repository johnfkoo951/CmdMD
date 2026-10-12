import SwiftUI

/// Menu-bar extra content: quick capture plus shortcuts into the main app.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            QuickCaptureView()

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
    }
}

#if !SWIFT_PACKAGE
#Preview {
    MenuBarView()
        .environment(AppState())
}
#endif
