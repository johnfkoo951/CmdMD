import SwiftUI
import WebKit

extension PreviewTheme {
    /// Approximate page background per theme, mirroring each CSS --bg-primary.
    /// Painted behind the (transparent) preview WebView so reloads never flash
    /// a mismatched color.
    func backgroundColor(forDark isDark: Bool) -> Color {
        switch self {
        case .github:    return Color(hex: isDark ? "0d1117" : "ffffff")
        case .obsidian:  return Color(hex: isDark ? "1e1e1e" : "ffffff")
        case .minimal:   return Color(hex: isDark ? "1d1d1f" : "ffffff")
        case .cmds:      return Color(hex: isDark ? "06080a" : "fbfbfa")
        case .sepia:     return Color(hex: isDark ? "2b2114" : "f4ecd8")
        case .newsprint: return Color(hex: isDark ? "121212" : "ffffff")
        case .darkPro:   return Color(hex: "0d0d0d")
        }
    }
}

/// The preview's web view. WebKit claims every drag over the page, so a
/// note or folder dropped there never reached the window's drop handler
/// ("Drop a Markdown file anywhere to open it") and nothing opened. Those
/// drops open from here; any other drag (text, an image, a link from the
/// page itself) is still WebKit's.
final class PreviewWebView: WKWebView {
    /// False in Source mode, where the preview stays mounted off-screen.
    var isPaneVisible = true
    /// Opens the notes and folders dropped on the page.
    var onFileDrop: (([URL]) -> Void)?
    /// What the drag in progress would open, read once per drag.
    private var currentDrop: (sequence: Int, urls: [URL])?

    /// Hidden, the page leaves the key-view loop: Tab moved focus into it.
    override var canBecomeKeyView: Bool {
        isPaneVisible && super.canBecomeKeyView
    }

    /// The notes and folders a drop would open; none for a drag that starts
    /// in this page or carries nothing CmdMD opens.
    func droppedItems(for sender: NSDraggingInfo) -> [URL] {
        if let drop = currentDrop, drop.sequence == sender.draggingSequenceNumber { return drop.urls }
        let isOwnDrag = (sender.draggingSource as AnyObject?) === self
        let urls = onFileDrop == nil || isOwnDrag ? [] : Self.openableURLs(on: sender.draggingPasteboard)
        currentDrop = (sender.draggingSequenceNumber, urls)
        return urls
    }

    /// Folders and notes (by extension) among a pasteboard's file URLs.
    static func openableURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let dropped = AppWindowPolicy.partitionDroppedURLs(urls)
        return dropped.folders + dropped.files.filter {
            NoteIndexService.supportedExtensions.contains($0.pathExtension.lowercased())
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedItems(for: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedItems(for: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, !droppedItems(for: sender).isEmpty { return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedItems(for: sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedItems(for: sender)
        guard !urls.isEmpty, let onFileDrop else { return super.performDragOperation(sender) }
        onFileDrop(urls)
        return true
    }
}

/// The previewed text as a view input whose equality checks the UTF-16
/// length before the characters (`String.differs(from:)`). SwiftUI compares
/// a view's inputs on every update, and String == walks both notes up to
/// the edit point: 11-13 ms per keystroke for a 500 KB note from the editor.
/// Typing changes the length, so the comparison is O(1).
struct PreviewSource: Equatable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    static func == (lhs: PreviewSource, rhs: PreviewSource) -> Bool {
        !lhs.text.differs(from: rhs.text)
    }
}

struct MarkdownPreviewView: NSViewRepresentable {
    /// Identity of the previewed document; a change means a tab switch, which
    /// renders immediately and resets scroll (vs. debounced live typing updates).
    let documentID: UUID?
    /// False in source mode, where the preview stays mounted but off-screen.
    var isVisible = true
    /// Where the document's reading position is remembered
    /// (`ReadingPositions.key(for:)`). Unlike `documentID`, which every open
    /// mints anew, it survives closing the tab and relaunching.
    let positionKey: String?
    let source: PreviewSource
    let baseURL: URL?
    let options: MarkdownRenderOptions
    let scrollSyncEnabled: Bool
    /// Unified zoom multiplier. Applied via `pageZoom` (reflowing, survives
    /// loadHTMLString reloads) — deliberately NOT part of `options`, which
    /// would force a full re-render per step and leak into HTML/PDF exports.
    let zoom: Double

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isTextInteractionEnabled = true
        // Bridge for preview→app messages (task toggles, which the page
        // hears back about, and the reading position).
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "cmdmd")
        // Local images: a loadHTMLString page can't read file:// URLs, so the
        // renderer points them at this scheme (see LocalAssetURL).
        config.setURLSchemeHandler(context.coordinator.assetHandler, forURLScheme: LocalAssetURL.scheme)
        // KaTeX, highlight.js and their styles from inside the app (see PreviewLibrary).
        config.setURLSchemeHandler(PreviewLibrarySchemeHandler(), forURLScheme: PreviewLibrary.scheme)

        let webView = PreviewWebView(frame: .zero, configuration: config)
        PreviewWarmup.end()
        webView.navigationDelegate = context.coordinator
        webView.pageZoom = zoom
        webView.isPaneVisible = isVisible
        // Notes and folders dropped on the page open as on the window.
        webView.onFileDrop = { urls in
            AppState.shared?.openDroppedItems(urls)
        }
        // Transparent web view: the SwiftUI pane behind it supplies the theme
        // background, so the white default never flashes between loadHTMLString
        // and first CSS paint (most visible as a dark-mode flicker while typing).
        webView.setValue(false, forKey: "drawsBackground")
        // Pinch-zoom routed to the app-wide zoom level (allowsMagnification
        // would keep its own transform, out of sync with the editor).
        let pinch = NSMagnificationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMagnification(_:))
        )
        webView.addGestureRecognizer(pinch)
        context.coordinator.webView = webView
        context.coordinator.scrollSyncEnabled = scrollSyncEnabled
        // Reports the reading position as the user scrolls. A user script, not
        // page HTML, so it never reaches exports and needs no CSP allowance.
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: Coordinator.scrollReportScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))

        // The first page (a relaunch, the first note after the welcome
        // screen) opens at its remembered position, as a tab switch does.
        context.coordinator.switchDocument(
            to: documentID, positionKey: positionKey, markdown: source.text, baseURL: baseURL, options: options
        )

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.scrollSyncEnabled = scrollSyncEnabled
        (webView as? PreviewWebView)?.isPaneVisible = isVisible

        // Before the early exits below — zoom must apply even when the
        // document content is unchanged.
        if webView.pageZoom != zoom {
            webView.pageZoom = zoom
        }

        // Tab switch: remember the outgoing document's reading position, render
        // the new one at once (no debounce), and restore its saved position —
        // losing the scroll offset on every tab switch broke the core
        // review-first flow of flipping between long notes.
        if context.coordinator.currentDocumentID != documentID {
            context.coordinator.switchDocument(
                to: documentID, positionKey: positionKey, markdown: source.text, baseURL: baseURL, options: options
            )
            return
        }
        // Same document, new path (renamed or moved): file its position there.
        context.coordinator.updatePositionKey(positionKey, for: documentID)

        // Against the newest render asked for, not the page on screen: an
        // update carrying the text already rendering (a zoom step, a mode
        // switch) would otherwise start it over. The folder counts too: Save
        // As, a move or a rename keeps the text, and the page must resolve
        // its images and links against the new folder.
        let coordinator = context.coordinator
        guard coordinator.latestSource.differs(from: source.text) || coordinator.latestOptions != options
                || coordinator.latestBaseURL != baseURL else {
            return
        }
        // Debounced + scroll-preserving: rendering happens inside the debounce so
        // fast typing doesn't pay a full markdown→HTML pass per keystroke.
        context.coordinator.scheduleRender(markdown: source.text, baseURL: baseURL, options: options)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "cmdmd")
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        weak var webView: WKWebView?
        let renderer = MarkdownRenderer()
        var scrollSyncEnabled: Bool = true
        var currentDocumentID: UUID?
        /// The newest text and settings handed to a render (or shown): what
        /// the preview is showing or about to.
        private(set) var latestSource = ""
        private(set) var latestOptions = MarkdownRenderOptions()
        private(set) var latestBaseURL: URL?

        /// Bumped for every page about to be rendered or shown.
        private var generation = 0
        /// Where the current document's reading position is filed.
        private var currentPositionKey: String?
        /// The page on screen (or loading): the one loaded, or the last
        /// one patched in. Task toggles check their line against its text.
        /// Its baseURL (nil → about:blank): its own load and #anchor jumps
        /// are the only navigations allowed without a click, and its folder
        /// and asset roots are where local images may come from.
        private var page: PreviewPage?
        /// The loaded page's nonce, and how many patches it has taken since:
        /// what the page names in a task toggle, and a patch must name.
        private var pageNonce = ""
        private var pageVersion = 0
        /// The page a patch in flight brings, and the newest one rendered
        /// meanwhile, shown once it lands.
        private var patching: PreviewPage?
        private var nextPage: PreviewPage?
        private var pageCache = PreviewPageCache()
        private var debounce = PreviewDebounce()
        private var loadStartedAt: UInt64 = 0

        private var pendingScrollY: Double = 0
        /// The document whose page is loaded (or loading), and the key its
        /// reading position is filed under (positions live in AppState, so
        /// they outlive the tab and the app). These lag `currentDocumentID`
        /// while a tab switch waits for the outgoing page's offset.
        private var displayedDocumentID: UUID?
        private var displayedKey: String?
        /// The page load in flight. Until it finishes, the offset on screen
        /// can still be the previous page's, or the top before the restore,
        /// so it is neither captured nor accepted from the page.
        private var loadingNavigation: WKNavigation?
        /// A heading jump that arrived while a page was loading or before a
        /// pending switch rendered: applied when that page finishes, instead of
        /// the remembered reading position.
        private var pendingHeadingSlug: String?
        private var renderDebounce: DispatchWorkItem?
        private var observers: [NSObjectProtocol] = []
        let assetHandler = LocalAssetSchemeHandler()

        override init() {
            super.init()
            assetHandler.allowedRoots = { [weak self] in
                guard let self else { return [] }
                return [self.page?.baseURL].compactMap { $0 } + (self.page?.options.localAssetRoots ?? [])
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: .scrollToHeading,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let slug = notification.object as? String else { return }
                self?.scrollToHeadingSlug(slug)
            })
            observers.append(center.addObserver(
                forName: .editorDidScroll,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, self.scrollSyncEnabled,
                      let fraction = notification.object as? Double else { return }
                self.scrollToFraction(fraction)
            })
            observers.append(center.addObserver(
                forName: .findInPreview,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let request = notification.object as? PreviewFindRequest else { return }
                self?.find(request)
            })
            observers.append(center.addObserver(
                forName: .endFindInPreview,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.endFind(focusPreview: notification.object as? Bool ?? false)
            })
            observers.append(center.addObserver(
                forName: .previewSelectionForFind,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let request = notification.object as? PreviewSelectionRequest else { return }
                self?.selectedText(then: request.completion)
            })
            observers.append(center.addObserver(
                forName: .focusVisiblePane,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let request = notification.object as? PaneFocus.Request, request.target == .preview else { return }
                self?.takeFocus(for: request)
            })
        }

        deinit {
            tearDown()
        }

        func tearDown() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            renderDebounce?.cancel()
            PreviewRenderThread.shared.cancel(for: self)
        }

        /// Tab switch, or the first page: capture the outgoing document's
        /// scroll offset, then at once (no debounce) show the incoming one at
        /// its remembered position (or the top on first visit) — from the
        /// cache when its text and settings are unchanged, rendered otherwise.
        func switchDocument(to documentID: UUID?, positionKey: String?, markdown: String, baseURL: URL?, options: MarkdownRenderOptions) {
            currentDocumentID = documentID
            currentPositionKey = positionKey
            setLatest(markdown, baseURL: baseURL, options: options)
            renderDebounce?.cancel()
            // The outgoing note's: a patch in flight still lands on its page.
            nextPage = nil
            guard let webView else { return }

            // The newest text when the offset comes back: typing may have
            // asked for a render meanwhile, or even put the page up already.
            let open = { [weak self] in
                guard let self, self.currentDocumentID == documentID else { return }
                // Up already: typed in, or back before the other note's page came.
                if self.displayedDocumentID == documentID, let page = self.patching ?? self.page,
                   page.matches(self.latestSource, baseURL: self.latestBaseURL, options: self.latestOptions) {
                    PreviewRenderThread.shared.cancel(for: self)
                    return
                }
                // Newer than any render asked for before, which can't replace it.
                self.generation += 1
                if let cached = self.pageCache.page(for: documentID, source: self.latestSource, baseURL: self.latestBaseURL,
                                                    options: self.latestOptions, generation: self.generation) {
                    PreviewRenderThread.shared.cancel(for: self)
                    self.show(cached)
                } else {
                    self.render(self.latestSource, baseURL: self.latestBaseURL, options: self.latestOptions, for: documentID)
                }
            }

            // Filed under the page actually on screen: keyed by the outgoing
            // id, a fast A→B→C switch put A's offset under B, which never
            // rendered. Not captured from a page that is still loading.
            if let outgoingKey = displayedKey, loadingNavigation == nil {
                webView.evaluateJavaScript("window.scrollY") { value, _ in
                    if let y = value as? Double { AppState.shared?.recordReadingPosition(y, forKey: outgoingKey) }
                    open()
                }
            } else {
                open()
            }
        }

        /// A renamed or moved file keeps its document but changes key: once
        /// its page is the one on screen, file the position under the new key.
        func updatePositionKey(_ positionKey: String?, for documentID: UUID?) {
            currentPositionKey = positionKey
            guard displayedDocumentID == documentID, displayedKey != positionKey else { return }
            displayedKey = positionKey
        }

        private func setLatest(_ markdown: String, baseURL: URL?, options: MarkdownRenderOptions) {
            latestSource = markdown
            latestBaseURL = baseURL
            latestOptions = options
        }

        /// Marks `documentID`'s page as the one on screen and returns its
        /// remembered offset (0, the top, on a first visit).
        private func beginDisplaying(_ documentID: UUID?, positionKey: String?) -> Double {
            displayedDocumentID = documentID
            displayedKey = positionKey
            return positionKey.flatMap { AppState.shared?.readingPosition(forKey: $0) } ?? 0
        }

        /// Debounces preview rebuilds and restores the prior scroll offset, so
        /// typing in split view doesn't jump the preview to the top. The wait
        /// follows what the last refresh of this preview cost.
        func scheduleRender(markdown: String, baseURL: URL?, options: MarkdownRenderOptions) {
            renderDebounce?.cancel()
            setLatest(markdown, baseURL: baseURL, options: options)
            // A work item that has begun can't be cancelled, and the render
            // and offset read after it finish later still: each step re-checks
            // the document, so the old note never clobbers the new one.
            let documentID = currentDocumentID
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.currentDocumentID == documentID else { return }
                self.render(markdown, baseURL: baseURL, options: options, for: documentID)
            }
            renderDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounce.delay, execute: work)
        }

        /// Renders on the render thread and shows the page back on the main
        /// thread, unless the tab changed or a newer page was shown meanwhile.
        /// A render still waiting when the next is asked for never runs (see
        /// PreviewRenderThread).
        private func render(_ markdown: String, baseURL: URL?, options: MarkdownRenderOptions, for documentID: UUID?) {
            generation += 1
            let generation = generation
            let renderer = renderer
            PreviewRenderThread.shared.enqueue(for: self) { [weak self] in
                let start = DispatchTime.now().uptimeNanoseconds
                let rendered = renderer.renderPage(markdown: markdown, baseURL: baseURL, options: options)
                let renderMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentDocumentID == documentID else { return }
                    self.show(PreviewPage(rendered: rendered, source: markdown, baseURL: baseURL, options: options, generation: generation, renderMs: renderMs))
                }
            }
        }

        /// The newest page shown, being patched in, or waiting for that.
        private var newestGeneration: Int {
            max(page?.generation ?? 0, patching?.generation ?? 0, nextPage?.generation ?? 0)
        }

        /// Puts a page of the current document up: its first one opens at
        /// the remembered position — whichever render brings it, since typing
        /// right after a switch supersedes the switch's own — and the next
        /// ones patch the changed blocks into the page on screen, or reload
        /// keeping its offset.
        private func show(_ page: PreviewPage) {
            guard let webView, page.generation > newestGeneration else { return }
            if displayedDocumentID != currentDocumentID {
                pendingScrollY = beginDisplaying(currentDocumentID, positionKey: currentPositionKey)
                load(page, into: webView)
            } else if patching != nil {
                // One patch at a time: each is computed against the page it lands on.
                nextPage = page
            } else if loadingNavigation != nil {
                // Mid-load, the page on screen is not yet at its offset: the
                // new one takes over the offset that load was restoring.
                load(page, into: webView)
            } else if let current = self.page, let edit = PreviewEdit(from: current, to: page) {
                apply(edit, bringing: page, into: webView)
            } else {
                reload(page, into: webView)
            }
        }

        /// A load of the page at the offset on screen.
        private func reload(_ page: PreviewPage, into webView: WKWebView) {
            let documentID = currentDocumentID
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                guard let self, self.currentDocumentID == documentID,
                      page.generation > self.newestGeneration, let webView = self.webView else { return }
                self.pendingScrollY = (value as? Double) ?? 0
                self.load(page, into: webView)
            }
        }

        /// Patches the changed blocks into the page on screen. Until the
        /// page answers, the page on screen is still the old one: its task
        /// lines, its blocks for the next edit. A page that refuses (it is
        /// not the one this was computed against) reloads.
        private func apply(_ edit: PreviewEdit, bringing page: PreviewPage, into webView: WKWebView) {
            guard !edit.isEmpty else { return settle(page, version: pageVersion) }
            patching = page
            let started = DispatchTime.now().uptimeNanoseconds
            webView.callAsyncJavaScript(
                "return window.cmdmdPreview.patch(edit);", arguments: ["edit": edit.argument(forPage: pageNonce)], in: nil, in: .page
            ) { [weak self] result in
                // A load since (a tab switch) replaced the page.
                guard let self, self.patching?.generation == page.generation else { return }
                self.patching = nil
                if case .success(let value) = result, let reply = value as? [String: Any],
                   reply["done"] as? Bool == true, let version = reply["version"] as? Int {
                    // Render + patch pace the typing debounce, as render + load did.
                    if let renderMs = page.renderMs {
                        self.debounce.record(refreshMs: renderMs + Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    }
                    self.settle(page, version: version)
                } else if let webView = self.webView {
                    let newest = self.nextPage ?? page
                    self.nextPage = nil
                    self.reload(newest, into: webView)
                }
            }
        }

        /// The patched page is on screen: then the page that came meanwhile,
        /// or the heading jump that waited.
        private func settle(_ page: PreviewPage, version: Int) {
            self.page = page
            pageVersion = version
            if page.renderMs != nil { pageCache.store(page, for: displayedDocumentID) }
            if let next = nextPage {
                nextPage = nil
                show(next)
            } else if let slug = pendingHeadingSlug, displayedDocumentID == currentDocumentID {
                pendingHeadingSlug = nil
                runHeadingScroll(slug)
            }
        }

        /// Loads the page with the pending scroll offset injected so restoration
        /// happens at DOMContentLoaded — before first paint. The didFinish
        /// fallback stays for slow subresource layouts, but the top-of-page
        /// flash per re-render is gone.
        private func load(_ page: PreviewPage, into webView: WKWebView) {
            self.page = page
            pageNonce = page.rendered.nonce
            pageVersion = 0
            // A patch in flight lands on the page this replaces: dropped.
            patching = nil
            nextPage = nil
            if page.renderMs != nil { pageCache.store(page, for: displayedDocumentID) }
            var html = page.html
            if pendingScrollY > 0, pendingHeadingSlug == nil {
                // Nonce'd so the page CSP runs it; lands in the renderer's head only.
                // Diagrams draw after the text (and after didFinish): until then
                // the page can be too short for the offset, and swapping a
                // source for its drawing moves it, so it is set again once
                // they are in.
                html = MarkdownRenderer.insertingHeadScript(
                    "addEventListener('DOMContentLoaded',function(){var y=\(pendingScrollY);window.scrollTo(0,y);"
                        + "if(window.cmdmdDiagrams)window.cmdmdDiagrams.then(function(){window.scrollTo(0,y);});});",
                    into: html
                )
            }
            loadStartedAt = DispatchTime.now().uptimeNanoseconds
            loadingNavigation = webView.loadHTMLString(html, baseURL: page.baseURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if navigation === loadingNavigation {
                loadingNavigation = nil
                // A rendered page's whole refresh paces the typing debounce:
                // up to its diagrams drawn, as one sooner would redraw them.
                if let page, let renderMs = page.renderMs {
                    let started = loadStartedAt
                    webView.callAsyncJavaScript("await window.cmdmdDiagrams; return true;", arguments: [:], in: nil, in: .page) { [weak self] _ in
                        guard let self, self.page?.generation == page.generation else { return }
                        self.debounce.record(refreshMs: renderMs + Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    }
                }
            }
            if let slug = pendingHeadingSlug, loadingNavigation == nil, displayedDocumentID == currentDocumentID {
                pendingHeadingSlug = nil
                pendingScrollY = 0
                runHeadingScroll(slug)
            } else if pendingScrollY > 0 {
                webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollY));", completionHandler: nil)
                pendingScrollY = 0
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if navigation === loadingNavigation { loadingNavigation = nil }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if navigation === loadingNavigation { loadingNavigation = nil }
        }

        private func scrollToHeadingSlug(_ slug: String) {
            // [[Note#Heading]] and search hits fire a fixed delay after the read:
            // on a page still loading or being patched (or not yet swapped
            // in) the jump was lost, or the restored reading position
            // overrode it.
            if loadingNavigation != nil || patching != nil || displayedDocumentID != currentDocumentID {
                pendingHeadingSlug = slug
                pendingScrollY = 0
                return
            }
            runHeadingScroll(slug)
        }

        private func runHeadingScroll(_ slug: String) {
            let escaped = slug.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            // Once the diagrams are in: drawing them moves what is below. The
            // DOM's own methods, never a note element's property (see
            // PreviewRuntime).
            let js = """
            (function() {
                Promise.resolve(window.cmdmdDiagrams).then(function() {
                    var el = Document.prototype.getElementById.call(document, '\(escaped)');
                    if (el) {
                        Element.prototype.scrollIntoView.call(el, { behavior: 'smooth', block: 'start' });
                    }
                });
            })();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        private func scrollToFraction(_ fraction: Double) {
            // The editor's offset is the current note's, not the outgoing page's.
            guard displayedDocumentID == currentDocumentID else { return }
            let js = "window.scrollTo(0, \(fraction) * (document.documentElement.scrollHeight - window.innerHeight));"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: Find in preview

        /// WebKit's own find: selects the match and scrolls it into view. It
        /// searches onward from the selection, so repeated finds step through
        /// the matches; a miss clears the selection.
        private func find(_ request: PreviewFindRequest) {
            guard let webView else {
                request.completion?(false)
                return
            }
            let search = { [weak webView] in
                webView?.find(request.query, configuration: request.configuration) { result in
                    request.completion?(result.matchFound)
                }
            }
            if request.fromCurrentMatch {
                // Collapse the match to its start so it can be found again:
                // typing "alp" → "alph" keeps the same occurrence.
                let collapse = "(function(){var s=window.getSelection();if(s.rangeCount)s.collapseToStart();})();"
                webView.evaluateJavaScript(collapse) { _, _ in search() }
            } else {
                search()
            }
        }

        /// Drops the highlighted match. On Esc / Done the web view takes
        /// keyboard focus, so the next keystrokes scroll the preview instead
        /// of reaching the hidden editor.
        private func endFind(focusPreview: Bool) {
            guard let webView else { return }
            webView.evaluateJavaScript("window.getSelection().removeAllRanges();", completionHandler: nil)
            if focusPreview {
                webView.window?.makeFirstResponder(webView)
            }
        }

        /// The text selected on the page (Use Selection for Find).
        private func selectedText(then completion: @escaping (String) -> Void) {
            guard let webView else { return completion("") }
            webView.evaluateJavaScript("window.getSelection().toString()") { value, _ in
                completion(value as? String ?? "")
            }
        }

        /// Preview mode: the page takes keyboard focus, so Space, the arrow
        /// keys and Page Down scroll it (see PaneFocus).
        private func takeFocus(for request: PaneFocus.Request) {
            guard let webView, let window = webView.window, window.attachedSheet == nil,
                  PaneFocus.shouldTakeFocus(request, from: window.firstResponder, in: window) else { return }
            window.makeFirstResponder(webView)
        }

        // MARK: Pinch zoom

        @objc func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
            // `magnification` accumulates over the gesture; resetting it after
            // each read turns the callback into incremental deltas.
            let delta = recognizer.magnification
            recognizer.magnification = 0
            AppState.shared?.adjustZoom(by: delta)
        }

        // MARK: Preview → app messages

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            // Handlers are exposed to every frame; only the rendered page itself
            // may edit the document.
            guard message.name == "cmdmd",
                  message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return replyHandler(nil, nil) }

            if type == "toggleTask" {
                return replyHandler(toggleTask(body), nil)
            }

            // Reading position from scrollReportScript. While a page loads, a
            // report can still come from the page it replaces: dropped. So is
            // one from the outgoing page while the incoming one renders: its
            // offset was taken at the switch. A patch keeps the page, and the
            // reader's place on it.
            if type == "scroll", let y = body["y"] as? Double,
               loadingNavigation == nil, displayedDocumentID == currentDocumentID, let key = displayedKey {
                AppState.shared?.recordReadingPosition(y, forKey: key)
            }
            replyHandler(nil, nil)
        }

        /// Only the active note's own, settled page may edit it: during a tab
        /// switch the outgoing page stays clickable until the new one loads,
        /// and a click there flipped the same line of the new note. The box
        /// names its page and patch, whose task lines map it to a line of the
        /// page's text; AppState maps that through any edit since, and the
        /// line must still read as rendered.
        private func toggleTask(_ body: [String: Any]) -> Bool {
            guard let ordinal = body["task"] as? Int, let page,
                  body["page"] as? String == pageNonce, body["version"] as? Int == pageVersion,
                  loadingNavigation == nil, displayedDocumentID == currentDocumentID,
                  page.rendered.taskLines.indices.contains(ordinal) else { return false }
            let line = page.rendered.taskLines[ordinal]
            let rendered = page.source.components(separatedBy: "\n")
            let expected = line >= 1 && line <= rendered.count ? rendered[line - 1] : nil
            return AppState.shared?.toggleTask(atLine: line, checked: body["checked"] as? Bool ?? true,
                                               expectedLine: expected, renderedSource: page.source) ?? false
        }

        /// Posts `window.scrollY` once scrolling settles for 300 ms. Passive,
        /// so it never holds up scrolling.
        static let scrollReportScript = """
        (function () {
            var timer = null;
            addEventListener('scroll', function () {
                clearTimeout(timer);
                timer = setTimeout(function () {
                    window.webkit.messageHandlers.cmdmd.postMessage({ type: 'scroll', y: window.scrollY });
                }, 300);
            }, { passive: true });
        })();
        """

        // MARK: Navigation policy

        /// Rules live in PreviewNavigationPolicy: only link clicks leave the
        /// page, so opening a note can't launch URLs or drive obsidian://.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let decision = PreviewNavigationPolicy.decide(
                url: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                pageURL: PreviewNavigationPolicy.pageURL(forBaseURL: page?.baseURL)
            )

            switch decision {
            case .allow:
                return .allow
            case .cancel:
                break
            case .openInternal(let url):
                NotificationCenter.default.post(name: .openInternalLink, object: url)
            case .openExternal(let url):
                NSWorkspace.shared.open(url)
            case .openNote(let url):
                // A clicked relative link to another note opens in the app instead
                // of rendering the raw file inside the preview WebView.
                Task { @MainActor in
                    AppState.shared?.openDocument(at: url, inNewTab: true)
                }
            case .revealInFinder(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return .cancel
        }
    }
}
