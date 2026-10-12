import SwiftUI

/// CmdMD owns document tabs itself, so the app has exactly one editor window.
/// Keeping the scene id in one place also lets the menu-bar extra reopen that
/// same window instead of asking SwiftUI to create another editor scene.
enum AppWindowPolicy {
    static let mainSceneID = "main"
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
                Button("About CmdMD") {
                    appState.showAbout = true
                }
                Button("Check for Updates…") {
                    appState.checkForUpdates(userInitiated: true)
                }
                .disabled(appState.isCheckingForUpdate)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Draft") {
                    appState.createNewDraft()
                }
                .appShortcut(appState.keyBinding(for: .newDraft))

                Divider()

                Button("Open…") {
                    appState.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Folder…") {
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
                    ForEach(appState.recentFiles.prefix(10), id: \.self) { url in
                        Button(url.lastPathComponent) {
                            appState.openDocument(at: url)
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
                .disabled(appState.activeTab?.isDirty != true)

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

            CommandMenu("View") {
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

                Button("Zoom Out") {
                    appState.zoomOut()
                }
                .appShortcut(appState.keyBinding(for: .zoomOut))

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
                Button("New Tab") {
                    appState.createNewTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button(appState.tabs.isEmpty ? "Close Window" : "Close Tab") {
                    if let tab = appState.activeTab {
                        // Route through the dirty-tab guard — the menu item
                        // previously discarded unsaved changes silently.
                        if tab.isDirty && appState.settings.confirmBeforeClosingDirtyTabs {
                            appState.closeTabWithConfirmation(tab)
                        } else {
                            appState.closeTab(tab)
                        }
                    } else {
                        NSApp.keyWindow?.performClose(nil)
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
                Button("Bold") {
                    NotificationCenter.default.post(name: .formatBold, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    NotificationCenter.default.post(name: .formatItalic, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Insert Link") {
                    NotificationCenter.default.post(name: .formatLink, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            CommandMenu("Find") {
                Button("Omnisearch…") {
                    appState.showOmnisearch = true
                }
                .appShortcut(appState.keyBinding(for: .omnisearch))

                Divider()

                Button("Find in Document…") {
                    NotificationCenter.default.post(name: .showDocumentSearch, object: nil)
                }
                .appShortcut(appState.keyBinding(for: .findInDocument))

                Button("Find in Folder…") {
                    appState.selectedSidebarTab = .files
                    appState.sidebarVisible = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandMenu("Vault") {
                Button("Send to Vault…") {
                    appState.showSendToVault = true
                }
                .appShortcut(appState.keyBinding(for: .sendToVault))
                .disabled(appState.currentDocument == nil)

                Button("Auto-Route Send") {
                    appState.autoRouteCurrentDocument()
                }
                .appShortcut(appState.keyBinding(for: .autoRoute))
                .disabled(appState.currentDocument == nil)

                Divider()

                Button("Quick Capture") {
                    appState.showQuickCapture = true
                }
                .appShortcut(appState.keyBinding(for: .quickCapture))

                Divider()

                Button("Manage Vaults…") {
                    appState.showVaultManager = true
                }
            }

            CommandGroup(replacing: .help) {
                Button("CmdMD Help") {
                    NSWorkspace.shared.open(URL(string: "https://cmdmd.cmdspace.work")!)
                }

                Divider()

                Button("Command Palette") {
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
            appState.openDocument(at: url)
        }
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            appState.openDocument(at: url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}

// MARK: - AppDelegate for Menu Bar & Global Hotkey
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private let launchDefaults = AppLaunchDefaults()
    private var globalMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app has its own document tab bar — the system's window-tab
        // machinery (View > Show Tab Bar, ⌘T stealing) would fight it.
        NSWindow.allowsAutomaticWindowTabbing = false

        DispatchQueue.main.async { [launchDefaults] in
            guard launchDefaults.requiresRegularLaunchActivation else { return }

            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Register for global hotkey (Cmd+Shift+M for quick capture). Keep the
        // returned token so it can be removed on teardown.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 46 { // M key
                self?.showQuickCapture()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("CmdMD terminating", .app)
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running for menu bar
    }

    /// Guards against quitting with unsaved changes. Previously ⌘Q (or quitting
    /// the resident menu-bar app) discarded all dirty tabs silently.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared?.saveSession()
        // Flush settings synchronously — zoom changes persist on a 0.5s
        // debounce that would otherwise be lost by a quick ⌘Q.
        AppState.shared?.saveUserData()

        guard let appState = AppState.shared,
              appState.settings.confirmBeforeClosingDirtyTabs,
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
                await appState.saveAllDirtyTabs()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func showQuickCapture() {
        // Post notification to show quick capture
        NotificationCenter.default.post(name: .showQuickCapture, object: nil)
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
