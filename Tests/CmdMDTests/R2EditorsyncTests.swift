import XCTest
import SwiftUI
import AppKit
@testable import CmdMD

// MARK: - Pure helpers

final class R2EditorsyncHelperTests: XCTestCase {
    private func apply(_ old: String, _ new: String) -> (NSRange, NSRange, String) {
        let edit = MarkdownTextEditor.minimalEdit(from: old as NSString, to: new as NSString)
        let result = (old as NSString).replacingCharacters(
            in: edit.range, with: (new as NSString).substring(with: edit.replacement)
        )
        return (edit.range, edit.replacement, result)
    }

    func testMinimalEditTrimsCommonPrefixAndSuffix() {
        // A frontmatter reload that prepends a newline: one insertion at 0.
        var (range, replacement, result) = apply("alpha beta", "\nalpha beta")
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
        XCTAssertEqual(replacement, NSRange(location: 0, length: 1))
        XCTAssertEqual(result, "\nalpha beta")

        // A preview task toggle: one character.
        (range, replacement, result) = apply("- [ ] task\nnext", "- [x] task\nnext")
        XCTAssertEqual(range, NSRange(location: 3, length: 1))
        XCTAssertEqual(replacement, NSRange(location: 3, length: 1))
        XCTAssertEqual(result, "- [x] task\nnext")

        // Shrinking, growing, emptying, filling.
        XCTAssertEqual(apply("Hello world again", "short").2, "short")
        XCTAssertEqual(apply("abc", "abXc").0, NSRange(location: 2, length: 0))
        XCTAssertEqual(apply("", "abc").2, "abc")
        XCTAssertEqual(apply("abc", "").2, "")
        XCTAssertEqual(apply("aaa", "aaaa").2, "aaaa")
        XCTAssertEqual(apply("same", "same").0, NSRange(location: 4, length: 0))
    }

    func testMinimalEditNeverSplitsComposedCharacters() {
        // Emoji differing only in the low surrogate: the pair is replaced whole.
        let (range, _, result) = apply("a😀b", "a😃b")
        XCTAssertEqual(range, NSRange(location: 1, length: 2))
        XCTAssertEqual(result, "a😃b")

        // A character inserted between a base letter and its combining mark.
        let (markRange, _, markResult) = apply("e\u{301}", "eX\u{301}")
        XCTAssertEqual(markRange.location, 0)
        XCTAssertEqual(markResult, "eX\u{301}")

        // Korean.
        XCTAssertEqual(apply("안녕하세 그리고", "안녕하세요 그리고").2, "안녕하세요 그리고")
    }

    func testModelChangeIsMeasuredAgainstWhatTheEditorPushed() {
        let pushed = "안녕하세"
        // Marked text ("요") lives only in the view; the model still matches
        // what was pushed, so an update must not replace the view's text.
        XCTAssertFalse(MarkdownTextEditor.isModelChange(pushed, lastPushed: pushed))
        XCTAssertFalse(MarkdownTextEditor.isModelChange(NSMutableString(string: pushed) as String, lastPushed: pushed))
        XCTAssertTrue(MarkdownTextEditor.isModelChange("- [x] a", lastPushed: "- [ ] a"))
        XCTAssertTrue(MarkdownTextEditor.isModelChange("abc", lastPushed: "ab"))
    }

    func testDiffersMatchesInequalityForDocumentText() {
        XCTAssertFalse("abc".differs(from: "abc"))
        XCTAssertTrue("abc".differs(from: "abd"))
        XCTAssertTrue("abc".differs(from: "abcd"))
        XCTAssertFalse("".differs(from: ""))
        XCTAssertFalse("한글".differs(from: "한글"))
        // Bridged from an NSString, as editor text is.
        let bridged = NSMutableString(string: "본문 text") as String
        XCTAssertFalse(bridged.differs(from: "본문 text"))
        XCTAssertTrue(bridged.differs(from: "본문 test"))
        // Different code units write different bytes: not the same text.
        XCTAssertTrue("\u{E9}".differs(from: "e\u{301}"))
    }

    func testFullTextUTF16CountMirrorsFullText() {
        var documents = [
            MarkdownDocument(content: ""),
            MarkdownDocument(content: "# Title\nbody"),
            MarkdownDocument(content: "본문 😀\n"),
        ]
        var frontmatter = Frontmatter()
        frontmatter.title = "제목"
        frontmatter.tags = ["a", "태그"]
        documents.append(MarkdownDocument(content: "본문 body", frontmatter: frontmatter))
        documents.append(MarkdownDocument(content: "", frontmatter: frontmatter))
        documents.append(MarkdownDocument(content: "x", frontmatter: Frontmatter()))
        for document in documents {
            XCTAssertEqual(document.fullTextUTF16Count, document.fullText.utf16.count, document.fullText)
        }
    }

    /// A note as FileService reads it, so the count follows whatever
    /// `fullText` writes for a parsed frontmatter block.
    static func load(_ text: String) async throws -> MarkdownDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("R2Editorsync-\(UUID().uuidString).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await FileService().loadDocument(from: url)
    }

    func testFullTextUTF16CountForLoadedNotes() async throws {
        let files = [
            "---\ntitle: A\n---\n\nBody text\n",
            "---\ntitle: A\n---\nBody text",
            "---\ntags: [a, 태그]\ndate: 2026-10-12\n---\n\n본문 😀\n",
            "---\ntitle: A\n---\n",
            "---\r\ntitle: A\r\n---\r\n\r\nBody\r\n",
            "No frontmatter\n",
        ]
        for file in files {
            var document = try await Self.load(file)
            XCTAssertEqual(document.fullTextUTF16Count, document.fullText.utf16.count, file)
            document.content += "x"
            XCTAssertEqual(document.fullTextUTF16Count, document.fullText.utf16.count, file)
            document.content = ""
            XCTAssertEqual(document.fullTextUTF16Count, document.fullText.utf16.count, file)
        }
    }

    func testDocumentEqualityChecksTheEditStampBeforeTheBody() throws {
        // SwiftUI compares a view's document input on every render; typing
        // changes modifiedAt, so the synthesized == must reach it first.
        let labels = Mirror(reflecting: MarkdownDocument()).children.compactMap(\.label)
        let stamp = try XCTUnwrap(labels.firstIndex(of: "modifiedAt"))
        let body = try XCTUnwrap(labels.firstIndex(of: "content"))
        XCTAssertLessThan(stamp, body)

        let document = MarkdownDocument(content: "one")
        var edited = document
        edited.content = "two"
        XCTAssertNotEqual(document, edited, "the body is still compared")
        XCTAssertEqual(document, document)
    }
}

// MARK: - Dirty tracking and change keys (no per-keystroke whole-text compares)

final class R2EditorsyncStateTests: XCTestCase {
    private var tempDir: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDEditorsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Never the real Application Support folder (or its restored session).
        previousDataDir = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        setenv("CMDMD_DATA_DIR", tempDir.appendingPathComponent("data").path, 1)
    }

    override func tearDownWithError() throws {
        if let previousDataDir {
            setenv("CMDMD_DATA_DIR", previousDataDir, 1)
        } else {
            unsetenv("CMDMD_DATA_DIR")
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDirtyFlagSurvivesTheLengthShortcut() {
        let state = AppState()
        state.createNewTab()
        state.updateContent("ab")
        state.originalContent = state.currentDocument!.fullText
        XCTAssertEqual(state.activeTab?.isDirty, false)

        state.updateContent("ac")  // same length, different text
        XCTAssertEqual(state.activeTab?.isDirty, true)
        state.updateContent("abc")
        XCTAssertEqual(state.activeTab?.isDirty, true)
        state.updateContent("ab")  // back to the baseline
        XCTAssertEqual(state.activeTab?.isDirty, false)
    }

    func testDirtyFlagWithFrontmatter() {
        let state = AppState()
        state.createNewTab()
        var document = state.currentDocument!
        var frontmatter = Frontmatter()
        frontmatter.title = "노트"
        document.frontmatter = frontmatter
        document.content = "본문"
        state.currentDocument = document
        state.originalContent = document.fullText
        XCTAssertEqual(state.activeTab?.isDirty, false)

        state.updateContent("본몬")
        XCTAssertEqual(state.activeTab?.isDirty, true)
        state.updateContent("본문")
        XCTAssertEqual(state.activeTab?.isDirty, false)
    }

    @MainActor
    func testDirtyFlagForALoadedFrontmatterNote() async throws {
        let loaded = try await R2EditorsyncHelperTests.load("---\ntitle: 노트\ntags: [a, b]\n---\n\n본문 body\n")
        let state = AppState()
        state.createNewTab()
        state.currentDocument = loaded
        state.originalContent = loaded.fullText
        XCTAssertEqual(state.activeTab?.isDirty, false)

        state.updateContent(loaded.content + "!")
        XCTAssertEqual(state.activeTab?.isDirty, true)
        state.updateContent(loaded.content)
        XCTAssertEqual(state.activeTab?.isDirty, false)
    }

    func testIdenticalUpdateKeepsTheRevision() {
        let state = AppState()
        state.createNewTab()
        state.updateContent("hello")
        let revision = state.currentDocument!.contentRevision
        state.updateContent(NSMutableString(string: "hello") as String)
        XCTAssertEqual(state.currentDocument!.contentRevision, revision)

        state.updateContent("hellp")
        XCTAssertNotEqual(state.currentDocument!.contentRevision, revision)
    }

    func testActiveDocumentChangeCommitsCompositionIntoTheOutgoingDocument() {
        let state = AppState()
        state.createNewTab()
        let first = state.activeTabId
        state.createNewTab()
        let second = state.activeTabId

        var seen: [UUID?] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .commitPendingComposition, object: nil, queue: nil
        ) { _ in
            seen.append(state.activeTabId)
            state.updateContent("composed")  // what the editor's push does
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        state.activeTabId = first
        XCTAssertEqual(seen, [second], "posted before the switch")
        XCTAssertEqual(state.tabs.first { $0.id == second }.flatMap { state.documents[$0.documentId]?.content }, "composed")
        XCTAssertEqual(state.currentDocument?.content, "")

        state.activeTabId = first  // not a change
        XCTAssertEqual(seen.count, 1)
    }
}

// MARK: - Hosted editor

@Observable
private final class EditorHostModel {
    var text: String
    var documentID = UUID()
    var isVisible = true
    var fontSize: CGFloat = 14
    var softWrap = true
    var revision = 0

    init(text: String) { self.text = text }
}

private struct EditorHost: View {
    let model: EditorHostModel

    var body: some View {
        // Like EditorPane, the body depends on the document text, so every
        // keystroke re-runs updateNSView.
        let _ = model.text
        let _ = model.revision
        MarkdownTextEditor(
            documentID: model.documentID,
            isVisible: model.isVisible,
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            font: .monospacedSystemFont(ofSize: model.fontSize, weight: .regular),
            editorTheme: .cmdsLight,
            softWrap: model.softWrap,
            showLineNumbers: true,
            highlightCurrentLine: true,
            tabSize: 4,
            insertSpacesForTab: true,
            enableCompletion: false,
            scrollSyncEnabled: false,
            copySelectionOnDrag: false
        )
    }
}

final class R2EditorsyncHostedEditorTests: XCTestCase {
    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!
    private var model: EditorHostModel!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        host?.rootView = AnyView(EmptyView())
        spin(0.02)
        window?.close()
        window = nil
        host = nil
        model = nil
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins until SwiftUI has delivered the update `condition` waits for.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.01) }
    }

    @MainActor
    private func mount(_ text: String) -> CmdMDTextView {
        model = EditorHostModel(text: text)
        host = NSHostingView(rootView: AnyView(EditorHost(model: model)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        spin(0.05)
        let textView = Self.find(in: host)
        XCTAssertNotNil(textView)
        // The app's editor falls back to TextKit 1 at its first draw (the
        // ruler and current-line band use the layout manager).
        _ = textView?.layoutManager
        return textView!
    }

    private static func find(in view: NSView) -> CmdMDTextView? {
        if let textView = view as? CmdMDTextView { return textView }
        for subview in view.subviews {
            if let found = find(in: subview) { return found }
        }
        return nil
    }

    private func fontSize(_ textView: NSTextView, at index: Int) -> CGFloat {
        (textView.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    private func type(_ text: String, into textView: NSTextView) {
        textView.insertText(text, replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
    }

    // F004 / F095: a keystroke or any other re-render must not reset the font.

    @MainActor
    func testUpdatesKeepStyledFontRuns() {
        let textView = mount("# Heading\nbody text")
        XCTAssertGreaterThan(fontSize(textView, at: 2), 14, "heading styled at mount")

        type("x", into: textView)
        XCTAssertTrue(model.text.hasSuffix("x"), "keystroke pushed")
        spin(0.04)  // past the update, before the 150 ms re-highlight
        XCTAssertGreaterThan(fontSize(textView, at: 2), 14, "a keystroke's update reset the heading font")

        model.revision += 1  // a save stamp / mode switch: no re-highlight follows
        spin(0.3)
        XCTAssertGreaterThan(fontSize(textView, at: 2), 14, "a non-text update reset the heading font")

        // Zoom still applies the base font at once, and restyles after.
        model.fontSize = 20
        waitUntil { self.fontSize(textView, at: 12) == 20 }
        XCTAssertEqual(fontSize(textView, at: 12), 20)
        waitUntil { self.fontSize(textView, at: 2) > 20 }
        XCTAssertGreaterThan(fontSize(textView, at: 2), 20)
    }

    @MainActor
    func testTypingInsideAHeadingKeepsItsFont() {
        let textView = mount("# Heading\nbody")
        window.makeFirstResponder(textView)
        let headingSize = fontSize(textView, at: 2)
        XCTAssertGreaterThan(headingSize, 14)

        textView.setSelectedRange(NSRange(location: 9, length: 0))
        textView.insertText("Q", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.03)  // the keystroke's update, before the 150 ms re-highlight
        textView.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.03)
        XCTAssertEqual(fontSize(textView, at: 9), headingSize)
        XCTAssertEqual(fontSize(textView, at: 10), headingSize, "typed after an update, at body size")
    }

    // F006 / F110: the soft-wrap container is what width tracking computes.

    @MainActor
    func testSoftWrapContainerMatchesTrackedWidth() {
        let textView = mount(String(repeating: "lorem ipsum dolor sit amet ", count: 80))
        let inset = 2 * textView.textContainerInset.width
        XCTAssertEqual(textView.textContainer!.size.width, textView.frame.width - inset, accuracy: 0.5)

        type("y", into: textView)
        spin(0.05)
        XCTAssertEqual(textView.textContainer!.size.width, textView.frame.width - inset, accuracy: 0.5)
        model.revision += 1  // a non-text update leaves it alone
        spin(0.05)
        XCTAssertEqual(textView.textContainer!.size.width, textView.frame.width - inset, accuracy: 0.5)

        model.softWrap = false
        waitUntil { textView.textContainer!.size.width > 10_000 }
        model.softWrap = true
        waitUntil { textView.textContainer!.size.width < 10_000 }
        let clip = textView.enclosingScrollView!.contentSize.width
        XCTAssertEqual(textView.frame.width, clip, accuracy: 0.5)
        XCTAssertEqual(textView.textContainer!.size.width, clip - inset, accuracy: 0.5)
    }

    // F001: an update mid-composition leaves the marked text alone.

    @MainActor
    func testUpdateDuringIMECompositionKeepsMarkedText() {
        let textView = mount("안녕하세")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.setMarkedText("요", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(model.text, "안녕하세", "marked text is not pushed")

        model.revision += 1  // e.g. the ⌘S modifiedAt stamp
        spin(0.05)
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "안녕하세요")

        // AppState asks for a commit before a switch or save: it is pushed.
        NotificationCenter.default.post(name: .commitPendingComposition, object: nil)
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(model.text, "안녕하세요")
    }

    @MainActor
    func testHighlightPassDuringCompositionKeepsIt() throws {
        let textView = mount("# 안녕하세")
        let coordinator = try XCTUnwrap(textView.delegate as? MarkdownTextEditor.Coordinator)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.setMarkedText("요", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))

        coordinator.applyHighlightingNow()  // the typing-pause pass
        XCTAssertTrue(textView.hasMarkedText())
        // The next jamo still reworks the syllable being composed.
        textView.setMarkedText("욕", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("욕", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(textView.string, "# 안녕하세욕")
        XCTAssertEqual(model.text, "# 안녕하세욕")
    }

    @MainActor
    func testModelChangeDuringCompositionWinsWithoutPushingTheSyllable() {
        let textView = mount("abc")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))

        model.text = "- [x] abc"
        waitUntil { textView.string == "- [x] abc" }
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "- [x] abc")
        XCTAssertEqual(model.text, "- [x] abc")
    }

    @MainActor
    func testTabSwitchDuringCompositionDoesNotLeakIntoTheNewDocument() {
        let textView = mount("# Doc A")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.setMarkedText("의", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))

        model.documentID = UUID()
        model.text = "# Doc B\nbody"
        waitUntil { textView.string == "# Doc B\nbody" }
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "# Doc B\nbody")
        XCTAssertEqual(model.text, "# Doc B\nbody")
    }

    // F127 / F002: programmatic replacements leave a consistent undo stack.
    // A real keystroke's undo group closes with its event; `spin` after
    // `type` does the same, or (on macOS 15) the model change lands while
    // the typing group is still open.

    @MainActor
    func testDiskReloadDropsUndoHistory() {
        let textView = mount("alpha beta")
        window.makeFirstResponder(textView)
        type(" TYPED", into: textView)
        spin(0.02)
        XCTAssertEqual(textView.undoManager?.canUndo, true)

        NotificationCenter.default.post(name: .documentReloadedFromDisk, object: model.documentID)
        model.text = "\nalpha beta TYPED"
        waitUntil { textView.string == "\nalpha beta TYPED" }
        XCTAssertEqual(textView.string, "\nalpha beta TYPED")
        XCTAssertEqual(textView.undoManager?.canUndo, false)

        // Shorter than what an old undo entry would address.
        type("Z", into: textView)
        spin(0.02)
        NotificationCenter.default.post(name: .documentReloadedFromDisk, object: model.documentID)
        model.text = "short"
        waitUntil { textView.string == "short" }
        XCTAssertEqual(textView.string, "short")
        XCTAssertEqual(textView.undoManager?.canUndo, false)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "short")
        XCTAssertEqual(model.text, "short")
    }

    @MainActor
    func testDiskReloadKeepsUnrelatedUndoEntries() throws {
        let textView = mount("alpha")
        let undoManager = try XCTUnwrap(textView.undoManager)
        final class Field {}
        let field = Field()
        var fieldUndone = false
        // e.g. an Inspector text field sharing the window's undo manager
        undoManager.registerUndo(withTarget: field) { _ in fieldUndone = true }
        spin(0.02)
        window.makeFirstResponder(textView)
        type(" beta", into: textView)
        spin(0.02)

        NotificationCenter.default.post(name: .documentReloadedFromDisk, object: model.documentID)
        model.text = "# alpha beta"
        waitUntil { textView.string == "# alpha beta" }
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertTrue(fieldUndone)
        XCTAssertEqual(textView.string, "# alpha beta")
        XCTAssertFalse(undoManager.canUndo)
    }

    @MainActor
    func testProgrammaticChangeIsOneUndoableStep() {
        let textView = mount("- [ ] task")
        window.makeFirstResponder(textView)
        type("!", into: textView)
        spin(0.02)
        XCTAssertEqual(model.text, "- [ ] task!")

        model.text = "- [x] task!"  // a preview checkbox toggle
        waitUntil { textView.string == "- [x] task!" }
        XCTAssertEqual(textView.string, "- [x] task!")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 0), "caret kept its place")

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "- [ ] task!")
        XCTAssertEqual(model.text, "- [ ] task!")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "- [ ] task")
        XCTAssertEqual(model.text, "- [ ] task")
    }

    // F003: hidden in preview, the editor never takes keyboard focus.

    @MainActor
    func testHiddenEditorNeverTakesFocus() {
        let textView = mount("# Title\nline two\nline three")
        window.makeFirstResponder(textView)
        XCTAssertTrue(window.firstResponder === textView)

        model.isVisible = false
        waitUntil { self.window.firstResponder !== textView }
        XCTAssertFalse(window.firstResponder === textView, "focus given up when hidden")

        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertFalse(window.firstResponder === textView)

        NotificationCenter.default.post(name: .scrollToLine, object: 2)
        spin(0.05)
        XCTAssertFalse(window.firstResponder === textView, "search-hit scroll took focus")
        XCTAssertEqual(textView.selectedRange().location, 8, "the caret still lands on the hit")

        // Shown again, it takes focus back, with the caret still on the hit.
        model.isVisible = true
        waitUntil { self.window.firstResponder === textView }
        XCTAssertTrue(window.firstResponder === textView, "focus handed back when shown")
        XCTAssertEqual(textView.selectedRange().location, 8)

        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: .scrollToLine, object: 3)
        waitUntil { self.window.firstResponder === textView }
        XCTAssertTrue(window.firstResponder === textView, "a visible editor takes focus on a hit")
    }

    @MainActor
    func testHidingTheEditorTakesFocusFromItsFindBar() throws {
        let textView = mount("find me\nsecond line")
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        func focusInFindBar() -> Bool {
            guard let responder = window.firstResponder as? NSView, responder !== textView else { return false }
            return responder.isDescendant(of: scrollView)
        }
        window.makeFirstResponder(textView)
        NotificationCenter.default.post(name: .showDocumentSearch, object: nil)
        waitUntil(timeout: 1) { focusInFindBar() }
        try XCTSkipUnless(focusInFindBar(), "the find bar did not take focus in this environment")

        model.isVisible = false
        waitUntil { !focusInFindBar() }
        XCTAssertFalse(focusInFindBar(), "the hidden find field kept focus")
        XCTAssertFalse(window.firstResponder === textView)
    }

    // F021: a selection erases the band painted for the caret.

    @MainActor
    func testSelectionErasesTheCurrentLineBand() {
        let textView = mount(String(repeating: "wrapped paragraph text ", count: 60))
        textView.setSelectedRange(NSRange(location: 40, length: 0))
        let rect = textView.visibleRect
        if let rep = textView.bitmapImageRepForCachingDisplay(in: rect) {
            textView.cacheDisplay(in: rect, to: rep)
        }
        XCTAssertNotNil(textView.paintedBandRect)

        // The band rect was invalidated (and forgotten) when the caret became
        // a selection, so the next draw paints that area without the band.
        textView.setSelectedRange(NSRange(location: 40, length: 5))
        XCTAssertNil(textView.paintedBandRect)
    }

    // F023: losing focus reports back (the editor dismisses completion on it).

    @MainActor
    func testResignFirstResponderIsReported() {
        let textView = mount("[[No")
        XCTAssertNotNil(textView.onResignFirstResponder)
        var resigned = 0
        textView.onResignFirstResponder = { resigned += 1 }
        window.makeFirstResponder(textView)
        window.makeFirstResponder(nil)
        XCTAssertEqual(resigned, 1)
    }
}
