import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var hostWindow: NSWindow?
    
    private var effectiveColorScheme: ColorScheme? {
        switch appState.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var body: some View {
        @Bindable var state = appState
        
        NavigationSplitView(columnVisibility: Binding(
            get: { appState.sidebarVisible ? .all : .detailOnly },
            set: { appState.sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        } detail: {
            MainEditorView()
        }
        .navigationTitle(appState.windowTitle)
        .modifier(DocumentProxyIcon(url: appState.currentDocument?.fileURL))
        .inspector(isPresented: $state.inspectorVisible) {
            InspectorView()
                .inspectorColumnWidth(min: 250, ideal: 280, max: 350)
        }
        .preferredColorScheme(effectiveColorScheme)
        .tint(.cmdsAccent)
        .background(WindowAccessor(window: $hostWindow))
        .onChange(of: hostWindow) { _, window in
            // ⌘W and the Quick Capture hot key need to know which window
            // is the editor.
            AppWindowPolicy.editorWindow = window
        }
        .onDisappear {
            // The window closed; CmdMD keeps running in the menu bar. A sheet
            // or overlay still flagged must not pop up when it reopens.
            appState.dismissTransientPresentations()
        }
        .onChange(of: appState.settings.defaultWindowWidth) { _, w in
            resizeHostWindow(width: w)
        }
        .onChange(of: appState.settings.defaultWindowHeight) { _, h in
            resizeHostWindow(height: h)
        }
        .onChange(of: appState.activeTab?.isDirty == true) { _, dirty in
            // Native "edited" dot inside the window close button.
            hostWindow?.isDocumentEdited = dirty
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ViewModePicker()
            }

            ToolbarItemGroup(placement: .primaryAction) {
                SendToVaultButton()

                // The right-sidebar (inspector) toggle, pinned to the trailing edge.
                Button {
                    appState.toggleInspector()
                } label: {
                    // A real Label (not a bare Image) keeps the toolbar overflow
                    // menu and VoiceOver meaningful.
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(appState.shortcutHelp("Show or hide the Inspector", .toggleInspector))
            }
        }
        .sheet(isPresented: $state.showSendToVault, onDismiss: {
            appState.batchSendURLs = []
            appState.batchSendRoot = nil
        }) {
            SendToVaultSheet()
        }
        .sheet(isPresented: $state.showVaultManager) {
            VaultManagerView()
        }
        .sheet(isPresented: $state.showQuickCapture) {
            // The ⇧⌘M quick-capture panel — previously the hotkey set a flag
            // that nothing observed.
            QuickCaptureView {
                appState.showQuickCapture = false
            }
        }
        .sheet(isPresented: Binding(
            get: { !appState.settings.hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView()
                .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $state.showAbout) {
            AboutView()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .overlay {
            // ⌘P / ⇧⌘O as centered floating panels (Spotlight / Xcode Open
            // Quickly idiom) — the previous window sheets slid down from the
            // title bar with double chrome and felt slow to invoke.
            PaletteOverlay(window: hostWindow)
        }
        .overlay {
            if let toast = appState.toastMessage {
                ToastView(message: toast, style: appState.toastStyle)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.toastMessage)
        .focusedSceneValue(\.document, appState.currentDocument)
    }

    /// Applies a Window-size setting to this window. Only the dimension that
    /// changed moves (the other used to snap back to its stored value), the
    /// top edge stays put, and the frame stays on screen: the width slider
    /// goes to 2000 px, wider than many displays.
    private func resizeHostWindow(width: CGFloat? = nil, height: CGFloat? = nil) {
        guard let window = hostWindow, !window.styleMask.contains(.fullScreen) else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(forContentRect: NSRect(
            x: content.minX, y: content.minY,
            width: width ?? content.width, height: height ?? content.height
        ))
        frame.origin.y = window.frame.maxY - frame.height
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame = WindowFrameClamp.clamped(frame, to: visible)
        }
        window.setFrame(frame, display: true)
    }
}

/// Keeps a window frame inside the screen's visible area.
enum WindowFrameClamp {
    /// Shrinks `frame` to fit `visible`, keeping its top edge where it can,
    /// then shifts it back inside.
    static func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.maxY - height, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Applies `.navigationDocument` only when a real file backs the current tab —
/// this is what puts the draggable proxy icon (with ⌘-click path menu) in the
/// titlebar, like every first-party document app.
struct DocumentProxyIcon: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
        }
    }
}

/// Hosts the command palette and Omnisearch as top-anchored floating overlays
/// with a click-away scrim, replacing their `.sheet` presentation.
struct PaletteOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The window the overlay covers. Its search field takes this window's
    /// first responder (the old sheets had their own window), so closing
    /// must hand focus back.
    var window: NSWindow?
    @State private var focusToRestore = PaletteFocus.Memory()

    private var isPresented: Bool {
        appState.showCommandPalette || appState.showOmnisearch
    }

    var body: some View {
        @Bindable var state = appState

        ZStack(alignment: .top) {
            if isPresented {
                // Barely-visible scrim: dims just enough to signal modality and
                // catches click-away dismissal.
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture {
                        state.showCommandPalette = false
                        state.showOmnisearch = false
                    }
                    .transition(.opacity)

                Group {
                    if appState.showCommandPalette {
                        CommandPaletteView()
                    } else {
                        OmnisearchView()
                    }
                }
                .padding(.top, 110)
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                // Keeps VoiceOver inside the panel instead of the window behind.
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isPresented)
        .onChange(of: isPresented) { _, presented in
            if presented {
                // Runs before the search field's async focus grab.
                focusToRestore.view = PaletteFocus.restorableView(for: window?.firstResponder)
            } else {
                // Next turn: the field is gone and the chosen command has run
                // (it may have switched the view mode or opened a note).
                DispatchQueue.main.async { restoreFocus() }
            }
        }
    }

    private func restoreFocus() {
        // The palette may have handed over to Omnisearch in the meantime.
        guard !isPresented, let window else { return }
        let view = focusToRestore.view
        focusToRestore.view = nil
        guard let view, view.window === window,
              PaletteFocus.shouldRestore(
                isEditor: view is CmdMDTextView,
                isPreview: PaletteFocus.isInWebView(view),
                mode: appState.viewMode
              ) else {
            // Nothing to go back to: the pane on screen takes focus (unless
            // the command put it somewhere), so ↓ / Space scroll the note.
            PaneFocus.post(mode: appState.viewMode, modeChanged: false)
            return
        }
        window.makeFirstResponder(view)
    }
}

/// Where keyboard focus returns when the palette overlay closes. Without it
/// the window itself kept first responder, so typing beeped until a click.
enum PaletteFocus {
    final class Memory {
        weak var view: NSView?
    }

    /// The view to refocus: the text field itself while one is being edited
    /// (the shared field editor moves on to the palette's field), and never
    /// the palette's own field.
    static func restorableView(for responder: NSResponder?) -> NSView? {
        let view: NSView?
        if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
            view = fieldEditor.delegate as? NSView
        } else {
            view = responder as? NSView
        }
        return view is AutoFocusTextField ? nil : view
    }

    /// Never back into a pane the current mode hides: the editor stays mounted
    /// in Preview, and typing into it would edit the note invisibly.
    static func shouldRestore(isEditor: Bool, isPreview: Bool, mode: ViewMode) -> Bool {
        if isEditor { return mode != .preview }
        if isPreview { return mode != .source }
        return true
    }

    static func isInWebView(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate is WKWebView { return true }
            current = candidate.superview
        }
        return false
    }
}

struct ViewModePicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Picker("View Mode", selection: $state.viewMode) {
            Label("Source", systemImage: "text.alignleft")
                .tag(ViewMode.source)
            Label("Split", systemImage: "rectangle.split.2x1")
                .tag(ViewMode.split)
            Label("Preview", systemImage: "eye")
                .tag(ViewMode.preview)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .fixedSize()
        .help("\(appState.shortcutHelp("Source", .sourceMode)) · \(appState.shortcutHelp("Split", .splitMode)) · \(appState.shortcutHelp("Preview", .previewMode))")
    }
}

struct SendToVaultButton: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Menu {
            if appState.vaults.isEmpty {
                Text("No vaults configured")
                Button("Add Vault…") {
                    appState.showVaultManager = true
                }
            } else {
                ForEach(appState.vaults) { vault in
                    Button {
                        Task {
                            var options = SendOptions()
                            options.targetVault = vault
                            options.targetFolder = appState.effectiveSendFolder(for: vault)
                            options.conflictResolution = appState.settings.conflictResolution
                            options.injectFrontmatter = appState.settings.injectFrontmatterByDefault
                            do {
                                try await appState.sendToVault(options: options)
                            } catch {
                                appState.errorMessage = "Send to \(vault.displayName) failed: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Label("\(vault.displayName) / \(appState.effectiveSendFolder(for: vault))", systemImage: "tray.and.arrow.down")
                    }
                }

                Divider()

                // The same remappable bindings as the Vault menu.
                Button("Send with Options…") {
                    appState.showSendToVault = true
                }
                .appShortcut(appState.keyBinding(for: .sendToVault))

                Button("Auto-Route") {
                    appState.autoRouteCurrentDocument()
                }
                .appShortcut(appState.keyBinding(for: .autoRoute))
            }
        } label: {
            Image(systemName: "paperplane")
        }
        .disabled(appState.currentDocument == nil)
        .help(appState.shortcutHelp("Send to Vault", .sendToVault))
    }
}

/// How a toast reads at a glance. Every toast used to carry a green
/// checkmark, failures included.
enum ToastStyle {
    case success, warning, error

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct ToastView: View {
    let message: String
    var style: ToastStyle = .success

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.color)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            .padding(.top, 8)
            
            Spacer()
        }
    }
}

extension AppState {
    var sidebarColumnVisibility: NavigationSplitViewVisibility {
        get { sidebarVisible ? .all : .detailOnly }
        set { sidebarVisible = newValue != .detailOnly }
    }

    /// Clears the sheets and overlays the editor window presents, for when
    /// that window closes. Onboarding is left alone: it isn't done yet.
    func dismissTransientPresentations() {
        showCommandPalette = false
        showOmnisearch = false
        showSendToVault = false
        showVaultManager = false
        showQuickCapture = false
        showAbout = false
        batchSendURLs = []
    }
}

// MARK: - First-run onboarding

/// Shown once on first launch. Keeps setup to a single decision — appearance —
/// and applies the CMDS theme as the default automatically.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var appearance: AppTheme = .system

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                BrandLogo(size: 84, showWordmark: true)

                VStack(spacing: 4) {
                    Text("Welcome to CmdMD")
                        .font(.title2.bold())
                    Text("A review-first Markdown editor & Obsidian vault router")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Appearance")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        AppearanceCard(theme: theme, isSelected: appearance == theme) {
                            appearance = theme
                        }
                    }
                }

                Text("The CMDS theme is applied by default. You can change any of this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button {
                appState.settings.theme = appearance
                appState.settings.previewTheme = PreviewTheme.cmds.rawValue
                appState.settings.editorTheme = .cmds
                appState.settings.hasCompletedOnboarding = true
                appState.saveUserData()
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Return completes the only step of a sheet that can't be dismissed.
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 460)
        .tint(.cmdsAccent)
    }
}

struct AppearanceCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    private var icon: String {
        switch theme {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon.stars"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.cmdsAccent : .secondary)
                Text(theme.rawValue)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.cmdsAccent : Color.gray.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Captures the hosting `NSWindow` so the main window (not the Settings window)
/// can be resized live when the window-size settings change.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}

// MARK: - About / creator info

enum AppInfo {
    static var version: String { version(from: Bundle.main.infoDictionary) }
    /// False for `swift build` / `swift run` binaries: SwiftPM embeds no Info.plist
    /// (scripts/package_app.sh writes the app's, from VERSION), so there is no
    /// release version to report or to compare with the latest release.
    static var isPackagedBuild: Bool { isPackaged(info: Bundle.main.infoDictionary) }

    static func version(from info: [String: Any]?) -> String {
        info?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    static func isPackaged(info: [String: Any]?) -> Bool {
        info?["CFBundleShortVersionString"] is String
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }
    static var versionLabel: String {
        build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
    }
    static let maker = "구요한 · CMDSPACE"
    static let website = URL(string: "https://cmdspace.work")!
    static let github = URL(string: "https://github.com/johnfkoo951/CmdMD")!
}

/// Shared row of brand links — reused by the About window and Settings.
struct CreatorLinks: View {
    var body: some View {
        HStack(spacing: 16) {
            Link(destination: AppInfo.website) {
                Label("cmdspace.work", systemImage: "globe")
            }
            Link(destination: AppInfo.github) {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .font(.callout)
        .tint(.cmdsAccent)
    }
}

struct AboutView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            BrandLogo(size: 76, showWordmark: true)

            VStack(spacing: 3) {
                Text("CmdMD")
                    .font(.title2.bold())
                Text(AppInfo.versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("A review-first Markdown editor & Obsidian vault router.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Update status / action
            if appState.updateAvailable {
                Button {
                    if let url = appState.updateURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Update available: \(appState.latestVersion ?? "")", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cmdsAccent)
            } else {
                Button {
                    appState.checkForUpdates(userInitiated: true)
                } label: {
                    if appState.isCheckingForUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.isCheckingForUpdate)
            }

            Divider().frame(width: 220)

            VStack(spacing: 8) {
                Text("Made by \(AppInfo.maker)")
                    .font(.callout.weight(.medium))
                CreatorLinks()
            }

            Text("© 2026 CMDSPACE · MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 360)
        .tint(.cmdsAccent)
    }
}

struct FocusedDocumentKey: FocusedValueKey {
    typealias Value = MarkdownDocument
}

extension FocusedValues {
    var document: MarkdownDocument? {
        get { self[FocusedDocumentKey.self] }
        set { self[FocusedDocumentKey.self] = newValue }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    ContentView()
        .environment(AppState())
        .frame(width: 1200, height: 800)
}
#endif
