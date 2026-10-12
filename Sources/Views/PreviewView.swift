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

struct MarkdownPreviewView: NSViewRepresentable {
    /// Identity of the previewed document; a change means a tab switch, which
    /// renders immediately and resets scroll (vs. debounced live typing updates).
    let documentID: UUID?
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.pageZoom = zoom
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

        let html = context.coordinator.renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
        context.coordinator.lastSource = markdown
        context.coordinator.lastOptions = options
        context.coordinator.currentDocumentID = documentID
        webView.loadHTMLString(html, baseURL: baseURL)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.scrollSyncEnabled = scrollSyncEnabled

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
                to: documentID, markdown: markdown, baseURL: baseURL, options: options
            )
            return
        }

        guard context.coordinator.lastSource != markdown || context.coordinator.lastOptions != options else {
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
        /// Last known reading position per document, so tab switches restore
        /// where the user left off instead of resetting to the top.
        private var savedScrollPositions: [UUID: Double] = [:]
        private var renderDebounce: DispatchWorkItem?
        private var observers: [NSObjectProtocol] = []

        override init() {
            super.init()
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
        func switchDocument(to documentID: UUID?, markdown: String, baseURL: URL?, options: MarkdownRenderOptions) {
            let outgoingID = currentDocumentID
            currentDocumentID = documentID
            renderDebounce?.cancel()
            guard let webView else { return }

            let render = { [weak self] in
                guard let self, self.currentDocumentID == documentID, let webView = self.webView else { return }
                let html = self.renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
                self.lastSource = markdown
                self.lastOptions = options
                self.pendingScrollY = documentID.flatMap { self.savedScrollPositions[$0] } ?? 0
                self.load(html, into: webView, baseURL: baseURL)
            }

            if let outgoingID {
                webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                    if let y = value as? Double { self?.savedScrollPositions[outgoingID] = y }
                    render()
                }
            } else {
                render()
            }
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
        private func load(_ html: String, into webView: WKWebView, baseURL: URL?) {
            var html = html
            if pendingScrollY > 0 {
                let restore = "<script>addEventListener('DOMContentLoaded',function(){window.scrollTo(0,\(pendingScrollY));});</script></head>"
                html = html.replacingOccurrences(of: "</head>", with: restore)
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if pendingScrollY > 0 {
                webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollY));", completionHandler: nil)
                pendingScrollY = 0
            }
        }

        private func scrollToHeadingSlug(_ slug: String) {
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
            guard message.name == "cmdmd",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            if type == "toggleTask",
               let line = body["line"] as? Int {
                let checked = body["checked"] as? Bool ?? true
                AppState.shared?.toggleTask(atLine: line, checked: checked)
            }
        }

        // MARK: Navigation policy

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .allow
            }

            if url.scheme == "cmdmd" {
                NotificationCenter.default.post(name: .openInternalLink, object: url)
                return .cancel
            }

            if url.scheme == "obsidian" {
                NSWorkspace.shared.open(url)
                return .cancel
            }

            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                return .cancel
            }

            // A clicked relative link to another note opens in the app instead
            // of rendering the raw file inside the preview WebView.
            if navigationAction.navigationType == .linkActivated, url.isFileURL {
                let ext = url.pathExtension.lowercased()
                if ["md", "markdown", "txt"].contains(ext) {
                    Task { @MainActor in
                        AppState.shared?.openDocument(at: url, inNewTab: true)
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }

            return .allow
        }
    }
}
