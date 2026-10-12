import SwiftUI

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
        .onChange(of: appState.settings.defaultWindowWidth) { _, w in
            hostWindow?.setContentSize(NSSize(width: w, height: appState.settings.defaultWindowHeight))
        }
        .onChange(of: appState.settings.defaultWindowHeight) { _, h in
            hostWindow?.setContentSize(NSSize(width: appState.settings.defaultWindowWidth, height: h))
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
                .help("Show or hide the Inspector (\(appState.keyBinding(for: .toggleInspector).displayString))")
            }
        }
        .sheet(isPresented: $state.showSendToVault, onDismiss: {
            appState.batchSendURLs = []
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
            PaletteOverlay()
        }
        .overlay {
            if let toast = appState.toastMessage {
                ToastView(message: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.toastMessage)
        .focusedSceneValue(\.document, appState.currentDocument)
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
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isPresented)
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
        .help("Source ⌘1 · Split ⌘2 · Preview ⌘3")
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
                            try? await appState.sendToVault(options: options)
                        }
                    } label: {
                        Label("\(vault.displayName) / \(appState.effectiveSendFolder(for: vault))", systemImage: "tray.and.arrow.down")
                    }
                }

                Divider()

                Button("Send with Options…") {
                    appState.showSendToVault = true
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Auto-Route") {
                    appState.autoRouteCurrentDocument()
                }
                .keyboardShortcut("t", modifiers: [.command, .control])
            }
        } label: {
            Image(systemName: "paperplane")
        }
        .disabled(appState.currentDocument == nil)
        .help("Send to Vault (⇧⌘T)")
    }
}

struct ToastView: View {
    let message: String
    
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
            }
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
                    Text("리뷰 우선 마크다운 에디터 · Obsidian 볼트 라우터")
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

                Text("CMDS 테마가 기본으로 적용됩니다. 세부 설정은 언제든 설정에서 바꿀 수 있어요.")
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
                Text("시작하기")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.4.2"
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
