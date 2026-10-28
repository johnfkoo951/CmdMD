import SwiftUI
import WebKit
import XCTest
@testable import CmdMD

/// A preview's page driven from a test: waits, script run in it, and
/// waiting for every render asked for to be up.
class PreviewPageTestCase: IsolatedDataDirTestCase {
    override class func setUp() {
        super.setUp()
        PreviewLibrary.installed = .checkout
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.01) }
    }

    /// Runs `body` in the page once it parsed; nil when it never answered.
    @MainActor
    func run(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView, timeout: TimeInterval = 10) -> Any? {
        var answer: Any?
        var answered = false
        func ask() {
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    answer = value
                    answered = true
                case .failure:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: ask)
                }
            }
        }
        ask()
        waitUntil(timeout: timeout) { answered }
        return answer
    }

    /// Waits until every render asked for ran and its page is up: the
    /// render thread is drained, the page holds `text`, the diagrams and
    /// fonts are in.
    @MainActor
    func settle(_ webView: WKWebView, showing text: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        var drained = false
        PreviewRenderThread.shared.enqueue(for: NSObject()) {
            DispatchQueue.main.async { drained = true }
        }
        waitUntil(timeout: 60) { drained }
        if let text {
            let deadline = Date().addingTimeInterval(10)
            var shown = false
            while !shown, Date() < deadline {
                spin(0.02)
                guard !webView.isLoading else { continue }
                shown = run("const r = document.getElementById('cmdmd-root'); return !!r && r.textContent.includes(text);",
                            arguments: ["text": text], in: webView) as? Bool == true
            }
            XCTAssertTrue(shown, "the page never showed \(text)", file: file, line: line)
        }
        spin(0.15)
        waitUntil(timeout: 10) { !webView.isLoading }
        _ = run("await Promise.all([window.cmdmdDiagrams, document.fonts.ready]); return true;", in: webView)
    }

}

/// Patches through the real view, coordinator and WebKit: what an edit
/// leaves on screen is what a fresh load of the note shows, without a load.
final class PreviewPatchHostedTests: PreviewPageTestCase {
    @Observable
    final class Model {
        var documentID = UUID()
        var markdown = ""
        var options = MarkdownRenderOptions()
    }

    private struct Harness: View {
        let model: Model
        var body: some View {
            MarkdownPreviewView(
                documentID: model.documentID,
                positionKey: nil,
                source: PreviewSource(model.markdown),
                baseURL: nil,
                options: model.options,
                scrollSyncEnabled: false,
                zoom: 1
            )
        }
    }

    private static let size = NSSize(width: 700, height: 500)
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?
    private var loadWatcher: HostedTypingBenchmarkTests.LoadWatcher?
    /// Finished page loads of the preview.
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

    // MARK: Harness

    @MainActor
    private func mount(_ view: some View) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.layoutSubtreeIfNeeded()
        spin(0.05)
        self.window = window
        host = hosting
        return hosting
    }

    /// Mounts the preview of `model` and waits for its first page.
    @MainActor
    private func mountPreview(_ model: Model) throws -> WKWebView {
        let webView = try XCTUnwrap(R3bFocusHostedTestCase.find(PreviewWebView.self, in: mount(Harness(model: model))))
        loadWatcher = HostedTypingBenchmarkTests.LoadWatcher(webView)
        waitUntil(timeout: 20) { loads > 0 && !webView.isLoading }
        try XCTSkipUnless(loads > 0, "the page did not load in this environment")
        try settle(webView)
        return webView
    }

    /// The note as the page shows it: `#cmdmd-root`'s markup (Pele's
    /// per-page ids aside), `<html lang>` and its classes.
    static let snapshotScript = """
        await Promise.all([window.cmdmdDiagrams, document.fonts.ready]);
        const root = document.getElementById('cmdmd-root');
        return {
            html: root ? root.innerHTML.replace(/pele-[a-z0-9]+-\\d+/g, 'pele-N') : null,
            lang: document.documentElement.lang,
            classes: document.documentElement.className
        };
        """

    @MainActor
    func snapshot(_ webView: WKWebView) -> [String: String]? {
        run(Self.snapshotScript, in: webView) as? [String: String]
    }

    /// A fresh load of `markdown`'s page in a web view of the preview's size.
    @MainActor
    func freshSnapshot(_ markdown: String, options: MarkdownRenderOptions) -> [String: String]? {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(PreviewLibrarySchemeHandler(), forURLScheme: PreviewLibrary.scheme)
        let webView = WKWebView(frame: NSRect(origin: .zero, size: Self.size), configuration: config)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(MarkdownRenderer().renderToHTML(markdown: markdown, options: options), baseURL: nil)
        spin(0.05)
        waitUntil(timeout: 10) { !webView.isLoading }
        return snapshot(webView)
    }

    // MARK: Fixture

    static let note = """
        # Review notes

        Intro with **bold**, `code`, [[Other note]] and a footnote[^1].

        - [ ] first task
        - [x] second task

        > [!note] Callout
        > Body of the callout.

        ```swift
        let answer = 42
        ```

        Inline math $a^2 + b^2$ here.

        $$
        E = mc^2
        $$

        ```mermaid
        flowchart LR
            A[Open] --> B[Review]
        ```

        <details>
        <summary>More</summary>

        Hidden paragraph.

        </details>

        | a | b |
        |---|---|
        | 1 | 2 |

        Closing paragraph.

        [^1]: The footnote.
        """

    static var options: MarkdownRenderOptions {
        var options = MarkdownRenderOptions()
        options.enableKaTeX = true
        return options
    }

    // MARK: Tests

    /// Random edits in bursts (some faster than a patch round trip), each
    /// burst checked against a fresh load of the same text.
    @MainActor
    func testPatchedPageMatchesAFreshLoadAfterRandomEdits() throws {
        let model = Model()
        model.options = Self.options
        model.markdown = Self.note
        let webView = try mountPreview(model)
        let start = loads

        var rng = SeededGenerator(seed: 7)
        let pool = [
            "", "New paragraph", "- [ ] new task", "- [x] done task", "## New heading", "> quoted line",
            "Text with $x^2$ math", "Some `inline code`", "한국어 문장입니다", "**bold** words", "| 3 | 4 |",
            "<div>raw html</div>", "1. ordered", "Footnote ref[^1]", "> [!tip] New callout", "---"
        ]
        var lines = Self.note.components(separatedBy: "\n")
        for burst in 0..<14 {
            let edits = 1 + Int(rng.next() % 4)
            for _ in 0..<edits {
                let index = Int(rng.next() % UInt64(lines.count))
                // Fence and HTML block lines stay, so the page keeps its
                // libraries and mostly patches.
                let fixed = ["```", "$$", "<details>", "</details>", "<summary>"].contains { lines[index].hasPrefix($0) }
                switch rng.next() % 3 {
                case 0: lines.insert(pool[Int(rng.next() % UInt64(pool.count))], at: index)
                case 1 where !fixed && lines.count > 4: lines.remove(at: index)
                default: if !fixed { lines[index] += " edit\(burst)" }
                }
                model.markdown = lines.joined(separator: "\n")
                spin(Double(rng.next() % 80) / 1000)
            }
            let sentinel = "Sentinel\(burst)"
            lines.append(sentinel)
            model.markdown = lines.joined(separator: "\n")
            try settle(webView, showing: sentinel)
            lines.removeLast()

            let shown = try XCTUnwrap(snapshot(webView))
            let fresh = try XCTUnwrap(freshSnapshot(model.markdown, options: model.options))
            XCTAssertEqual(shown["lang"], fresh["lang"], "burst \(burst)")
            XCTAssertEqual(shown["classes"], fresh["classes"], "burst \(burst)")
            if shown["html"] != fresh["html"] {
                XCTFail("burst \(burst): the page differs from a fresh load\n--- shown\n\(shown["html"] ?? "")\n--- fresh\n\(fresh["html"] ?? "")")
                break
            }
        }
        XCTAssertLessThan(loads - start, 5, "edits patch; only a page that gains a library or a callout type reloads")
    }

    /// Counts what highlight.js, KaTeX and Pele are asked to do from here
    /// on, and tags the nodes they did it to.
    static let instrumentScript = """
        window.calls = {hljs: 0, katex: 0, pele: 0};
        const count = (owner, name, key) => {
            const original = owner[name];
            owner[name] = function () { window.calls[key] += 1; return original.apply(this, arguments); };
        };
        count(window.hljs, 'highlightElement', 'hljs');
        count(window, 'renderMathInElement', 'katex');
        count(window.cmdsPele, 'mountAll', 'pele');
        document.querySelectorAll('pre code, .cmdmd-math, .cmdmd-diagram svg').forEach(el => { el.dataset.old = '1'; });
        return true;
        """

    static let callsScript = """
        const old = s => Array.from(document.querySelectorAll(s)).map(el => el.dataset.old === '1');
        return {calls: window.calls, code: old('pre code'), math: old('.cmdmd-math'), diagrams: old('.cmdmd-diagram svg')};
        """

    @MainActor
    func testLibrariesRunOnTheNewNodesOnly() throws {
        let note = """
            Para one.

            ```swift
            let a = 1
            ```

            ```python
            b = 2
            ```

            Math $x^2$ and $y_1$.

            Display $z$ too.

            ```mermaid
            flowchart LR
                A --> B
            ```

            ```mermaid
            flowchart LR
                C --> D
            ```
            """
        let model = Model()
        model.options = Self.options
        model.markdown = note
        let webView = try mountPreview(model)
        let start = loads
        XCTAssertEqual(run(Self.instrumentScript, in: webView) as? Bool, true)

        /// Once the page shows `shown`.
        func edit(_ old: String, _ new: String, until shown: String) throws -> [String: Any] {
            model.markdown = model.markdown.replacingOccurrences(of: old, with: new)
            try settle(webView)
            waitUntil(timeout: 10) { run("return \(shown);", in: webView) as? Bool == true }
            return try XCTUnwrap(run(Self.callsScript, in: webView) as? [String: Any])
        }
        let text = { (needle: String) in "document.getElementById('cmdmd-root').textContent.includes('\(needle)')" }

        var state = try edit("Para one.", "Para one, edited.", until: text("edited"))
        XCTAssertEqual(state["calls"] as? [String: Int], ["hljs": 0, "katex": 0, "pele": 0], "a paragraph edit runs no library")
        XCTAssertEqual(state["code"] as? [Bool], [true, true])
        XCTAssertEqual(state["math"] as? [Bool], [true, true, true])
        XCTAssertEqual(state["diagrams"] as? [Bool], [true, true])

        state = try edit("b = 2", "b = 3", until: text("b = 3"))
        XCTAssertEqual(state["calls"] as? [String: Int], ["hljs": 1, "katex": 0, "pele": 0])
        XCTAssertEqual(state["code"] as? [Bool], [true, false], "only the edited block is highlighted again")

        state = try edit("Display $z$ too.", "Display $z$ now.", until: text("now"))
        XCTAssertEqual(state["calls"] as? [String: Int], ["hljs": 1, "katex": 1, "pele": 0])
        XCTAssertEqual(state["math"] as? [Bool], [true, true, false])

        state = try edit("C --> D", "C --> E", until: "window.calls.pele > 0")
        XCTAssertEqual(state["calls"] as? [String: Int], ["hljs": 1, "katex": 1, "pele": 1])
        XCTAssertEqual(state["diagrams"] as? [Bool], [true, false], "the other diagram keeps its drawing")
        let drawn = run("return document.querySelectorAll('.cmdmd-diagram svg.pele').length;", in: webView) as? Int
        XCTAssertEqual(drawn, 2)

        state = try edit("C --> E", "C --> ", until: "!!document.querySelector('.cmdmd-diagram-error')")
        let failed = run("return Array.from(document.querySelectorAll('.cmdmd-diagram-error')).map(e => e.textContent);", in: webView) as? [String]
        XCTAssertEqual(failed?.count, 1, "a diagram Pele can't draw shows its source and the reason, as on a load")
        XCTAssertEqual(loads, start, "all patched")
    }

    @MainActor
    func testTheReadingPositionStaysPutForEditsAboveIt() throws {
        let paragraphs = (0..<160).map { "Paragraph \($0) " + String(repeating: "words in a line ", count: 12) }
        let model = Model()
        model.markdown = paragraphs.joined(separator: "\n\n")
        let webView = try mountPreview(model)
        let start = loads

        // The first paragraph at the top of the window, and where it is.
        let probe = """
            const ps = Array.from(document.querySelectorAll('#cmdmd-root > p'));
            const p = ps.find(p => p.getBoundingClientRect().bottom > 0);
            return {text: p.textContent.slice(0, 14), top: p.getBoundingClientRect().top, y: window.scrollY};
            """
        // The runtime's own correction, without WebKit's scroll anchoring
        // (which macOS 14's WebKit lacks).
        _ = run("document.documentElement.style.overflowAnchor = 'none'; document.body.style.overflowAnchor = 'none'; return CSS.supports('overflow-anchor', 'none');", in: webView)
        _ = run("window.scrollTo(0, document.querySelectorAll('#cmdmd-root > p')[100].offsetTop + 7); return true;", in: webView)
        spin(0.1)
        let before = try XCTUnwrap(run(probe, in: webView) as? [String: Any])

        // A taller paragraph and a new one above the window.
        var lines = paragraphs
        lines[10] += " " + String(repeating: "more text ", count: 80)
        lines.insert("Inserted above " + String(repeating: "x ", count: 60), at: 20)
        model.markdown = lines.joined(separator: "\n\n")
        try settle(webView, showing: "Inserted above")
        let after = try XCTUnwrap(run(probe, in: webView) as? [String: Any])

        XCTAssertEqual(after["text"] as? String, before["text"] as? String)
        XCTAssertEqual(after["top"] as? Double ?? .nan, before["top"] as? Double ?? 0, accuracy: 1, "the paragraph read stays where it was")
        XCTAssertGreaterThan(after["y"] as? Double ?? 0, (before["y"] as? Double ?? 0) + 100, "the page scrolled by what grew above")
        XCTAssertEqual(loads, start, "patched")

        // An edit below the window moves nothing.
        lines[155] += " further below"
        model.markdown = lines.joined(separator: "\n\n")
        try settle(webView, showing: "further below")
        let below = try XCTUnwrap(run(probe, in: webView) as? [String: Any])
        XCTAssertEqual(below["y"] as? Double ?? .nan, after["y"] as? Double ?? 0, accuracy: 0.5)
    }

    /// One edit that changes blocks far apart, above the reader and below:
    /// a task typed under the first renumbers the last box, a duplicate
    /// heading re-slugs a later one, a new footnote renumbers the section.
    /// The blocks between stay on the page, and so does the reader's place,
    /// with WebKit's scroll anchoring or without (macOS 14's WebKit lacks it).
    @MainActor
    func testAnEditChangingBlocksFarApartKeepsTheReadingPlace() throws {
        let middle = (0..<120).map { "Paragraph \($0) " + String(repeating: "words in a line ", count: 10) }.joined(separator: "\n\n")
        let cases: [(String, String, String)] = [
            ("task ordinals", "- [ ] first task\n\n\(middle)\n\n- [ ] last task",
             "- [ ] first task\n- [ ] new task typed above\n\n\(middle)\n\n- [ ] last task"),
            ("heading slug", "# Top\n\n\(middle)\n\n## Notes\n\nEnd.", "# Top\n\n## Notes\n\n\(middle)\n\n## Notes\n\nEnd."),
            ("footnotes", "Intro.\n\n\(middle)\n\nEnd[^1].\n\n[^1]: one",
             "Intro with a new ref[^2].\n\n\(middle)\n\nEnd[^1].\n\n[^1]: one\n[^2]: two")
        ]
        let probe = """
            const p = Array.from(document.querySelectorAll('#cmdmd-root > p')).find(p => p.textContent.startsWith('Paragraph 60 '));
            const same = p.dataset.reader === 'here';
            p.dataset.reader = 'here';
            return {top: p.getBoundingClientRect().top, same: same};
            """
        var failures: [String] = []
        for native in [false, true] {
            for (name, note, edited) in cases {
                let model = Model()
                model.markdown = note
                let webView = try mountPreview(model)
                let start = loads
                if !native {
                    _ = run("document.documentElement.style.overflowAnchor = 'none'; document.body.style.overflowAnchor = 'none'; return true;", in: webView)
                }
                _ = run("""
                    const p = Array.from(document.querySelectorAll('#cmdmd-root > p')).find(p => p.textContent.startsWith('Paragraph 60 '));
                    window.scrollTo(0, p.offsetTop + 7); return true;
                    """, in: webView)
                spin(0.2)
                let before = try XCTUnwrap(run(probe, in: webView) as? [String: Any])
                model.markdown = edited
                try settle(webView)
                spin(0.3)
                try settle(webView)
                let after = try XCTUnwrap(run(probe, in: webView) as? [String: Any])
                let moved = (after["top"] as? Double ?? .nan) - (before["top"] as? Double ?? 0)
                if !(abs(moved) <= 1) { failures.append("\(name) native=\(native): the reader moved \(moved) px") }
                if after["same"] as? Bool != true { failures.append("\(name) native=\(native): the reader's paragraph was made again") }
                if loads != start { failures.append("\(name) native=\(native): reloaded") }
                _ = run("document.querySelectorAll('[data-reader]').forEach(p => delete p.dataset.reader); return true;", in: webView)
                if snapshot(webView) != freshSnapshot(edited, options: model.options) { failures.append("\(name) native=\(native): not as a fresh load") }
                host?.rootView = AnyView(EmptyView())
                spin(0.05)
                window?.close()
                window = nil
                host = nil
                loadWatcher = nil
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// A task added under the first, with code, math, diagrams and opened
    /// details between it and a task at the end: only the two lists change.
    @MainActor
    func testATaskAddedAboveLeavesTheBlocksBetweenAlone() throws {
        let between = (0..<3).map { i in
            "Para \(i).\n\n```swift\nlet v\(i) = \(i)\n```\n\nMath $x_\(i)$.\n\n```mermaid\nflowchart LR\n    A\(i) --> B\(i)\n```\n\n<details>\n<summary>S\(i)</summary>\n\nHidden \(i).\n\n</details>"
        }.joined(separator: "\n\n")
        let model = Model()
        model.options = Self.options
        model.markdown = "- [ ] first\n\n" + between + "\n\n- [ ] last"
        let webView = try mountPreview(model)
        let start = loads
        XCTAssertEqual(run(Self.instrumentScript, in: webView) as? Bool, true)
        _ = run("document.querySelectorAll('details').forEach(d => d.open = true); return true;", in: webView)
        model.markdown = "- [ ] first\n- [ ] added\n\n" + between + "\n\n- [ ] last"
        try settle(webView, showing: "added")
        let state = try XCTUnwrap(run(Self.callsScript, in: webView) as? [String: Any])
        XCTAssertEqual(state["calls"] as? [String: Int], ["hljs": 0, "katex": 0, "pele": 0], "only the task lists changed")
        XCTAssertEqual(run("return Array.from(document.querySelectorAll('details')).map(d => d.open);", in: webView) as? [Bool],
                       [true, true, true], "opened details stay open")
        XCTAssertEqual(run("return Array.from(document.querySelectorAll('input[data-task]')).map(b => b.dataset.task);", in: webView) as? [String],
                       ["0", "1", "2"], "the last box renumbered")
        XCTAssertEqual(loads, start, "patched")
    }

    @MainActor
    func testKoreanTextSwitchesTheLanguageInPlace() throws {
        let model = Model()
        model.markdown = "Hello there.\n\nSecond paragraph."
        let webView = try mountPreview(model)
        let start = loads
        let probe = "return {lang: document.documentElement.lang, breaks: getComputedStyle(document.body).wordBreak};"
        XCTAssertEqual(run(probe, in: webView) as? [String: String], ["lang": "", "breaks": "normal"])

        model.markdown = "Hello there.\n\n점검 항목을 정리합니다."
        try settle(webView, showing: "점검")
        XCTAssertEqual(run(probe, in: webView) as? [String: String], ["lang": "ko", "breaks": "keep-all"], "Korean line breaking, as on a load")

        model.markdown = "Hello there.\n\nSecond paragraph again."
        try settle(webView, showing: "again")
        XCTAssertEqual(run(probe, in: webView) as? [String: String], ["lang": "", "breaks": "normal"])
        XCTAssertEqual(loads, start, "patched")
    }

    /// A patch held up in the page (its script busy) when the user flips to
    /// another note: the other note shows, and the late patch never lands
    /// on it.
    @MainActor
    func testATabSwitchDuringAPatchShowsTheNewNote() throws {
        let model = Model()
        model.markdown = "# Note A\n\nFirst paragraph of A."
        let webView = try mountPreview(model)

        webView.evaluateJavaScript("var until = Date.now() + 900; while (Date.now() < until) {}", completionHandler: nil)
        model.markdown = "# Note A\n\nFirst paragraph of A, edited."
        spin(0.4)
        model.documentID = UUID()
        model.markdown = "# Note B\n\nOnly B here."
        try settle(webView, showing: "Only B here")
        spin(1)
        try settle(webView)
        let text = run("return document.getElementById('cmdmd-root').textContent;", in: webView) as? String ?? ""
        XCTAssertTrue(text.contains("Only B here"), text)
        XCTAssertFalse(text.contains("Note A"), text)

        // B patches from here on, as its own page.
        model.markdown = "# Note B\n\nOnly B here, edited."
        try settle(webView, showing: "edited")
        XCTAssertFalse((run("return document.getElementById('cmdmd-root').textContent;", in: webView) as? String ?? "").contains("Note A"))
    }

    @MainActor
    func testDeepNestingPatches() throws {
        let model = Model()
        model.markdown = String(repeating: ">", count: 600) + " deep\n\nAfter."
        let webView = try mountPreview(model)
        let start = loads
        model.markdown = String(repeating: ">", count: 600) + " deeper\n\nAfter."
        try settle(webView, showing: "deeper")
        XCTAssertEqual(run("return document.querySelectorAll('blockquote').length;", in: webView) as? Int, 600)
        XCTAssertEqual(loads, start, "patched")
    }
}

/// Task toggles through the preview of an AppState note.
final class PreviewPatchTaskTests: PreviewPageTestCase {
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?

    override func tearDownWithError() throws {
        host?.rootView = AnyView(EmptyView())
        spin(0.05)
        window?.close()
        window = nil
        host = nil
        try super.tearDownWithError()
    }

    @MainActor
    private func mount(_ state: AppState, note: String) throws -> WKWebView {
        let url = dataDir.appendingPathComponent("tasks.md")
        try note.write(to: url, atomically: true, encoding: .utf8)
        let document = MarkdownDocument(content: note, fileURL: url)
        let tab = EditorTab(documentId: document.id, fileURL: url, title: "tasks.md")
        state.documents[document.id] = document
        state.originalContents[document.id] = document.fullText
        state.tabs.append(tab)
        state.activeTabId = tab.id
        state.viewMode = .preview

        let hosting = NSHostingView(rootView: AnyView(PreviewPane().environment(state)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        hosting.layoutSubtreeIfNeeded()
        self.window = window
        host = hosting
        let webView = try XCTUnwrap(R3bFocusHostedTestCase.find(PreviewWebView.self, in: hosting))
        spin(0.1)
        waitUntil(timeout: 20) { !webView.isLoading && run("return !!document.getElementById('cmdmd-root');", in: webView) as? Bool == true }
        try XCTSkipUnless(run("return !!document.getElementById('cmdmd-root');", in: webView) as? Bool == true, "the page did not load in this environment")
        try settle(webView)
        return webView
    }

    /// Clicks box `ordinal`; whether it is checked once the app answered.
    @MainActor
    private func click(_ ordinal: Int, in webView: WKWebView) -> Bool? {
        run("""
            const box = document.querySelector(`input[data-task="${ordinal}"]`);
            box.click();
            await new Promise(r => setTimeout(r, 150));
            return box.checked;
            """, arguments: ["ordinal": ordinal], in: webView) as? Bool
    }

    @MainActor
    func testATaskTogglesItsLineAfterLinesWereAddedAboveIt() throws {
        let state = AppState()
        let webView = try mount(state, note: "Intro\n\n- [ ] alpha\n- [ ] beta\n")
        state.updateContent("New line one\n\nNew line two\n\nIntro\n\n- [ ] alpha\n- [ ] beta\n")
        try settle(webView, showing: "New line two")

        XCTAssertEqual(click(1, in: webView), true)
        XCTAssertEqual(state.currentDocument?.content, "New line one\n\nNew line two\n\nIntro\n\n- [ ] alpha\n- [x] beta\n")
        try settle(webView)
        XCTAssertEqual(click(0, in: webView), true)
        XCTAssertEqual(state.currentDocument?.content, "New line one\n\nNew line two\n\nIntro\n\n- [x] alpha\n- [x] beta\n")
    }

    /// The page still shows the lines from before an edit (its render is
    /// held up): the click names the old line. Line 4 is alpha now, never
    /// flipped for the beta clicked: beta's line maps through the edit to
    /// line 5. A box whose own line the edit changed has no line to map
    /// to: nothing flips and the box goes back.
    @MainActor
    func testAToggleOnAStalePageFlipsItsTaskOrIsRefusedAndTheBoxGoesBack() throws {
        let state = AppState()
        let webView = try mount(state, note: "Intro\n\n- [ ] alpha\n- [ ] beta\n")
        let gate = DispatchSemaphore(value: 0)
        PreviewRenderThread.shared.enqueue(for: NSObject()) { gate.wait() }
        let edited = "Intro\n\n- [ ] new first\n- [ ] alpha edited\n- [ ] beta\n"
        state.updateContent(edited)
        spin(0.3)

        XCTAssertEqual(click(0, in: webView), false, "refused: the box shows the note again")
        XCTAssertEqual(state.currentDocument?.content, edited, "alpha's line was edited")
        XCTAssertEqual(click(1, in: webView), true)
        XCTAssertEqual(state.currentDocument?.content, "Intro\n\n- [ ] new first\n- [ ] alpha edited\n- [x] beta\n",
                       "beta, at its line now; not line 4 (alpha)")
        gate.signal()
        try settle(webView, showing: "new first")
        let boxes = run("return Array.from(document.querySelectorAll('input[data-task]')).map(b => b.checked);", in: webView) as? [Bool]
        XCTAssertEqual(boxes, [false, false, true])
    }
}

/// splitmix64: the same edits every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
