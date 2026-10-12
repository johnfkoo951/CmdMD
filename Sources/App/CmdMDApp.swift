import SwiftUI

/// CmdMD owns document tabs itself, so the app has exactly one editor window.
/// Keeping the scene id in one place also lets the menu-bar extra reopen that
/// same window instead of asking SwiftUI to create another editor scene.
enum AppWindowPolicy {
    static let mainSceneID = "main"

    /// The editor window, captured by ContentView. Weak: SwiftUI owns it, and
    /// it goes away when the user closes it (the app stays in the menu bar).
    static weak var editorWindow: NSWindow?

    /// What ⌘W acts on.
    enum CloseTarget: Equatable {
        /// No key window: nothing on screen to close.
        case nothing
        /// A sheet is key. It has its own Cancel/Done, and the window under
        /// it can't close while it's up (AppKit beeps the same way).
        case beep
        /// Settings, the Quick Capture panel, the menu-bar window.
        case keyWindow
        /// The editor window: its active tab, or the window when no tab is open.
        case editor
    }

    /// Tab › Close Tab is CmdMD's only ⌘W (it replaces File › Close), so it
    /// must act on the key window. It used to close the editor's active note
    /// even when Settings, a capture panel or a sheet was in front.
    static func closeTarget(hasKeyWindow: Bool, keyIsEditor: Bool, keyIsSheet: Bool) -> CloseTarget {
        guard hasKeyWindow else { return .nothing }
        if keyIsSheet { return .beep }
        return keyIsEditor ? .editor : .keyWindow
    }

    /// Splits a drop on the window into folders, which open as the workspace,
    /// and files, which open as tabs. A folder used to go down the file path
    /// and fail with "Failed to open file". Packages (.textbundle, .app) are
    /// files to Finder, so they stay files here too.
    static func partitionDroppedURLs(_ urls: [URL]) -> (folders: [URL], files: [URL]) {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true && values?.isPackage != true {
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        return (folders, files)
    }
}

/// A menu command whose result appears in the editor window: a document, a
/// sheet, an overlay or a toast. With that window closed (CmdMD keeps running
/// in the menu bar) such commands showed nothing, and their sheets popped up
/// together on the next reopen. Opening the window first (or bringing it
/// forward) makes the result visible now.
struct EditorWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    private let title: String
    private let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title) {
            openWindow(id: AppWindowPolicy.mainSceneID)
            action()
        }
    }
}

@main
struct CmdMDApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Window("CmdMD", id: AppWindowPolicy.mainSceneID) {
            ContentView()
                .environment(appState)
                .onOpenURL { url in
                    handleURL(url)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
        }
        // Title + document proxy icon in the unified toolbar — the strongest
        // native-document signals (draggable icon, ⌘-click path menu). The
        // proxy icon itself comes from .navigationDocument in ContentView.
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: appState.settings.defaultWindowWidth, height: appState.settings.defaultWindowHeight)
        .commands {
            CommandGroup(replacing: .appInfo) {
                EditorWindowButton("About CmdMD") {
                    appState.showAbout = true
                }
                EditorWindowButton("Check for Updates…") {
                    appState.checkForUpdates(userInitiated: true)
                }
                .disabled(appState.isCheckingForUpdate)
            }

            CommandGroup(replacing: .newItem) {
                EditorWindowButton("New Draft") {
                    appState.createNewDraft()
                }
                .appShortcut(appState.keyBinding(for: .newDraft))

                Divider()

                EditorWindowButton("Open…") {
                    appState.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                EditorWindowButton("Open Folder…") {
                    appState.openFolder()
                }
                .appShortcut(appState.keyBinding(for: .openFolder))

                Button("Reload from Disk") {
                    appState.reloadCurrentDocument()
                }
                .appShortcut(appState.keyBinding(for: .reloadFromDisk))
                .disabled(appState.currentDocument?.fileURL == nil)

                Divider()

                Menu("Open Recent") {
                    let recents = Array(appState.recentFiles.prefix(10))
                    let titles = AppState.recentMenuTitles(recents)
                    ForEach(recents.indices, id: \.self) { index in
                        EditorWindowButton(titles[index]) {
                            appState.openDocument(at: recents[index], inNewTab: true)
                        }
                    }

                    if !appState.recentFiles.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            appState.clearRecentFiles()
                        }
                    }
                }
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    Task { await appState.saveCurrentDocument() }
                }
                .appShortcut(appState.keyBinding(for: .save))
                // A draft or untitled tab can always be saved (that is how it
                // becomes a file, as in TextEdit); drafts read clean because
                // they persist themselves. A file only when it has changes.
                .disabled(appState.activeTab.map { !$0.isDirty && $0.fileURL != nil } ?? true)

                Button("Save As…") {
                    Task { await appState.saveDocumentAs() }
                }
                .appShortcut(appState.keyBinding(for: .saveAs))
                .disabled(appState.currentDocument == nil)

                Button("Copy File Path") {
                    appState.copyCurrentFilePath()
                }
                .appShortcut(appState.keyBinding(for: .copyFilePath))
                .disabled(appState.currentDocument?.fileURL == nil)

                Divider()

                Button("Export as HTML…") {
                    appState.exportAsHTML()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.currentDocument == nil)

                Button("Export as PDF…") {
                    appState.exportAsPDF()
                }
                .disabled(appState.currentDocument == nil)

                Button("Copy as HTML") {
                    appState.copyAsHTML()
                }
                .disabled(appState.currentDocument == nil)
            }

            // Into the system View menu (with Enter Full Screen and the toolbar
            // items): a CommandMenu("View") added a second View menu beside it.
            CommandGroup(before: .toolbar) {
                // Toggles (not Buttons) so the active mode carries the native
                // menu checkmark.
                Toggle("Source Only", isOn: viewModeBinding(.source))
                    .appShortcut(appState.keyBinding(for: .sourceMode))

                Toggle("Split View", isOn: viewModeBinding(.split))
                    .appShortcut(appState.keyBinding(for: .splitMode))

                Toggle("Preview Only", isOn: viewModeBinding(.preview))
                    .appShortcut(appState.keyBinding(for: .previewMode))

                Divider()

                // HIG order: Actual Size above Zoom In/Out (Safari, Preview, Notes).
                Button("Actual Size") {
                    appState.resetZoom()
                }
                .appShortcut(appState.keyBinding(for: .resetZoom))
                .disabled(appState.settings.zoomLevel == 1.0)

                Button("Zoom In") {
                    appState.zoomIn()
                }
                .appShortcut(appState.keyBinding(for: .zoomIn))
                .disabled(appState.settings.zoomLevel >= AppState.zoomRange.upperBound)

                Button("Zoom Out") {
                    appState.zoomOut()
                }
                .appShortcut(appState.keyBinding(for: .zoomOut))
                .disabled(appState.settings.zoomLevel <= AppState.zoomRange.lowerBound)

                Divider()

                Button(appState.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    appState.toggleSidebar()
                }
                .appShortcut(appState.keyBinding(for: .toggleSidebar))

                Button(appState.inspectorVisible ? "Hide Inspector" : "Show Inspector") {
                    appState.toggleInspector()
                }
                .appShortcut(appState.keyBinding(for: .toggleInspector))

                Divider()

                Button(appState.settings.showTabBar ? "Hide Tab Bar" : "Show Tab Bar") {
                    appState.settings.showTabBar.toggle()
                }

                Button(appState.settings.showStatusBar ? "Hide Status Bar" : "Show Status Bar") {
                    appState.settings.showStatusBar.toggle()
                }
            }

            CommandMenu("Tab") {
                EditorWindowButton("New Tab") {
                    appState.createNewTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button(appState.tabs.isEmpty ? "Close Window" : "Close Tab") {
                    let key = NSApp.keyWindow
                    switch AppWindowPolicy.closeTarget(
                        hasKeyWindow: key != nil,
                        keyIsEditor: key != nil && key === AppWindowPolicy.editorWindow,
                        keyIsSheet: key?.sheetParent != nil
                    ) {
                    case .nothing:
                        break
                    case .beep:
                        NSSound.beep()
                    case .keyWindow:
                        key?.performClose(nil)
                    case .editor:
                        // First, so the dirty check below counts a syllable
                        // still being composed.
                        appState.commitPendingComposition()
                        if let tab = appState.activeTab {
                            // Route through the dirty-tab guard — the menu item
                            // previously discarded unsaved changes silently.
                            if tab.isDirty && appState.settings.confirmBeforeClosingDirtyTabs {
                                appState.closeTabWithConfirmation(tab)
                            } else {
                                appState.closeTab(tab)
                            }
                        } else {
                            key?.performClose(nil)
                        }
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                
                Divider()
                
                Button("Next Tab") {
                    appState.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(appState.tabs.count <= 1)
                
                Button("Previous Tab") {
                    appState.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(appState.tabs.count <= 1)
                
                Divider()
                
                ForEach(0..<min(9, appState.tabs.count), id: \.self) { index in
                    Button("Tab \(index + 1): \(appState.tabs[index].displayTitle)") {
                        appState.selectTab(at: index)
                    }
                    // ⌘⌃number so this no longer collides with ⌘1/2/3 view modes.
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                }
            }

            CommandMenu("Format") {
                // Only the source editor formats; in Preview these did nothing.
                let canFormat = appState.currentDocument != nil && appState.viewMode != .preview

                Button("Bold") {
                    NotificationCenter.default.post(name: .formatBold, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!canFormat)

                Button("Italic") {
                    NotificationCenter.default.post(name: .formatItalic, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!canFormat)

                Button("Insert Link") {
                    NotificationCenter.default.post(name: .formatLink, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!canFormat)
            }

            CommandMenu("Find") {
                EditorWindowButton("Omnisearch…") {
                    appState.showOmnisearch = true
                }
                .appShortcut(appState.keyBinding(for: .omnisearch))

                Divider()

                // Routed to the visible pane: the rendered preview in Preview
                // mode, the source editor's find bar otherwise.
                Button("Find in Document…") {
                    DocumentFind.perform(.showFindInterface, in: appState.viewMode)
                }
                .appShortcut(appState.keyBinding(for: .findInDocument))

                // The source editor's find bar with Replace showing. The
                // preview is read-only, so not in Preview mode.
                Button("Find and Replace…") {
                    DocumentFind.perform(.showReplaceInterface, in: appState.viewMode)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(appState.currentDocument == nil || appState.viewMode == .preview)

                Button("Find Next") {
                    DocumentFind.perform(.nextMatch, in: appState.viewMode)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(appState.currentDocument == nil)

                Button("Find Previous") {
                    DocumentFind.perform(.previousMatch, in: appState.viewMode)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState.currentDocument == nil)

                Button("Use Selection for Find") {
                    DocumentFind.perform(.setSearchString, in: appState.viewMode)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(appState.currentDocument == nil)

                EditorWindowButton("Find in Folder…") {
                    appState.beginFolderSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandMenu("Vault") {
                EditorWindowButton("Send to Vault…") {
                    appState.showSendToVault = true
                }
                .appShortcut(appState.keyBinding(for: .sendToVault))
                .disabled(appState.currentDocument == nil)

                EditorWindowButton("Auto-Route Send") {
                    appState.autoRouteCurrentDocument()
                }
                .appShortcut(appState.keyBinding(for: .autoRoute))
                .disabled(appState.currentDocument == nil)

                Divider()

                Button("Open in Obsidian") {
                    appState.openCurrentDocumentInObsidian()
                }
                .appShortcut(appState.keyBinding(for: .openInObsidian))
                .disabled(appState.activeTab?.fileURL == nil)

                Divider()

                EditorWindowButton("Quick Capture") {
                    appState.showQuickCapture = true
                }
                .appShortcut(appState.keyBinding(for: .quickCapture))

                Divider()

                EditorWindowButton("Manage Vaults…") {
                    appState.showVaultManager = true
                }
            }

            CommandGroup(replacing: .help) {
                Button("CmdMD Help") {
                    NSWorkspace.shared.open(URL(string: "https://cmdmd.cmdspace.work")!)
                }

                Divider()

                EditorWindowButton("Command Palette") {
                    appState.showCommandPalette = true
                }
                .appShortcut(appState.keyBinding(for: .commandPalette))
            }
        }
        
        Settings {
            SettingsView()
                .environment(appState)
                .tint(.cmdsAccent)
        }

        // Menu bar quick capture
        MenuBarExtra("CmdMD", systemImage: "book.fill") {
            MenuBarView()
                .environment(appState)
                .tint(.cmdsAccent)
        }
        .menuBarExtraStyle(.window)
    }
    
    /// Menu Toggle binding for one view mode — checkmarked when active,
    /// selecting an already-active mode is a no-op (never "unchecks").
    private func viewModeBinding(_ mode: ViewMode) -> Binding<Bool> {
        Binding(
            get: { appState.viewMode == mode },
            set: { if $0 { appState.viewMode = mode } }
        )
    }

    private func handleURL(_ url: URL) {
        if url.scheme == "cmdmd" {
            appState.openInternalURL(url)
        } else if url.isFileURL {
            // Finder / Dock opens add a tab (like ⌘O). Replacing the clean
            // active tab evicted the note being read, and with several files
            // each load replaced the previous one until only the last was left.
            appState.openDocument(at: url, inNewTab: true)
        }
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }
        // Every dropped file gets its own tab, in drop order — this used to
        // read only the first item and replace the active tab with it.
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let data = try? await provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
            appState.openDroppedItems(urls)
        }
        return true
    }
}

// MARK: - AppDelegate for Menu Bar & Global Hotkey
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private let launchDefaults = AppLaunchDefaults()
    /// System-wide Quick Capture shortcut. A Carbon hot key: the NSEvent global
    /// monitor it replaces only ever saw keys once the app was granted
    /// Accessibility — never requested, so the hotkey silently did nothing.
    private lazy var quickCaptureHotKey = GlobalHotKey { [weak self] in
        self?.showQuickCapture()
    }
    private var registeredQuickCaptureBinding: KeyBinding?
    private let quickCapturePanel = QuickCapturePanelController()
    /// ⌘+ typed as ⇧⌘=, on the keypad or on a layout's + key: the Zoom In menu
    /// item matches only "=" — see `KeyBinding.isZoomInAlternate`.
    private var zoomInAlternateMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app has its own document tab bar — the system's window-tab
        // machinery (View > Show Tab Bar, ⌘T stealing) would fight it.
        NSWindow.allowsAutomaticWindowTabbing = false

        DispatchQueue.main.async { [launchDefaults] in
            guard launchDefaults.requiresRegularLaunchActivation else { return }

            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        trackQuickCaptureHotKey()

        zoomInAlternateMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags
            guard KeyBinding.isZoomInAlternate(
                    characters: event.charactersIgnoringModifiers,
                    command: flags.contains(.command),
                    option: flags.contains(.option),
                    control: flags.contains(.control)),
                  NSApp.modalWindow == nil,
                  let appState = AppState.shared, appState.acceptsZoomInAlternate else { return event }
            appState.zoomIn()
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("CmdMD terminating", .app)
        quickCaptureHotKey.unregister()
        if let zoomInAlternateMonitor { NSEvent.removeMonitor(zoomInAlternateMonitor) }
        // Last: AppKit exits as soon as this returns. Every quit path ends
        // here, so this also drains a quit-time Save All's error lines.
        Log.flush()
    }

    /// Registers the (remappable) Quick Capture binding as the global hot key
    /// and re-registers whenever it changes — any path: the Keyboard settings
    /// recorder, Reset, Reset All.
    private func trackQuickCaptureHotKey() {
        guard let appState = AppState.shared else { return }
        let binding = withObservationTracking {
            appState.keyBinding(for: .quickCapture)
        } onChange: {
            // Fires before the new value is stored — re-read on the next turn.
            Task { @MainActor in self.trackQuickCaptureHotKey() }
        }
        guard binding != registeredQuickCaptureBinding else { return }
        registeredQuickCaptureBinding = binding
        quickCaptureHotKey.register(binding)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running for menu bar
    }

    /// Guards against quitting with unsaved changes. Previously ⌘Q (or quitting
    /// the resident menu-bar app) discarded all dirty tabs silently.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A syllable still being composed counts as an unsaved change.
        AppState.shared?.commitPendingComposition()
        // A capture left in the hidden floating panel would vanish with the
        // process; keep it as a draft (saved by saveUserData below).
        if quickCapturePanel.hasUnsentText {
            AppState.shared?.stashCaptureAsDraft(quickCapturePanel.pendingText)
        }
        AppState.shared?.saveSession()
        // Flush settings synchronously — zoom changes persist on a 0.5s
        // debounce that would otherwise be lost by a quick ⌘Q.
        AppState.shared?.saveUserData()

        // Deliberately not gated on confirmBeforeClosingDirtyTabs: that toggle
        // covers closing one tab, while quitting (or logging out) would drop
        // every unsaved document at once, pending autosaves included.
        guard let appState = AppState.shared,
              appState.hasAnyDirtyTabs else {
            return .terminateNow
        }

        // Native multi-document quit pattern: default action rightmost, Cancel
        // beside it, and the destructive choice farthest from the default.
        let dirtyCount = appState.tabs.filter { appState.isTabDirty($0) }.count
        let alert = NSAlert()
        alert.messageText = dirtyCount == 1
            ? "You have 1 document with unsaved changes"
            : "You have \(dirtyCount) documents with unsaved changes"
        alert.informativeText = "Do you want to save your changes before quitting?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save All")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle: "Discard Changes")
        discard.hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                // A failed write, a cancelled Save panel (untitled tabs) or
                // Cancel at a changed-on-disk prompt cancels the quit; replying
                // true here used to discard them.
                let saved = await appState.saveAllDirtyTabs()
                NSApplication.shared.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func showQuickCapture() {
        // A hidden panel still holding typed text comes back instead of a
        // fresh, empty sheet.
        if NSApp.isActive && !quickCapturePanel.isVisible && !quickCapturePanel.hasUnsentText
            && AppWindowPolicy.editorWindow?.isKeyWindow == true {
            // Inside CmdMD the hot key pre-empts the menu's key equivalent, so
            // do what Vault › Quick Capture does: the in-window sheet. Only
            // while that window is in front: with it closed, the sheet waited
            // unseen and popped up on the next reopen.
            NotificationCenter.default.post(name: .showQuickCapture, object: nil)
        } else if let appState = AppState.shared {
            // From another app, Settings or with the editor window closed: a
            // floating capture panel. The sheet would open on a background (or
            // closed) main window and never be seen.
            quickCapturePanel.show(appState: appState)
        }
    }
}

extension AppLaunchDefaults {
    var activationPolicy: NSApplication.ActivationPolicy { .regular }
    var activatesOnLaunch: Bool { true }
    var requiresRegularLaunchActivation: Bool { activationPolicy == .regular && activatesOnLaunch }
}

extension Notification.Name {
    static let showQuickCapture = Notification.Name("showQuickCapture")
    static let showDocumentSearch = Notification.Name("showDocumentSearch")
    static let formatBold = Notification.Name("formatBold")
    static let formatItalic = Notification.Name("formatItalic")
    static let formatLink = Notification.Name("formatLink")
}
