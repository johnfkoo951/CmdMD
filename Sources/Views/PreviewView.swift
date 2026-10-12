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
    let markdown: String
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
        // Bridge for preview→app messages (interactive task checkboxes).
        config.userContentController.add(context.coordinator, name: "cmdmd")
        // Local images: a loadHTMLString page can't read file:// URLs, so the
        // renderer points them at this scheme (see LocalAssetURL).
        config.setURLSchemeHandler(context.coordinator.assetHandler, forURLScheme: LocalAssetURL.scheme)

        let webView = PreviewWebView(frame: .zero, configuration: config)
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

        let html = context.coordinator.renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
        context.coordinator.lastSource = markdown
        context.coordinator.lastOptions = options
        context.coordinator.currentDocumentID = documentID
        context.coordinator.loadFirstPage(html, documentID: documentID, positionKey: positionKey, baseURL: baseURL)

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
                to: documentID, positionKey: positionKey, markdown: markdown, baseURL: baseURL, options: options
            )
            return
        }
        // Same document, new path (renamed or moved): file its position there.
        context.coordinator.updatePositionKey(positionKey, for: documentID)

        guard context.coordinator.lastSource.differs(from: markdown) || context.coordinator.lastOptions != options else {
            return
        }
        // Debounced + scroll-preserving: rendering happens inside the debounce so
        // fast typing doesn't pay a full markdown→HTML pass per keystroke.
        context.coordinator.scheduleRender(markdown: markdown, baseURL: baseURL, options: options)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "cmdmd")
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let renderer = MarkdownRenderer()
        var lastSource: String = ""
        var lastOptions: MarkdownRenderOptions?
        var scrollSyncEnabled: Bool = true
        var currentDocumentID: UUID?

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
        /// baseURL of the page last loaded (nil → about:blank). Its own load
        /// and #anchor jumps are the only navigations allowed without a click,
        /// and its folder is where local images may come from.
        private var pageBaseURL: URL?
        let assetHandler = LocalAssetSchemeHandler()

        override init() {
            super.init()
            assetHandler.allowedRoots = { [weak self] in
                guard let self else { return [] }
                return [self.pageBaseURL].compactMap { $0 } + (self.lastOptions?.localAssetRoots ?? [])
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
        }

        /// Tab switch: capture the outgoing document's scroll offset, then
        /// immediately (no debounce) render the incoming one at its remembered
        /// position (or the top on first visit).
        func switchDocument(to documentID: UUID?, positionKey: String?, markdown: String, baseURL: URL?, options: MarkdownRenderOptions) {
            currentDocumentID = documentID
            renderDebounce?.cancel()
            guard let webView else { return }

            let render = { [weak self] in
                guard let self, self.currentDocumentID == documentID, let webView = self.webView else { return }
                let html = self.renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
                self.lastSource = markdown
                self.lastOptions = options
                self.pendingScrollY = self.beginDisplaying(documentID, positionKey: positionKey)
                self.load(html, into: webView, baseURL: baseURL)
            }

            // Filed under the page actually on screen: keyed by the outgoing
            // id, a fast A→B→C switch put A's offset under B, which never
            // rendered. Not captured from a page that is still loading.
            if let outgoingKey = displayedKey, loadingNavigation == nil {
                webView.evaluateJavaScript("window.scrollY") { value, _ in
                    if let y = value as? Double { AppState.shared?.recordReadingPosition(y, forKey: outgoingKey) }
                    render()
                }
            } else {
                render()
            }
        }

        /// First page of a new preview (a relaunch, the first document after
        /// the welcome screen), opened at its remembered position too.
        func loadFirstPage(_ html: String, documentID: UUID?, positionKey: String?, baseURL: URL?) {
            guard let webView else { return }
            pendingScrollY = beginDisplaying(documentID, positionKey: positionKey)
            load(html, into: webView, baseURL: baseURL)
        }

        /// A renamed or moved file keeps its document but changes key: once
        /// its page is the one on screen, file the position under the new key.
        func updatePositionKey(_ positionKey: String?, for documentID: UUID?) {
            guard displayedDocumentID == documentID, displayedKey != positionKey else { return }
            displayedKey = positionKey
        }

        /// Marks `documentID`'s page as the one on screen and returns its
        /// remembered offset (0, the top, on a first visit).
        private func beginDisplaying(_ documentID: UUID?, positionKey: String?) -> Double {
            displayedDocumentID = documentID
            displayedKey = positionKey
            return positionKey.flatMap { AppState.shared?.readingPosition(forKey: $0) } ?? 0
        }

        /// Debounces preview rebuilds and restores the prior scroll offset, so
        /// typing in split view doesn't jump the preview to the top.
        func scheduleRender(markdown: String, baseURL: URL?, options: MarkdownRenderOptions) {
            renderDebounce?.cancel()
            // Capture the document this render belongs to. A DispatchWorkItem that
            // has already begun executing can't be cancelled, and its async
            // evaluateJavaScript completion can fire after a tab switch — so both
            // the work item and the completion re-check the id and bail if the
            // document changed, preventing the old note from clobbering the new one.
            let docID = currentDocumentID
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.currentDocumentID == docID, let webView = self.webView else { return }
                let html = self.renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
                self.lastSource = markdown
                self.lastOptions = options
                webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                    guard let self, self.currentDocumentID == docID, let webView = self.webView else { return }
                    self.pendingScrollY = (value as? Double) ?? 0
                    self.load(html, into: webView, baseURL: baseURL)
                }
            }
            renderDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        /// Loads HTML with the pending scroll offset injected so restoration
        /// happens at DOMContentLoaded — before first paint. The didFinish
        /// fallback stays for slow subresource layouts, but the top-of-page
        /// flash per re-render is gone.
        func load(_ html: String, into webView: WKWebView, baseURL: URL?) {
            var html = html
            if pendingScrollY > 0, pendingHeadingSlug == nil {
                // Nonce'd so the page CSP runs it; lands in the renderer's head only.
                html = MarkdownRenderer.insertingHeadScript(
                    "addEventListener('DOMContentLoaded',function(){window.scrollTo(0,\(pendingScrollY));});",
                    into: html
                )
            }
            pageBaseURL = baseURL
            loadingNavigation = webView.loadHTMLString(html, baseURL: baseURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if navigation === loadingNavigation { loadingNavigation = nil }
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
            // on a page still loading (or not yet swapped in) the jump was lost,
            // or the restored reading position overrode it.
            if loadingNavigation != nil || displayedDocumentID != currentDocumentID {
                pendingHeadingSlug = slug
                pendingScrollY = 0
                return
            }
            runHeadingScroll(slug)
        }

        private func runHeadingScroll(_ slug: String) {
            let escaped = slug.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var el = document.getElementById('\(escaped)');
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            })();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        private func scrollToFraction(_ fraction: Double) {
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

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Handlers are exposed to every frame; only the rendered page itself
            // may edit the document.
            guard message.name == "cmdmd",
                  message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            // Only the active note's own, settled page may edit it: during a tab
            // switch the outgoing page stays clickable until the new one loads,
            // and a click there flipped the same line of the new note.
            if type == "toggleTask",
               let line = body["line"] as? Int,
               loadingNavigation == nil, displayedDocumentID == currentDocumentID {
                let checked = body["checked"] as? Bool ?? true
                let rendered = lastSource.components(separatedBy: "\n")
                let expected = line >= 1 && line <= rendered.count ? rendered[line - 1] : nil
                AppState.shared?.toggleTask(atLine: line, checked: checked, expectedLine: expected)
            }

            // Reading position from scrollReportScript. While a page loads, a
            // report can still come from the page it replaces: dropped.
            if type == "scroll", message.frameInfo.isMainFrame,
               let y = body["y"] as? Double,
               loadingNavigation == nil, let key = displayedKey {
                AppState.shared?.recordReadingPosition(y, forKey: key)
            }
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
                pageURL: PreviewNavigationPolicy.pageURL(forBaseURL: pageBaseURL)
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
