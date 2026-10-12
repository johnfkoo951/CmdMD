import Foundation
import AppKit
import WebKit

final class ExportService {
    private let renderer = MarkdownRenderer()
    /// PDF rendering is async; exporters must stay alive until their WebView
    /// finishes, so they're retained here for the duration.
    private var activePDFExporters: [ObjectIdentifier: PDFExporter] = [:]

    func exportToHTML(document: MarkdownDocument, options: MarkdownRenderOptions) -> String {
        // Image sources stay note-relative so the file works outside the app.
        var exportOptions = options
        exportOptions.localAssetRoots = nil
        return renderExport(document: document, options: exportOptions)
    }

    private func renderExport(document: MarkdownDocument, options: MarkdownRenderOptions) -> String {
        // Exports are static artifacts — interactive checkboxes can't post back.
        var exportOptions = options
        exportOptions.interactiveTasks = false
        return renderer.renderToHTML(
            markdown: document.content,
            baseURL: document.fileURL?.deletingLastPathComponent(),
            options: exportOptions
        )
    }

    func saveHTML(document: MarkdownDocument, options: MarkdownRenderOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = document.displayTitle + ".html"
        panel.title = "Export as HTML"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let html = exportToHTML(document: document, options: options)

        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func savePDF(document: MarkdownDocument, options: MarkdownRenderOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.displayTitle + ".pdf"
        panel.title = "Export as PDF"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Local images keep the asset scheme here: the offscreen view, like the
        // preview, has no file:// access.
        let baseURL = document.fileURL?.deletingLastPathComponent()
        let html = renderExport(document: document, options: options)
        let exporter = PDFExporter(
            html: html,
            baseURL: baseURL,
            assetRoots: [baseURL].compactMap { $0 } + (options.localAssetRoots ?? [])
        ) { [weak self] result, exporter in
            self?.activePDFExporters.removeValue(forKey: ObjectIdentifier(exporter))
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                case .failure(let error):
                    NSAlert(error: error).runModal()
                }
            }
        }
        activePDFExporters[ObjectIdentifier(exporter)] = exporter
        exporter.start()
    }

    func copyAsHTML(document: MarkdownDocument, options: MarkdownRenderOptions) {
        let html = exportToHTML(document: document, options: options)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .html)
        NSPasteboard.general.setString(document.content, forType: .string)
    }
}

/// Renders HTML in an offscreen WebView and prints it to a paginated PDF on
/// the default paper size. Waits for the actual page load (the old fixed 0.5s
/// sleep truncated slow documents) plus a grace period for CDN-loaded extras.
final class PDFExporter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    /// Never shown. NSPrintOperation only paginates a WKWebView when run
    /// modally for a window — a plain `run()` deadlocks.
    private let window: NSWindow
    private let html: String
    private let baseURL: URL?
    private let completion: (Result<Data, Error>, PDFExporter) -> Void
    private var printing = false
    private var finished = false
    /// Temporary file the print operation saves to.
    private var outputURL: URL?
    private static let pageWidth: CGFloat = 800
    private static let margin: CGFloat = 36

    init(html: String, baseURL: URL?, assetRoots: [URL], completion: @escaping (Result<Data, Error>, PDFExporter) -> Void) {
        self.webView = Self.makeWebView(assetRoots: assetRoots)
        self.window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        self.html = html
        self.baseURL = baseURL
        self.completion = completion
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = self
    }

    /// The export view: local images through the asset scheme (no file://
    /// access here either), backgrounds printed, and pinned to the light
    /// appearance — a windowless WKWebView otherwise takes
    /// prefers-color-scheme from the system, so Dark Mode exported dark pages
    /// with light ink. Set before loading so mermaid's matchMedia check at
    /// DOMContentLoaded sees light too.
    static func makeWebView(assetRoots: [URL]) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            LocalAssetSchemeHandler(allowedRoots: { assetRoots }),
            forURLScheme: LocalAssetURL.scheme
        )
        config.preferences.shouldPrintBackgrounds = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 1000), configuration: config)
        webView.appearance = NSAppearance(named: .aqua)
        return webView
    }

    func start() {
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// Only the export page itself may load: a meta refresh in the note must
    /// not navigate the offscreen view elsewhere (or fire didFinish twice).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let decision = PreviewNavigationPolicy.decide(
            url: navigationAction.request.url,
            navigationType: navigationAction.navigationType,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            pageURL: PreviewNavigationPolicy.pageURL(forBaseURL: baseURL)
        )
        return decision == .allow ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !printing else { return }
        printing = true
        // Grace period for CDN-loaded extras (syntax highlighting, math,
        // diagrams) to settle before printing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.printToPDF()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func printToPDF() {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMD-export-\(UUID().uuidString).pdf")
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = outputURL
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = Self.margin
        info.bottomMargin = Self.margin
        info.leftMargin = Self.margin
        info.rightMargin = Self.margin

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit prints blank pages for a zero-sized print view.
        operation.view?.frame = webView.bounds
        self.outputURL = outputURL
        operation.runModal(
            for: window,
            delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let outputURL else { return }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard success, let data = try? Data(contentsOf: outputURL) else {
            finish(.failure(CocoaError(.fileWriteUnknown)))
            return
        }
        finish(.success(data))
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        completion(result, self)
    }
}
