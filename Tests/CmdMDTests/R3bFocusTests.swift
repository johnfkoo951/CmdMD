import XCTest
import SwiftUI
import AppKit
import WebKit
@testable import CmdMD

// MARK: - Tab size sets the tab stops (G097)

final class R3bFocusTabStopTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    private var spaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }

    private func paragraphStyle(of string: NSAttributedString, at index: Int = 0) -> NSParagraphStyle? {
        string.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    func testParagraphStyleTabIntervalFollowsTabSize() {
        for tabSize in [2, 4, 8] {
            let style = SyntaxHighlighter.paragraphStyle(font: font, tabSize: tabSize)
            XCTAssertTrue(style.tabStops.isEmpty, "no fixed 28 pt stops")
            XCTAssertEqual(style.defaultTabInterval, CGFloat(tabSize) * spaceWidth, accuracy: 0.01)
            XCTAssertEqual(style.lineSpacing, 4)
        }
    }

    func testTabCharactersRenderAtTabSizeColumns() throws {
        for tabSize in [2, 4, 8] {
            let markdown = String(repeating: "a", count: 45) + "\tX"
            let string = SyntaxHighlighter().highlight(markdown: markdown, font: font, theme: .github, tabSize: tabSize)
            let style = try XCTUnwrap(paragraphStyle(of: string))
            XCTAssertEqual(style.defaultTabInterval, CGFloat(tabSize) * spaceWidth, accuracy: 0.01)

            let storage = NSTextStorage(attributedString: string)
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 100_000, height: 100_000))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)

            var fragments = 0
            layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, _, _ in
                fragments += 1
            }
            // AppKit's default stops end at 336 pt: the tab after 45 columns
            // used to break the line even with wrapping off.
            XCTAssertEqual(fragments, 1, "tab size \(tabSize)")

            let x = layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: 46)).x
            let columns = x / (CGFloat(tabSize) * spaceWidth)
            XCTAssertEqual(columns, columns.rounded(), accuracy: 0.01, "X sits on a tab stop")
            XCTAssertGreaterThan(x, 45 * spaceWidth)
        }
    }

    func testTypingPassAfterATabSizeChangeRestylesEverything() throws {
        let highlighter = SyntaxHighlighter()
        let storage = NSTextStorage(string: "one\ttwo\n\nthree\tfour\n")
        highlighter.applyHighlights(to: storage, font: font, theme: .github, tabSize: 4)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")

        highlighter.applyHighlights(to: storage, font: font, theme: .github, tabSize: 2,
                                    editedRange: NSRange(location: 0, length: 1))

        let last = (storage.string as NSString).range(of: "four").location
        let style = try XCTUnwrap(paragraphStyle(of: storage, at: last))
        XCTAssertEqual(style.defaultTabInterval, 2 * spaceWidth, accuracy: 0.01, "untouched lines follow too")
    }
}

// MARK: - Hosted editor

@Observable
private final class FocusEditorModel {
    var text: String
    let documentID = UUID()
    var isVisible = true
    var tabSize = 4

    init(text: String) { self.text = text }
}

private struct FocusEditorHost: View {
    let model: FocusEditorModel

    var body: some View {
        let _ = model.text
        MarkdownTextEditor(
            documentID: model.documentID,
            isVisible: model.isVisible,
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            editorTheme: .cmdsLight,
            softWrap: true,
            showLineNumbers: true,
            highlightCurrentLine: true,
            tabSize: model.tabSize,
            insertSpacesForTab: false,
            enableCompletion: false,
            scrollSyncEnabled: false,
            copySelectionOnDrag: false
        )
    }
}

/// A window with the editor and a plain text field standing in for the
/// sidebar search or an Inspector field.
class R3bFocusHostedTestCase: XCTestCase {
    var window: NSWindow!
    var field: NSTextField!
    private var host: NSView?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        (host as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
        spin(0.02)
        window?.close()
        window = nil
        field = nil
        host = nil
        super.tearDown()
    }

    func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.01) }
    }

    func mount(_ view: some View) -> NSView {
        let hosting = NSHostingView(rootView: AnyView(view))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        hosting.frame = NSRect(x: 0, y: 40, width: container.bounds.width, height: container.bounds.height - 40)
        container.addSubview(hosting)
        field = NSTextField(frame: NSRect(x: 10, y: 8, width: 200, height: 24))
        container.addSubview(field)
        hosting.layoutSubtreeIfNeeded()
        spin(0.05)
        host = hosting
        return hosting
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    /// Whether keyboard focus is in `field` (its field editor holds it).
    var fieldHasFocus: Bool {
        (window.firstResponder as? NSTextView)?.delegate === field
    }

    func post(_ mode: ViewMode, modeChanged: Bool) {
        NotificationCenter.default.post(
            name: .focusVisiblePane,
            object: PaneFocus.Request(mode: mode, modeChanged: modeChanged)
        )
    }
}

final class R3bFocusEditorTests: R3bFocusHostedTestCase {
    private var model: FocusEditorModel!

    override func tearDown() {
        model = nil
        super.tearDown()
    }

    @MainActor
    private func mountEditor(_ text: String) throws -> CmdMDTextView {
        model = FocusEditorModel(text: text)
        let hosting = mount(FocusEditorHost(model: model))
        let textView = try XCTUnwrap(Self.find(CmdMDTextView.self, in: hosting))
        _ = textView.layoutManager
        return textView
    }

    private func tabInterval(_ textView: NSTextView) -> CGFloat? {
        (textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.defaultTabInterval
    }

    // G097: the Tab size stepper restyles the open note.

    @MainActor
    func testTabSizeChangeRestylesTheOpenNote() throws {
        let textView = try mountEditor("a\tb\n\tindented")
        let font = try XCTUnwrap(textView.font)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(try XCTUnwrap(tabInterval(textView)), 4 * space, accuracy: 0.01)

        model.tabSize = 2
        waitUntil { abs((self.tabInterval(textView) ?? 0) - 2 * space) < 0.01 }
        XCTAssertEqual(try XCTUnwrap(tabInterval(textView)), 2 * space, accuracy: 0.01)
        let typing = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(try XCTUnwrap(typing).defaultTabInterval, 2 * space, accuracy: 0.01, "typed text too")
    }

    // G113: hidden, the editor is skipped by Tab.

    @MainActor
    func testHiddenEditorLeavesTheKeyViewLoop() throws {
        let textView = try mountEditor("note")
        XCTAssertTrue(textView.canBecomeKeyView)

        model.isVisible = false
        waitUntil { !textView.isEditorVisible }
        XCTAssertFalse(textView.canBecomeKeyView)

        model.isVisible = true
        waitUntil { textView.isEditorVisible }
        XCTAssertTrue(textView.canBecomeKeyView)
    }

    @MainActor
    func testTabSkipsAHiddenEditor() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let before = NSTextField(frame: NSRect(x: 10, y: 250, width: 100, height: 22))
        let after = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        let textView = CmdMDTextView(frame: NSRect(x: 10, y: 50, width: 300, height: 180))
        window.contentView?.addSubview(before)
        window.contentView?.addSubview(textView)
        window.contentView?.addSubview(after)
        before.nextKeyView = textView
        textView.nextKeyView = after
        after.nextKeyView = before

        XCTAssertTrue(before.nextValidKeyView === textView)
        textView.isEditorVisible = false
        XCTAssertTrue(before.nextValidKeyView === after, "Tab goes past the hidden editor")

        window.makeFirstResponder(before)
        window.selectKeyView(following: before)
        XCTAssertFalse(window.firstResponder === textView)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === after)
    }

    // G114: the editor takes focus that is nowhere, never a field's.

    @MainActor
    func testEditorTakesFocusThatIsNowhere() throws {
        let textView = try mountEditor("note")
        window.makeFirstResponder(nil)

        post(.source, modeChanged: false)
        waitUntil { self.window.firstResponder === textView }
        XCTAssertTrue(window.firstResponder === textView)
    }

    @MainActor
    func testEditorLeavesAFocusedFieldAlone() throws {
        let textView = try mountEditor("note")
        window.makeFirstResponder(field)
        XCTAssertTrue(fieldHasFocus)

        post(.split, modeChanged: true)
        spin(0.05)
        XCTAssertTrue(fieldHasFocus, "the sidebar or an Inspector field keeps focus")
        XCTAssertFalse(window.firstResponder === textView)
    }

    @MainActor
    func testPreviewRequestIsNotTheEditors() throws {
        let textView = try mountEditor("note")
        window.makeFirstResponder(nil)

        post(.preview, modeChanged: true)
        spin(0.05)
        XCTAssertFalse(window.firstResponder === textView)
    }

    @MainActor
    func testPostedRequestArrivesAfterTheUpdate() throws {
        let textView = try mountEditor("note")
        window.makeFirstResponder(nil)

        PaneFocus.post(mode: .split, modeChanged: false)
        XCTAssertFalse(window.firstResponder === textView, "not in the middle of the update")
        waitUntil { self.window.firstResponder === textView }
        XCTAssertTrue(window.firstResponder === textView)
    }
}

// MARK: - Focus rules (G114)

final class R3bFocusRuleTests: XCTestCase {
    func testTargetFollowsTheMode() {
        XCTAssertEqual(PaneFocus.Request(mode: .preview, modeChanged: true).target, .preview)
        XCTAssertEqual(PaneFocus.Request(mode: .source, modeChanged: true).target, .editor)
        XCTAssertEqual(PaneFocus.Request(mode: .split, modeChanged: false).target, .editor)
    }

    @MainActor
    func testPaneOfResponder() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let textView = CmdMDTextView(frame: scrollView.bounds)
        scrollView.documentView = textView
        // Stands in for the editor's find bar, which lives in its scroll view.
        let findField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        scrollView.addSubview(findField)
        let elsewhere = NSTextField(frame: NSRect(x: 0, y: 250, width: 100, height: 22))
        let webView = WKWebView(frame: NSRect(x: 300, y: 0, width: 100, height: 200))
        let inner = NSView()
        webView.addSubview(inner)
        window.contentView?.addSubview(scrollView)
        window.contentView?.addSubview(elsewhere)
        window.contentView?.addSubview(webView)

        XCTAssertEqual(PaneFocus.pane(of: textView), .editor)
        XCTAssertEqual(PaneFocus.pane(of: webView), .preview)
        XCTAssertEqual(PaneFocus.pane(of: inner), .preview)
        XCTAssertNil(PaneFocus.pane(of: elsewhere))
        XCTAssertNil(PaneFocus.pane(of: nil))
        XCTAssertNil(PaneFocus.pane(of: window))

        // A focused field is represented by its field editor.
        window.makeFirstResponder(findField)
        let findEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(findEditor.isFieldEditor)
        XCTAssertEqual(PaneFocus.pane(of: findEditor), .editor)
        window.makeFirstResponder(elsewhere)
        XCTAssertNil(PaneFocus.pane(of: window.firstResponder))
    }

    @MainActor
    func testWhenTheVisiblePaneTakesFocus() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let textView = CmdMDTextView(frame: .zero)
        let webView = WKWebView(frame: .zero)
        let field = NSTextField(frame: .zero)

        let reading = PaneFocus.Request(mode: .preview, modeChanged: true)
        // Nowhere: always.
        XCTAssertTrue(PaneFocus.shouldTakeFocus(reading, from: nil, in: window))
        XCTAssertTrue(PaneFocus.shouldTakeFocus(reading, from: window, in: window))
        // ⌘3: out of the editor, which is about to be hidden.
        XCTAssertTrue(PaneFocus.shouldTakeFocus(reading, from: textView, in: window))
        // Already there, or somewhere the user put it.
        XCTAssertFalse(PaneFocus.shouldTakeFocus(reading, from: webView, in: window))
        XCTAssertFalse(PaneFocus.shouldTakeFocus(reading, from: field, in: window))

        // ⌘2 while reading puts the caret in the editor.
        XCTAssertTrue(PaneFocus.shouldTakeFocus(PaneFocus.Request(mode: .split, modeChanged: true), from: webView, in: window))

        // A document switch only fills a focus that is nowhere: a page the
        // user clicked in Split keeps it.
        let switched = PaneFocus.Request(mode: .split, modeChanged: false)
        XCTAssertTrue(PaneFocus.shouldTakeFocus(switched, from: window, in: window))
        XCTAssertFalse(PaneFocus.shouldTakeFocus(switched, from: webView, in: window))
        XCTAssertFalse(PaneFocus.shouldTakeFocus(switched, from: field, in: window))
    }
}

// MARK: - Hosted preview (G113, G114, G036)

final class R3bFocusPreviewTests: R3bFocusHostedTestCase {
    @MainActor
    private func mountPreview(_ markdown: String, isVisible: Bool = true) throws -> PreviewWebView {
        let preview = MarkdownPreviewView(
            documentID: UUID(),
            isVisible: isVisible,
            positionKey: nil,
            markdown: markdown,
            baseURL: nil,
            options: MarkdownRenderOptions(),
            scrollSyncEnabled: false,
            zoom: 1
        )
        let hosting = mount(preview)
        return try XCTUnwrap(Self.find(PreviewWebView.self, in: hosting))
    }

    @MainActor
    func testPreviewTakesFocusThatIsNowhere() throws {
        let webView = try mountPreview("# Hello\n\nworld")
        window.makeFirstResponder(nil)

        post(.preview, modeChanged: false)
        waitUntil { PaneFocus.pane(of: self.window.firstResponder) == .preview }
        XCTAssertEqual(PaneFocus.pane(of: window.firstResponder), .preview, "Space and the arrows scroll the page")
        XCTAssertTrue(webView.canBecomeKeyView)
    }

    @MainActor
    func testPreviewLeavesAFocusedFieldAlone() throws {
        _ = try mountPreview("# Hello")
        window.makeFirstResponder(field)

        post(.preview, modeChanged: true)
        spin(0.05)
        XCTAssertTrue(fieldHasFocus)
    }

    @MainActor
    func testHiddenPreviewLeavesTheKeyViewLoop() throws {
        let webView = try mountPreview("# Hello", isVisible: false)
        XCTAssertFalse(webView.isPaneVisible)
        XCTAssertFalse(webView.canBecomeKeyView)
    }

    @MainActor
    func testUseSelectionForFindReadsThePageSelection() throws {
        let webView = try mountPreview("# Hello\n\nworld")
        waitUntil(timeout: 5) { !webView.isLoading }
        var selected = false
        webView.evaluateJavaScript("""
            (function(){var h=document.querySelector('h1');if(!h)return false;
            var r=document.createRange();r.selectNodeContents(h);
            var s=getSelection();s.removeAllRanges();s.addRange(r);return true;})()
            """) { value, _ in selected = value as? Bool ?? false }
        waitUntil(timeout: 5) { selected }
        try XCTSkipUnless(selected, "the page did not load in this environment")

        var answer: String?
        NotificationCenter.default.post(
            name: .previewSelectionForFind,
            object: PreviewSelectionRequest { answer = $0 }
        )
        waitUntil(timeout: 5) { answer != nil }
        XCTAssertEqual(answer?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello")
    }
}

// MARK: - Dropping a note on the preview opens it (G128)

/// A drag from Finder unless `source` is set.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    init(pasteboard: NSPasteboard, source: Any? = nil, sequence: Int) {
        draggingPasteboard = pasteboard
        draggingSource = source
        draggingSequenceNumber = sequence
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

final class R3bFocusPreviewDropTests: R3WindowSandboxTestCase {
    private var pasteboards: [NSPasteboard] = []

    override func tearDownWithError() throws {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        try super.tearDownWithError()
    }

    private func pasteboard(_ urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("R3bFocusTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboards.append(pasteboard)
        return pasteboard
    }

    func testOpenableURLsAreNotesAndFolders() throws {
        let note = try make("a.md", contents: "# A")
        let image = try make("b.png")
        let vault = try make("Vault/")
        let text = try make("c.txt", contents: "c")

        let urls = PreviewWebView.openableURLs(on: pasteboard([note, image, vault, text]))

        XCTAssertEqual(urls.map(\.lastPathComponent), ["Vault", "a.md", "c.txt"])
    }

    @MainActor
    func testNoteDroppedOnThePreviewOpens() throws {
        let note = try make("a.md", contents: "# A")
        let webView = PreviewWebView(frame: .zero)
        var opened: [[URL]] = []
        webView.onFileDrop = { opened.append($0) }
        let drag = FakeDraggingInfo(pasteboard: pasteboard([note]), sequence: 1)

        XCTAssertEqual(webView.draggingEntered(drag), .copy)
        XCTAssertEqual(webView.draggingUpdated(drag), .copy)
        XCTAssertTrue(webView.prepareForDragOperation(drag))
        XCTAssertTrue(webView.performDragOperation(drag))
        XCTAssertEqual(opened.map { $0.map(\.lastPathComponent) }, [["a.md"]])
    }

    @MainActor
    func testOtherDragsStayWebKits() throws {
        let note = try make("a.md", contents: "# A")
        let image = try make("b.png")
        let webView = PreviewWebView(frame: .zero)
        webView.onFileDrop = { _ in XCTFail("nothing to open") }

        XCTAssertTrue(webView.droppedItems(for: FakeDraggingInfo(pasteboard: pasteboard([image]), sequence: 1)).isEmpty)
        // A link dragged out of the page and back onto it.
        XCTAssertTrue(webView.droppedItems(for: FakeDraggingInfo(pasteboard: pasteboard([note]), source: webView, sequence: 2)).isEmpty)

        let unwired = PreviewWebView(frame: .zero)
        XCTAssertTrue(unwired.droppedItems(for: FakeDraggingInfo(pasteboard: pasteboard([note]), sequence: 3)).isEmpty)
    }

    func testDroppedItemsOpenTheFolderAndTheNotes() throws {
        let vault = try make("Vault/")
        let note = try make("a.md", contents: "# A")
        let state = AppState()

        state.openDroppedItems([vault, note])

        XCTAssertEqual(state.currentFolder, vault, "the folder becomes the workspace")
        let deadline = Date().addingTimeInterval(2)
        while !state.tabs.contains(where: { $0.fileURL == note }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(state.tabs.contains { $0.fileURL == note }, "the note opens in a tab")
        XCTAssertFalse(state.tabs.contains { $0.fileURL == vault })
    }
}

// MARK: - Find menu shortcuts stay reserved (G036)

final class R3bFocusFindMenuTests: XCTestCase {
    func testFindShortcutsAreReserved() {
        let reserved: [(KeyBinding, String)] = [
            (KeyBinding(key: "f", command: true, option: true), "Find and Replace…"),
            (KeyBinding(key: "g", command: true), "Find Next"),
            (KeyBinding(key: "g", command: true, shift: true), "Find Previous"),
            (KeyBinding(key: "e", command: true), "Use Selection for Find"),
        ]
        for (binding, title) in reserved {
            XCTAssertEqual(AppShortcut.save.conflict(for: binding, overrides: [:]), title)
            XCTAssertFalse(AppShortcut.allCases.contains { $0.defaultBinding.isSameCombo(as: binding) }, title)
        }
    }

    func testUseSelectionForFindReachesThePreviewFindBar() {
        // Source and Split go to the editor's NSTextFinder, which writes the
        // system-wide find pasteboard, so only the preview route runs here.
        var actions: [NSTextFinder.Action] = []
        let token = NotificationCenter.default.addObserver(forName: .previewFindCommand, object: nil, queue: nil) { note in
            if let action = note.object as? NSTextFinder.Action { actions.append(action) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        DocumentFind.perform(.setSearchString, in: .preview)

        XCTAssertEqual(actions, [.setSearchString])
    }
}
