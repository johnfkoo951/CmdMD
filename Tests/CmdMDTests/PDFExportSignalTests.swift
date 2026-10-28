import WebKit
import XCTest
@testable import CmdMD

/// PDF export prints when the page says it is drawn, not after a fixed wait.
final class PDFExportSignalTests: CheckoutLibrariesTestCase {
    private func render(_ markdown: String, reportsRendered: Bool) -> String {
        var options = MarkdownRenderOptions()
        options.enableKaTeX = true
        options.interactiveTasks = false
        options.reportsRendered = reportsRendered
        return MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
    }

    // MARK: When to print

    func testPrintsOnceLoadedAndReported() {
        var gate = PrintGate()
        XCTAssertFalse(gate.shouldPrint(after: .loaded))
        XCTAssertTrue(gate.shouldPrint(after: .rendered))
        XCTAssertFalse(gate.shouldPrint(after: .timedOut), "only once")
        XCTAssertFalse(gate.shouldPrint(after: .loaded))
    }

    func testAReportBeforeTheLoadWaitsForIt() {
        var gate = PrintGate()
        XCTAssertFalse(gate.shouldPrint(after: .rendered))
        XCTAssertTrue(gate.shouldPrint(after: .loaded))
    }

    func testTimesOutWithoutAReport() {
        var gate = PrintGate()
        XCTAssertFalse(gate.shouldPrint(after: .loaded))
        XCTAssertTrue(gate.shouldPrint(after: .timedOut))
        XCTAssertFalse(gate.shouldPrint(after: .rendered), "a late report prints nothing twice")
    }

    // MARK: The page's report

    func testOnlyPagesForPDFReport() {
        XCTAssertFalse(render("text", reportsRendered: false).contains(MarkdownRenderer.renderedMessage))
        let html = render("text", reportsRendered: true)
        XCTAssertTrue(html.contains("window.webkit.messageHandlers.\(MarkdownRenderer.renderedMessage).postMessage('rendered')"))
        XCTAssertTrue(html.contains("Promise.all([window.cmdmdDiagrams, document.fonts.ready])"))
        XCTAssertNotEqual(MarkdownRenderer.renderedMessage, "cmdmd", "not the preview's task handler")
    }

    /// Loads `markdown`'s PDF page in the export view and returns what had
    /// drawn when the page reported, or nil if it never loaded here.
    private func drawnWhenReported(_ markdown: String) throws -> [String: Any]? {
        final class Recorder: NSObject, WKScriptMessageHandler {
            var reports = 0
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                if message.frameInfo.isMainFrame { reports += 1 }
            }
        }
        let webView = PDFExporter.makeWebView(assetRoots: [])
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        let recorder = Recorder()
        webView.configuration.userContentController.add(recorder, name: MarkdownRenderer.renderedMessage)
        defer {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: MarkdownRenderer.renderedMessage)
            window.close()
        }
        webView.loadHTMLString(render(markdown, reportsRendered: true), baseURL: nil)

        let deadline = Date().addingTimeInterval(15)
        while recorder.reports == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard recorder.reports > 0 else { return nil }

        var state: [String: Any]?
        webView.evaluateJavaScript("""
            ({code: document.querySelectorAll('pre code').length,
              highlighted: document.querySelectorAll('pre code.hljs').length,
              math: document.querySelectorAll('.cmdmd-math').length,
              typeset: document.querySelectorAll('.cmdmd-math .katex').length,
              diagrams: document.querySelectorAll('.cmdmd-diagram').length,
              drawn: document.querySelectorAll('.cmdmd-diagram svg.pele').length})
            """) { value, _ in state = value as? [String: Any] ?? [:] }
        while state == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(recorder.reports, 1)
        return state
    }

    func testWebKitReportsOnceHighlightingMathAndDiagramsAreDone() throws {
        let page = try drawnWhenReported("""
        ```swift
        let x = 1
        ```

        Math $e^{i\\pi} + 1 = 0$.

        ```mermaid
        flowchart LR
            A --> B
        ```

        ```mermaid
        sequenceDiagram
            A->>B: hi
        ```
        """)
        let state = try XCTUnwrap(page, "the page did not load in this environment")
        XCTAssertEqual(state["highlighted"] as? Int, state["code"] as? Int)
        XCTAssertEqual(state["typeset"] as? Int, 1)
        XCTAssertEqual(state["diagrams"] as? Int, 2)
        XCTAssertEqual(state["drawn"] as? Int, 2)
    }

    func testWebKitReportsAPageWithNothingToDraw() throws {
        let state = try XCTUnwrap(try drawnWhenReported("# Plain\n\ntext"), "the page did not load in this environment")
        XCTAssertEqual(state["diagrams"] as? Int, 0)
    }
}
