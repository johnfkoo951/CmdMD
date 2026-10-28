import SwiftUI
import WebKit
import XCTest
@testable import CmdMD

/// The parts of preview scheduling that need no web view: the render thread,
/// the debounce, the page cache and its nonce refresh, the text input.
final class PreviewSchedulingTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int] = []
        var values: [Int] { lock.withLock { items } }
        func append(_ value: Int) { lock.withLock { items.append(value) } }
    }

    // MARK: Render thread

    func testRendersRunInOrderOffTheMainThread() {
        let calls = Calls()
        let owners = (0..<4).map { _ in NSObject() }
        let done = expectation(description: "rendered")
        done.expectedFulfillmentCount = owners.count
        for (index, owner) in owners.enumerated() {
            PreviewRenderThread.shared.enqueue(for: owner) {
                XCTAssertFalse(Thread.isMainThread)
                calls.append(index)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls.values, [0, 1, 2, 3])
    }

    func testOnlyAPreviewsNewestWaitingRenderRuns() {
        let calls = Calls()
        let gate = DispatchSemaphore(value: 0)
        let blocker = NSObject()
        let preview = NSObject()
        PreviewRenderThread.shared.enqueue(for: blocker) { gate.wait() }
        PreviewRenderThread.shared.enqueue(for: preview) { calls.append(1) }
        PreviewRenderThread.shared.enqueue(for: preview) { calls.append(2) }
        let cancelled = NSObject()
        PreviewRenderThread.shared.enqueue(for: cancelled) { calls.append(3) }
        PreviewRenderThread.shared.cancel(for: cancelled)
        let done = expectation(description: "drained")
        PreviewRenderThread.shared.enqueue(for: NSObject()) { done.fulfill() }
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls.values, [2], "the superseded and the cancelled render never ran")
    }

    /// A GCD worker's 512 KB stack overflowed from 80 quote levels (release)
    /// on what the main thread renders; the render thread has the main
    /// thread's 8 MB.
    func testDeepNestingRendersOnTheRenderThread() {
        let quotes = String(repeating: ">", count: 600) + " deep - [ ] task\n"
        let lists = (0..<200).map { String(repeating: "  ", count: $0) + "- [ ] l\($0)" }.joined(separator: "\n")
        var pages: [String] = []
        let done = expectation(description: "rendered")
        PreviewRenderThread.shared.enqueue(for: NSObject()) {
            let renderer = MarkdownRenderer()
            let rendered = [quotes, lists].map { renderer.renderToHTML(markdown: $0) }
            DispatchQueue.main.async {
                pages = rendered
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(pages.first?.components(separatedBy: "<blockquote>").count, 601)
        XCTAssertEqual(pages.last?.components(separatedBy: "data-task=\"").count, 201)
    }

    // MARK: Debounce

    func testDebounceFollowsTheRefreshCost() {
        var debounce = PreviewDebounce()
        XCTAssertEqual(debounce.delay, 0.25, "until a refresh was measured")
        debounce.record(refreshMs: 2)
        XCTAssertEqual(debounce.delay, 0.04, accuracy: 1e-9, "small notes refresh as you type")
        debounce.record(refreshMs: 60)
        XCTAssertEqual(debounce.delay, 0.09, accuracy: 1e-9)
        debounce.record(refreshMs: 400)
        XCTAssertEqual(debounce.delay, 0.25, accuracy: 1e-9, "never longer than before")
    }

    // MARK: Page cache

    private func nonces(in html: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"nonce(?:-|=")([0-9A-F]{32})"#)
        let ns = html as NSString
        return Set(regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    private func page(_ source: String, options: MarkdownRenderOptions = MarkdownRenderOptions(), generation: Int = 1) -> PreviewPage {
        PreviewPage(rendered: MarkdownRenderer().renderPage(markdown: source, options: options), source: source,
                    baseURL: nil, options: options, generation: generation, renderMs: 1)
    }

    func testRefreshedNonceReplacesTheHeadsOnly() throws {
        var options = MarkdownRenderOptions()
        options.enableKaTeX = true
        let html = MarkdownRenderer().renderToHTML(markdown: "```swift\nlet x = 1\n```\n\n$a$\n\n```mermaid\nflowchart LR\nA-->B\n```", options: options)
        let old = try XCTUnwrap(nonces(in: html).first)
        XCTAssertEqual(nonces(in: html), [old], "one nonce per page")
        // A note can't know its page's nonce, but one quoting an old page's
        // source keeps its text.
        let quoting = html.replacingOccurrences(of: "<body class=\"markdown-body\">", with: "<body class=\"markdown-body\">\(old)")

        let refreshed = MarkdownRenderer.refreshingNonce(in: quoting)
        let fresh = try XCTUnwrap(nonces(in: refreshed).first)
        XCTAssertEqual(nonces(in: refreshed), [fresh])
        XCTAssertNotEqual(fresh, old)
        let head = { (page: String) in String(page[..<page.range(of: "</head>")!.lowerBound]) }
        XCTAssertEqual(head(refreshed), head(html).replacingOccurrences(of: old, with: fresh))
        XCTAssertTrue(refreshed.hasSuffix(String(quoting[quoting.range(of: "</head>")!.lowerBound...])), "the body is untouched")
    }

    func testCacheHitsOnlyTheSameTextAndSettings() throws {
        var cache = PreviewPageCache()
        let id = UUID()
        let stored = page("# A\n\ntext")
        cache.store(stored, for: id)

        let hit = try XCTUnwrap(cache.page(for: id, source: "# A\n\ntext", baseURL: nil, options: MarkdownRenderOptions(), generation: 7))
        XCTAssertEqual(hit.generation, 7)
        XCTAssertNil(hit.renderMs, "costs no render")
        XCTAssertNotEqual(nonces(in: hit.html), nonces(in: stored.html), "a fresh nonce per load")
        XCTAssertNotEqual(nonces(in: try XCTUnwrap(cache.page(for: id, source: "# A\n\ntext", baseURL: nil, options: MarkdownRenderOptions(), generation: 8)).html),
                          nonces(in: hit.html))

        XCTAssertNil(cache.page(for: id, source: "# A\n\ntext!", baseURL: nil, options: MarkdownRenderOptions(), generation: 9))
        XCTAssertNil(cache.page(for: id, source: "# A\n\ntexT", baseURL: nil, options: MarkdownRenderOptions(), generation: 9), "same length")
        var dark = MarkdownRenderOptions()
        dark.theme = .darkPro
        XCTAssertNil(cache.page(for: id, source: "# A\n\ntext", baseURL: nil, options: dark, generation: 9))
        XCTAssertNil(cache.page(for: id, source: "# A\n\ntext", baseURL: URL(fileURLWithPath: "/tmp"), options: MarkdownRenderOptions(), generation: 9))
        XCTAssertNil(cache.page(for: UUID(), source: "# A\n\ntext", baseURL: nil, options: MarkdownRenderOptions(), generation: 9))
        XCTAssertNil(cache.page(for: nil, source: "# A\n\ntext", baseURL: nil, options: MarkdownRenderOptions(), generation: 9))
    }

    func testCacheKeepsTheMostRecentlyShownNotes() {
        var cache = PreviewPageCache(limit: 2)
        let ids = (0..<3).map { _ in UUID() }
        cache.store(page("a"), for: ids[0])
        cache.store(page("b"), for: ids[1])
        XCTAssertNotNil(cache.page(for: ids[0], source: "a", baseURL: nil, options: MarkdownRenderOptions(), generation: 2), "now the most recent")
        cache.store(page("c"), for: ids[2])
        XCTAssertNil(cache.page(for: ids[1], source: "b", baseURL: nil, options: MarkdownRenderOptions(), generation: 3), "the oldest went")
        XCTAssertNotNil(cache.page(for: ids[0], source: "a", baseURL: nil, options: MarkdownRenderOptions(), generation: 3))
        cache.store(page("a2"), for: ids[0])
        XCTAssertNil(cache.page(for: ids[0], source: "a", baseURL: nil, options: MarkdownRenderOptions(), generation: 4), "one page per note")
    }

    // MARK: Text input

    func testPreviewSourceEquality() {
        XCTAssertEqual(PreviewSource("abc"), PreviewSource("abc"))
        XCTAssertNotEqual(PreviewSource("abc"), PreviewSource("abcd"))
        XCTAssertNotEqual(PreviewSource("abc"), PreviewSource("abd"), "same length: compared in full")
        XCTAssertNotEqual(PreviewSource("\u{E9}"), PreviewSource("e\u{301}"), "renders differently, so not equal")
    }
}

/// The preview's scheduling through the real view, coordinator and WebKit:
/// pages render on the render thread and only the current note's newest
/// page reaches the screen.
final class PreviewSchedulingHostedTests: R3bFocusHostedTestCase {
    @Observable
    final class Model {
        var documentID = UUID()
        var markdown = ""
        var zoom = 1.0
    }

    private struct Harness: View {
        let model: Model
        var body: some View {
            MarkdownPreviewView(
                documentID: model.documentID,
                positionKey: nil,
                source: PreviewSource(model.markdown),
                baseURL: nil,
                options: MarkdownRenderOptions(),
                scrollSyncEnabled: false,
                zoom: model.zoom
            )
        }
    }

    @MainActor
    private func mountHarness(_ model: Model) throws -> WKWebView {
        let hosting = mount(Harness(model: model))
        return try XCTUnwrap(Self.find(PreviewWebView.self, in: hosting))
    }

    /// Evaluates `script` once no load is running; nil when the page never
    /// answered here.
    @MainActor
    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var answer: Any?
        var answered = false
        webView.evaluateJavaScript(script) { value, _ in
            answer = value
            answered = true
        }
        waitUntil(timeout: 5) { answered }
        return answer
    }

    @MainActor
    private func waitForText(_ text: String, in webView: WKWebView, timeout: TimeInterval = 10) -> String? {
        var shown: String?
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            spin(0.02)
            if !webView.isLoading { shown = evaluate("document.body ? document.body.innerText : ''", in: webView) as? String }
        } while shown?.contains(text) != true && Date() < deadline
        return shown
    }

    /// Returns once every render queued so far has run and whatever page it
    /// brought has loaded.
    @MainActor
    private func settle(_ webView: WKWebView) {
        var drained = false
        PreviewRenderThread.shared.enqueue(for: NSObject()) {
            DispatchQueue.main.async { drained = true }
        }
        waitUntil(timeout: 60) { drained }
        spin(0.3)
        waitUntil(timeout: 10) { !webView.isLoading }
    }

    @MainActor
    private func nonce(in webView: WKWebView) -> String? {
        evaluate("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content.match(/'nonce-([^']+)'/)[1]", in: webView) as? String
    }

    @MainActor
    func testDeepNestingThroughThePreview() throws {
        let model = Model()
        model.markdown = String(repeating: ">", count: 600) + " deep\n"
        let webView = try mountHarness(model)
        let shown = waitForText("deep", in: webView)
        try XCTSkipUnless(shown != nil, "the page did not load in this environment")
        XCTAssertEqual(evaluate("document.querySelectorAll('blockquote').length", in: webView) as? Int, 600)
    }

    /// Identical updates (a zoom step, a mode switch) keep arriving while
    /// the edit renders: they must not start it over.
    @MainActor
    func testUpdatesWithTheSameTextDontRestartTheRender() throws {
        let model = Model()
        model.markdown = "first"
        let webView = try mountHarness(model)
        try XCTSkipUnless(waitForText("first", in: webView)?.contains("first") == true, "the page did not load in this environment")

        model.markdown = "second"
        let deadline = Date().addingTimeInterval(4)
        var shown = ""
        var step = 0
        while !shown.contains("second"), Date() < deadline {
            model.zoom = model.zoom == 1 ? 1.01 : 1
            spin(0.01)
            step += 1
            if step % 10 == 0 { shown = evaluate("document.body.innerText", in: webView) as? String ?? "" }
        }
        XCTAssertTrue(shown.contains("second"), "rendered while updates kept coming")
    }

    /// A note whose render is still running when the user flips to a cached
    /// one: the cached page shows (under a new nonce) and stays.
    @MainActor
    func testSlowRenderOfAnOutgoingNoteNeverReplacesTheCurrentOne() throws {
        let model = Model()
        let b = model.documentID
        model.markdown = "note B"
        let webView = try mountHarness(model)
        try XCTSkipUnless(waitForText("note B", in: webView)?.contains("note B") == true, "the page did not load in this environment")
        let firstNonce = nonce(in: webView)

        model.documentID = UUID()
        model.markdown = "note C"
        XCTAssertEqual(waitForText("note C", in: webView)?.contains("note C"), true)

        // A long note renders for a while, off the main thread.
        model.documentID = UUID()
        model.markdown = "note A\n\n" + String(repeating: "Paragraph with **bold**, `code` and [[link]].\n\n", count: 20_000)
        spin(0.1)
        model.documentID = b
        model.markdown = "note B"
        let shown = waitForText("note B", in: webView)
        XCTAssertEqual(shown?.contains("note B"), true)
        settle(webView)
        let settled = evaluate("document.body.innerText", in: webView) as? String
        XCTAssertEqual(settled?.contains("note B"), true, "the outgoing note's late page was dropped")
        XCTAssertEqual(settled?.contains("note A"), false)
        XCTAssertNotNil(firstNonce)
        XCTAssertNotEqual(nonce(in: webView), firstNonce, "the cached page loaded under a fresh nonce")
    }
}
