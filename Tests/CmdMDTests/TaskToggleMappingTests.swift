import SwiftUI
import WebKit
import XCTest
@testable import CmdMD

/// The preview of an AppState note (PreviewPane) in an unshown window:
/// clicked from script, or with real mouse events, which WebKit treats as
/// the user's own.
class AppStatePreviewTestCase: PreviewPageTestCase {
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
    func mount(_ state: AppState, note: String) throws -> WKWebView {
        let url = dataDir.appendingPathComponent("toggle-note.md")
        try note.write(to: url, atomically: true, encoding: .utf8)
        let document = MarkdownDocument(content: note, fileURL: url)
        let tab = EditorTab(documentId: document.id, fileURL: url, title: "toggle-note.md")
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
        waitUntil(timeout: 30) { !webView.isLoading && run("return !!document.getElementById('cmdmd-root');", in: webView) as? Bool == true }
        try XCTSkipUnless(run("return !!document.getElementById('cmdmd-root');", in: webView) as? Bool == true, "the page did not load in this environment")
        try settle(webView)
        return webView
    }

    /// Clicks box `ordinal` from script; whether it is checked once the app answered.
    @MainActor
    func click(_ ordinal: Int, in webView: WKWebView) -> Bool? {
        run("""
            const box = document.querySelector(`input[data-task="${ordinal}"]`);
            box.click();
            await new Promise(r => setTimeout(r, 150));
            return box.checked;
            """, arguments: ["ordinal": ordinal], in: webView) as? Bool
    }

    /// A real mouse click (down, up) at a CSS point of the page.
    @MainActor
    func mouseClick(_ webView: WKWebView, x: Double, y: Double) {
        let zoom = webView.pageZoom
        let local = NSPoint(x: x * zoom, y: webView.isFlipped ? y * zoom : webView.bounds.height - y * zoom)
        let point = webView.convert(local, to: nil)
        let windowNumber = webView.window?.windowNumber ?? 0
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                           pressure: type == .leftMouseDown ? 1 : 0)!
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
            spin(0.05)
        }
        spin(0.6)
    }

    /// The center of the first element `selector` names, in CSS pixels.
    @MainActor
    func center(of selector: String, in webView: WKWebView) throws -> (x: Double, y: Double) {
        let point = try XCTUnwrap(run("""
            const r = Element.prototype.querySelector.call(document.documentElement, selector).getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2];
            """, arguments: ["selector": selector], in: webView) as? [Double])
        return (point[0], point[1])
    }

    /// Holds the render thread until signalled: the page on screen stays
    /// the one from before the next edit.
    func holdRenders() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        PreviewRenderThread.shared.enqueue(for: NSObject()) { gate.wait() }
        return gate
    }
}

/// A click on a page that hasn't caught up with the note flips the task the
/// box shows, at the line it is on now.
final class TaskToggleMappingHostedTests: AppStatePreviewTestCase {
    /// A paragraph typed above moves both identical tasks by two lines:
    /// the old line of Tuesday's box is now Monday's task, which reads the
    /// same. Tuesday's flips.
    @MainActor
    func testAStaleClickFlipsItsOwnTaskNotOneReadingTheSame() throws {
        let state = AppState()
        let note = "## Monday\n- [ ] call mom\n## Tuesday\n- [ ] call mom\n"
        let webView = try mount(state, note: note)
        let gate = holdRenders()
        state.updateContent("New first line\n\n" + note)
        spin(0.3)

        XCTAssertEqual(click(1, in: webView), true)
        XCTAssertEqual(state.currentDocument?.content, "New first line\n\n## Monday\n- [ ] call mom\n## Tuesday\n- [x] call mom\n",
                       "Tuesday's task, not Monday's")
        gate.signal()
        try settle(webView, showing: "New first line")
        let boxes = run("return Array.from(document.querySelectorAll('input[data-task]')).map(b => b.checked);", in: webView) as? [Bool]
        XCTAssertEqual(boxes, [false, true])
    }

    /// A second click (undoing a misclick) before the page re-rendered the
    /// first: still the same task, now unchecked again.
    @MainActor
    func testAQuickSecondClickBeforeTheRerenderUndoesTheFirst() throws {
        let state = AppState()
        let note = "Intro\n\n- [ ] alpha\n- [ ] beta\n"
        let webView = try mount(state, note: note)
        let gate = holdRenders()
        let checked = run("""
            const box = document.querySelector('input[data-task="0"]');
            box.click();
            await new Promise(r => setTimeout(r, 30));
            box.click();
            await new Promise(r => setTimeout(r, 150));
            return box.checked;
            """, in: webView) as? Bool
        XCTAssertEqual(checked, false)
        XCTAssertEqual(state.currentDocument?.content, note, "the second click unchecks alpha again")
        gate.signal()
        try settle(webView)
        let boxes = run("return Array.from(document.querySelectorAll('input[data-task]')).map(b => b.checked);", in: webView) as? [Bool]
        XCTAssertEqual(boxes, [false, false])
    }
}

/// A line of the text a page was rendered from, in the note now.
final class TaskLineMappingTests: XCTestCase {
    private func map(_ line: Int, _ old: String, _ new: String) -> Int? {
        TaskLineMapping.line(line, renderedFrom: old, in: new)
    }

    func testLinesBeforeAndAfterTheChangeMoveWithIt() {
        let old = "Intro\n\n- [ ] alpha\n- [ ] beta\n"
        let new = "Intro\n\n- [ ] new first\n- [ ] alpha\n- [ ] beta\n"
        XCTAssertEqual(map(1, old, new), 1)
        XCTAssertEqual(map(3, old, new), 4, "alpha moved down a line")
        XCTAssertEqual(map(4, old, new), 5)
        XCTAssertEqual(map(3, old, old), 3, "no change")
        XCTAssertEqual(map(2, "a\nb\nc", "a\nc"), nil, "removed")
        XCTAssertEqual(map(3, "a\nb\nc", "a\nc"), 2)
    }

    func testALineTheEditChangedHasNoPlace() {
        let old = "- [ ] alpha\n- [ ] beta"
        XCTAssertNil(map(1, old, "- [ ] alpha edited\n- [ ] beta"))
        XCTAssertEqual(map(2, old, "- [ ] alpha edited\n- [ ] beta"), 2)
        XCTAssertNil(map(3, old, old), "past the end")
        XCTAssertNil(map(0, old, old))
    }

    func testTwoIdenticalTasksMovedByTheirDistance() {
        let old = "## Monday\n- [ ] call mom\n## Tuesday\n- [ ] call mom\n"
        XCTAssertEqual(map(4, old, "New first line\n\n" + old), 6, "Tuesday's, not Monday's at line 4")
        XCTAssertEqual(map(2, old, "New first line\n\n" + old), 4)
    }

    func testAFlippedBoxIsTheSameLine() {
        XCTAssertTrue(TaskLineMapping.same("- [ ] alpha", "- [x] alpha"))
        XCTAssertTrue(TaskLineMapping.same("  1. [X] alpha", "  1. [ ] alpha"))
        XCTAssertFalse(TaskLineMapping.same("- [ ] alpha", "- [x] alphb"))
        XCTAssertFalse(TaskLineMapping.same("[ ] alpha", "[x] alpha"), "not task lines")
        XCTAssertEqual(map(2, "Intro\n- [ ] alpha\nend", "Intro\n- [x] alpha\nend"), 2)
    }
}

/// toggleTask with the text the clicked page was rendered from.
final class TaskToggleRenderedSourceTests: IsolatedDataDirTestCase {
    func testTheClickedLineMapsThroughTheEditSinceItsPage() {
        let state = AppState()
        state.createNewTab()
        let rendered = "## Monday\n- [ ] call mom\n## Tuesday\n- [ ] call mom\n"
        state.updateContent("New first line\n\n" + rendered)

        XCTAssertTrue(state.toggleTask(atLine: 4, checked: true, expectedLine: "- [ ] call mom", renderedSource: rendered))
        XCTAssertEqual(state.currentDocument?.content, "New first line\n\n## Monday\n- [ ] call mom\n## Tuesday\n- [x] call mom\n")
        // Again before a re-render: the page still has the old text, the box its own state.
        XCTAssertTrue(state.toggleTask(atLine: 4, checked: false, expectedLine: "- [ ] call mom", renderedSource: rendered))
        XCTAssertEqual(state.currentDocument?.content, "New first line\n\n" + rendered)
        state.tabs.forEach { state.closeTab($0) }
    }

    func testALineTheEditChangedIsRefused() {
        let state = AppState()
        state.createNewTab()
        let edited = "- [ ] alpha edited\n- [ ] beta"
        state.updateContent(edited)

        XCTAssertFalse(state.toggleTask(atLine: 1, checked: true, expectedLine: "- [ ] alpha", renderedSource: "- [ ] alpha\n- [ ] beta"))
        XCTAssertEqual(state.currentDocument?.content, edited)
        state.tabs.forEach { state.closeTab($0) }
    }
}
