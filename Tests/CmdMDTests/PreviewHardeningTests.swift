import SwiftUI
import WebKit
import XCTest
@testable import CmdMD

/// What a note's raw HTML may not take from the page: its task boxes'
/// ordinals, and the names `document` exposes elements by.
final class RawHTMLPageAttributeTests: XCTestCase {
    func testANotesCheckboxCannotNameATask() {
        let clean = RawHTMLSanitizer.sanitize(#"<input type="checkbox" data-task="0" DATA-TASK=1 data-tasks="x" checked>"#)
        XCTAssertFalse(clean.lowercased().contains("data-task="), clean)
        XCTAssertTrue(clean.contains(#"data-tasks="x""#), "only the page's own attribute goes: \(clean)")
        XCTAssertTrue(clean.contains("type=\"checkbox\"") && clean.contains("checked"), clean)
    }

    func testTheRenderersTaskBoxesKeepTheirOrdinal() {
        let page = MarkdownRenderer().renderToHTML(markdown: "- [ ] one\n- [x] two\n\n<input type=\"checkbox\" data-task=\"0\">\n")
        let html = String(page[page.range(of: "<body")!.lowerBound...])
        XCTAssertTrue(html.contains("data-task=\"0\""))
        XCTAssertTrue(html.contains("data-task=\"1\""))
        XCTAssertEqual(html.components(separatedBy: "data-task=").count - 1, 2, "the note's box carries none")
    }

    func testElementsDocumentExposesByNameLoseTheName() {
        for tag in ["img", "IMG", "form", "iframe"] {
            let clean = RawHTMLSanitizer.sanitize("<\(tag) name=\"querySelectorAll\" id=\"keep\" alt=\"\"></\(tag)>")
            XCTAssertFalse(clean.lowercased().contains("name="), clean)
            XCTAssertTrue(clean.contains("id=\"keep\""), clean)
        }
        // Not exposed on document: their names stay (anchors, image maps, form fields).
        for html in [#"<a name="top">"#, #"<map name="m">"#, #"<input name="q">"#, #"<meta-data name="x">"#] {
            XCTAssertTrue(RawHTMLSanitizer.sanitize(html).contains("name="), html)
        }
    }
}

/// Real mouse clicks on boxes and labels a note writes.
final class ForgedTaskBoxHostedTests: AppStatePreviewTestCase {
    @MainActor
    private func record(_ webView: WKWebView) {
        _ = run("""
            window.__seen = [];
            document.addEventListener('click', e => window.__seen.push('click ' + e.target.tagName), true);
            document.addEventListener('change', e => window.__seen.push('change ' + e.target.tagName), true);
            return true;
            """, in: webView)
    }

    @MainActor
    private func seen(_ webView: WKWebView) -> [String] {
        run("return window.__seen;", in: webView) as? [String] ?? []
    }

    /// A box in the note's text naming task 0, clicked.
    @MainActor
    func testANoteCheckboxNamingATaskFlipsNothing() throws {
        let note = """
            - [ ] real task zero
            - [ ] real task one

            I agree <input type="checkbox" data-task="0" id="forged"> to the terms.
            """
        let state = AppState()
        let webView = try mount(state, note: note)
        record(webView)
        let box = try center(of: "input#forged", in: webView)
        mouseClick(webView, x: box.x, y: box.y)
        XCTAssertTrue(seen(webView).contains("change INPUT"), "the click reached the box: \(seen(webView))")
        XCTAssertEqual(state.currentDocument?.content, note)
    }

    /// A hidden box naming task 1 inside a label over the whole window: a
    /// click anywhere.
    @MainActor
    func testAWholeWindowLabelAroundANoteBoxFlipsNothing() throws {
        let note = """
            - [ ] pay the invoice
            - [ ] second task

            Some text.

            <label style="position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:99"><input type="checkbox" data-task="1" style="display:none"></label>
            """
        let state = AppState()
        let webView = try mount(state, note: note)
        record(webView)
        mouseClick(webView, x: 500, y: 400)
        XCTAssertTrue(seen(webView).contains("click LABEL"), "the click hit the label: \(seen(webView))")
        XCTAssertEqual(state.currentDocument?.content, note)
    }

    /// The note's label wraps its own task list: a click on the label (far
    /// from any box) handed the first box a click of its own.
    @MainActor
    func testALabelAroundTheTaskListFlipsNothingButTheBoxItselfStillDoes() throws {
        let note = """
            <label style="position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:99;display:block">

            - [ ] pay the invoice
            - [ ] second task

            </label>

            Some text.
            """
        let state = AppState()
        let webView = try mount(state, note: note)
        record(webView)
        XCTAssertEqual(run("return document.querySelector('label input[data-task]') !== null;", in: webView) as? Bool, true,
                       "the renderer's boxes are inside the note's label")
        mouseClick(webView, x: 500, y: 400)
        XCTAssertTrue(seen(webView).contains("click LABEL"), "the click hit the label: \(seen(webView))")
        XCTAssertFalse(seen(webView).contains("change INPUT"), "\(seen(webView))")
        XCTAssertEqual(state.currentDocument?.content, note)

        let box = try center(of: "input[data-task=\"1\"]", in: webView)
        mouseClick(webView, x: box.x, y: box.y)
        XCTAssertEqual(state.currentDocument?.content, note.replacingOccurrences(of: "- [ ] second task", with: "- [x] second task"),
                       "a click on the box itself")
    }

    /// The plain case, with a real click: the box flips its task.
    @MainActor
    func testARealClickOnATaskBoxFlipsIt() throws {
        let note = "Intro\n\n- [ ] alpha\n- [ ] beta\n"
        let state = AppState()
        let webView = try mount(state, note: note)
        let box = try center(of: "input[data-task=\"1\"]", in: webView)
        mouseClick(webView, x: box.x, y: box.y)
        XCTAssertEqual(state.currentDocument?.content, "Intro\n\n- [ ] alpha\n- [x] beta\n")
    }
}

/// Elements named like the DOM's methods: the page's scripts still run,
/// and edits still patch.
final class ClobberedDocumentHostedTests: PreviewPageTestCase {
    @Observable
    final class Model {
        var documentID = UUID()
        var markdown = ""
        var options = MarkdownRenderOptions()
    }

    private struct Harness: View {
        let model: Model
        var body: some View {
            MarkdownPreviewView(documentID: model.documentID, positionKey: nil, source: PreviewSource(model.markdown),
                                baseURL: nil, options: model.options, scrollSyncEnabled: false, zoom: 1)
        }
    }

    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?
    private var loadWatcher: HostedTypingBenchmarkTests.LoadWatcher?
    private var loads: Int { loadWatcher?.finished ?? 0 }

    override func tearDownWithError() throws {
        loadWatcher = nil
        host?.rootView = AnyView(EmptyView())
        spin(0.05)
        window?.close()
        window = nil
        host = nil
        try super.tearDownWithError()
    }

    @MainActor
    private func mountPreview(_ model: Model) throws -> WKWebView {
        let hosting = NSHostingView(rootView: AnyView(Harness(model: model)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        hosting.layoutSubtreeIfNeeded()
        spin(0.05)
        self.window = window
        host = hosting
        let webView = try XCTUnwrap(R3bFocusHostedTestCase.find(PreviewWebView.self, in: hosting))
        // A small page can finish before the watcher is up: counted from here.
        loadWatcher = HostedTypingBenchmarkTests.LoadWatcher(webView)
        let loaded = "return !!Document.prototype.getElementById.call(document, 'cmdmd-root');"
        waitUntil(timeout: 30) { !webView.isLoading && run(loaded, in: webView) as? Bool == true }
        try XCTSkipUnless(run(loaded, in: webView) as? Bool == true, "the page did not load in this environment")
        try settle(webView)
        return webView
    }

    /// The page's own state, read through the DOM's prototypes.
    private static let probe = """
        const all = s => Element.prototype.querySelectorAll.call(document.documentElement, s);
        const settled = await Promise.race([Promise.resolve(window.cmdmdDiagrams).then(() => true),
                                            new Promise(r => setTimeout(() => r(false), 5000))]);
        return {settled: settled, drawn: all('.cmdmd-diagram svg').length, katex: all('.cmdmd-math .katex').length,
                hljs: all('pre code.hljs').length, text: all('#cmdmd-root')[0].textContent};
        """

    @MainActor
    func testAnImageNamedLikeADocumentMethodLeavesTheLibrariesRunning() throws {
        let model = Model()
        model.options.enableKaTeX = true
        model.markdown = """
            <img name="querySelectorAll" alt="">

            <img name="createElement" alt="">

            # Title

            Math $a^2$ here.

            ```swift
            let x = 1
            ```

            ```mermaid
            flowchart LR
                A --> B
            ```
            """
        let webView = try mountPreview(model)
        let state = try XCTUnwrap(run(Self.probe, in: webView, timeout: 20) as? [String: Any])
        XCTAssertEqual(state["settled"] as? Bool, true, "\(state)")
        XCTAssertEqual(state["drawn"] as? Int, 1, "\(state)")
        XCTAssertEqual(state["katex"] as? Int, 1, "\(state)")
        XCTAssertEqual(state["hljs"] as? Int, 1, "\(state)")
    }

    @MainActor
    func testEditsPatchWithAnImageNamedGetElementById() throws {
        let model = Model()
        model.markdown = "first\n\n<img name=\"getElementById\" alt=\"\">\n\nlast 0\n"
        let webView = try mountPreview(model)
        let start = loads
        for i in 1...3 {
            model.markdown = "first\n\n<img name=\"getElementById\" alt=\"\">\n\nlast \(i)\n"
            try settle(webView, showing: "last \(i)")
        }
        XCTAssertEqual(loads, start, "patched, not reloaded")
    }

    /// A form's controls answer the form's own properties by name.
    @MainActor
    func testEditsPatchAroundAFormWhoseControlsShadowNodeProperties() throws {
        let form = "<form><input name=\"nextSibling\"><input name=\"matches\"><input name=\"getBoundingClientRect\"><input name=\"remove\"></form>"
        let filler = (0..<40).map { "Paragraph \($0) " + String(repeating: "words ", count: 20) }.joined(separator: "\n\n")
        let model = Model()
        model.markdown = "top 0\n\n\(form)\n\n\(filler)\n\nend 0\n"
        let webView = try mountPreview(model)
        let start = loads
        // The reader below the form, so the patch looks for its place.
        _ = run("window.scrollTo(0, 600); return true;", in: webView)
        spin(0.2)
        for i in 1...2 {
            model.markdown = "top \(i)\n\n\(form)\n\n\(filler)\n\nend \(i)\n"
            try settle(webView, showing: "end \(i)")
        }
        model.markdown = "top 2\n\n\(form.replacingOccurrences(of: "<form>", with: "<form class=\"edited\">"))\n\n\(filler)\n\nend 2\n"
        try settle(webView)
        spin(0.3)
        XCTAssertEqual(loads, start, "patched, not reloaded")
        let state = run("""
            const all = s => Element.prototype.querySelectorAll.call(document.documentElement, s);
            return {forms: all('form').length, edited: all('form.edited input').length, top: all('#cmdmd-root > p')[0].textContent};
            """, in: webView) as? [String: Any]
        XCTAssertEqual(state?["forms"] as? Int, 1, "\(state ?? [:])")
        XCTAssertEqual(state?["edited"] as? Int, 4, "\(state ?? [:])")
        XCTAssertEqual(state?["top"] as? String, "top 2", "\(state ?? [:])")
    }
}
