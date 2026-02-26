import SwiftUI
import Observation
import UniformTypeIdentifiers

// MARK: - Enums

enum ViewMode: String, CaseIterable, Codable {
    case source = "Source"
    case split = "Split"
    case preview = "Preview"
}

enum SidebarTab: String, CaseIterable, Codable {
    case files = "Files"
    case favorites = "Favorites"
    case drafts = "Drafts"
    case recent = "Recent"
    
    var icon: String {
        switch self {
        case .files: return "folder"
        case .favorites: return "star"
        case .drafts: return "doc.text"
        case .recent: return "clock"
        }
    }
}

enum AppTheme: String, CaseIterable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

// MARK: - Editor Theme (8 themes from spec)

enum EditorTheme: String, CaseIterable, Codable, Identifiable {
    case oneDark = "One Dark"
    case dracula = "Dracula"
    case github = "GitHub"
    case nord = "Nord"
    case tokyoNight = "Tokyo Night"
    case gruvbox = "Gruvbox"
    case solarizedDark = "Solarized Dark"
    case materialDark = "Material Dark"
    
    var id: String { rawValue }
    
    var backgroundColor: Color {
        switch self {
        case .oneDark: return Color(hex: "282c34")
        case .dracula: return Color(hex: "282a36")
        case .github: return Color(hex: "ffffff")
        case .nord: return Color(hex: "2e3440")
        case .tokyoNight: return Color(hex: "1a1b26")
        case .gruvbox: return Color(hex: "282828")
        case .solarizedDark: return Color(hex: "002b36")
        case .materialDark: return Color(hex: "263238")
        }
    }
    
    var textColor: Color {
        switch self {
        case .oneDark: return Color(hex: "abb2bf")
        case .dracula: return Color(hex: "f8f8f2")
        case .github: return Color(hex: "24292e")
        case .nord: return Color(hex: "d8dee9")
        case .tokyoNight: return Color(hex: "a9b1d6")
        case .gruvbox: return Color(hex: "ebdbb2")
        case .solarizedDark: return Color(hex: "839496")
        case .materialDark: return Color(hex: "eeffff")
        }
    }
    
    var keywordColor: Color {
        switch self {
        case .oneDark: return Color(hex: "c678dd")
        case .dracula: return Color(hex: "ff79c6")
        case .github: return Color(hex: "d73a49")
        case .nord: return Color(hex: "81a1c1")
        case .tokyoNight: return Color(hex: "bb9af7")
        case .gruvbox: return Color(hex: "fb4934")
        case .solarizedDark: return Color(hex: "859900")
        case .materialDark: return Color(hex: "c792ea")
        }
    }
    
    var stringColor: Color {
        switch self {
        case .oneDark: return Color(hex: "98c379")
        case .dracula: return Color(hex: "f1fa8c")
        case .github: return Color(hex: "032f62")
        case .nord: return Color(hex: "a3be8c")
        case .tokyoNight: return Color(hex: "9ece6a")
        case .gruvbox: return Color(hex: "b8bb26")
        case .solarizedDark: return Color(hex: "2aa198")
        case .materialDark: return Color(hex: "c3e88d")
        }
    }
    
    var commentColor: Color {
        switch self {
        case .oneDark: return Color(hex: "5c6370")
        case .dracula: return Color(hex: "6272a4")
        case .github: return Color(hex: "6a737d")
        case .nord: return Color(hex: "616e88")
        case .tokyoNight: return Color(hex: "565f89")
        case .gruvbox: return Color(hex: "928374")
        case .solarizedDark: return Color(hex: "586e75")
        case .materialDark: return Color(hex: "546e7a")
        }
    }
    
    var headingColor: Color {
        switch self {
        case .oneDark: return Color(hex: "e06c75")
        case .dracula: return Color(hex: "bd93f9")
        case .github: return Color(hex: "005cc5")
        case .nord: return Color(hex: "88c0d0")
        case .tokyoNight: return Color(hex: "7aa2f7")
        case .gruvbox: return Color(hex: "83a598")
        case .solarizedDark: return Color(hex: "268bd2")
        case .materialDark: return Color(hex: "82aaff")
        }
    }
    
    var linkColor: Color {
        switch self {
        case .oneDark: return Color(hex: "61afef")
        case .dracula: return Color(hex: "8be9fd")
        case .github: return Color(hex: "0366d6")
        case .nord: return Color(hex: "5e81ac")
        case .tokyoNight: return Color(hex: "73daca")
        case .gruvbox: return Color(hex: "458588")
        case .solarizedDark: return Color(hex: "cb4b16")
        case .materialDark: return Color(hex: "89ddff")
        }
    }
    
    var selectionColor: Color {
        switch self {
        case .oneDark: return Color(hex: "3e4451")
        case .dracula: return Color(hex: "44475a")
        case .github: return Color(hex: "c8e1ff")
        case .nord: return Color(hex: "434c5e")
        case .tokyoNight: return Color(hex: "283457")
        case .gruvbox: return Color(hex: "3c3836")
        case .solarizedDark: return Color(hex: "073642")
        case .materialDark: return Color(hex: "37474f")
        }
    }
    
    var lineNumberColor: Color {
        switch self {
        case .oneDark: return Color(hex: "4b5263")
        case .dracula: return Color(hex: "6272a4")
        case .github: return Color(hex: "babbbc")
        case .nord: return Color(hex: "4c566a")
        case .tokyoNight: return Color(hex: "3b4261")
        case .gruvbox: return Color(hex: "665c54")
        case .solarizedDark: return Color(hex: "586e75")
        case .materialDark: return Color(hex: "37474f")
        }
    }
    
    var cursorColor: Color {
        switch self {
        case .oneDark: return Color(hex: "528bff")
        case .dracula: return Color(hex: "f8f8f0")
        case .github: return Color(hex: "044289")
        case .nord: return Color(hex: "d8dee9")
        case .tokyoNight: return Color(hex: "c0caf5")
        case .gruvbox: return Color(hex: "ebdbb2")
        case .solarizedDark: return Color(hex: "839496")
        case .materialDark: return Color(hex: "ffcc00")
        }
    }
}

// MARK: - Tab Model

struct EditorTab: Identifiable, Equatable, Codable {
    let id: UUID
    var documentId: UUID
    var fileURL: URL?
    var title: String
    var isPinned: Bool
    var isDirty: Bool
    var scrollPosition: CGFloat
    var cursorPosition: Int
    
    init(
        id: UUID = UUID(),
        documentId: UUID = UUID(),
        fileURL: URL? = nil,
        title: String = "Untitled",
        isPinned: Bool = false,
        isDirty: Bool = false,
        scrollPosition: CGFloat = 0,
        cursorPosition: Int = 0
    ) {
        self.id = id
        self.documentId = documentId
        self.fileURL = fileURL
        self.title = title
        self.isPinned = isPinned
        self.isDirty = isDirty
        self.scrollPosition = scrollPosition
        self.cursorPosition = cursorPosition
    }
    
    var displayTitle: String {
        if let url = fileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return title.isEmpty ? "Untitled" : title
    }
}

// MARK: - Favorite Item

struct FavoriteItem: Identifiable, Equatable, Codable {
    let id: UUID
    var url: URL
    var addedAt: Date
    var alias: String?
    
    init(id: UUID = UUID(), url: URL, addedAt: Date = Date(), alias: String? = nil) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
        self.alias = alias
    }
    
    var displayName: String {
        alias ?? url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Preview Settings

struct PreviewSettings: Codable, Equatable {
    var lineHeight: CGFloat = 1.6
    var headingScale: CGFloat = 1.0
    var headingColor: String = "#333333"
    var headingMarginTop: CGFloat = 24
    var headingMarginBottom: CGFloat = 16
    var codeBlockTheme: String = "github"
    var customCSS: String = ""
    var maxWidth: CGFloat = 800
    var fontFamily: String = "system-ui"
    var fontSize: CGFloat = 16
}

// MARK: - App Settings (Enhanced)

struct AppSettings: Codable, Equatable {
    // Appearance
    var theme: AppTheme = .system
    var editorTheme: EditorTheme = .oneDark
    
    // Editor
    var autosaveEnabled: Bool = false
    var autosaveInterval: TimeInterval = 30
    var showLineNumbers: Bool = true
    var softWrap: Bool = true
    var fontSize: CGFloat = 14
    var fontName: String = "SF Mono"
    var tabSize: Int = 4
    var insertSpacesInsteadOfTabs: Bool = true
    var highlightCurrentLine: Bool = true
    var showInvisibles: Bool = false
    var enableAutocompletion: Bool = true
    var bracketMatching: Bool = true
    
    // Preview
    var previewTheme: String = "github"
    var previewSettings: PreviewSettings = PreviewSettings()
    var enableWikiLinks: Bool = true
    var enableCallouts: Bool = true
    var enableMermaid: Bool = false
    var enableKaTeX: Bool = false
    
    // Vault & Sync
    var defaultVaultId: UUID?
    var conflictResolution: FileConflictResolution = .rename
    var injectFrontmatterByDefault: Bool = true
    var cloudSyncEnabled: Bool = false
    
    // UI
    var showStatusBar: Bool = true
    var showTabBar: Bool = true
    var sidebarWidth: CGFloat = 250
    var restoreLastSession: Bool = true
    var confirmBeforeClosingDirtyTabs: Bool = true
    var scrollSyncEnabled: Bool = true

    // Remote Control
    var remoteControlEnabled: Bool = false
    var remoteControlPort: Int = 51707
    var remoteControlApiKey: String = ""
}

// MARK: - File Tree Item

struct FileTreeItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let isDirectory: Bool
    var isExpanded: Bool
    var children: [FileTreeItem]
    
    init(url: URL, isDirectory: Bool = false, isExpanded: Bool = false, children: [FileTreeItem] = []) {
        self.id = UUID()
        self.url = url
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.children = children
    }
    
    var name: String {
        url.lastPathComponent
    }
    
    var icon: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "doc.text"
        case "txt": return "doc.plaintext"
        case "json": return "curlybraces"
        case "yml", "yaml": return "list.bullet.rectangle"
        default: return "doc"
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: FileTreeItem, rhs: FileTreeItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Search Result

struct SearchResult: Identifiable {
    let id: UUID
    let fileURL: URL
    let lineNumber: Int
    let lineContent: String
    let matchRange: Range<String.Index>
    
    init(fileURL: URL, lineNumber: Int, lineContent: String, matchRange: Range<String.Index>) {
        self.id = UUID()
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.lineContent = lineContent
        self.matchRange = matchRange
    }
    
    var fileName: String {
        fileURL.lastPathComponent
    }
}

// MARK: - TOC Heading (for Table of Contents)

struct TOCHeading: Identifiable {
    let id: UUID
    let level: Int
    let text: String
    let lineNumber: Int
    
    init(level: Int, text: String, lineNumber: Int) {
        self.id = UUID()
        self.level = level
        self.text = text
        self.lineNumber = lineNumber
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

@Observable
final class AppState {
    // Tab System
    var tabs: [EditorTab] = []
    var activeTabId: UUID?
    var documents: [UUID: MarkdownDocument] = [:]
    var originalContents: [UUID: String] = [:]
    
    // View State
    var viewMode: ViewMode = .split
    var sidebarVisible: Bool = true
    var inspectorVisible: Bool = false
    var selectedSidebarTab: SidebarTab = .files
    
    // File System
    var vaults: [Vault] = []
    var drafts: [Draft] = []
    var favorites: [FavoriteItem] = []
    var recentFiles: [URL] = []
    var currentFolder: URL?
    var fileTree: [FileTreeItem] = []
    var expandedFolders: Set<URL> = []
    
    // Templates & Rules
    var templates: [VaultTemplate] = []
    var routingRules: [RoutingRule] = []
    
    // Settings
    var settings: AppSettings = AppSettings()
    
    // Modals & Dialogs
    var showCommandPalette: Bool = false
    var showSendToVault: Bool = false
    var showVaultManager: Bool = false
    var showQuickCapture: Bool = false
    var showSettings: Bool = false
    
    // Search
    var searchText: String = ""
    var folderSearchText: String = ""
    var searchResults: [SearchResult] = []
    var isSearching: Bool = false
    
    // Status
    var isLoading: Bool = false
    var errorMessage: String?
    var toastMessage: String?
    
    // Services
    private let fileService: FileService
    private let vaultService: VaultService
    private let draftService: DraftService
    private let exportService: ExportService
    let remoteControlService = RemoteControlService()
    private let dataURL: URL
    private var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]
    
    // Computed Properties
    var activeTab: EditorTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }
    
    var currentDocument: MarkdownDocument? {
        get {
            guard let tab = activeTab else { return nil }
            return documents[tab.documentId]
        }
        set {
            guard let tab = activeTab, let doc = newValue else { return }
            documents[tab.documentId] = doc
        }
    }
    
    var originalContent: String {
        get {
            guard let tab = activeTab else { return "" }
            return originalContents[tab.documentId] ?? ""
        }
        set {
            guard let tab = activeTab else { return }
            originalContents[tab.documentId] = newValue
        }
    }
    
    var isDirty: Bool {
        guard let doc = currentDocument else { return false }
        return doc.content != originalContent
    }
    
    var hasAnyDirtyTabs: Bool {
        tabs.contains { tab in
            guard let doc = documents[tab.documentId],
                  let original = originalContents[tab.documentId] else { return false }
            return doc.content != original
        }
    }
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("CmdMD")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dataURL = appDir
        
        fileService = FileService()
        vaultService = VaultService(dataDirectory: appDir)
        draftService = DraftService(dataDirectory: appDir)
        exportService = ExportService()
        
        loadUserData()
        
        NotificationCenter.default.addObserver(
            forName: .showQuickCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showQuickCapture = true
        }

        if settings.remoteControlEnabled {
            startRemoteControl()
        }
    }

    func startRemoteControl() {
        let port = UInt16(clamping: settings.remoteControlPort)
        let key = settings.remoteControlApiKey.isEmpty ? nil : settings.remoteControlApiKey
        remoteControlService.start(appState: self, port: port, apiKey: key)
    }

    func stopRemoteControl() {
        remoteControlService.stop()
    }

    func restartRemoteControl() {
        stopRemoteControl()
        if settings.remoteControlEnabled {
            startRemoteControl()
        }
    }
    
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url {
            openDocument(at: url)
        }
    }
    
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            currentFolder = url
            selectedSidebarTab = .files
            loadFileTree()
        }
    }
    
    func openDocument(at url: URL, inNewTab: Bool = false) {
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            return
        }
        
        Task { @MainActor in
            do {
                let document = try await fileService.loadDocument(from: url)
                let tab = EditorTab(
                    documentId: document.id,
                    fileURL: url,
                    title: document.displayTitle
                )
                
                documents[document.id] = document
                originalContents[document.id] = document.content
                
                if inNewTab || tabs.isEmpty {
                    tabs.append(tab)
                } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabId }) {
                    tabs[activeIndex] = tab
                } else {
                    tabs.append(tab)
                }
                
                activeTabId = tab.id
                addToRecentFiles(url)
                startWatchingFile(at: url, for: tab.id)
            } catch {
                errorMessage = "Failed to open file: \(error.localizedDescription)"
            }
        }
    }
    
    private func startWatchingFile(at url: URL, for tabId: UUID) {
        stopWatchingFile(for: tabId)
        
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        
        source.setEventHandler { [weak self] in
            self?.handleExternalFileChange(at: url, event: source.data)
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        fileWatchers[tabId] = source
    }
    
    private func stopWatchingFile(for tabId: UUID? = nil) {
        if let tabId = tabId {
            fileWatchers[tabId]?.cancel()
            fileWatchers.removeValue(forKey: tabId)
        } else {
            for watcher in fileWatchers.values {
                watcher.cancel()
            }
            fileWatchers.removeAll()
        }
    }
    
    private func handleExternalFileChange(at url: URL, event: DispatchSource.FileSystemEvent) {
        guard let tab = tabs.first(where: { $0.fileURL == url }) else { return }
        
        if event.contains(.delete) {
            showToast("File was deleted externally")
            if var doc = documents[tab.documentId] {
                doc.fileURL = nil
                documents[tab.documentId] = doc
            }
            stopWatchingFile(for: tab.id)
            return
        }
        
        if event.contains(.rename) {
            showToast("File was renamed externally")
            stopWatchingFile(for: tab.id)
            return
        }
        
        if event.contains(.write) {
            let tabIsDirty: Bool = {
                guard let doc = documents[tab.documentId],
                      let original = originalContents[tab.documentId] else { return false }
                return doc.content != original
            }()
            
            guard !tabIsDirty else {
                showExternalChangeConflict(for: url)
                return
            }
            
            Task { @MainActor in
                do {
                    let document = try await fileService.loadDocument(from: url)
                    documents[tab.documentId] = document
                    originalContents[tab.documentId] = document.content
                    showToast("Reloaded from disk")
                } catch {
                    errorMessage = "Failed to reload file: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func showExternalChangeConflict(for url: URL) {
        showToast("File changed externally - save to overwrite or reload")
    }
    
    func reloadCurrentDocument() {
        guard let url = currentDocument?.fileURL else { return }
        Task { @MainActor in
            do {
                let document = try await fileService.loadDocument(from: url)
                currentDocument = document
                originalContent = document.content
                showToast("Reloaded")
            } catch {
                errorMessage = "Failed to reload: \(error.localizedDescription)"
            }
        }
    }
    
    func loadFileTree() {
        guard let folder = currentFolder else { return }
        fileTree = buildFileTree(at: folder)
    }
    
    private func buildFileTree(at url: URL, depth: Int = 0) -> [FileTreeItem] {
        guard depth < 10 else { return [] }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            
            var items: [FileTreeItem] = []
            
            for itemURL in contents.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = resourceValues.isDirectory ?? false
                
                if isDirectory {
                    let children = expandedFolders.contains(itemURL) ? buildFileTree(at: itemURL, depth: depth + 1) : []
                    items.append(FileTreeItem(url: itemURL, isDirectory: true, isExpanded: expandedFolders.contains(itemURL), children: children))
                } else {
                    let ext = itemURL.pathExtension.lowercased()
                    if ext == "md" || ext == "markdown" || ext == "txt" {
                        items.append(FileTreeItem(url: itemURL, isDirectory: false))
                    }
                }
            }
            
            return items.sorted { item1, item2 in
                if item1.isDirectory == item2.isDirectory {
                    return item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
                }
                return item1.isDirectory && !item2.isDirectory
            }
        } catch {
            errorMessage = "Failed to load folder: \(error.localizedDescription)"
            return []
        }
    }
    
    func toggleFolderExpansion(_ url: URL) {
        if expandedFolders.contains(url) {
            expandedFolders.remove(url)
        } else {
            expandedFolders.insert(url)
        }
        loadFileTree()
    }
    
    @MainActor
    func saveCurrentDocument() async {
        guard var document = currentDocument else { return }
        
        if let url = document.fileURL {
            do {
                try await fileService.saveDocument(document, to: url)
                document.modifiedAt = Date()
                originalContent = document.content
                currentDocument = document
                showToast("Saved")
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        } else {
            await saveDocumentAs()
        }
    }
    
    @MainActor
    func saveDocumentAs() async {
        guard var document = currentDocument else { return }
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
        panel.nameFieldStringValue = document.displayTitle + ".md"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try await fileService.saveDocument(document, to: url)
                document.fileURL = url
                document.modifiedAt = Date()
                originalContent = document.content
                currentDocument = document
                addToRecentFiles(url)
                showToast("Saved")
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }
    
    func createNewDraft() {
        let draft = Draft()
        currentDocument = draft.toDocument()
        originalContent = ""
    }
    
    func updateContent(_ newContent: String) {
        currentDocument?.content = newContent
        currentDocument?.modifiedAt = Date()
    }
    
    func exportAsHTML() {
        guard let document = currentDocument else { return }
        let theme = PreviewTheme(rawValue: settings.previewTheme) ?? .github
        exportService.saveHTML(document: document, theme: theme)
    }
    
    func exportAsPDF() {
        guard let document = currentDocument else { return }
        let theme = PreviewTheme(rawValue: settings.previewTheme) ?? .github
        exportService.savePDF(document: document, theme: theme)
    }
    
    func copyAsHTML() {
        guard let document = currentDocument else { return }
        let theme = PreviewTheme(rawValue: settings.previewTheme) ?? .github
        exportService.copyAsHTML(document: document, theme: theme)
        showToast("Copied as HTML")
    }
    
    private func addToRecentFiles(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 {
            recentFiles = Array(recentFiles.prefix(20))
        }
        saveUserData()
    }
    
    func clearRecentFiles() {
        recentFiles.removeAll()
        saveUserData()
    }
    
    func addToFavorites(_ url: URL) {
        guard !favorites.contains(where: { $0.url == url }) else { return }
        favorites.append(FavoriteItem(url: url))
        saveUserData()
        showToast("Added to favorites")
    }
    
    func removeFromFavorites(_ favorite: FavoriteItem) {
        favorites.removeAll { $0.id == favorite.id }
        saveUserData()
    }
    
    func openDraft(_ draft: Draft) {
        let document = draft.toDocument()
        let tab = EditorTab(
            documentId: document.id,
            title: draft.displayTitle
        )
        
        documents[document.id] = document
        originalContents[document.id] = document.content
        tabs.append(tab)
        activeTabId = tab.id
    }
    
    func createNewTab() {
        let document = MarkdownDocument()
        let tab = EditorTab(
            documentId: document.id,
            title: "Untitled"
        )
        
        documents[document.id] = document
        originalContents[document.id] = ""
        tabs.append(tab)
        activeTabId = tab.id
    }
    
    func closeTab(_ tab: EditorTab) {
        stopWatchingFile(for: tab.id)
        documents.removeValue(forKey: tab.documentId)
        originalContents.removeValue(forKey: tab.documentId)
        
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        
        if activeTabId == tab.id {
            if tabs.isEmpty {
                activeTabId = nil
            } else if index < tabs.count {
                activeTabId = tabs[index].id
            } else {
                activeTabId = tabs.last?.id
            }
        }
    }
    
    func closeTabWithConfirmation(_ tab: EditorTab) {
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes?"
        alert.informativeText = "Your changes to \"\(tab.displayTitle)\" will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await saveCurrentDocument()
                closeTab(tab)
            }
        case .alertSecondButtonReturn:
            closeTab(tab)
        default:
            break
        }
    }
    
    func closeOtherTabs(except tab: EditorTab) {
        let otherTabs = tabs.filter { $0.id != tab.id && !$0.isPinned }
        for t in otherTabs {
            closeTab(t)
        }
    }
    
    func closeTabsToRight(of tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let tabsToRight = tabs.suffix(from: index + 1).filter { !$0.isPinned }
        for t in tabsToRight {
            closeTab(t)
        }
    }
    
    func toggleTabPin(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].isPinned.toggle()
        
        if tabs[index].isPinned {
            let pinnedCount = tabs.prefix(index).filter { $0.isPinned }.count
            let movedTab = tabs.remove(at: index)
            tabs.insert(movedTab, at: pinnedCount)
        }
    }
    
    func selectNextTab() {
        guard !tabs.isEmpty, let currentId = activeTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        activeTabId = tabs[nextIndex].id
    }
    
    func selectPreviousTab() {
        guard !tabs.isEmpty, let currentId = activeTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        activeTabId = tabs[prevIndex].id
    }
    
    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        activeTabId = tabs[index].id
    }
    
    func searchInFolder(query: String) {
        guard let folder = currentFolder, !query.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        searchResults = []
        
        Task {
            let results = await performSearch(query: query, in: folder)
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }
    
    private func performSearch(query: String, in folder: URL) async -> [SearchResult] {
        var results: [SearchResult] = []
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        
        let lowercaseQuery = query.lowercased()
        
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "md" || fileURL.pathExtension.lowercased() == "markdown" else { continue }
            
            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                let lines = content.components(separatedBy: .newlines)
                
                for (index, line) in lines.enumerated() {
                    if let range = line.lowercased().range(of: lowercaseQuery) {
                        let result = SearchResult(
                            fileURL: fileURL,
                            lineNumber: index + 1,
                            lineContent: line,
                            matchRange: range
                        )
                        results.append(result)
                    }
                }
            } catch {
                continue
            }
        }
        
        return results
    }
    
    func clearSearch() {
        folderSearchText = ""
        searchResults = []
        isSearching = false
    }
    
    func addVault(_ vault: Vault) {
        vaults.append(vault)
        saveUserData()
    }
    
    func removeVault(_ vault: Vault) {
        vaults.removeAll { $0.id == vault.id }
        saveUserData()
    }
    
    func sendToVault(options: SendOptions) async throws {
        guard let document = currentDocument,
              let vault = options.targetVault else {
            throw SendError.noDocumentOrVault
        }
        
        var targetURL = vault.rootPath.appendingPathComponent(options.targetFolder)
        
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        }
        
        let filename = document.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        targetURL = targetURL.appendingPathComponent(filename)
        
        targetURL = resolveConflict(for: targetURL, resolution: options.conflictResolution)
        
        var contentToWrite = document.content
        if options.injectFrontmatter {
            let frontmatter = Frontmatter(
                title: document.displayTitle,
                date: Date(),
                tags: document.frontmatter?.tags ?? [],
                custom: ["source": "CmdMD", "created": ISO8601DateFormatter().string(from: Date())]
            )
            contentToWrite = frontmatter.toYAML() + "\n\n" + contentToWrite
        }
        
        try contentToWrite.write(to: targetURL, atomically: true, encoding: .utf8)
        
        if options.action == .move, let sourceURL = document.fileURL {
            try FileManager.default.removeItem(at: sourceURL)
            currentDocument = nil
            originalContent = ""
        }
        
        showToast("Sent to \(vault.displayName)")
        
        if options.openAfterSend {
            openInObsidian(vault: vault, filePath: targetURL)
        }
    }
    
    private func openInObsidian(vault: Vault, filePath: URL) {
        let vaultName = vault.name.isEmpty ? vault.rootPath.lastPathComponent : vault.name
        let relativePath = filePath.path.replacingOccurrences(of: vault.rootPath.path + "/", with: "")
        
        var urlComponents = URLComponents()
        urlComponents.scheme = "obsidian"
        urlComponents.host = "open"
        urlComponents.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "file", value: relativePath)
        ]
        
        if let obsidianURL = urlComponents.url {
            NSWorkspace.shared.open(obsidianURL)
        }
    }
    
    private func resolveConflict(for url: URL, resolution: FileConflictResolution) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        
        switch resolution {
        case .overwrite:
            return url
        case .skip:
            return url
        case .rename:
            var counter = 1
            var newURL = url
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let parent = url.deletingLastPathComponent()
            
            while FileManager.default.fileExists(atPath: newURL.path) {
                newURL = parent.appendingPathComponent("\(baseName) (\(counter)).\(ext)")
                counter += 1
            }
            return newURL
        case .timestamp:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let parent = url.deletingLastPathComponent()
            return parent.appendingPathComponent("\(baseName)_\(timestamp).\(ext)")
        }
    }
    
    func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
    }
    
    private func loadUserData() {
        let settingsURL = dataURL.appendingPathComponent("settings.json")
        let vaultsURL = dataURL.appendingPathComponent("vaults.json")
        let recentsURL = dataURL.appendingPathComponent("recents.json")
        let templatesURL = dataURL.appendingPathComponent("templates.json")
        let rulesURL = dataURL.appendingPathComponent("rules.json")
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        if let data = try? Data(contentsOf: settingsURL),
           let loaded = try? decoder.decode(AppSettings.self, from: data) {
            settings = loaded
        }
        
        if let data = try? Data(contentsOf: vaultsURL),
           let loaded = try? decoder.decode([Vault].self, from: data) {
            vaults = loaded
        }
        
        if let data = try? Data(contentsOf: recentsURL),
           let loaded = try? decoder.decode([URL].self, from: data) {
            recentFiles = loaded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        
        if let data = try? Data(contentsOf: templatesURL),
           let loaded = try? decoder.decode([VaultTemplate].self, from: data) {
            templates = loaded
        }
        
        if let data = try? Data(contentsOf: rulesURL),
           let loaded = try? decoder.decode([RoutingRule].self, from: data) {
            routingRules = loaded
        }
    }
    
    func saveUserData() {
        let settingsURL = dataURL.appendingPathComponent("settings.json")
        let vaultsURL = dataURL.appendingPathComponent("vaults.json")
        let recentsURL = dataURL.appendingPathComponent("recents.json")
        let templatesURL = dataURL.appendingPathComponent("templates.json")
        let rulesURL = dataURL.appendingPathComponent("rules.json")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL)
        }
        if let data = try? encoder.encode(vaults) {
            try? data.write(to: vaultsURL)
        }
        if let data = try? encoder.encode(recentFiles) {
            try? data.write(to: recentsURL)
        }
        if let data = try? encoder.encode(templates) {
            try? data.write(to: templatesURL)
        }
        if let data = try? encoder.encode(routingRules) {
            try? data.write(to: rulesURL)
        }
    }
}

enum SendError: LocalizedError {
    case noDocumentOrVault
    case fileConflict
    case writeError(Error)
    
    var errorDescription: String? {
        switch self {
        case .noDocumentOrVault:
            return "No document or vault selected"
        case .fileConflict:
            return "File already exists"
        case .writeError(let error):
            return "Write error: \(error.localizedDescription)"
        }
    }
}
