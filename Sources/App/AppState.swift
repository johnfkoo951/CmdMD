import SwiftUI
import Observation
import UniformTypeIdentifiers

@Observable
final class AppState {
    /// Weak shared reference so the AppDelegate (created independently via
    /// @NSApplicationDelegateAdaptor) can consult app state on quit.
    static weak var shared: AppState?
    private static let launchDefaults = AppLaunchDefaults()

    // Tab System
    var tabs: [EditorTab] = []
    var activeTabId: UUID?
    var documents: [UUID: MarkdownDocument] = [:]
    var originalContents: [UUID: String] = [:]

    // View State
    var viewMode: ViewMode = AppState.launchDefaults.viewMode
    var sidebarVisible: Bool = AppState.launchDefaults.sidebarVisible
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
    var showOmnisearch: Bool = false
    var showAbout: Bool = false
    /// Editor/preview width ratio in split view (runtime-only).
    var splitFraction: CGFloat = 0.5
    /// Non-empty while the Send sheet is operating on a batch of files
    /// (e.g. "Send Folder to Vault…") instead of the active document.
    var batchSendURLs: [URL] = []

    // Search
    var folderSearchText: String = ""
    var searchResults: [SearchResult] = []
    var isSearching: Bool = false

    // Status
    var errorMessage: String?
    var toastMessage: String?

    // Editor caret (for the status bar)
    var cursorLine: Int = 1
    var cursorColumn: Int = 1

    // Completion index
    private(set) var linkableNotes: [VaultNote] = []
    private(set) var knownTags: Set<String> = []
    private var noteIndexTask: Task<Void, Never>?

    // Services
    private let fileService: FileService
    private let exportService: ExportService
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
        return doc.fullText != originalContent
    }

    var hasAnyDirtyTabs: Bool {
        tabs.contains { isTabDirty($0) }
    }

    func isTabDirty(_ tab: EditorTab) -> Bool {
        guard let doc = documents[tab.documentId],
              let original = originalContents[tab.documentId] else { return false }
        return doc.fullText != original
    }

    var windowTitle: String {
        guard let title = currentDocument?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "CmdMD"
        }
        return title
    }

    var defaultVault: Vault? {
        if let id = settings.defaultVaultId, let vault = vaults.first(where: { $0.id == id }) {
            return vault
        }
        return vaults.first
    }

    /// Resolves the destination folder for a Send. A vault's own Inbox wins when
    /// it is set; otherwise the app-wide `settings.defaultSendFolder` applies,
    /// falling back to "Inbox" so a send always has a valid target.
    func effectiveSendFolder(for vault: Vault) -> String {
        Self.resolveSendFolder(vaultInbox: vault.inboxPath, globalDefault: settings.defaultSendFolder)
    }

    /// Pure resolution rule (extracted so it is unit-testable without a live
    /// AppState): trimmed vault Inbox wins; else the trimmed global default;
    /// else "Inbox".
    static func resolveSendFolder(vaultInbox: String, globalDefault: String) -> String {
        let inbox = vaultInbox.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inbox.isEmpty { return inbox }
        let global = globalDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        return global.isEmpty ? "Inbox" : global
    }

    /// The active binding for an action — user override or the default.
    func keyBinding(for shortcut: AppShortcut) -> KeyBinding {
        settings.keyBindings[shortcut.rawValue] ?? shortcut.defaultBinding
    }

    /// Copies the current document's filesystem path to the clipboard (⌥⌘C).
    func copyCurrentFilePath() {
        guard let url = currentDocument?.fileURL else {
            showToast("No file path — save the document first")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showToast("Path copied")
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("CmdMD")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dataURL = appDir

        fileService = FileService()
        exportService = ExportService()

        AppState.shared = self

        loadUserData()
        restoreSessionIfNeeded()
        rebuildNoteIndex()

        NotificationCenter.default.addObserver(
            forName: .showQuickCapture,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showQuickCapture = true
        }

        NotificationCenter.default.addObserver(
            forName: .openInternalLink,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            self?.openInternalURL(url)
        }
    }

    // MARK: - Opening Files

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")!]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            for url in panel.urls {
                openDocument(at: url, inNewTab: true)
            }
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
            sidebarVisible = true
            loadFileTree()
            rebuildNoteIndex()
            saveSession()
        }
    }

    func openInternalURL(_ url: URL) {
        guard url.scheme == "cmdmd" else { return }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let note = components.queryItems?.first(where: { $0.name == "note" })?.value {
                openLinkedNote(note)
                return
            }

            if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
                openDocument(at: URL(fileURLWithPath: path))
                return
            }
        }

        if url.host == "open", let path = url.pathComponents.dropFirst().first {
            openDocument(at: URL(fileURLWithPath: path))
        }
    }

    func openLinkedNote(_ rawTarget: String) {
        guard let target = LinkedNoteResolver.normalizedTarget(rawTarget) else { return }

        let roots = linkedNoteSearchRoots()
        let resolver = LinkedNoteResolver(roots: roots)

        if let directURL = resolver.resolveDirectCandidate(named: target) {
            openDocument(at: directURL, inNewTab: true)
            return
        }

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                LinkedNoteResolver(roots: roots).resolve(normalizedTarget: target)
            }.value

            await MainActor.run {
                if let found {
                    self.openDocument(at: found, inNewTab: true)
                } else {
                    self.showToast("Linked note not found: \(target)")
                }
            }
        }
    }

    func openDocument(at url: URL, inNewTab: Bool = false, scrollToLine line: Int? = nil) {
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            if let line { scrollEditor(toLine: line) }
            return
        }

        Task { @MainActor in
            await loadAndActivateDocument(at: url, inNewTab: inNewTab)
            if let line { scrollEditor(toLine: line) }
        }
    }

    @MainActor
    private func loadAndActivateDocument(at url: URL, inNewTab: Bool) async {
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            return
        }
        do {
            let document = try await fileService.loadDocument(from: url)
            let tab = EditorTab(
                documentId: document.id,
                fileURL: url,
                title: document.displayTitle
            )

            documents[document.id] = document
            originalContents[document.id] = document.fullText

            if inNewTab || tabs.isEmpty {
                tabs.append(tab)
            } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabId }) {
                // Replacing the active tab in place: release the previous
                // document and cancel its file watcher so we don't leak file
                // descriptors or orphan documents/originalContents entries.
                let oldTab = tabs[activeIndex]
                stopWatchingFile(for: oldTab.id)
                documents.removeValue(forKey: oldTab.documentId)
                originalContents.removeValue(forKey: oldTab.documentId)
                tabs[activeIndex] = tab
            } else {
                tabs.append(tab)
            }

            activeTabId = tab.id
            addToRecentFiles(url)
            startWatchingFile(at: url, for: tab.id)
            harvestTags(from: document)
            saveSession()
        } catch {
            errorMessage = "Failed to open file: \(error.localizedDescription)"
        }
    }

    /// Posts the scroll request after a short delay so a freshly-created editor
    /// (the editor subtree is keyed to document identity) has time to subscribe.
    private func scrollEditor(toLine line: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            NotificationCenter.default.post(name: .scrollToLine, object: line)
            guard let self, self.viewMode != .source else { return }
            // In preview/split, also bring the nearest preceding heading into view.
            if let slug = self.nearestHeadingSlug(before: line) {
                NotificationCenter.default.post(name: .scrollToHeading, object: slug)
            }
        }
    }

    private func nearestHeadingSlug(before line: Int) -> String? {
        guard let content = currentDocument?.content else { return nil }
        let headings = TOCBuilder.extractHeadings(from: content)
        return headings.last(where: { $0.lineNumber <= line })?.slug
    }

    func linkedNoteSearchRoots() -> [URL] {
        var roots: [URL] = []

        if let documentFolder = currentDocument?.fileURL?.deletingLastPathComponent() {
            roots.append(documentFolder)
        }
        if let currentFolder {
            roots.append(currentFolder)
        }
        roots.append(contentsOf: vaults.map(\.rootPath))

        var seen: Set<String> = []
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    // MARK: - Completion Index

    /// Rebuilds the wiki-link completion index off the main thread. Scans the
    /// open folder and registered vault roots for note files (names only — file
    /// contents are never read here).
    func rebuildNoteIndex() {
        noteIndexTask?.cancel()
        var roots: [URL] = []
        if let currentFolder { roots.append(currentFolder) }
        roots.append(contentsOf: vaults.map(\.rootPath))

        guard !roots.isEmpty else {
            linkableNotes = []
            return
        }

        // Hop back through the static ref instead of capturing self across the
        // detached-task boundary (AppState itself is not Sendable).
        noteIndexTask = Task.detached(priority: .utility) {
            let notes = NoteIndexService.buildIndex(roots: roots)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                AppState.shared?.linkableNotes = notes
            }
        }
    }

    private static let inlineTagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)#([a-zA-Z][a-zA-Z0-9_/-]*)"#
    )

    /// Collects tags from a document (frontmatter + inline #tags) so the tag
    /// completion popup learns vocabulary from everything the user opens.
    func harvestTags(from document: MarkdownDocument) {
        var tags = Set(document.frontmatter?.tags ?? [])
        let ns = document.content as NSString
        Self.inlineTagPattern.enumerateMatches(in: document.content, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            tags.insert(ns.substring(with: match.range(at: 1)))
        }
        knownTags.formUnion(tags)
    }

    // MARK: - File Watching

    private func startWatchingFile(at url: URL, for tabId: UUID) {
        stopWatchingFile(for: tabId)

        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
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

        // Atomic saves (Obsidian, vim, VS Code, and most editors) write to a temp
        // file then rename it over the original. That swaps the inode, so the
        // watched fd — bound to the OLD inode — receives .rename/.delete (never
        // .write) and stops seeing changes. So on rename/delete we re-resolve the
        // path and re-arm the watch on the new file, which is why external edits
        // now reflect instead of going silent.
        if event.contains(.rename) || event.contains(.delete) {
            stopWatchingFile(for: tab.id)   // close the stale descriptor
            // Brief delay so the atomic replacement is fully in place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let tab = self.tabs.first(where: { $0.fileURL == url }) else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    self.startWatchingFile(at: url, for: tab.id)   // re-arm on the new inode
                    self.reloadExternally(url: url, tab: tab)
                } else {
                    self.showToast("File was removed externally")
                    if var doc = self.documents[tab.documentId] {
                        doc.fileURL = nil
                        self.documents[tab.documentId] = doc
                    }
                    if let index = self.tabs.firstIndex(where: { $0.id == tab.id }) {
                        self.tabs[index].fileURL = nil
                    }
                }
            }
            return
        }

        if event.contains(.write) || event.contains(.extend) {
            reloadExternally(url: url, tab: tab)
        }
    }

    /// Reloads a tab's content from disk after an external change, preserving the
    /// document's identity (so scroll/selection survive). Won't clobber unsaved
    /// in-app edits — those get a toast prompting a manual reload instead.
    private func reloadExternally(url: URL, tab: EditorTab) {
        guard !isTabDirty(tab) else {
            showToast("File changed externally — ⌥⌘R to reload")
            return
        }
        Task { @MainActor in
            do {
                let fresh = try await fileService.loadDocument(from: url)
                if var existing = documents[tab.documentId] {
                    existing.content = fresh.content
                    existing.frontmatter = fresh.frontmatter
                    existing.modifiedAt = Date()
                    documents[tab.documentId] = existing
                    originalContents[tab.documentId] = existing.fullText
                } else {
                    documents[tab.documentId] = fresh
                    originalContents[tab.documentId] = fresh.fullText
                }
                showToast("Reloaded from disk")
            } catch {
                errorMessage = "Failed to reload file: \(error.localizedDescription)"
            }
        }
    }

    func reloadCurrentDocument() {
        guard let url = currentDocument?.fileURL else { return }
        Task { @MainActor in
            do {
                let document = try await fileService.loadDocument(from: url)
                currentDocument = document
                originalContent = document.fullText
                showToast("Reloaded")
            } catch {
                errorMessage = "Failed to reload: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - File Tree

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

    /// Creates a new, uniquely-named Markdown file in `folder` and opens it.
    /// (The old implementation blindly wrote an empty "Untitled.md", silently
    /// truncating an existing file of that name.)
    func createNewFile(in folder: URL) {
        let target = folder.appendingPathComponent("Untitled.md").uniquified()
        do {
            try "".write(to: target, atomically: true, encoding: .utf8)
            loadFileTree()
            openDocument(at: target, inNewTab: true)
            viewMode = .source
        } catch {
            errorMessage = "Failed to create file: \(error.localizedDescription)"
        }
    }

    func createNewFolder(in parent: URL) {
        let target = parent.appendingPathComponent("New Folder").uniquified()
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            loadFileTree()
        } catch {
            errorMessage = "Failed to create folder: \(error.localizedDescription)"
        }
    }

    // MARK: - Saving

    @MainActor
    func saveCurrentDocument() async {
        guard let document = currentDocument else { return }

        if let url = document.fileURL {
            do {
                try await fileService.saveDocument(document, to: url)
                // Update the dirty baseline to exactly what we wrote. We do NOT
                // reassign the whole captured snapshot back into currentDocument:
                // doing so would clobber any keystrokes the user made while the
                // async write was in flight. We only stamp modifiedAt on the
                // live document.
                originalContent = document.fullText
                if var current = currentDocument {
                    current.modifiedAt = Date()
                    currentDocument = current
                }
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
        guard let document = currentDocument else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
        panel.nameFieldStringValue = document.displayTitle + ".md"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                var doc = document
                doc.fileURL = url
                doc.modifiedAt = Date()
                let wasDraft = doc.isDraft
                doc.isDraft = false
                try await fileService.saveDocument(doc, to: url)
                currentDocument = doc
                originalContent = doc.fullText
                // Persist the new URL on the tab too, otherwise dedup/watching/
                // breadcrumb logic that keys off tab.fileURL stays out of sync.
                if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
                    tabs[index].fileURL = url
                    tabs[index].title = doc.displayTitle
                    startWatchingFile(at: url, for: tabId)
                }
                // A draft that became a real file graduates out of the drafts list.
                if wasDraft {
                    drafts.removeAll { $0.id == doc.id }
                    saveUserData()
                }
                addToRecentFiles(url)
                saveSession()
                showToast("Saved")
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }

    /// Saves every file-backed dirty tab. Used by the save-on-quit guard.
    /// Unsaved (no fileURL) tabs are skipped since they'd require a Save panel.
    @MainActor
    func saveAllDirtyTabs() async {
        for tab in tabs {
            guard let doc = documents[tab.documentId],
                  let url = doc.fileURL,
                  isTabDirty(tab) else { continue }
            do {
                try await fileService.saveDocument(doc, to: url)
                originalContents[tab.documentId] = doc.fullText
            } catch {
                errorMessage = "Failed to save \(tab.displayTitle): \(error.localizedDescription)"
            }
        }
    }

    func updateContent(_ newContent: String) {
        currentDocument?.content = newContent
        currentDocument?.modifiedAt = Date()
        if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs[index].isDirty = isDirty
        }
        // Keep the backing draft in sync while a draft is being edited so its
        // content survives restarts even without an explicit save.
        if let doc = currentDocument, doc.isDraft,
           let draftIndex = drafts.firstIndex(where: { $0.id == doc.id }) {
            drafts[draftIndex].body = newContent
            drafts[draftIndex].updatedAt = Date()
            scheduleDraftPersist()
        }
        scheduleAutosaveIfNeeded()
    }

    func updateCursorPosition(line: Int, column: Int) {
        if cursorLine != line { cursorLine = line }
        if cursorColumn != column { cursorColumn = column }
    }

    /// Flips a `- [ ]`/`- [x]` marker on the given 1-based source line. Invoked
    /// by checkbox clicks in the preview. The line is re-validated against the
    /// task pattern before mutating so a stale line number can never corrupt
    /// unrelated text.
    func toggleTask(atLine line: Int, checked: Bool) {
        guard let doc = currentDocument else { return }
        var lines = doc.content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }

        let target = lines[line - 1]
        let ns = target as NSString
        guard let match = TaskLineQueue.taskLinePattern.firstMatch(
            in: target,
            range: NSRange(location: 0, length: ns.length)
        ) else {
            showToast("Couldn't toggle that task")
            return
        }

        let markerRange = match.range(at: 2)
        lines[line - 1] = ns.replacingCharacters(in: markerRange, with: checked ? "x" : " ")
        updateContent(lines.joined(separator: "\n"))
    }

    // MARK: - Autosave

    private var autosaveWorkItem: DispatchWorkItem?

    /// Debounced autosave: each edit reschedules, so a save fires only after the
    /// user pauses for `autosaveInterval` seconds. Only saves file-backed
    /// documents so it never pops a Save panel unexpectedly.
    private func scheduleAutosaveIfNeeded() {
        guard settings.autosaveEnabled, currentDocument?.fileURL != nil else { return }
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.settings.autosaveEnabled,
                      self.currentDocument?.fileURL != nil, self.isDirty else { return }
                await self.saveCurrentDocument()
            }
        }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, settings.autosaveInterval), execute: work)
    }

    // MARK: - Drafts

    private var draftPersistWorkItem: DispatchWorkItem?

    private func scheduleDraftPersist() {
        draftPersistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistDrafts()
        }
        draftPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func createNewDraft() {
        let draft = Draft()
        drafts.insert(draft, at: 0)
        persistDrafts()
        openDraft(draft)
        viewMode = .source
    }

    func addDraft(_ draft: Draft) {
        drafts.insert(draft, at: 0)
        persistDrafts()
    }

    func deleteDraft(_ draft: Draft) {
        drafts.removeAll { $0.id == draft.id }
        // Close any tab editing this draft.
        if let tab = tabs.first(where: { $0.documentId == draft.id }) {
            closeTab(tab)
        }
        persistDrafts()
    }

    func openDraft(_ draft: Draft) {
        if let existingTab = tabs.first(where: { $0.documentId == draft.id }) {
            activeTabId = existingTab.id
            return
        }

        let document = draft.toDocument()
        let tab = EditorTab(
            documentId: document.id,
            title: draft.displayTitle
        )

        documents[document.id] = document
        originalContents[document.id] = document.fullText
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
        originalContents[document.id] = document.fullText
        tabs.append(tab)
        activeTabId = tab.id
        viewMode = .source
    }

    // MARK: - Tabs

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
        saveSession()
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

    func moveTab(id: UUID, before targetId: UUID) {
        guard id != targetId,
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetId }) else { return }
        let tab = tabs.remove(at: sourceIndex)
        let insertIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(tab, at: insertIndex)
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

    // MARK: - Export

    func exportAsHTML() {
        guard let document = currentDocument else { return }
        exportService.saveHTML(document: document, options: renderOptions())
    }

    func exportAsPDF() {
        guard let document = currentDocument else { return }
        exportService.savePDF(document: document, options: renderOptions())
    }

    func copyAsHTML() {
        guard let document = currentDocument else { return }
        exportService.copyAsHTML(document: document, options: renderOptions())
        showToast("Copied as HTML")
    }

    /// The render configuration shared by the live preview and all exporters.
    func renderOptions() -> MarkdownRenderOptions {
        MarkdownRenderOptions(
            theme: PreviewTheme(rawValue: settings.previewTheme) ?? .github,
            preview: settings.previewSettings,
            enableWikiLinks: settings.enableWikiLinks,
            enableCallouts: settings.enableCallouts,
            enableMermaid: settings.enableMermaid,
            enableKaTeX: settings.enableKaTeX,
            enableCodeHighlight: settings.enablePreviewCodeHighlight
        )
    }

    // MARK: - Recents & Favorites

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

    // MARK: - Folder Search

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
        let maxResults = 500

        // Pull all URLs up front: iterating an enumerator directly is a
        // makeIterator call that's unavailable from async contexts in Swift 6.
        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
        for fileURL in fileURLs {
            guard fileURL.pathExtension.lowercased() == "md" || fileURL.pathExtension.lowercased() == "markdown" else { continue }

            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                let lines = content.components(separatedBy: .newlines)

                for (index, line) in lines.enumerated() {
                    if let range = line.lowercased().range(of: lowercaseQuery) {
                        results.append(SearchResult(
                            fileURL: fileURL,
                            lineNumber: index + 1,
                            lineContent: line,
                            matchRange: range
                        ))
                        if results.count >= maxResults { return results }
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

    /// Content search over the open folder, used by Omnisearch.
    func searchContent(query: String) async -> [SearchResult] {
        guard let folder = currentFolder, !query.isEmpty else { return [] }
        return await performSearch(query: query, in: folder)
    }

    // MARK: - Vaults

    func addVault(_ vault: Vault) {
        vaults.append(vault)
        saveUserData()
        rebuildNoteIndex()
    }

    func removeVault(_ vault: Vault) {
        vaults.removeAll { $0.id == vault.id }
        routingRules.removeAll { $0.targetVaultId == vault.id }
        saveUserData()
        rebuildNoteIndex()
    }

    // MARK: - Send to Vault

    func sendToVault(options: SendOptions) async throws {
        guard let document = currentDocument else {
            throw SendError.noDocumentOrVault
        }
        try await sendToVault(document: document, options: options)
    }

    /// Sends an explicit document. Used directly by menu-bar Quick Capture, which
    /// has no active tab and therefore can't rely on `currentDocument`.
    func sendToVault(document: MarkdownDocument, options: SendOptions, quiet: Bool = false) async throws {
        guard let vault = options.targetVault else {
            throw SendError.noDocumentOrVault
        }

        let targetDir = vault.rootPath.appendingPathComponent(options.targetFolder)
        if !FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let template: VaultTemplate? = options.applyTemplate
            ? templates.first(where: { $0.id == options.templateId })
            : nil

        let baseName = template?.generateFilename(title: document.displayTitle) ?? document.displayTitle
        let filename = Self.sanitizedFilename(baseName) + ".md"
        let candidateURL = targetDir.appendingPathComponent(filename)

        guard let targetURL = resolveConflict(for: candidateURL, resolution: options.conflictResolution) else {
            // .skip on an existing file must leave both target and source intact.
            if !quiet { showToast("Skipped: \(filename) already exists") }
            return
        }

        let body = template?.renderContent(for: document) ?? document.content

        let contentToWrite: String
        if options.injectFrontmatter {
            // Preserve the document's REAL frontmatter (tags, dates, custom keys)
            // instead of synthesizing a minimal one that discards user metadata.
            var frontmatter = document.frontmatter ?? Frontmatter(title: document.displayTitle, date: Date())
            if frontmatter.title == nil { frontmatter.title = document.displayTitle }
            if options.addSourceLink, let source = document.fileURL {
                frontmatter.custom["source"] = .string(source.path)
            }
            contentToWrite = frontmatter.toYAML() + "\n\n" + body
        } else if template != nil {
            contentToWrite = body
        } else {
            // No injection and no template: ship the file exactly as it is on
            // disk. Writing `content` alone silently stripped existing
            // frontmatter from the copy.
            contentToWrite = document.fullText
        }

        try contentToWrite.write(to: targetURL, atomically: true, encoding: .utf8)

        if options.action == .move, let sourceURL = document.fileURL {
            try FileManager.default.removeItem(at: sourceURL)
            // Detach the in-app tab from the now-deleted source file.
            if document.id == currentDocument?.id, var current = currentDocument {
                current.fileURL = nil
                currentDocument = current
                if let tabId = activeTabId, let index = tabs.firstIndex(where: { $0.id == tabId }) {
                    tabs[index].fileURL = nil
                    stopWatchingFile(for: tabId)
                }
            }
        }

        if !quiet { showToast("Sent to \(vault.displayName)") }

        if options.openAfterSend, let obsidianURL = vault.obsidianURL(forFile: targetURL) {
            NSWorkspace.shared.open(obsidianURL)
        }
    }

    /// Sends a batch of files with the same options. Returns counts for the
    /// summary toast. Used by "Send Folder to Vault…".
    @MainActor
    @discardableResult
    func sendFiles(_ urls: [URL], options: SendOptions) async -> (sent: Int, failed: Int) {
        var sent = 0, failed = 0
        for url in urls {
            do {
                let document = try await fileService.loadDocument(from: url)
                try await sendToVault(document: document, options: options, quiet: true)
                sent += 1
            } catch {
                failed += 1
            }
        }
        showToast("Sent \(sent) of \(urls.count) files" + (failed > 0 ? " (\(failed) failed)" : ""))
        return (sent, failed)
    }

    // MARK: - Routing Rules

    /// Highest-priority enabled rule whose conditions all match (a rule with no
    /// conditions acts as a catch-all) and whose target vault still exists.
    func matchingRoutingRule(for document: MarkdownDocument) -> RoutingRule? {
        routingRules
            .filter { $0.isEnabled }
            .sorted { $0.priority > $1.priority }
            .first { rule in
                vaults.contains(where: { $0.id == rule.targetVaultId }) &&
                rule.conditions.allSatisfy { $0.matches(document: document) }
            }
    }

    /// One-keystroke routed send: evaluates routing rules against the current
    /// document and sends without showing a dialog. Falls back to the Send
    /// sheet when no rule matches.
    func autoRouteCurrentDocument() {
        guard let document = currentDocument else { return }
        guard let rule = matchingRoutingRule(for: document),
              let vault = vaults.first(where: { $0.id == rule.targetVaultId }) else {
            showToast("No routing rule matches — opening Send dialog")
            showSendToVault = true
            return
        }

        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = rule.targetFolder
        options.action = rule.action
        options.conflictResolution = settings.conflictResolution
        options.injectFrontmatter = rule.injectFrontmatter

        Task { @MainActor in
            do {
                try await sendToVault(document: document, options: options, quiet: true)
                showToast("Routed to \(vault.displayName)/\(rule.targetFolder) (\(rule.name))")
            } catch {
                errorMessage = "Auto-route failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Conflict Resolution

    /// Returns the URL to write to, or `nil` when the write should be skipped
    /// (the file exists and resolution is `.skip`). Distinguishing skip from
    /// overwrite is what stops "Skip" from silently clobbering the existing note.
    private func resolveConflict(for url: URL, resolution: FileConflictResolution) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        switch resolution {
        case .overwrite:
            return url
        case .skip:
            return nil
        case .rename:
            return url.uniquified()
        case .timestamp:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let parent = url.deletingLastPathComponent()
            return parent.appendingPathComponent("\(baseName)_\(timestamp).\(ext)").uniquified()
        }
    }

    static func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    // MARK: - Toast

    func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
    }

    // MARK: - Session Persistence

    private var sessionURL: URL { dataURL.appendingPathComponent("session.json") }

    func saveSession() {
        let openFiles = tabs.compactMap(\.fileURL)
        var activeIndex: Int?
        if let activeURL = activeTab?.fileURL {
            activeIndex = openFiles.firstIndex(of: activeURL)
        }
        let session = SessionState(
            openFiles: openFiles,
            activeFileIndex: activeIndex,
            viewMode: viewMode,
            currentFolder: currentFolder,
            sidebarVisible: sidebarVisible,
            inspectorVisible: inspectorVisible
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(session) {
            try? data.write(to: sessionURL)
        }
    }

    private func restoreSessionIfNeeded() {
        guard settings.restoreLastSession,
              let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SessionState.self, from: data) else { return }

        viewMode = session.viewMode
        sidebarVisible = session.sidebarVisible
        inspectorVisible = session.inspectorVisible

        if let folder = session.currentFolder,
           FileManager.default.fileExists(atPath: folder.path) {
            currentFolder = folder
            loadFileTree()
        }

        let files = session.openFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }

        Task { @MainActor in
            for url in files {
                await loadAndActivateDocument(at: url, inNewTab: true)
            }
            if let index = session.activeFileIndex, index < tabs.count {
                activeTabId = tabs[index].id
            }
        }
    }

    // MARK: - User Data Persistence

    private func loadUserData() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
            guard let data = try? Data(contentsOf: dataURL.appendingPathComponent(filename)) else { return nil }
            return try? decoder.decode(type, from: data)
        }

        if let loaded = load(AppSettings.self, from: "settings.json") { settings = loaded }
        if let loaded = load([Vault].self, from: "vaults.json") { vaults = loaded }
        if let loaded = load([URL].self, from: "recents.json") {
            recentFiles = loaded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let loaded = load([VaultTemplate].self, from: "templates.json") { templates = loaded }
        if let loaded = load([RoutingRule].self, from: "rules.json") { routingRules = loaded }
        if let loaded = load([FavoriteItem].self, from: "favorites.json") {
            favorites = loaded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
        if let loaded = load([Draft].self, from: "drafts.json") { drafts = loaded }
    }

    func saveUserData() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        func save<T: Encodable>(_ value: T, to filename: String) {
            if let data = try? encoder.encode(value) {
                try? data.write(to: dataURL.appendingPathComponent(filename))
            }
        }

        save(settings, to: "settings.json")
        save(vaults, to: "vaults.json")
        save(recentFiles, to: "recents.json")
        save(templates, to: "templates.json")
        save(routingRules, to: "rules.json")
        save(favorites, to: "favorites.json")
        persistDrafts()
    }

    func persistDrafts() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(drafts) {
            try? data.write(to: dataURL.appendingPathComponent("drafts.json"))
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

// MARK: - URL Uniquifying

extension URL {
    /// Returns self if no file exists at this path, otherwise appends
    /// " (1)", " (2)", … before the extension until the name is free.
    func uniquified() -> URL {
        guard FileManager.default.fileExists(atPath: path) else { return self }
        let baseName = deletingPathExtension().lastPathComponent
        let ext = pathExtension
        let parent = deletingLastPathComponent()

        var counter = 1
        var candidate = self
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidate = parent.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
