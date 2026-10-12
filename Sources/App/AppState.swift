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
    var activeTabId: UUID? {
        // An IME composition in the editor hasn't reached the model yet. Have
        // it committed now, while it still lands in the outgoing document —
        // after the switch the editor's push would go to the new one.
        willSet {
            if newValue != activeTabId {
                commitPendingComposition()
            }
        }
    }
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
    // The palette and Omnisearch share one overlay: opening either closes the
    // other, so a flag set underneath can't resurface when the top one closes.
    var showCommandPalette: Bool = false {
        didSet { if showCommandPalette { showOmnisearch = false } }
    }
    var showSendToVault: Bool = false
    var showVaultManager: Bool = false
    var showQuickCapture: Bool = false
    var showOmnisearch: Bool = false {
        didSet { if showOmnisearch { showCommandPalette = false } }
    }
    var showAbout: Bool = false
    /// The action Settings › Shortcuts is recording a key combination for —
    /// one row at a time; app key handlers (the ⌘+ zoom alternate) stand aside.
    var recordingShortcut: AppShortcut?

    // Update checking (GitHub Releases)
    var updateAvailable: Bool = false
    var latestVersion: String?
    var updateURL: URL?
    var isCheckingForUpdate: Bool = false
    /// Editor/preview width ratio in split view (runtime-only).
    var splitFraction: CGFloat = 0.5
    /// Non-empty while the Send sheet is operating on a batch of files
    /// (e.g. "Send Folder to Vault…") instead of the active document.
    var batchSendURLs: [URL] = []
    /// The folder a batch was collected from. Each file keeps its subfolder
    /// path below it inside the target folder (see `sendFiles`).
    var batchSendRoot: URL?

    // Search
    var folderSearchText: String = ""
    var searchResults: [SearchResult] = []
    var isSearching: Bool = false
    /// The query the current `searchResults` belong to (folder search runs on
    /// Return), so the panel doesn't report "No Results" for unsearched text.
    var searchedQuery: String?
    /// The sidebar shows its folder search instead of the file tree. Kept here
    /// (not in SidebarView) so Find in Folder… (⇧⌘F) can open it.
    var showFolderSearch: Bool = false
    /// Bumped by ⇧⌘F so an already-open search field takes focus again.
    var folderSearchFocusRequest: Int = 0

    // Status
    /// Every error surfaced through AppState is logged in one place here, so
    /// call sites don't need individual Log lines next to each assignment.
    var errorMessage: String? {
        didSet {
            // Error strings embed file names and paths: detail, not message.
            if let errorMessage { Log.error("alert:", detail: errorMessage) }
        }
    }
    var toastMessage: String?
    var toastStyle: ToastStyle = .success

    // Editor caret (for the status bar)
    var cursorLine: Int = 1
    var cursorColumn: Int = 1

    // Completion index
    private(set) var linkableNotes: [VaultNote] = []
    private(set) var knownTags: Set<String> = []
    private var noteIndexTask: Task<Void, Never>?
    /// A walk is running (cleared when its result lands).
    @ObservationIgnored private var noteIndexInFlight = false

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
            // Every document mutation funnels through here (typing, frontmatter
            // edits, saves), so this is the one place the stored per-tab dirty
            // flag stays correct — views read the flag instead of re-comparing
            // fullText on every render.
            refreshStoredDirty(forTabId: tab.id)
        }
    }

    /// Recomputes and stores the dirty flag for one tab. O(n) once per actual
    /// mutation instead of per render.
    func refreshStoredDirty(forTabId tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let dirty = isTabDirty(tabs[index])
        if tabs[index].isDirty != dirty {
            tabs[index].isDirty = dirty
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
            // A new baseline changes what "dirty" means, so re-derive the stored
            // flag here too. Save As and ⌥⌘R assign the document first (which
            // compares against the OLD baseline) and left the tab looking dirty.
            refreshStoredDirty(forTabId: tab.id)
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
        // A draft persists itself — body and properties go to drafts.json — so
        // it is never an unsaved change. Answering here also keeps typing in a
        // draft with properties from rebuilding its YAML on every keystroke.
        if doc.isDraft, drafts.contains(where: { $0.id == doc.id }) { return false }
        // Runs per keystroke (refreshStoredDirty). Lengths first: they differ
        // after nearly every edit, and fullText rebuilds the whole text when
        // the note has frontmatter.
        guard doc.fullTextUTF16Count == original.utf16.count else { return true }
        return doc.fullText != original
    }

    var windowTitle: String {
        guard let title = currentDocument?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "CmdMD"
        }
        return title
    }

    /// The vault chosen as "Default vault for Send". Nil when that setting is
    /// None: callers must not quietly fall back to the first vault.
    var defaultVault: Vault? {
        guard let id = settings.defaultVaultId else { return nil }
        return vaults.first(where: { $0.id == id })
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

    /// A typed send folder as a vault-relative path: blanks, "." and stray
    /// slashes dropped, "" for the vault root. Nil when a ".." component would
    /// climb out of the vault.
    static func normalizedSendFolder(_ folder: String) -> String? {
        let parts = folder.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." }
        guard !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    /// The active binding for an action — user override or the default.
    func keyBinding(for shortcut: AppShortcut) -> KeyBinding {
        settings.keyBindings[shortcut.rawValue] ?? shortcut.defaultBinding
    }

    // MARK: - Panel toggles

    /// Every entry point (menu, toolbar, palette) routes through these so the
    /// panels always slide with the same motion instead of animating from the
    /// menu but hard-cutting from the toolbar button.
    func toggleSidebar() {
        withAnimation(.snappy(duration: 0.25)) { sidebarVisible.toggle() }
    }

    func toggleInspector() {
        withAnimation(.snappy(duration: 0.25)) { inspectorVisible.toggle() }
    }

    // MARK: - Update checking

    /// Compares two version strings ("v1.4.4" / "1.4.4") component-wise.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Checks the GitHub Releases API for a newer version. Silent checks are
    /// throttled to once every 6h; `userInitiated` checks always run and report.
    func checkForUpdates(userInitiated: Bool = false) {
        // A dev build reports version "dev": every release would look newer.
        guard AppInfo.isPackagedBuild else {
            if userInitiated { showToast("Development build — no release version to compare") }
            return
        }
        guard !isCheckingForUpdate else { return }

        let throttleKey = "lastUpdateCheck"
        if !userInitiated {
            let last = UserDefaults.standard.double(forKey: throttleKey)
            if Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        }

        isCheckingForUpdate = true
        Task { @MainActor in
            defer { isCheckingForUpdate = false }
            let current = AppInfo.version
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/johnfkoo951/CmdMD/releases/latest")!)
                request.setValue("CmdMD", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10

                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if userInitiated { showToast("Couldn't check for updates", style: .error) }
                    return
                }

                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: throttleKey)
                latestVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                updateURL = URL(string: (json["html_url"] as? String) ?? "https://github.com/johnfkoo951/CmdMD/releases/latest")

                if Self.isVersion(tag, newerThan: current) {
                    updateAvailable = true
                    if userInitiated { showToast("Update available: \(latestVersion ?? tag)") }
                } else {
                    updateAvailable = false
                    if userInitiated { showToast("You're on the latest version (\(current))") }
                }
            } catch {
                if userInitiated { showToast("Couldn't check for updates", style: .error) }
            }
        }
    }

    /// Copies the current document's filesystem path to the clipboard (⌥⌘C).
    func copyCurrentFilePath() {
        guard let url = currentDocument?.fileURL else {
            showToast("No file path — save the document first", style: .warning)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showToast("Path copied")
    }

    // MARK: - Open in Obsidian

    /// Hands the current document to Obsidian (⌥⌘J, Vault menu, palette).
    func openCurrentDocumentInObsidian() {
        guard let url = currentDocument?.fileURL else {
            showToast("No file to open — save the document first", style: .warning)
            return
        }
        openInObsidian(fileURL: url)
    }

    func openInObsidian(fileURL: URL) {
        guard let url = Self.obsidianOpenURL(for: fileURL, vaults: vaults) else { return }
        // False when nothing handles obsidian:// (Obsidian isn't installed).
        if !NSWorkspace.shared.open(url) {
            showToast("Couldn't open Obsidian", style: .error)
        }
    }

    /// The obsidian:// URL for a file. Inside a configured vault it names the
    /// vault folder, which is what Obsidian keys on (the display alias broke
    /// links), plus the vault-relative path; elsewhere it falls back to a
    /// path-based open.
    static func obsidianOpenURL(for fileURL: URL, vaults: [Vault]) -> URL? {
        if let vault = vaults.first(where: { $0.contains(fileURL) }),
           let url = vault.obsidianURL(forFile: fileURL) {
            return url
        }
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: fileURL.path)]
        return components.url
    }

    // MARK: - Zoom

    /// Bounds for the unified editor/preview zoom multiplier.
    static let zoomRange: ClosedRange<Double> = 0.5...3.0

    /// Clamps to `zoomRange` and rounds to 2 decimals so pinch gestures don't
    /// leave float dust that defeats the editor's pointSize-equality check.
    static func clampedZoom(_ value: Double) -> Double {
        let clamped = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        return (clamped * 100).rounded() / 100
    }

    func zoomIn() { setZoom(settings.zoomLevel + 0.1) }
    func zoomOut() { setZoom(settings.zoomLevel - 0.1) }
    func resetZoom() { setZoom(1.0) }

    /// Continuous pinch input: `magnification` is the incremental delta from an
    /// NSMagnificationGestureRecognizer / magnify(with:) event.
    func adjustZoom(by magnification: Double) {
        // Deltas compound on an unrounded accumulator — applied one by one to
        // the 2-decimal stored level, slow pinches rounded away to nothing and
        // fast ones fell short. Re-seed when the level moved without a pinch
        // (⌘= / ⌘- / ⌘0, Settings).
        var base = pinchZoomAccumulator ?? settings.zoomLevel
        if Self.clampedZoom(base) != settings.zoomLevel { base = settings.zoomLevel }
        let next = Self.accumulatedZoom(base, magnification: magnification)
        pinchZoomAccumulator = next
        setZoom(next)
    }

    /// One pinch step: clamped to `zoomRange` but deliberately NOT rounded —
    /// only the stored level (`setZoom`) is quantized.
    static func accumulatedZoom(_ base: Double, magnification: Double) -> Double {
        min(max(base * (1 + magnification), zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// Unrounded running pinch zoom (see `adjustZoom`).
    @ObservationIgnored private var pinchZoomAccumulator: Double?

    private func setZoom(_ value: Double) {
        let clamped = Self.clampedZoom(value)
        guard clamped != settings.zoomLevel else { return }
        settings.zoomLevel = clamped
        Log.info("zoom \(Int((clamped * 100).rounded()))%", .zoom)
        scheduleSettingsSave()
    }

    /// Debounced saveUserData — pinch gestures change settings many times per
    /// second, and each save rewrites all the data JSONs. One write 0.5s after
    /// the last change is enough.
    @ObservationIgnored private var settingsSaveDebounce: DispatchWorkItem?

    private func scheduleSettingsSave() {
        settingsSaveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveUserData()
        }
        settingsSaveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Debounced persistence for high-frequency settings changes (sliders,
    /// steppers). Each Settings tick was synchronously rewriting all 7 JSON
    /// files; one write 0.5s after the last change is enough. Quit still
    /// flushes synchronously via applicationShouldTerminate.
    func saveUserDataDebounced() {
        scheduleSettingsSave()
    }

    /// Root of all app data (settings/session/drafts…, vault bookmarks, logs/).
    /// CMDMD_DATA_DIR points the whole data layer at an alternate directory —
    /// lets dev builds run side-by-side with the installed app without touching
    /// real user data. Everything that persists (AppState, Log, VaultService)
    /// must resolve its location here so the isolation has no gaps.
    static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CmdMD")
    }

    init() {
        let appDir = AppState.dataDirectory
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dataURL = appDir

        fileService = FileService()
        exportService = ExportService()

        AppState.shared = self

        loadUserData()
        Log.setFileLoggingEnabled(settings.fileLoggingEnabled)
        Log.info("CmdMD \(AppInfo.version) launched", .app)
        restoreSessionIfNeeded()
        rebuildNoteIndex()
        Task { @MainActor in await reconcileVaultLocations() }
        checkForUpdates()   // silent, throttled to once per 6h

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

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFolderStateOnActivation()
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
            openFolder(at: url)
        }
    }

    /// Makes `url` the workspace folder (the Files tree's root) and shows it
    /// in the sidebar: Open Folder…, or a folder dropped on the window.
    func openFolder(at url: URL) {
        // A search still scanning the old folder would land its hits under
        // the new one.
        if currentFolder.map({ !Self.isSameFile($0, url) }) ?? true { clearSearch() }
        currentFolder = url
        selectedSidebarTab = .files
        sidebarVisible = true
        loadFileTree()
        rebuildNoteIndex()
        saveSession()
    }

    func openInternalURL(_ url: URL) {
        guard url.scheme == "cmdmd" else { return }

        // `[[#Heading]]`: a heading in the current note, slugged by the renderer.
        if url.host == "heading" {
            let slug = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "slug" })?.value ?? ""
            if !slug.isEmpty { scrollToHeading(slug: slug) }
            return
        }

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
        let (note, heading) = LinkedNoteResolver.splitTarget(rawTarget)
        guard let target = note else {
            // `#Heading` alone points into the current note.
            if let heading { scrollToHeading(slug: markdownHeadingSlug(heading)) }
            return
        }

        let roots = linkedNoteSearchRoots()
        let resolver = LinkedNoteResolver(roots: roots)

        if let directURL = resolver.resolveDirectCandidate(named: target) {
            openLinkedDocument(at: directURL, heading: heading)
            return
        }

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                LinkedNoteResolver(roots: roots).resolve(normalizedTarget: target)
            }.value

            await MainActor.run {
                if let found {
                    self.openLinkedDocument(at: found, heading: heading)
                } else {
                    self.showToast("Linked note not found: \(target)", style: .warning)
                }
            }
        }
    }

    /// Opens a resolved wiki-link target in a new tab. For `[[Note#Heading]]`
    /// it then scrolls to the heading, after the same short delay as
    /// scrollEditor(toLine:) so the note's freshly-made views are listening.
    private func openLinkedDocument(at url: URL, heading: String?) {
        guard let heading else {
            openDocument(at: url, inNewTab: true)
            return
        }
        let slug = markdownHeadingSlug(heading)
        let scroll = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self, self.currentDocument?.fileURL == url else { return }
                self.scrollToHeading(slug: slug)
            }
        }

        if tabs.contains(where: { $0.fileURL == url }) {
            openDocument(at: url, inNewTab: true)
            scroll()
            return
        }
        Task { @MainActor in
            await loadAndActivateDocument(at: url, inNewTab: true)
            scroll()
        }
    }

    /// Scrolls to the current note's first heading with this base slug, like a
    /// TOC click: the editor to its line, the preview to its anchor. A heading
    /// the TOC doesn't list (setext, quoted) still gets the preview scroll.
    private func scrollToHeading(slug: String) {
        let heading = currentDocument.flatMap { document in
            TOCBuilder.extractHeadings(from: document.content, options: renderOptions())
                .first { markdownHeadingSlug($0.text) == slug }
        }
        if let heading, viewMode != .preview {
            NotificationCenter.default.post(name: .scrollToLine, object: heading.lineNumber)
        }
        if viewMode != .source {
            NotificationCenter.default.post(name: .scrollToHeading, object: heading?.slug ?? slug)
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

    /// Opens several files at once (a multi-file drop) — each in its own tab,
    /// in the given order. Loaded one after another so tabs keep that order
    /// instead of landing in load-completion order.
    func openDocuments(at urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                await loadAndActivateDocument(at: url, inNewTab: true)
            }
        }
    }

    /// A drop on the window or the preview: the first folder becomes the
    /// workspace (one at a time), files open as tabs in drop order.
    func openDroppedItems(_ urls: [URL]) {
        let dropped = AppWindowPolicy.partitionDroppedURLs(urls)
        if let folder = dropped.folders.first {
            openFolder(at: folder)
        }
        if !dropped.files.isEmpty {
            openDocuments(at: dropped.files)
        }
    }

    @MainActor
    private func loadAndActivateDocument(at url: URL, inNewTab: Bool) async {
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            return
        }
        // Favorited folders, drops and Finder or cmdmd:// opens can name a
        // folder; reading it as a file only fails with a cryptic alert.
        if Self.isFolder(at: url) {
            showToast("\u{201C}\(url.lastPathComponent)\u{201D} is a folder", style: .warning)
            return
        }
        do {
            let document = try await fileService.loadDocument(from: url)
            // Checked again after the read: an open of the same file that
            // finished meanwhile (a second click, a Finder open racing session
            // restore) already has a tab, and a second one would go stale.
            if let existingTab = tabs.first(where: { $0.fileURL == url }) {
                activeTabId = existingTab.id
                return
            }
            let tab = EditorTab(
                documentId: document.id,
                fileURL: url,
                title: document.displayTitle
            )

            documents[document.id] = document
            originalContents[document.id] = document.fullText

            if inNewTab || tabs.isEmpty {
                tabs.append(tab)
            } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabId }),
                      !tabs[activeIndex].isPinned,
                      !isTabDirty(tabs[activeIndex]),
                      documents[tabs[activeIndex].documentId]?.isDraft != true {
                // Replacing the active tab in place: release the previous
                // document and cancel its file watcher so we don't leak file
                // descriptors or orphan documents/originalContents entries.
                // Pinned or dirty tabs are never replaced — silently discarding
                // unsaved edits (or a deliberately pinned note) would be data loss.
                // Nor are drafts: they read clean (they save themselves), but
                // a draft being written shouldn't vanish on a sidebar click.
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
            Log.info("opened", .file, detail: url.lastPathComponent)
        } catch {
            // A file deleted since it was listed would stay in Open Recent
            // (pruned only at launch) and fail the same way on every click.
            if Self.isDefinitelyMissing(url), recentFiles.contains(url) {
                recentFiles.removeAll { $0 == url }
                saveUserDataDebounced()
            }
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
        let headings = TOCBuilder.extractHeadings(from: content, options: renderOptions())
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
    func rebuildNoteIndex(keepingInFlight: Bool = false) {
        // The app-activation refresh comes every few seconds; restarting a walk
        // still running (a large tree takes many seconds) meant the index
        // never finished. Explicit rebuilds still restart it.
        if keepingInFlight, noteIndexInFlight { return }
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
        noteIndexInFlight = true
        noteIndexTask = Task.detached(priority: .utility) {
            // Coalesce bursts (batch sends, repeated file operations): each call
            // cancels the previous task, so only the last one scans.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let notes = NoteIndexService.buildIndex(roots: roots)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                AppState.shared?.linkableNotes = notes
                AppState.shared?.noteIndexInFlight = false
            }
        }
    }

    /// Collects tags from a document (frontmatter + inline #tags) so the tag
    /// completion popup learns vocabulary from everything the user opens.
    func harvestTags(from document: MarkdownDocument) {
        knownTags.formUnion(document.allTags)
    }

    // MARK: - Folder Refresh

    /// Last time the sidebar tree and note index were re-read (throttles the
    /// app-activation refresh; launch has just read both).
    @ObservationIgnored private var lastFolderRefresh = Date()

    /// Re-reads the sidebar tree and the note index behind [[ completion and
    /// Omnisearch, picking up notes other apps (Obsidian, Finder, sync)
    /// created, renamed or deleted. Only per-file watchers exist, so without
    /// this those changes stayed invisible until the folder was reopened.
    func refreshFolderState(keepingInFlightIndex: Bool = false) {
        lastFolderRefresh = Date()
        loadFileTree()
        rebuildNoteIndex(keepingInFlight: keepingInFlightIndex)
    }

    /// Switching back to CmdMD is when changes made in other apps show up.
    private func refreshFolderStateOnActivation() {
        guard Self.shouldRefreshFolderState(last: lastFolderRefresh, now: Date(), minInterval: 3) else { return }
        // A folder that vanished (unmounted drive, deleted elsewhere) would
        // raise a "Failed to load folder" alert on every switch back.
        if let folder = currentFolder, !FileManager.default.fileExists(atPath: folder.path) { return }
        refreshFolderState(keepingInFlightIndex: true)
    }

    static func shouldRefreshFolderState(last: Date, now: Date, minInterval: TimeInterval) -> Bool {
        now.timeIntervalSince(last) >= minInterval
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
            let event = source.data
            // Ask where a renamed file went while the descriptor is still
            // open: handling the event cancels the source, which closes it.
            let movedTo = event.contains(.rename) ? Self.currentPath(ofWatchedDescriptor: fileDescriptor) : nil
            self?.handleExternalFileChange(at: url, tabId: tabId, event: event, movedTo: movedTo)
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

    /// `tabId` is the tab the firing watcher belongs to. Looking the tab up by
    /// URL instead found the first tab on that file, whichever watcher fired,
    /// so another tab showing the same file was never re-armed or reloaded.
    private func handleExternalFileChange(at url: URL, tabId: UUID, event: DispatchSource.FileSystemEvent, movedTo: URL?) {
        guard let tab = tabs.first(where: { $0.id == tabId && $0.fileURL == url }) else { return }

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
                self?.settleMovedOrRemovedFile(at: url, tabId: tabId, movedTo: movedTo, retries: 1)
            }
            return
        }

        if event.contains(.write) || event.contains(.extend) {
            reloadExternally(url: url, tab: tab)
        }
    }

    /// Follows up a rename/delete event once the dust has settled: re-arms on
    /// a replaced file, follows a file another app renamed or moved, and —
    /// when it is really gone — keeps the tab's text as unsaved changes.
    private func settleMovedOrRemovedFile(at url: URL, tabId: UUID, movedTo: URL?, retries: Int) {
        guard let tab = tabs.first(where: { $0.id == tabId && $0.fileURL == url }) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            startWatchingFile(at: url, for: tab.id)   // re-arm on the new inode
            reloadExternally(url: url, tab: tab)
        } else if let movedTo, !Self.isInTrash(movedTo), FileManager.default.fileExists(atPath: movedTo.path) {
            // Renamed or moved (Finder, Obsidian…): follow the file, as an
            // in-app rename does, instead of orphaning the tab.
            retargetOpenItems(from: url, to: movedTo)
            saveSession()
            showToast("File renamed externally: \(movedTo.lastPathComponent)")
        } else if retries > 0 {
            // Sync tools and git can remove a file and write it back a moment
            // later — look again before calling it deleted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.settleMovedOrRemovedFile(at: url, tabId: tabId, movedTo: movedTo, retries: retries - 1)
            }
        } else {
            // Deleted, or moved to the Trash. Keep the URL and make the whole
            // text unsaved changes: close and quit then ask first, and Save
            // writes the file back. Detaching the URL instead left a clean,
            // never-autosaved buffer that ⌘W discarded without a prompt.
            originalContents[tab.documentId] = ""
            refreshStoredDirty(forTabId: tab.id)
            showToast("File was removed externally — save to keep it", style: .warning)
        }
    }

    /// Where the file behind a watched descriptor lives now. F_GETPATH follows
    /// renames, but after an unlink (or an atomic replace) it still reports
    /// the old path, which by then names another file — hence the inode check.
    static func currentPath(ofWatchedDescriptor fileDescriptor: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fileDescriptor, F_GETPATH, &buffer) != -1 else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var watched = stat(), linked = stat()
        guard fstat(fileDescriptor, &watched) == 0, stat(path, &linked) == 0,
              watched.st_dev == linked.st_dev, watched.st_ino == linked.st_ino else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// A move into Finder's Trash, a volume's .Trashes or Obsidian's vault
    /// .trash is a deletion, not a rename to follow.
    static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { [".trash", ".trashes"].contains($0.lowercased()) }
    }

    /// Reloads a tab's content from disk after an external change, preserving the
    /// document's identity (so scroll/selection survive). Won't clobber unsaved
    /// in-app edits — those get a toast prompting a manual reload instead.
    private func reloadExternally(url: URL, tab: EditorTab) {
        Task { @MainActor in
            do {
                let disk = try await fileService.loadDocumentWithText(from: url)
                guard let tab = tabs.first(where: { $0.id == tab.id }), tab.fileURL == url else { return }
                // Our own saves land here too (the atomic write swaps the
                // inode). The file then holds exactly the baseline, and
                // reloading it re-parsed the note under the caret and replaced
                // the "Saved" toast after every ⌘S.
                if Self.diskMatches(originalContents[tab.documentId] ?? "", diskText: disk.text, diskFullText: disk.document.fullText) {
                    return
                }
                // Checked after the read so keystrokes typed meanwhile are never overwritten.
                guard !isTabDirty(tab) else {
                    showToast("File changed externally — " + (shortcutHint(for: .reloadFromDisk).map { "\($0) to reload" } ?? "use File › Reload from Disk"),
                              style: .warning)
                    return
                }
                applyDiskVersion(disk.document, toTabId: tab.id, from: url)
                showToast("Reloaded from disk")
            } catch {
                errorMessage = "Failed to reload file: \(error.localizedDescription)"
            }
        }
    }

    /// Reload from Disk (⌥⌘R). Asks first when the tab has unsaved edits, and
    /// writes into the tab it was invoked on even if another tab is active
    /// by the time a slow read finishes.
    func reloadCurrentDocument() {
        guard let tab = activeTab, let url = documents[tab.documentId]?.fileURL else { return }
        if isTabDirty(tab) {
            let alert = NSAlert()
            alert.messageText = "Revert \u{201C}\(tab.displayTitle)\u{201D} to the version on disk?"
            alert.informativeText = "Your unsaved changes will be lost."
            alert.alertStyle = .warning
            let revert = alert.addButton(withTitle: "Revert")
            revert.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { @MainActor in
            do {
                let document = try await fileService.loadDocument(from: url)
                guard applyDiskVersion(document, toTabId: tab.id, from: url) else { return }
                showToast("Reloaded")
            } catch {
                errorMessage = "Failed to reload: \(error.localizedDescription)"
            }
        }
    }

    /// Swaps the file's current contents into a tab in place and makes them
    /// the new baseline. The document keeps its id, so the editor and preview
    /// treat it as the same document (caret and scroll survive) instead of a
    /// switch. Returns false when the tab was closed or retargeted meanwhile.
    @discardableResult
    private func applyDiskVersion(_ fresh: MarkdownDocument, toTabId tabId: UUID, from url: URL) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }), tab.fileURL == url,
              let existing = documents[tab.documentId] else { return false }
        let reloaded = Self.applyingDiskReload(fresh, to: existing)
        documents[tab.documentId] = reloaded
        originalContents[tab.documentId] = reloaded.fullText
        refreshStoredDirty(forTabId: tab.id)
        // The editor keeps its undo stack for a same-document text change;
        // undoing typing recorded against the old text would corrupt this one.
        NotificationCenter.default.post(name: .documentReloadedFromDisk, object: reloaded.id)
        return true
    }

    /// `existing` with its text and metadata replaced by the version on disk;
    /// identity (id, file URL, draft state) is kept.
    static func applyingDiskReload(_ fresh: MarkdownDocument, to existing: MarkdownDocument) -> MarkdownDocument {
        var reloaded = existing
        reloaded.title = fresh.title
        reloaded.content = fresh.content
        reloaded.frontmatter = fresh.frontmatter
        reloaded.frontmatterSource = fresh.frontmatterSource
        reloaded.fileFormat = fresh.fileFormat
        reloaded.modifiedAt = fresh.modifiedAt
        return reloaded
    }

    /// Whether a file read back as `diskText` (parsed: `diskFullText`) holds
    /// `text`. Our own saves match byte for byte; a file as first loaded only
    /// matches after parsing, because `fullText` re-serializes frontmatter.
    static func diskMatches(_ text: String, diskText: String, diskFullText: String) -> Bool {
        diskText == text || diskFullText == text
    }

    /// Whether writing `pending` would overwrite a version another app saved
    /// after CmdMD last loaded or wrote the file (`baseline`).
    static func isSaveConflict(diskText: String, diskFullText: String, baseline: String, pending: String) -> Bool {
        !diskMatches(baseline, diskText: diskText, diskFullText: diskFullText)
            && !diskMatches(pending, diskText: diskText, diskFullText: diskFullText)
    }

    // MARK: - File Tree

    /// Each folder's sorted shallow listing (children not filled in), so a
    /// disclosure toggle reads at most the folder being expanded instead of
    /// re-listing the root and every expanded folder. loadFileTree() — Refresh,
    /// file operations, opening a folder — starts from a clean slate.
    @ObservationIgnored private var folderListings: [URL: [FileTreeItem]] = [:]

    func loadFileTree() {
        guard let folder = currentFolder else { return }
        folderListings.removeAll()
        fileTree = buildFileTree(at: folder)
    }

    private func buildFileTree(at url: URL, depth: Int = 0) -> [FileTreeItem] {
        guard depth < 10 else { return [] }

        let listing: [FileTreeItem]
        if let cached = folderListings[url] {
            listing = cached
        } else {
            do {
                listing = try Self.listFolder(at: url)
            } catch {
                errorMessage = "Failed to load folder: \(error.localizedDescription)"
                return []
            }
            folderListings[url] = listing
        }

        return listing.map { item in
            guard item.isDirectory, expandedFolders.contains(item.url) else { return item }
            return FileTreeItem(
                url: item.url,
                isDirectory: true,
                isExpanded: true,
                children: buildFileTree(at: item.url, depth: depth + 1)
            )
        }
    }

    /// One folder's visible entries: subfolders first, then Markdown/text
    /// files, each group in case-insensitive name order (sorted once).
    static func listFolder(at url: URL) throws -> [FileTreeItem] {
        // contentsOfDirectory(at:) won't open a symlink as a folder (ENOTDIR),
        // so a linked folder is listed at its target.
        let folder = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            ? url.resolvingSymlinksInPath() : url
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var items: [FileTreeItem] = []

        for itemURL in contents {
            let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var isDirectory = resourceValues.isDirectory ?? false
            if resourceValues.isSymbolicLink == true {
                // isDirectoryKey describes the link, not its target, so linked
                // folders fell through to the file filter and went missing.
                isDirectory = isLinkedFolder(itemURL, listedIn: folder)
            }

            if isDirectory {
                // A linked folder gets the trailing slash real folders carry.
                let folderURL = resourceValues.isSymbolicLink == true
                    ? URL(fileURLWithPath: itemURL.path, isDirectory: true) : itemURL
                items.append(FileTreeItem(url: folderURL, isDirectory: true))
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
    }

    /// Whether the symlink `link`, an entry of `folder`, leads to a folder the
    /// tree can show: not a dangling link, and not `folder` itself or one of
    /// its ancestors, which would nest the tree inside itself.
    private static func isLinkedFolder(_ link: URL, listedIn folder: URL) -> Bool {
        let target = link.resolvingSymlinksInPath()
        guard (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        return !folder.resolvingSymlinksInPath().pathComponents.starts(with: target.pathComponents)
    }

    func toggleFolderExpansion(_ url: URL) {
        if expandedFolders.contains(url) {
            // Collapsing only hides rows: rebuilt from cached listings.
            expandedFolders.remove(url)
        } else {
            expandedFolders.insert(url)
            // Expanding re-reads just this folder, so it opens current.
            folderListings[url] = nil
        }
        guard let folder = currentFolder else { return }
        fileTree = buildFileTree(at: folder)
    }

    /// True when `url` is an existing folder (symlinks followed). Folder rows
    /// are selectable in the file tree, but only files open as documents.
    static func isFolder(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Creates a new, uniquely-named Markdown file in `folder` and opens it.
    /// (The old implementation blindly wrote an empty "Untitled.md", silently
    /// truncating an existing file of that name.)
    func createNewFile(in folder: URL) {
        let target = folder.appendingPathComponent("Untitled.md").uniquified()
        do {
            try "".write(to: target, atomically: true, encoding: .utf8)
            loadFileTree()
            rebuildNoteIndex()
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

    // MARK: - Sidebar file operations

    /// Renames a file or folder via a standard prompt, keeping any open tab,
    /// its file watcher, and the session in sync with the new URL.
    func renameItem(at url: URL) {
        // Follows a symlink, so a linked folder is renamed like a folder.
        let isDirectory = url.hasDirectoryPath
            || (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let (baseName, ext) = Self.renameParts(for: url, isDirectory: isDirectory)

        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}\(url.lastPathComponent)\u{201D}"
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = baseName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }

        let destination = url.deletingLastPathComponent()
            .appendingPathComponent(Self.renamedFileName(newName, keeping: ext))
        guard destination.path != url.path else { return }
        // moveItem never overwrites, so only the case-only check is skipped.
        guard Self.isCaseOnlyRename(from: url, to: destination)
                || !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "A file named \u{201C}\(destination.lastPathComponent)\u{201D} already exists."
            return
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
            retargetOpenItems(from: url, to: destination)
            loadFileTree()
            rebuildNoteIndex()
            saveSession()
            Log.info("renamed", .file, detail: "\(url.lastPathComponent) → \(destination.lastPathComponent)")
        } catch {
            errorMessage = "Failed to rename: \(error.localizedDescription)"
        }
    }

    /// The part of `url`'s name the Rename prompt edits, and the extension it
    /// keeps. Folders and names without an extension are edited whole:
    /// deletingPathExtension() cuts the folder "74. Projects" to "74" and
    /// "Release.v2" to "Release", and the cut-off part was lost on rename.
    static func renameParts(for url: URL, isDirectory: Bool) -> (base: String, ext: String) {
        let ext = url.pathExtension
        guard !isDirectory, !ext.isEmpty else { return (url.lastPathComponent, "") }
        return (url.deletingPathExtension().lastPathComponent, ext)
    }

    /// The name a Rename to `newName` produces: `ext` is kept, and not doubled
    /// when it was typed too ("Plan.md" stays "Plan.md", not "Plan.md.md").
    static func renamedFileName(_ newName: String, keeping ext: String) -> String {
        guard !ext.isEmpty, !newName.lowercased().hasSuffix(".\(ext.lowercased())") else { return newName }
        return "\(newName).\(ext)"
    }

    /// True when `destination` differs from `url` only in case (or Unicode
    /// normalization) and names the same file: on a case-insensitive volume
    /// "Note.md" then "exists" because it is "note.md" itself, which made
    /// fixing a name's capitalization fail with "already exists".
    static func isCaseOnlyRename(from url: URL, to destination: URL) -> Bool {
        destination.path.caseInsensitiveCompare(url.path) == .orderedSame && isSameFile(url, destination)
    }

    /// Points everything that referenced `old` — or anything inside it, when
    /// it is a folder — at `new` after a rename or move: open tabs (with their
    /// documents and file watchers, whose handlers captured the old path),
    /// favorites, recents and expanded folders. Matching only the exact URL
    /// left tabs inside a renamed folder on a path that no longer exists, so
    /// every save of them failed.
    private func retargetOpenItems(from old: URL, to new: URL) {
        for index in tabs.indices {
            guard let oldURL = tabs[index].fileURL,
                  let newURL = Self.remappedURL(oldURL, from: old, to: new) else { continue }
            let oldName = oldURL.deletingPathExtension().lastPathComponent
            let newName = newURL.deletingPathExtension().lastPathComponent
            tabs[index].fileURL = newURL
            if newName != oldName { tabs[index].title = newName }
            if var doc = documents[tabs[index].documentId] {
                doc.fileURL = newURL
                // A note without a frontmatter title is titled by its file name.
                if doc.frontmatter?.title == nil, doc.title == oldName { doc.title = newName }
                documents[tabs[index].documentId] = doc
            }
            startWatchingFile(at: newURL, for: tabs[index].id)
        }

        let favoritesBefore = favorites, recentsBefore = recentFiles
        for index in favorites.indices {
            if let newURL = Self.remappedURL(favorites[index].url, from: old, to: new) {
                favorites[index].url = newURL
            }
        }
        recentFiles = recentFiles.map { Self.remappedURL($0, from: old, to: new) ?? $0 }
        expandedFolders = Set(expandedFolders.map { Self.remappedURL($0, from: old, to: new) ?? $0 })
        if favorites != favoritesBefore || recentFiles != recentsBefore {
            saveUserData()
        }
    }

    /// Where `url` ends up when `old` (a file or folder) becomes `new`: `new`
    /// for an exact match, the same relative path under `new` for anything
    /// inside `old`, nil otherwise — including siblings such as "2024-old"
    /// next to "2024". Keeps `url`'s directory flag, since sidebar folder URLs
    /// carry a trailing slash and `expandedFolders` membership is exact.
    static func remappedURL(_ url: URL, from old: URL, to new: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let oldPath = old.standardizedFileURL.path
        let newPath = new.standardizedFileURL.path
        if path == oldPath {
            return URL(fileURLWithPath: newPath, isDirectory: url.hasDirectoryPath)
        }
        guard path.hasPrefix(oldPath + "/") else { return nil }
        return URL(fileURLWithPath: newPath + path.dropFirst(oldPath.count), isDirectory: url.hasDirectoryPath)
    }

    func duplicateFile(at url: URL) {
        let destination = url.uniquified()
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            loadFileTree()
            rebuildNoteIndex()
            showToast("Duplicated as \(destination.lastPathComponent)")
        } catch {
            errorMessage = "Failed to duplicate: \(error.localizedDescription)"
        }
    }

    /// Trashes a file or folder with feedback, closing any tabs that were
    /// showing content under the trashed path.
    func moveItemToTrash(at url: URL) {
        // Those tabs close below, and the Trash only holds the last saved
        // version — so unsaved edits in any of them need a yes first.
        let dirtyTabs = tabs.filter {
            isTabDirty($0) && ($0.fileURL == url || $0.fileURL?.path.hasPrefix(url.path + "/") == true)
        }
        if !dirtyTabs.isEmpty {
            let alert = NSAlert()
            alert.messageText = dirtyTabs.count == 1
                ? "\u{201C}\(dirtyTabs[0].displayTitle)\u{201D} has unsaved changes."
                : "\(dirtyTabs.count) documents in \u{201C}\(url.lastPathComponent)\u{201D} have unsaved changes."
            alert.informativeText = "Moving \u{201C}\(url.lastPathComponent)\u{201D} to the Trash discards these changes."
            alert.alertStyle = .warning
            let trash = alert.addButton(withTitle: "Move to Trash")
            trash.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            for tab in tabs where tab.fileURL == url || tab.fileURL?.path.hasPrefix(url.path + "/") == true {
                closeTab(tab)
            }
            forgetTrashedItem(at: url)
            loadFileTree()
            rebuildNoteIndex()
            showToast("Moved to Trash")
            Log.info("trashed", .file, detail: url.lastPathComponent)
        } catch {
            errorMessage = "Failed to move to Trash: \(error.localizedDescription)"
        }
    }

    /// Drops the favorites, recents and expanded-folder state for a trashed
    /// `url` and everything inside it. Left behind, a favorite lingered as a
    /// row that ignored clicks and a recent failed to open.
    func forgetTrashedItem(at url: URL) {
        // remappedURL matches exactly what a rename of `url` would carry along.
        let isTrashed = { (candidate: URL) in Self.remappedURL(candidate, from: url, to: url) != nil }
        let favoritesBefore = favorites, recentsBefore = recentFiles
        favorites.removeAll { isTrashed($0.url) }
        recentFiles.removeAll(where: isTrashed)
        expandedFolders = expandedFolders.filter { !isTrashed($0) }
        if favorites != favoritesBefore || recentFiles != recentsBefore {
            saveUserData()
        }
    }

    // MARK: - Saving

    /// Has the editor commit an in-progress IME composition into the current
    /// document, synchronously. Marked text never reaches the model on its
    /// own, and menu shortcuts (⌘S, ⌘W, ⌘Q) fire without the input method
    /// committing, so whatever is about to save, close or swap the document
    /// asks first. Never on a timer such as autosave: committing mid-syllable
    /// would break the word being typed.
    func commitPendingComposition() {
        NotificationCenter.default.post(name: .commitPendingComposition, object: nil)
    }

    /// `interactive: false` never prompts: when another app changed the file it
    /// skips the write with a toast instead (the rule `performAutosave` follows).
    @MainActor
    func saveCurrentDocument(interactive: Bool = true) async {
        // Save what's on screen, including a syllable still being composed.
        commitPendingComposition()
        guard let tab = activeTab else { return }
        await save(tab: tab, interactive: interactive)
    }

    /// Saves one specific tab, which need not be the active one (the tab bar's
    /// ✕ and context menu close background tabs). Returns false when the write
    /// fails or the Save panel is cancelled, so a close or quit that follows can
    /// keep the document instead of discarding its edits. A file another app
    /// changed is confirmed first (`interactive: false` skips it with a toast):
    /// Cancel returns false, Revert true, since the tab is then clean.
    @MainActor
    @discardableResult
    func save(tab: EditorTab, interactive: Bool = true) async -> Bool {
        guard let document = documents[tab.documentId] else { return true }

        if let url = document.fileURL {
            guard await confirmSaveOverDiskChanges(tabId: tab.id, url: url, pending: document.fullText, interactive: interactive) else {
                // Revert left the tab clean; Cancel left it dirty.
                return !isTabDirty(tab)
            }
            // The check may have adopted a format change made on disk.
            var document = document
            if let format = documents[tab.documentId]?.fileFormat { document.fileFormat = format }
            do {
                try await fileService.saveDocument(document, to: url)
                // Update the dirty baseline to exactly what we wrote. We do NOT
                // reassign the whole captured snapshot back into the document:
                // doing so would clobber any keystrokes the user made while the
                // async write was in flight. We only stamp modifiedAt on the
                // live document. Both are keyed to `tab`, never "the active
                // tab", which can change while the write is in flight.
                if var current = documents[tab.documentId] {
                    current.modifiedAt = Date()
                    documents[tab.documentId] = current
                    originalContents[tab.documentId] = document.fullText
                    refreshStoredDirty(forTabId: tab.id)
                }
                // A file deleted on disk while open was just written back; watch it again.
                if fileWatchers[tab.id] == nil, tabs.first(where: { $0.id == tab.id })?.fileURL == url {
                    startWatchingFile(at: url, for: tab.id)
                }
                Log.info("saved", .file, detail: url.lastPathComponent)
                showToast("Saved")
                return true
            } catch {
                errorMessage = "Failed to save \(tab.displayTitle): \(error.localizedDescription)"
                return false
            }
        } else {
            // Untitled or draft: Save As works on the active tab, so bring this
            // one forward first; the panel has to be for the document being saved.
            activeTabId = tab.id
            return await saveDocumentAs()
        }
    }

    /// Guards a save against another app's edit. When the file no longer holds
    /// what CmdMD last loaded or wrote (Obsidian Sync, iCloud, git, another
    /// editor changed it), asks before overwriting — saves used to replace it
    /// silently, with the watcher's 2-second toast as the only trace. Returns
    /// whether to write; Revert reloads the disk version into the tab (now
    /// clean) and returns false, as do Cancel and a non-interactive conflict.
    @MainActor
    private func confirmSaveOverDiskChanges(tabId: UUID, url: URL, pending: String, interactive: Bool) async -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return true }
        let disk: (document: MarkdownDocument, text: String)
        do {
            disk = try await fileService.loadDocumentWithText(from: url)
        } catch {
            // Gone: nothing to protect, the write recreates it. Still there but
            // unreadable (another app re-encoded or replaced it) is a conflict:
            // writing over it destroyed that version unseen.
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            guard interactive else {
                showToast("Not saved — \(tab.displayTitle) was changed by another app", style: .warning)
                return false
            }
            let alert = NSAlert()
            alert.messageText = "\u{201C}\(tab.displayTitle)\u{201D} was replaced by a version CmdMD can\u{2019}t read."
            alert.informativeText = "Save Anyway replaces that version with yours."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard Self.isSaveConflict(diskText: disk.text, diskFullText: disk.document.fullText,
                                  baseline: originalContents[tab.documentId] ?? "", pending: pending) else {
            // Same text: an encoding, line-ending or BOM change made elsewhere
            // is adopted instead of being reverted by this write.
            if let format = disk.document.fileFormat, documents[tab.documentId]?.fileFormat != format {
                documents[tab.documentId]?.fileFormat = format
            }
            return true
        }

        guard interactive else {
            showToast("Not saved — \(tab.displayTitle) was changed by another app", style: .warning)
            return false
        }
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(tab.displayTitle)\u{201D} was changed by another application."
        alert.informativeText = "Save Anyway replaces that version with yours. Revert discards your unsaved changes and loads the version on disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            applyDiskVersion(disk.document, toTabId: tabId, from: url)
            return false
        default:
            return false
        }
    }

    @MainActor
    @discardableResult
    func saveDocumentAs() async -> Bool {
        commitPendingComposition()
        // The tab is taken before the panel: it runs a modal session, and an
        // open finishing meanwhile (a slow [[link]], session restore) can bring
        // another tab forward — the result must still land in this one.
        guard let tab = activeTab, let document = documents[tab.documentId] else { return false }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
        panel.nameFieldStringValue = document.displayTitle + ".md"

        // Panel cancelled: the edits are still unsaved.
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return await saveAs(tab: tab, to: url)
    }

    /// Save As for one specific tab once its destination is chosen: writes the
    /// document there and points that tab — never "the active tab", which can
    /// change while the write is in flight — at the new file. Returns false
    /// when the write fails or another tab already has that file open.
    @MainActor
    @discardableResult
    func saveAs(tab: EditorTab, to url: URL) async -> Bool {
        guard let document = documents[tab.documentId] else { return false }
        // Two tabs on one file drift apart, and the stale one's next save
        // overwrites whatever the other wrote.
        if tabs.contains(where: { $0.id != tab.id && $0.fileURL.map { Self.isSameFile($0, url) } == true }) {
            errorMessage = "\u{201C}\(url.lastPathComponent)\u{201D} is open in another tab. Close that tab first, or save under a different name."
            return false
        }
        do {
            var doc = document
            doc.fileURL = url
            doc.modifiedAt = Date()
            // A new file is UTF-8, which also saves a legacy-encoded note
            // whose edits that encoding can't hold.
            doc.fileFormat = doc.fileFormat?.inUTF8
            let wasDraft = doc.isDraft
            doc.isDraft = false
            try await fileService.saveDocument(doc, to: url)
            // The live document gets the new file and the baseline becomes
            // exactly what was written; the snapshot isn't put back, so
            // keystrokes typed during the write stay unsaved changes.
            if let index = tabs.firstIndex(where: { $0.id == tab.id }),
               var current = documents[tab.documentId] {
                current.fileURL = url
                current.isDraft = false
                current.modifiedAt = doc.modifiedAt
                current.fileFormat = doc.fileFormat
                documents[tab.documentId] = current
                originalContents[tab.documentId] = doc.fullText
                // Persist the new URL on the tab too, otherwise dedup/watching/
                // breadcrumb logic that keys off tab.fileURL stays out of sync.
                tabs[index].fileURL = url
                tabs[index].title = doc.displayTitle
                refreshStoredDirty(forTabId: tab.id)
                startWatchingFile(at: url, for: tab.id)
            }
            // A draft that became a real file graduates out of the drafts list.
            if wasDraft {
                drafts.removeAll { $0.id == doc.id }
                saveUserData()
            }
            addToRecentFiles(url)
            rebuildNoteIndex()
            saveSession()
            showToast("Saved")
            return true
        } catch {
            // The write failed: the edits are still unsaved.
            errorMessage = "Failed to save: \(error.localizedDescription)"
            return false
        }
    }

    /// Saves every dirty tab for the save-on-quit guard. Untitled tabs get a
    /// Save panel, since nothing else would keep them; only drafts persist on
    /// their own (drafts.json, flushed by saveUserData before the quit prompt).
    /// A file another app changed is confirmed first (`save(tab:)`): Revert
    /// leaves that tab clean and moves on. Stops at the first failed write,
    /// cancelled panel or Cancel at the changed-on-disk prompt and returns
    /// false with that tab in front, so the caller cancels the quit instead of
    /// losing edits.
    @MainActor
    @discardableResult
    func saveAllDirtyTabs() async -> Bool {
        for tab in tabs where isTabDirty(tab) {
            if documents[tab.documentId]?.isDraft == true { continue }
            guard await save(tab: tab) else {
                if tabs.contains(where: { $0.id == tab.id }) { activeTabId = tab.id }
                return false
            }
        }
        return true
    }

    func updateContent(_ newContent: String) {
        guard var document = currentDocument, document.content.differs(from: newContent) else { return }
        let now = Date()
        document.content = newContent
        document.modifiedAt = now
        // A draft's text persists on its own (the drafts sync below, then
        // drafts.json), so isTabDirty never counts it as an unsaved change: the
        // tab dot and close/quit prompts don't offer to discard kept edits.
        // Commit the document once. Optional-chaining the two fields separately
        // invoked the computed-property setter twice per keystroke, which also
        // performed dirty-state work and notified the SwiftUI observation graph
        // twice for one edit.
        currentDocument = document
        // The currentDocument setter refreshes the stored dirty flag.
        // Keep the backing draft in sync while a draft is being edited so its
        // content survives restarts even without an explicit save.
        if document.isDraft,
           let draftIndex = drafts.firstIndex(where: { $0.id == document.id }) {
            drafts[draftIndex].body = newContent
            drafts[draftIndex].updatedAt = now
            scheduleDraftPersist()
        }
        refreshFilelessTabTitle(for: document)
        scheduleAutosaveIfNeeded()
    }

    /// Properties edited in the Inspector. They take the path typing does: a
    /// draft keeps them (drafts.json) and autosave picks them up. Assigning
    /// `currentDocument` directly did neither, so a tag added to a file waited
    /// for the next keystroke and a draft's properties were lost on reopen.
    func updateFrontmatter(_ frontmatter: Frontmatter?) {
        guard var document = currentDocument, document.frontmatter != frontmatter else { return }
        let now = Date()
        document.frontmatter = frontmatter
        document.modifiedAt = now
        let draftIndex = document.isDraft ? drafts.firstIndex(where: { $0.id == document.id }) : nil
        // As in updateContent: what a draft keeps is its baseline.
        if draftIndex != nil {
            originalContents[document.id] = document.fullText
        }
        currentDocument = document
        if let draftIndex {
            drafts[draftIndex].frontmatter = frontmatter
            drafts[draftIndex].updatedAt = now
            scheduleDraftPersist()
        }
        refreshFilelessTabTitle(for: document)
        scheduleAutosaveIfNeeded()
    }

    /// A draft or untitled tab is named after its text (or its properties'
    /// title), so its tab follows edits as the window title does; the title
    /// set when the tab opened stayed "Untitled Draft". Written only when it
    /// changes, so typing doesn't redraw the tab bar.
    private func refreshFilelessTabTitle(for document: MarkdownDocument) {
        guard document.fileURL == nil,
              let index = tabs.firstIndex(where: { $0.documentId == document.id }) else { return }
        let title = document.displayTitle
        if tabs[index].title != title {
            tabs[index].title = title
        }
    }

    func updateCursorPosition(line: Int, column: Int) {
        if cursorLine != line { cursorLine = line }
        if cursorColumn != column { cursorColumn = column }
    }

    /// Flips a `- [ ]`/`- [x]` marker on the given 1-based source line. Invoked
    /// by checkbox clicks in the preview. The line is re-validated against the
    /// task pattern before mutating so a stale line number can never corrupt
    /// unrelated text.
    func toggleTask(atLine line: Int, checked: Bool, expectedLine: String? = nil) {
        guard let doc = currentDocument else { return }
        var lines = doc.content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }

        let target = lines[line - 1]
        // The line as the clicked page rendered it: an edit that shifted lines
        // since (split view re-renders on a debounce) points the number at a
        // different task, which must not be the one flipped.
        if let expectedLine, target != expectedLine {
            showToast("Couldn't toggle that task", style: .error)
            return
        }
        let ns = target as NSString
        guard let match = TaskLineQueue.taskLinePattern.firstMatch(
            in: target,
            range: NSRange(location: 0, length: ns.length)
        ) else {
            showToast("Couldn't toggle that task", style: .error)
            return
        }

        let markerRange = match.range(at: 2)
        lines[line - 1] = ns.replacingCharacters(in: markerRange, with: checked ? "x" : " ")
        updateContent(lines.joined(separator: "\n"))
    }

    // MARK: - Autosave

    private var autosaveWorkItem: DispatchWorkItem?
    /// The autosave failure last shown per tab. A file that can't take the
    /// write (read-only, or an encoding that can't hold the new text) fails
    /// the same way every round; its alert is shown once, not every interval.
    @ObservationIgnored private var shownAutosaveFailures: [UUID: String] = [:]

    /// Throttled autosave: the first unsaved edit arms one timer and later edits
    /// leave it alone, so a save lands at most `autosaveInterval` seconds after
    /// the first change even while the user keeps typing. (Rescheduling on
    /// every keystroke made continuous typing never autosave.)
    private func scheduleAutosaveIfNeeded() {
        guard settings.autosaveEnabled, autosaveWorkItem == nil,
              currentDocument?.fileURL != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            // Cleared before saving so edits made during the write arm the
            // next round instead of being dropped.
            self?.autosaveWorkItem = nil
            Task { @MainActor in await self?.performAutosave() }
        }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(2, settings.autosaveInterval), execute: work)
    }

    /// Saves every dirty file-backed tab — not just whichever tab happens to be
    /// active when the timer fires, which dropped edits made in a tab the user
    /// had since switched away from. Drafts and untitled tabs are skipped so
    /// autosave never pops a Save panel. Silent: the tab's dirty dot clearing
    /// is the feedback. Never prompts either: a file another app changed is
    /// skipped with a toast (⌘S asks), and a file deleted on disk is left for
    /// an explicit Save to write back.
    @MainActor
    func performAutosave() async {
        guard settings.autosaveEnabled else { return }
        for tab in tabs {
            guard let candidate = documents[tab.documentId],
                  let url = candidate.fileURL,
                  isTabDirty(tab),
                  // A file removed on disk keeps its text as unsaved changes
                  // until the user saves it; autosaving every dirty tab would
                  // otherwise bring back a note deleted in another app.
                  FileManager.default.fileExists(atPath: url.path),
                  // Never overwrite a version another app saved meanwhile.
                  await confirmSaveOverDiskChanges(tabId: tab.id, url: url, pending: candidate.fullText, interactive: false),
                  // Looked up again after that read: the tab may have been
                  // closed or re-pointed at another file during the await.
                  tabs.contains(where: { $0.id == tab.id }),
                  let doc = documents[tab.documentId], doc.fileURL == url,
                  isTabDirty(tab) else { continue }
            // Our atomic write replaces the file's inode, which the watcher
            // would report as an external change mid-typing. Pause it for the
            // write and re-arm on the new file afterwards.
            stopWatchingFile(for: tab.id)
            var saved = false
            do {
                try await fileService.saveDocument(doc, to: url)
                saved = true
                shownAutosaveFailures[tab.id] = nil
            } catch {
                let message = "Failed to autosave \(tab.displayTitle): \(error.localizedDescription)"
                if shownAutosaveFailures[tab.id] != message {
                    shownAutosaveFailures[tab.id] = message
                    errorMessage = message
                }
            }
            // The tab may have been closed, replaced or re-pointed at another
            // file during the await — then there is nothing left to update.
            guard tabs.contains(where: { $0.id == tab.id }),
                  documents[tab.documentId]?.fileURL == url else { continue }
            startWatchingFile(at: url, for: tab.id)
            guard saved else { continue }
            // Baseline = exactly what was written. The live document is never
            // reassigned, so keystrokes typed during the write simply stay dirty.
            originalContents[tab.documentId] = doc.fullText
            refreshStoredDirty(forTabId: tab.id)
            Log.info("autosaved", .file, detail: url.lastPathComponent)
        }
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
                // Save THIS tab (not whichever one is active) and close it only
                // once that worked: a failed write, a cancelled Save panel or a
                // save cancelled at the changed-on-disk prompt keeps the tab
                // and its edits.
                if await save(tab: tab), !isTabDirty(tab) {
                    closeTab(tab)
                }
            }
        case .alertSecondButtonReturn:
            closeTab(tab)
        default:
            break
        }
    }

    /// Closes a group of tabs (the tab context menu's Close Tab / Close Other
    /// Tabs / Close Tabs to the Right) behind the same unsaved-changes guard as
    /// ⌘W; those items used to drop dirty tabs silently. A lone tab gets the
    /// usual per-document prompt, a larger group one prompt covering all of its
    /// dirty tabs. Cancel leaves every tab open.
    func closeTabsWithConfirmation(_ group: [EditorTab]) {
        commitPendingComposition()
        let dirtyTabs = group.filter { isTabDirty($0) }
        guard settings.confirmBeforeClosingDirtyTabs, !dirtyTabs.isEmpty else {
            group.forEach { closeTab($0) }
            return
        }
        if group.count == 1 {
            closeTabWithConfirmation(group[0])
            return
        }

        // Same layout as the quit prompt: default action rightmost, Cancel
        // beside it, and the destructive choice farthest from the default.
        let alert = NSAlert()
        alert.messageText = dirtyTabs.count == 1
            ? "You have 1 document with unsaved changes"
            : "You have \(dirtyTabs.count) documents with unsaved changes"
        alert.informativeText = "Do you want to save your changes before closing these tabs?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save All")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle: "Discard Changes")
        discard.hasDestructiveAction = true

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                // One at a time: a failed write, a cancelled Save panel or
                // Cancel at the changed-on-disk prompt stops here, leaving that
                // tab and the ones after it open.
                for tab in group {
                    if isTabDirty(tab) {
                        // Still dirty after the write: keys typed while it (or
                        // an untitled tab's Save panel) ran. Keep that tab open
                        // like the single-tab path does.
                        guard await save(tab: tab), !isTabDirty(tab) else { return }
                    }
                    closeTab(tab)
                }
            }
        case .alertThirdButtonReturn:
            group.forEach { closeTab($0) }
        default:
            break
        }
    }

    func closeOtherTabs(except tab: EditorTab) {
        let otherTabs = tabs.filter { $0.id != tab.id && !$0.isPinned }
        closeTabsWithConfirmation(otherTabs)
    }

    func closeTabsToRight(of tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let tabsToRight = tabs.suffix(from: index + 1).filter { !$0.isPinned }
        closeTabsWithConfirmation(tabsToRight)
    }

    /// Pinning moves the tab to the end of the pinned run, unpinning to just
    /// after it (as browsers do), so pinned tabs stay a prefix. Unpinning in
    /// place left an unpinned tab inside the run, and dragging and pinning
    /// then scattered pinned tabs through the bar.
    func toggleTabPin(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        var movedTab = tabs.remove(at: index)
        movedTab.isPinned.toggle()
        tabs.insert(movedTab, at: tabs.filter(\.isPinned).count)
    }

    func moveTab(id: UUID, before targetId: UUID) {
        guard id != targetId,
              let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetId }) else { return }
        let tab = tabs.remove(at: sourceIndex)
        let insertIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        tabs.insert(tab, at: clampedTabInsertIndex(insertIndex, isPinned: tab.isPinned))
    }

    /// Drop target for the empty trailing area of the tab bar — without it a
    /// tab could never be dragged to the last position.
    func moveTabToEnd(id: UUID) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: clampedTabInsertIndex(tabs.count, isPinned: tab.isPinned))
    }

    /// Pinned tabs form a fixed prefix: unpinned tabs can't land inside it, and
    /// pinned tabs can't drift past it.
    private func clampedTabInsertIndex(_ index: Int, isPinned: Bool) -> Int {
        let pinnedCount = tabs.filter(\.isPinned).count
        let clamped = isPinned ? min(index, pinnedCount) : max(index, pinnedCount)
        return min(max(0, clamped), tabs.count)
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
        Log.info("export HTML:", .file, detail: document.displayTitle)
        exportService.saveHTML(document: document, options: renderOptions())
    }

    func exportAsPDF() {
        guard let document = currentDocument else { return }
        Log.info("export PDF:", .file, detail: document.displayTitle)
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
            enableCodeHighlight: settings.enablePreviewCodeHighlight,
            // Images may come from the open folder and vaults as well as the
            // note's own folder (e.g. a vault-level attachments folder).
            localAssetRoots: contentSearchRoots
        )
    }

    // MARK: - Recents & Favorites

    /// Persisted recents that aren't reachable this launch because their volume
    /// or share isn't mounted. Hidden from the menus but written back on every
    /// save, so plugging the drive back in restores them.
    @ObservationIgnored private var parkedRecents: [URL] = []

    /// True only when `url` is gone for real: the item is absent but its parent
    /// folder is reachable. A missing parent usually means an unmounted volume
    /// or share (external SSD, SMB, a cloud folder not yet available), and such
    /// entries must survive until it is back.
    static func isDefinitelyMissing(_ url: URL) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: url.path)
            && fm.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    private func addToRecentFiles(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 {
            recentFiles = Array(recentFiles.prefix(20))
        }
        // Feeds the system-managed recents: Dock icon right-click menu and the
        // Apple menu's Recent Items — the in-app Open Recent stays app-managed.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        // Debounced: this runs on every open (arrow-keying through the sidebar
        // opens each file), and a full save rewrites all the data JSONs.
        saveUserDataDebounced()
    }

    func clearRecentFiles() {
        recentFiles.removeAll()
        parkedRecents.removeAll()
        // The system list (Dock menu, Apple menu › Recent Items) is fed in
        // addToRecentFiles, so Clear Menu clears it too.
        NSDocumentController.shared.clearRecentDocuments(nil)
        saveUserData()
    }

    /// Open Recent item titles: the file name, plus " — parent folder" when
    /// another listed file has the same name (README.md, index.md…), the way
    /// the system's Open Recent tells them apart. Pure — the menu is rebuilt
    /// while typing, so no file system access here.
    static func recentMenuTitles(_ urls: [URL]) -> [String] {
        var nameCounts: [String: Int] = [:]
        for url in urls { nameCounts[url.lastPathComponent, default: 0] += 1 }
        return urls.map { url in
            let name = url.lastPathComponent
            guard nameCounts[name, default: 0] > 1 else { return name }
            return "\(name) \u{2014} \(url.deletingLastPathComponent().lastPathComponent)"
        }
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

    /// Opens a favorite: a folder becomes the Files tree's root (as a Finder
    /// sidebar favorite does), a file opens in a new tab. One that can't be
    /// reached says so instead of ignoring the click.
    func openFavorite(_ favorite: FavoriteItem) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: favorite.url.path, isDirectory: &isDirectory) else {
            showToast("Can\u{2019}t find \u{201C}\(favorite.displayName)\u{201D} — it was moved or deleted, or its drive isn\u{2019}t connected", style: .warning)
            return
        }
        if isDirectory.boolValue {
            openFolder(at: favorite.url)
        } else {
            openDocument(at: favorite.url, inNewTab: true)
        }
    }

    // MARK: - Folder Search

    /// Find in Folder… (⇧⌘F): reveals the sidebar's folder search and focuses
    /// its field. With no folder open, the Files tab's Open Folder prompt shows.
    func beginFolderSearch() {
        selectedSidebarTab = .files
        sidebarVisible = true
        guard currentFolder != nil else { return }
        showFolderSearch = true
        folderSearchFocusRequest += 1
    }

    /// The folder search replaces only the Files section, so the ribbon's
    /// other sections still switch while a search is open.
    var isFolderSearchVisible: Bool {
        showFolderSearch && selectedSidebarTab == .files
    }

    /// The running folder search. A newer search or Clear cancels it, so a
    /// slow earlier scan can't overwrite newer results or refill cleared ones.
    @ObservationIgnored private var folderSearchTask: Task<Void, Never>?

    func searchInFolder(query: String) {
        folderSearchTask?.cancel()
        guard let folder = currentFolder, !query.isEmpty else {
            searchResults = []
            isSearching = false
            searchedQuery = nil
            return
        }

        isSearching = true
        searchResults = []
        searchedQuery = query

        folderSearchTask = Task {
            let results = await Self.performSearch(query: query, in: [folder])
            await MainActor.run {
                // Superseded searches are cancelled on the main thread as
                // well, so none can slip past this check.
                guard !Task.isCancelled else { return }
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    /// Case-insensitive line search over the Markdown files under `folders`,
    /// stopping at `limit` hits. A file under more than one root (a vault
    /// inside the open folder) is read once.
    static func performSearch(query: String, in folders: [URL], limit: Int = 500) async -> [SearchResult] {
        var results: [SearchResult] = []
        var scanned: Set<String> = []

        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            // Stream the enumerator instead of first materializing the entire file
            // tree. Omnisearch cancels its previous Task as the query changes; the
            // checks below let that cancellation stop disk reads instead of leaving
            // several stale multi-second vault searches running concurrently.
            while let object = enumerator.nextObject() {
                guard !Task.isCancelled else { return [] }
                guard let fileURL = object as? URL else { continue }
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "md" || ext == "markdown" else { continue }
                guard scanned.insert(fileURL.standardizedFileURL.path).inserted else { continue }

                // One pass over the whole file rejects non-matching files
                // without splitting or lowercasing a single line.
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                      content.range(of: query, options: .caseInsensitive) != nil else { continue }

                // Lines are numbered as the editor shows the note: LF line
                // breaks (a CRLF file's lines aren't doubled), and the body
                // below the frontmatter block, which the editor leaves out.
                // Raw file numbers put the caret as many lines too low as
                // the block is tall. A match in the block is a property.
                let text = FileService.normalizingLineEndings(content).text
                let block = FileService.frontmatterBlock(in: text)
                let propertyLines = block.map { text[$0.yaml].split(separator: "\n") } ?? []
                let bodyLines = text[(block?.bodyStart ?? text.startIndex)...]
                    .split(separator: "\n", omittingEmptySubsequences: false)
                let lines = propertyLines.map { (number: Int?.none, text: $0) }
                    + bodyLines.enumerated().map { (number: Int?.some($0.offset + 1), text: $0.element) }
                for line in lines {
                    guard !Task.isCancelled else { return [] }
                    guard line.text.range(of: query, options: .caseInsensitive) != nil else { continue }
                    let lineContent = String(line.text)
                    // Ranged on the line itself (not a lowercased copy, whose
                    // indices can differ) so matchRange indexes lineContent.
                    guard let range = lineContent.range(of: query, options: .caseInsensitive) else { continue }
                    results.append(SearchResult(
                        fileURL: fileURL,
                        lineNumber: line.number,
                        lineContent: lineContent,
                        matchRange: range
                    ))
                    if results.count >= limit { return results }
                }
            }
        }

        return results
    }

    func clearSearch() {
        folderSearchTask?.cancel()
        folderSearchTask = nil
        folderSearchText = ""
        searchResults = []
        isSearching = false
        searchedQuery = nil
    }

    /// Content search for Omnisearch over the open folder plus every registered
    /// vault — the scope its file-name matches already cover. Roots are read on
    /// the main actor; the scan itself runs off it.
    @MainActor
    func searchContent(query: String, limit: Int = 500) async -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        return await Self.performSearch(query: query, in: contentSearchRoots, limit: limit)
    }

    /// Roots Omnisearch's content search covers; empty when there is nothing
    /// to search (no folder open, no vaults registered).
    var contentSearchRoots: [URL] {
        Self.contentSearchRoots(currentFolder: currentFolder, vaultRoots: vaults.map(\.rootPath))
    }

    /// The open folder first (its hits rank first), then the vaults, with
    /// duplicate roots removed.
    static func contentSearchRoots(currentFolder: URL?, vaultRoots: [URL]) -> [URL] {
        var seen: Set<String> = []
        return ([currentFolder].compactMap { $0 } + vaultRoots).compactMap { root in
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
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
        // A dangling id left the "Default vault" picker blank.
        if settings.defaultVaultId == vault.id { settings.defaultVaultId = nil }
        saveUserData()
        rebuildNoteIndex()
    }

    /// Points a vault at its folder's new location in place, so its routing
    /// rules, default status and template stay with it (Disconnect and
    /// Connect again dropped its rules). A name that was just the folder's
    /// name follows the new one.
    func relocateVault(id: UUID, to url: URL, bookmarkData: Data?) {
        guard let index = vaults.firstIndex(where: { $0.id == id }) else { return }
        var vault = vaults[index]
        if vault.name == vault.rootPath.lastPathComponent { vault.name = url.lastPathComponent }
        vault.rootPath = url
        if let bookmarkData { vault.bookmarkData = bookmarkData }
        vaults[index] = vault
        saveUserData()
        rebuildNoteIndex()
        Log.info("vault folder relocated", .send, detail: "\(vault.displayName) → \(url.path)")
    }

    /// Follows vaults whose folder was renamed or moved (Obsidian's Rename
    /// vault, Finder, iCloud Drive) to where their bookmark finds it now.
    /// rootPath never followed, so sends recreated the old folder and wrote
    /// notes Obsidian never saw. Only vaults whose folder is gone are
    /// resolved, on VaultService's actor.
    @MainActor
    func reconcileVaultLocations() async {
        let missing = vaults.filter { !$0.folderExists }
        guard !missing.isEmpty else { return }
        let vaultService = VaultService(dataDirectory: dataURL)
        for vault in missing {
            guard let location = await vaultService.resolveLocation(of: vault),
                  Self.isUsableVaultFolder(location.url) else { continue }
            relocateVault(id: vault.id, to: location.url, bookmarkData: location.refreshedBookmark)
        }
    }

    /// An existing folder outside the Trash: a bookmark also follows a vault
    /// that was thrown away.
    static func isUsableVaultFolder(_ url: URL) -> Bool {
        guard !url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The vault a send writes into: the live entry (options carry a copy
    /// that predates any relocation), its folder looked up again when gone.
    /// Throws rather than create a missing vault folder.
    @MainActor
    private func vaultForSend(_ requested: Vault) async throws -> Vault {
        var vault = vaults.first { $0.id == requested.id } ?? requested
        if !vault.folderExists {
            await reconcileVaultLocations()
            vault = vaults.first { $0.id == requested.id } ?? requested
        }
        guard vault.folderExists else { throw SendError.vaultFolderMissing(vault.displayName) }
        return vault
    }

    // MARK: - Send to Vault

    @MainActor
    @discardableResult
    func sendToVault(options: SendOptions) async throws -> SendOutcome {
        guard let document = currentDocument else {
            throw SendError.noDocumentOrVault
        }
        return try await sendToVault(document: document, options: options)
    }

    /// Sends an explicit document. Used directly by menu-bar Quick Capture, which
    /// has no active tab and therefore can't rely on `currentDocument`.
    /// Main-actor bound: a Move detaches tabs and file watchers, which SwiftUI
    /// and the watcher handlers use on the main thread.
    @MainActor
    @discardableResult
    func sendToVault(document: MarkdownDocument, options: SendOptions, quiet: Bool = false) async throws -> SendOutcome {
        guard let requested = options.targetVault else {
            throw SendError.noDocumentOrVault
        }
        // Only the target folder below an existing vault folder is created.
        let vault = try await vaultForSend(requested)

        // Contained here, not only in the Send sheet: routing rules, auto-route
        // and Quick Capture reach this with their own folder text, and a "../X"
        // there wrote outside the vault.
        guard let folder = Self.normalizedSendFolder(options.targetFolder) else {
            throw SendError.invalidFolder(options.targetFolder)
        }
        let targetDir = folder.isEmpty ? vault.rootPath : vault.rootPath.appendingPathComponent(folder)
        if !FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        let template: VaultTemplate? = options.applyTemplate
            ? templates.first(where: { $0.id == options.templateId })
            : nil

        let filename = Self.sendFilename(for: document, template: template)
        let candidateURL = targetDir.appendingPathComponent(filename)

        // A note sent to the folder it already lives in is already there.
        // Resolving that as a conflict overwrote it and then (Move) deleted the
        // only copy, or renamed it to "Note (1).md" and broke its [[links]].
        if let sourceURL = document.fileURL,
           FileManager.default.fileExists(atPath: sourceURL.path),
           Self.isSameFile(sourceURL, candidateURL) {
            let outcome = SendOutcome.alreadyInPlace(candidateURL)
            if !quiet, let message = outcome.unsentMessage { showToast(message, style: .warning) }
            return outcome
        }

        // A name this batch already wrote, or still has to send, is never
        // overwritten or skipped: it gets a new name instead.
        var resolution = !options.reservedPaths.isEmpty && options.reservedPaths.contains(Self.sendPathKey(candidateURL))
            ? options.conflictResolution.nonDestructive
            : options.conflictResolution
        // A draft's or untitled note's name comes from its text (first line or
        // title), so "Overwrite" would replace an unrelated vault note that
        // happens to share it — toolbar, Inspector, palette and auto-route all
        // reach here. Only a file-backed note's own name may overwrite.
        if document.fileURL == nil, resolution == .overwrite {
            resolution = .rename
        }
        guard let targetURL = resolveConflict(for: candidateURL, resolution: resolution) else {
            // .skip on an existing file must leave both target and source intact.
            let outcome = SendOutcome.skipped(candidateURL)
            if !quiet, let message = outcome.unsentMessage { showToast(message, style: .warning) }
            return outcome
        }

        let contentToWrite = Self.sendContent(
            for: document,
            template: template,
            injectFrontmatter: options.injectFrontmatter,
            sourceLink: options.addSourceLink ? document.fileURL : nil
        )

        // UTF-8 for Obsidian, the note's own line breaks, and an overwritten
        // vault note keeps its creation date and tags.
        try FileService.writeText(contentToWrite, to: targetURL,
                                  format: TextFileFormat(lineEnding: document.fileFormat?.lineEnding ?? .lf))

        if options.action == .move, let sourceURL = document.fileURL, !Self.isSameFile(sourceURL, targetURL) {
            // Trash rather than unlink, so a mistaken Move stays recoverable.
            // Where trashing fails (a volume without a Trash) the original is
            // kept and reported, not deleted for good behind the user's back.
            do {
                try FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
            } catch {
                throw SendError.sourceNotTrashed(copy: targetURL, error)
            }
            // Detach any tab still showing the moved file. Matched by URL, not
            // by the active document: batch sends load their own copies.
            if let index = tabs.firstIndex(where: { $0.fileURL == sourceURL }) {
                let tab = tabs[index]
                tabs[index].fileURL = nil
                stopWatchingFile(for: tab.id)
                if var detached = documents[tab.documentId] {
                    detached.fileURL = nil
                    documents[tab.documentId] = detached
                }
            }
        }

        // A draft or untitled note has no file to trash. Move takes the draft
        // out of Drafts and leaves its tab a clean untitled note, since the
        // vault now holds the text; before, Move acted as Copy and a re-send
        // duplicated the note.
        if options.action == .move, document.fileURL == nil {
            if document.isDraft, drafts.contains(where: { $0.id == document.id }) {
                drafts.removeAll { $0.id == document.id }
                persistDrafts()
            }
            if let tab = tabs.first(where: { $0.documentId == document.id }),
               var moved = documents[tab.documentId] {
                // No longer a draft: later edits are unsaved work again
                // instead of updating a draft that is gone.
                moved.isDraft = false
                documents[tab.documentId] = moved
                originalContents[tab.documentId] = document.fullText
                refreshStoredDirty(forTabId: tab.id)
            }
        }

        // The sent note (and a moved source) must show up in [[ / Omnisearch.
        // sendToVault is main-actor bound, so no hop is needed.
        rebuildNoteIndex()
        Log.info("sent (\(options.action == .move ? "move" : "copy"))", .send, detail: "\(targetURL.lastPathComponent) → \(vault.displayName)/\(options.targetFolder)")

        if !quiet { showToast("Sent to \(vault.displayName)") }

        if options.openAfterSend, let obsidianURL = vault.obsidianURL(forFile: targetURL) {
            NSWorkspace.shared.open(obsidianURL)
        }
        return .sent(targetURL)
    }

    /// What a send writes. With injection, the note's REAL frontmatter (tags,
    /// dates, custom keys) is kept and gains a title and optional source,
    /// instead of a minimal synthesized block that discards user metadata.
    static func sendContent(for document: MarkdownDocument, template: VaultTemplate?, injectFrontmatter: Bool, sourceLink: URL?) -> String {
        var shipped = document
        // Properties typed at the top of a draft, capture or new note are
        // its frontmatter, as they are once it's saved: injected keys join
        // them instead of stacking a second block above them.
        if document.frontmatterSource == nil, document.frontmatter == nil {
            let typed = FileService.parseFrontmatter(from: document.content)
            if let source = typed.source, source.parsed != nil {
                shipped.frontmatterSource = source
                shipped.frontmatter = source.parsed
                shipped.content = typed.body
            }
        }
        let hasOwnFrontmatter = shipped.frontmatterSource != nil || shipped.frontmatter != nil

        // The note's own frontmatter travels above the (optionally templated)
        // body. Writing the template output alone dropped tags and aliases,
        // and a Move then deleted the only copy. Injected keys are patched
        // into the block as the file has it, and a block that couldn't be
        // read as properties travels unchanged. A template's own block joins
        // the note's: left above the body, it was a second block.
        let rendered = template?.renderParts(for: shipped)
        shipped.content = rendered?.body ?? shipped.content
        if let templateBlock = rendered?.frontmatter {
            if !hasOwnFrontmatter {
                shipped.frontmatterSource = templateBlock
                shipped.frontmatter = templateBlock.parsed
            } else if let merged = mergingTemplateBlock(templateBlock, into: shipped) {
                shipped.frontmatterSource = merged.source
                shipped.frontmatter = merged.frontmatter
            } else {
                // One of the blocks can't be read as properties, so they
                // can't be merged exactly: the template's stays text.
                shipped.content = templateBlock.text + shipped.content
            }
        }
        if injectFrontmatter, shipped.frontmatter != nil || shipped.frontmatterSource == nil {
            var frontmatter = shipped.frontmatter ?? Frontmatter(title: document.displayTitle, date: Frontmatter.calendarDay())
            if frontmatter.title == nil { frontmatter.title = document.displayTitle }
            // A note without properties of its own is dated, template or not.
            if !hasOwnFrontmatter, frontmatter.date == nil { frontmatter.date = Frontmatter.calendarDay() }
            if let sourceLink {
                frontmatter.custom["source"] = .string(sourceLink.path)
            }
            shipped.frontmatter = frontmatter
        }
        return shipped.fullText
    }

    /// A note's frontmatter with a template's block merged in: keys the note
    /// doesn't set come from the template, as its lines write them, tags and
    /// aliases are joined, and the note's own values win. Nil when either
    /// block can't be read as properties.
    private static func mergingTemplateBlock(_ template: FrontmatterSource, into document: MarkdownDocument) -> (source: FrontmatterSource, frontmatter: Frontmatter)? {
        let templateLines = FrontmatterSource.lines(of: template.yaml)
        guard let templateProperties = template.parsed, let ownProperties = document.frontmatter,
              let templateSpans = FrontmatterSource.keySpans(in: templateLines) else { return nil }
        // Properties set only in the Inspector have no text yet, so they are
        // written into the template's block. A note's own block gains the
        // lines of the template keys it lacks.
        var block = template
        var ownKeys: Set<String> = []
        if let source = document.frontmatterSource {
            guard source.parsed != nil,
                  let spans = FrontmatterSource.keySpans(in: FrontmatterSource.lines(of: source.yaml)) else { return nil }
            ownKeys = Set(spans.map(\.key))
            block.opening = source.opening
            block.closing = source.closing
            block.yaml = source.yaml + templateSpans.filter { !ownKeys.contains($0.key) }
                .flatMap { templateLines[$0.lines] }.map { $0 + "\n" }.joined()
            guard let parsed = FileService.properties(fromYAML: block.yaml) else { return nil }
            block.parsed = parsed
        }

        var merged = ownProperties
        for key in templateSpans.map(\.key) where !ownKeys.contains(key) && ownProperties.yamlEntry(forKey: key) == nil {
            switch key {
            case "title": merged.title = templateProperties.title
            case "date": merged.date = templateProperties.date
            case "tags": merged.tags = templateProperties.tags
            case "aliases": merged.aliases = templateProperties.aliases
            case "cssclass": merged.cssclass = templateProperties.cssclass
            default: break
            }
            merged.custom[key] = templateProperties.custom[key]
        }
        merged.tags += templateProperties.tags.filter { !merged.tags.contains($0) }
        merged.aliases += templateProperties.aliases.filter { !merged.aliases.contains($0) }
        return (block, merged)
    }

    /// Sends a batch of files with the same options. Returns how many were
    /// written plus each failed file with its error, so the sheet can list
    /// them. Used by "Send Folder to Vault…". With a `root`, each file keeps
    /// its subfolder path below it inside the target folder. Cancelling the
    /// calling task stops it between files; `progress` gets the count done.
    @MainActor
    @discardableResult
    func sendFiles(_ urls: [URL], options: SendOptions, relativeTo root: URL? = nil, progress: ((Int) -> Void)? = nil) async -> (sent: Int, failures: [(url: URL, message: String)]) {
        var sent = 0, skipped = 0
        var failures: [(url: URL, message: String)] = []
        var cancelled = false
        // Paths no send in this batch may Overwrite or Skip against: the
        // batch's own sources and every file it has written so far.
        var reserved = Set(urls.map(Self.sendPathKey))
        // A note open in a tab sends what is on screen, unsaved edits included,
        // as a single send of the active note does.
        let openDocuments = Dictionary(
            tabs.compactMap { tab in tab.fileURL.map { (Self.sendPathKey($0), tab.documentId) } },
            uniquingKeysWith: { first, _ in first }
        )
        for (index, url) in urls.enumerated() {
            // Only between files, so a Move never stops between its write and
            // trashing the source.
            if Task.isCancelled {
                cancelled = true
                break
            }
            do {
                let document: MarkdownDocument
                if let id = openDocuments[Self.sendPathKey(url)], let open = documents[id] {
                    document = open
                } else {
                    document = try await fileService.loadDocument(from: url)
                }
                var fileOptions = options
                fileOptions.targetFolder = Self.batchTargetFolder(for: url, root: root, base: options.targetFolder)
                fileOptions.reservedPaths = reserved
                let outcome = try await sendToVault(document: document, options: fileOptions, quiet: true)
                if case .sent(let target) = outcome {
                    sent += 1
                    reserved.insert(Self.sendPathKey(target))
                } else {
                    skipped += 1
                }
            } catch {
                Log.error("send failed for", .send, detail: "\(url.lastPathComponent): \(error.localizedDescription)")
                failures.append((url, error.localizedDescription))
            }
            progress?(index + 1)
        }
        let notes = [skipped > 0 ? "\(skipped) skipped" : nil, failures.isEmpty ? nil : "\(failures.count) failed"]
            .compactMap { $0 }
        let summary = "\(sent) of \(urls.count) files" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
        if cancelled { Log.info("batch send cancelled after \(sent) of \(urls.count) files", .send) }
        showToast(cancelled ? "Cancelled after sending \(summary)" : "Sent \(summary)",
                  style: notes.isEmpty && !cancelled ? .success : .warning)
        return (sent, failures)
    }

    /// Where one file of a folder batch goes: the target folder plus the
    /// file's subfolder path below `root`, so a recursive send keeps the tree
    /// (2025/README.md and 2026/README.md no longer land on one name).
    static func batchTargetFolder(for file: URL, root: URL?, base: String) -> String {
        guard let root else { return base }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard parentPath.hasPrefix(rootPath + "/") else { return base }
        let subfolder = parentPath.dropFirst(rootPath.count + 1)
        return (base.split(separator: "/") + subfolder.split(separator: "/")).joined(separator: "/")
    }

    /// Identity of a path for batch collision checks: standardized and
    /// symlink-resolved, then NFC and lowercased, since APFS compares names
    /// case- and normalization-insensitively by default. (On a case-sensitive
    /// volume this only reserves too much, which costs a numbered name.)
    static func sendPathKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
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
            Log.info("auto-route: no rule matched for", .send, detail: document.displayTitle)
            showToast("No routing rule matches — opening Send dialog", style: .warning)
            showSendToVault = true
            return
        }
        Log.info("auto-route: rule matched", .send, detail: "'\(rule.name)' → \(document.displayTitle)")

        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = rule.targetFolder
        options.action = rule.action
        options.conflictResolution = settings.conflictResolution
        options.injectFrontmatter = rule.injectFrontmatter

        Task { @MainActor in
            do {
                let outcome = try await sendToVault(document: document, options: options, quiet: true)
                showToast(outcome.unsentMessage ?? "Routed to \(vault.displayName)/\(rule.targetFolder) (\(rule.name))",
                          style: outcome.unsentMessage == nil ? .success : .warning)
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
            let formatter = DateFormatter.fixedFormat("yyyyMMdd-HHmmss")
            let timestamp = formatter.string(from: Date())
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let parent = url.deletingLastPathComponent()
            return parent.appendingPathComponent("\(baseName)_\(timestamp).\(ext)").uniquified()
        }
    }

    /// True when both URLs name the same file: the same path once standardized
    /// and symlink-resolved, or the same file resource identifier (catches
    /// case-only differences on case-insensitive volumes, and hard links).
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path {
            return true
        }
        guard let idA = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let idB = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return idA.isEqual(idB)
    }

    static func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
        // Path-safe but link-hostile in Obsidian: in [[Invoice #42]] the `#`
        // starts a heading reference, `^` a block reference, and brackets end
        // the link. Leading dots would make the note a hidden file.
        let linkHostile = CharacterSet(charactersIn: "#^[]")
        let trimSet = CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)
        var cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .components(separatedBy: linkHostile).joined()
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: trimSet)
        if cleaned.decomposedStringWithCanonicalMapping.utf16.count > maxFilenameUnits {
            // Cut whole characters (grapheme clusters), so no Hangul syllable
            // or emoji is split, then re-trim the new end.
            var capped = "", units = 0
            for character in cleaned {
                let cost = String(character).decomposedStringWithCanonicalMapping.utf16.count
                if units + cost > maxFilenameUnits { break }
                units += cost
                capped.append(character)
            }
            cleaned = capped.trimmingCharacters(in: trimSet)
        }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Longest base name a send writes, in UTF-16 units of the decomposed
    /// (NFD) form, which is how APFS counts its 255-unit name limit: a Hangul
    /// syllable costs 2-3 units, so about 85 of them already failed the write.
    /// The margin leaves room for ".md" and the conflict suffixes
    /// ("_yyyyMMdd-HHmmss", " (n)").
    static let maxFilenameUnits = 200

    /// The vault file name a send writes. A template's filename pattern wins;
    /// otherwise a note that has a file keeps its filename, because naming it
    /// after its `title:` property renamed the note and broke [[links]] to
    /// it. Drafts and captures are named after their title.
    static func sendFilename(for document: MarkdownDocument, template: VaultTemplate?, date: Date = Date()) -> String {
        let baseName = template?.generateFilename(title: document.displayTitle, date: date)
            ?? document.fileURL?.deletingPathExtension().lastPathComponent
            ?? document.displayTitle
        return sanitizedFilename(baseName) + ".md"
    }

    // MARK: - Toast

    /// Identifies the toast on screen, so only its own timer clears it. Matching
    /// on the text let an earlier identical toast (autosave "Saved", then ⌘S)
    /// cut the new one short.
    @ObservationIgnored private var toastToken = 0

    func showToast(_ message: String, style: ToastStyle = .success) {
        toastToken += 1
        let token = toastToken
        toastMessage = message
        toastStyle = style
        // VoiceOver heard none of these. Confirmations (autosave's "Saved"
        // among them) go at low priority so they don't talk over the user.
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = style == .success ? .low : .high
        AccessibilityNotification.Announcement(announcement).post()
        // A problem stays up long enough to read.
        let duration: TimeInterval = style == .success ? 2 : 4
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toastMessage = nil
        }
    }

    // MARK: - Reading Positions

    /// Per-file preview reading positions (see `ReadingPositions`). Not
    /// observed: the preview reads and reports them imperatively, and an
    /// observed store would re-render it on every scroll report.
    @ObservationIgnored private var readingPositions = ReadingPositions()
    @ObservationIgnored private var readingPositionsChanged = false
    @ObservationIgnored private var readingPositionsSaveDebounce: DispatchWorkItem?
    private static let readingPositionsFilename = "reading-positions.json"

    func readingPosition(forKey key: String) -> Double? {
        readingPositions.offset(forKey: key)
    }

    /// Reported by the preview after the user scrolls (debounced there) and
    /// when it switches away from a document. Saved on its own debounce, which
    /// writes this one small file instead of every data JSON per scroll, and
    /// by saveUserData, so quitting flushes it.
    func recordReadingPosition(_ offset: Double, forKey key: String) {
        guard readingPositions.record(offset, forKey: key) else { return }
        readingPositionsChanged = true
        readingPositionsSaveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveReadingPositions()
        }
        readingPositionsSaveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func saveReadingPositions() {
        readingPositionsSaveDebounce?.cancel()
        readingPositionsSaveDebounce = nil
        guard readingPositionsChanged else { return }
        readingPositionsChanged = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(readingPositions.entries) {
            Self.writeDataFile(data, to: dataURL.appendingPathComponent(Self.readingPositionsFilename))
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
            Self.writeDataFile(data, to: sessionURL)
        }
    }

    private func restoreSessionIfNeeded() {
        guard settings.restoreLastSession,
              let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SessionState.self, from: data) else { return }

        Log.info("restoring session: \(session.openFiles.count) file(s)", .app)
        viewMode = session.viewMode
        sidebarVisible = session.sidebarVisible
        inspectorVisible = session.inspectorVisible

        if let folder = session.currentFolder,
           FileManager.default.fileExists(atPath: folder.path) {
            currentFolder = folder
            loadFileTree()
        }

        // Resolved before the existence filter: the saved index points into
        // session.openFiles, so indexing the surviving tabs picked the wrong
        // one whenever an earlier file had been deleted.
        let activeURL = Self.restoredActiveURL(openFiles: session.openFiles, activeIndex: session.activeFileIndex)
        let files = session.openFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }

        // Load everything first, then add the tabs in one pass and activate
        // once. Activating each tab in turn made the editor highlight and the
        // preview start rendering every restored document, and rewrote the
        // recents and session files per tab.
        Task { @MainActor in
            var loaded: [MarkdownDocument] = []
            for url in files where !tabs.contains(where: { $0.fileURL == url }) {
                do {
                    loaded.append(try await fileService.loadDocument(from: url))
                } catch {
                    Log.error("session restore: couldn't open", detail: "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            var restored: [EditorTab] = []
            for document in loaded {
                // Re-checked: a file opened meanwhile (e.g. from Finder) keeps its tab.
                guard let url = document.fileURL,
                      !tabs.contains(where: { $0.fileURL == url }) else { continue }
                let tab = EditorTab(documentId: document.id, fileURL: url, title: document.displayTitle)
                documents[document.id] = document
                originalContents[document.id] = document.fullText
                startWatchingFile(at: url, for: tab.id)
                harvestTags(from: document)
                restored.append(tab)
            }
            tabs.append(contentsOf: restored)

            // Restore activates nothing until here, so an active tab means
            // something was opened while the files loaded — the note
            // double-clicked in Finder to launch the app, a sidebar click.
            // That stays in front instead of the session's active tab.
            if activeTabId == nil {
                if let activeURL, let tab = tabs.first(where: { $0.fileURL == activeURL }) {
                    activeTabId = tab.id
                } else {
                    activeTabId = restored.last?.id
                }
            }
            saveSession()
        }
    }

    /// The file that was active when the session was saved, looked up in the
    /// saved list itself (nil when there was none or the index is stale).
    static func restoredActiveURL(openFiles: [URL], activeIndex: Int?) -> URL? {
        guard let activeIndex, openFiles.indices.contains(activeIndex) else { return nil }
        return openFiles[activeIndex]
    }

    // MARK: - User Data Persistence

    private func loadUserData() {
        var backups: [String] = []

        func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
            let result = Self.loadDataFile(type, named: filename, in: dataURL)
            if let backup = result.backup { backups.append(backup.lastPathComponent) }
            return result.value
        }

        func loadList<T: Decodable>(_ type: T.Type, from filename: String) -> [T]? {
            let result = Self.loadDataList(type, named: filename, in: dataURL)
            if let backup = result.backup { backups.append(backup.lastPathComponent) }
            return result.value
        }

        if let loaded = load(AppSettings.self, from: "settings.json") { settings = loaded }
        // Honor a disabled file log before anything below can log.
        Log.setFileLoggingEnabled(settings.fileLoggingEnabled)
        if let loaded = loadList(Vault.self, from: "vaults.json") { vaults = loaded }
        if let loaded = loadList(URL.self, from: "recents.json") {
            recentFiles = loaded.filter { FileManager.default.fileExists(atPath: $0.path) }
            parkedRecents = loaded.filter { !recentFiles.contains($0) && !Self.isDefinitelyMissing($0) }
        }
        if let loaded = loadList(VaultTemplate.self, from: "templates.json") { templates = loaded }
        if let loaded = loadList(RoutingRule.self, from: "rules.json") { routingRules = loaded }
        if let loaded = loadList(FavoriteItem.self, from: "favorites.json") {
            // Favorites on an unmounted volume stay listed (opening one checks
            // that the file exists); only definitely-deleted files are pruned.
            favorites = loaded.filter { !Self.isDefinitelyMissing($0.url) }
        }
        if let loaded = loadList(Draft.self, from: "drafts.json") { drafts = loaded }
        // Only a cache: a damaged file is still set aside and logged by
        // loadDataList, but isn't worth the alert below.
        if let loaded = Self.loadDataList(ReadingPositions.Entry.self, named: Self.readingPositionsFilename, in: dataURL).value {
            readingPositions = ReadingPositions(entries: loaded)
        }

        if !backups.isEmpty {
            let folder = (dataURL.path as NSString).abbreviatingWithTildeInPath
            errorMessage = "Some saved data couldn't be read. The original files were kept in \(folder) as: \(backups.joined(separator: ", "))"
        }
    }

    func saveUserData() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        func save<T: Encodable>(_ value: T, to filename: String) {
            if let data = try? encoder.encode(value) {
                Self.writeDataFile(data, to: dataURL.appendingPathComponent(filename))
            }
        }

        Log.setFileLoggingEnabled(settings.fileLoggingEnabled)
        save(settings, to: "settings.json")
        save(vaults, to: "vaults.json")
        // Parked (unreachable) recents ride along so an unmounted volume
        // doesn't erase them; they age out under the 20-entry cap.
        save(Array((recentFiles + parkedRecents.filter { !recentFiles.contains($0) }).prefix(20)), to: "recents.json")
        save(templates, to: "templates.json")
        save(routingRules, to: "rules.json")
        save(favorites, to: "favorites.json")
        persistDrafts()
        saveReadingPositions()
    }

    /// Text left in the hidden Quick Capture panel at quit becomes a draft
    /// instead of disappearing with the process.
    func stashCaptureAsDraft(_ text: String) {
        drafts.insert(Draft(body: text), at: 0)
    }

    /// Set while drafts.json can't be written, so the alert shows once per
    /// failure streak rather than on every debounced persist.
    @ObservationIgnored private var draftsWriteFailing = false

    func persistDrafts() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(drafts) {
            let written = Self.writeDataFile(data, to: dataURL.appendingPathComponent("drafts.json"))
            // Drafts are never "unsaved" (they persist themselves) and quitting
            // doesn't ask about them, so a failing write (full disk, permissions)
            // lost them without a word.
            if !written, !draftsWriteFailing {
                errorMessage = "Drafts couldn\u{2019}t be saved to disk. Free up space or check permissions; recent draft edits are kept only while CmdMD stays open."
            }
            draftsWriteFailing = !written
        }
    }

    /// Writes one app-data file atomically (temp file + rename), so a crash,
    /// power loss or full disk mid-write leaves the previous version intact
    /// instead of a truncated file that no longer decodes.
    @discardableResult
    private static func writeDataFile(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.error("couldn't write \(url.lastPathComponent)", detail: error.localizedDescription)
            return false
        }
    }

    /// Reads one app-data JSON file. A missing file is nil (defaults apply). A
    /// file that exists but can't be read or decoded is moved aside to
    /// `<name>.corrupt-<timestamp>.json` first: otherwise the next save would
    /// replace the only copy of the user's data with defaults or an empty list.
    static func loadDataFile<T: Decodable>(_ type: T.Type, named filename: String, in directory: URL) -> (value: T?, backup: URL?) {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode(type, from: Data(contentsOf: url)), nil)
        } catch {
            Log.error("couldn't read \(filename)", detail: String(describing: error))
            return (nil, backUpDataFile(at: url, move: true))
        }
    }

    /// `loadDataFile` for lists, decoded entry by entry so a malformed entry
    /// costs only itself. When entries were skipped the file is copied aside,
    /// since the recovered entries are about to be written back over it.
    static func loadDataList<Element: Decodable>(_ type: Element.Type, named filename: String, in directory: URL) -> (value: [Element]?, backup: URL?) {
        let result = loadDataFile(LossyList<Element>.self, named: filename, in: directory)
        guard let list = result.value else { return (nil, result.backup) }
        guard list.skippedCount > 0 else { return (list.elements, nil) }
        Log.error("skipped \(list.skippedCount) unreadable entries in \(filename)")
        return (list.elements, backUpDataFile(at: directory.appendingPathComponent(filename), move: false))
    }

    /// Keeps a data file's original bytes next to it as
    /// `<name>.corrupt-<yyyyMMdd-HHmmss>.json`. Nil when that failed.
    private static func backUpDataFile(at url: URL, move: Bool) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(formatter.string(from: Date())).\(url.pathExtension)"
        let backup = url.deletingLastPathComponent().appendingPathComponent(name).uniquified()
        do {
            if move {
                try FileManager.default.moveItem(at: url, to: backup)
            } else {
                try FileManager.default.copyItem(at: url, to: backup)
            }
            return backup
        } catch {
            Log.error("couldn't back up \(url.lastPathComponent)", detail: error.localizedDescription)
            return nil
        }
    }
}

enum SendError: LocalizedError {
    case noDocumentOrVault
    case fileConflict
    case writeError(Error)
    /// A Move wrote the vault copy but couldn't trash the original.
    case sourceNotTrashed(copy: URL, Error)
    /// The target folder leaves the vault ("..").
    case invalidFolder(String)
    /// The vault's folder is gone (moved, renamed, deleted or unmounted) and
    /// its bookmark doesn't lead to it either.
    case vaultFolderMissing(String)

    var errorDescription: String? {
        switch self {
        case .noDocumentOrVault:
            return "No document or vault selected"
        case .vaultFolderMissing(let name):
            return "The folder of vault \u{201C}\(name)\u{201D} wasn't found. If it was moved or renamed, use Change… in Vault Manager to locate it."
        case .fileConflict:
            return "File already exists"
        case .writeError(let error):
            return "Write error: \(error.localizedDescription)"
        case .invalidFolder(let folder):
            return "\u{201C}\(folder)\u{201D} isn\u{2019}t a folder inside the vault."
        case .sourceNotTrashed(let copy, let error):
            return "Copied as \(copy.lastPathComponent), but the original couldn't be moved to the Trash, so it was kept: \(error.localizedDescription)"
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
