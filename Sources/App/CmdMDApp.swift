import SwiftUI

@main
struct CmdMDApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onOpenURL { url in
                    handleURL(url)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: appState.settings.defaultWindowWidth, height: appState.settings.defaultWindowHeight)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CmdMD") {
                    appState.showAbout = true
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Draft") {
                    appState.createNewDraft()
                }
                .appShortcut(appState.keyBinding(for: .newDraft))

                Divider()

                Button("Open File...") {
                    appState.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Folder...") {
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
                        Button("Clear Recent") {
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
                .disabled(!appState.isDirty)

                Button("Save As...") {
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
                
                Button("Export as HTML...") {
                    appState.exportAsHTML()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.currentDocument == nil)
                
                Button("Export as PDF...") {
                    appState.exportAsPDF()
                }
                .disabled(appState.currentDocument == nil)
                
                Button("Copy as HTML") {
                    appState.copyAsHTML()
                }
                .disabled(appState.currentDocument == nil)
            }
            
            CommandMenu("View") {
                Button("Source Only") {
                    appState.viewMode = .source
                }
                .appShortcut(appState.keyBinding(for: .sourceMode))

                Button("Split View") {
                    appState.viewMode = .split
                }
                .appShortcut(appState.keyBinding(for: .splitMode))

                Button("Preview Only") {
                    appState.viewMode = .preview
                }
                .appShortcut(appState.keyBinding(for: .previewMode))

                Divider()

                Button("Toggle Sidebar") {
                    withAnimation {
                        appState.sidebarVisible.toggle()
                    }
                }
                .appShortcut(appState.keyBinding(for: .toggleSidebar))

                Button("Toggle Inspector") {
                    withAnimation {
                        appState.inspectorVisible.toggle()
                    }
                }
                .appShortcut(appState.keyBinding(for: .toggleInspector))
                
                Divider()
                
                Button("Toggle Tab Bar") {
                    appState.settings.showTabBar.toggle()
                }
                
                Button("Toggle Status Bar") {
                    appState.settings.showStatusBar.toggle()
                }
            }
            
            CommandMenu("Tab") {
                Button("New Tab") {
                    appState.createNewTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                
                Button("Close Tab") {
                    if let tab = appState.activeTab {
                        appState.closeTab(tab)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState.tabs.isEmpty)
                
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
                Button("Omnisearch...") {
                    appState.showOmnisearch = true
                }
                .appShortcut(appState.keyBinding(for: .omnisearch))

                Divider()

                Button("Find in Document...") {
                    NotificationCenter.default.post(name: .showDocumentSearch, object: nil)
                }
                .appShortcut(appState.keyBinding(for: .findInDocument))

                Button("Find in Folder...") {
                    appState.selectedSidebarTab = .files
                    appState.sidebarVisible = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            
            CommandMenu("Vault") {
                Button("Send to Vault...") {
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

                Button("Manage Vaults, Templates & Rules...") {
                    appState.showVaultManager = true
                }
            }
            
            CommandGroup(replacing: .help) {
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

        guard let appState = AppState.shared,
              appState.settings.confirmBeforeClosingDirtyTabs,
              appState.hasAnyDirtyTabs else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before quitting?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await appState.saveAllDirtyTabs()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
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
