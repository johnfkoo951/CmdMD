import XCTest
import AppKit
import SwiftUI
@testable import CmdMD

// MARK: - Line index edits

/// The line index follows storage edits instead of rescanning the text per
/// keystroke; after any sequence of edits it must equal a rebuild.
final class LineIndexEditTests: XCTestCase {
    private func assertMatchesRebuild(_ index: LineIndex, _ text: NSString, _ message: String, line: UInt = #line) {
        let fresh = LineIndex()
        fresh.rebuild(from: text)
        XCTAssertEqual(index.newlinePositions, fresh.newlinePositions, message, line: line)
        XCTAssertEqual(index.lineCount, fresh.lineCount, message, line: line)
        for location in Set([0, text.length / 3, text.length / 2, text.length]) {
            XCTAssertEqual(index.lineNumber(at: location), fresh.lineNumber(at: location), "\(message) @\(location)", line: line)
        }
        for number in Set([1, 2, fresh.lineCount / 2, fresh.lineCount, fresh.lineCount + 1]) {
            XCTAssertEqual(index.startLocation(ofLine: number), fresh.startLocation(ofLine: number), "\(message) line \(number)", line: line)
        }
    }

    /// Replaces `range` with `replacement` and reports it the way
    /// NSTextStorage does: the new characters' range and the length change.
    private func edit(_ text: NSMutableString, _ index: LineIndex, _ range: NSRange, _ replacement: String) {
        text.replaceCharacters(in: range, with: replacement)
        let inserted = (replacement as NSString).length
        index.applyEdit(in: text, editedRange: NSRange(location: range.location, length: inserted),
                        changeInLength: inserted - range.length)
    }

    func testTypingDeletingAndPastingKeepTheIndexExact() {
        let text = NSMutableString(string: "first\nsecond\n\nfourth line\nfifth")
        let index = LineIndex()
        index.rebuild(from: text)

        edit(text, index, NSRange(location: 3, length: 0), "x")             // typing in line 1
        assertMatchesRebuild(index, text, "typing")
        edit(text, index, NSRange(location: 4, length: 0), "y")             // more typing, same place
        assertMatchesRebuild(index, text, "typing again")
        edit(text, index, NSRange(location: 20, length: 0), "z")            // typing further down
        assertMatchesRebuild(index, text, "typing elsewhere")
        edit(text, index, NSRange(location: 2, length: 0), "a")             // back up
        assertMatchesRebuild(index, text, "typing above")
        edit(text, index, NSRange(location: 8, length: 0), "\n")            // Enter
        assertMatchesRebuild(index, text, "newline")
        edit(text, index, NSRange(location: 8, length: 1), "")              // Backspace over it
        assertMatchesRebuild(index, text, "join")
        edit(text, index, NSRange(location: 5, length: 12), "p\nq\nr")      // paste over line breaks
        assertMatchesRebuild(index, text, "paste")
        edit(text, index, NSRange(location: 0, length: text.length), "")    // select all, delete
        assertMatchesRebuild(index, text, "emptied")
        edit(text, index, NSRange(location: 0, length: 0), "one\ntwo\n")    // into an empty text
        assertMatchesRebuild(index, text, "refilled")
    }

    func testRandomEditsMatchARebuild() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "bc", "\n", "\n\n", "한글", "😀", "x\ny", ""]
        let text = NSMutableString(string: "alpha\nbeta\ngamma\n\ndelta\n")
        let index = LineIndex()
        index.rebuild(from: text)
        for step in 0..<400 {
            let location = Int.random(in: 0...text.length, using: &generator)
            let length = Int.random(in: 0...min(6, text.length - location), using: &generator)
            edit(text, index, NSRange(location: location, length: length), pieces.randomElement(using: &generator)!)
            if step % 25 == 0 { assertMatchesRebuild(index, text, "step \(step)") }
            XCTAssertEqual(index.lineCount, text.components(separatedBy: "\n").count, "step \(step)")
        }
        assertMatchesRebuild(index, text, "end")
    }
}

// MARK: - Hosted editor

@Observable
private final class HotPathHostModel {
    var text: String
    let documentID = UUID()
    var highlightCurrentLine = true
    var caret: (line: Int, column: Int) = (0, 0)

    init(text: String) { self.text = text }
}

private struct HotPathHost: View {
    let model: HotPathHostModel

    var body: some View {
        // Like EditorPane, the body reads the text: every keystroke re-runs
        // updateNSView.
        let _ = model.text
        MarkdownTextEditor(
            documentID: model.documentID,
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            editorTheme: .cmdsLight,
            softWrap: true,
            showLineNumbers: true,
            highlightCurrentLine: model.highlightCurrentLine,
            tabSize: 4,
            insertSpacesForTab: true,
            enableCompletion: false,
            scrollSyncEnabled: false,
            copySelectionOnDrag: false,
            onSelectionChange: { [model] line, column in model.caret = (line, column) }
        )
    }
}

/// What a keystroke or a caret move repaints, with the real editor in a
/// window: the typing path must stay proportional to the edit, not to the
/// document or the page.
final class EditorHotPathTests: XCTestCase {
    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!
    private var model: HotPathHostModel!
    private var invalidated: [NSRect] = []

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

    @MainActor
    private func mount(_ text: String, band: Bool = true) throws -> CmdMDTextView {
        model = HotPathHostModel(text: text)
        model.highlightCurrentLine = band
        host = NSHostingView(rootView: AnyView(HotPathHost(model: model)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        spin(0.05)
        let textView = try XCTUnwrap(Self.find(CmdMDTextView.self, in: host))
        window.makeFirstResponder(textView)
        textView.onInvalidate = { [unowned self] rect in invalidated.append(rect) }
        return textView
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    private func ruler(of textView: NSTextView) throws -> NSRulerView {
        try XCTUnwrap(textView.enclosingScrollView?.verticalRulerView)
    }

    /// Draws everything dirty, then forgets what was invalidated so far.
    private func settle(_ textView: NSTextView) throws {
        spin(0.02)
        textView.displayIfNeeded()
        let ruler = try ruler(of: textView)
        ruler.displayIfNeeded()
        ruler.layer?.displayIfNeeded()
        XCTAssertFalse(isMarkedForRedraw(ruler))
        invalidated = []
    }

    private func wasInvalidated(_ rect: NSRect) -> Bool {
        invalidated.contains { $0.intersects(rect) }
    }

    /// Laid-out rect of the logical line holding `location`, full width.
    private func lineRect(_ textView: NSTextView, at location: Int) throws -> NSRect {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let ns = textView.string as NSString
        let glyphs = layoutManager.glyphRange(forCharacterRange: ns.lineRange(for: NSRange(location: location, length: 0)), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerInset.height
        rect.origin.x = 0
        rect.size.width = textView.bounds.width
        return rect
    }

    private func location(of needle: String, in textView: NSTextView) -> Int {
        (textView.string as NSString).range(of: needle).location
    }

    /// A small rect inside the line holding `needle` (inset off its edges).
    private func probe(_ textView: NSTextView, line needle: String) throws -> NSRect {
        try lineRect(textView, at: location(of: needle, in: textView)).insetBy(dx: 40, dy: 4)
    }

    /// Ends with a line break, as files do. TextKit 1 then answers every
    /// edit by marking everything from the edited line to the end of the
    /// text for redraw (without the final line break it marks only what it
    /// re-lays out).
    private static func lines(_ count: Int) -> String {
        (1...count).map { "line \($0) of the note" }.joined(separator: "\n") + "\n"
    }

    // MARK: Current-line band

    @MainActor
    func testCaretMoveRepaintsTheOldAndNewBandOnly() throws {
        let textView = try mount(Self.lines(30))
        textView.setSelectedRange(NSRange(location: location(of: "line 3 ", in: textView), length: 0))
        try settle(textView)
        let oldBand = try XCTUnwrap(textView.paintedBandRect)

        textView.setSelectedRange(NSRange(location: location(of: "line 9 ", in: textView), length: 0))

        XCTAssertTrue(wasInvalidated(oldBand.insetBy(dx: 40, dy: 2)), "the band left behind is erased")
        XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 9 ")), "the new band is painted")
        // needsDisplay = true over the bounds repainted (and laid out) the
        // whole document on every caret move and keystroke.
        XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 6 ")))
        XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 14 ")))
    }

    @MainActor
    func testAnUnmovedBandIsNotRepainted() throws {
        let textView = try mount(Self.lines(30))
        textView.setSelectedRange(NSRange(location: location(of: "line 5 ", in: textView) + 4, length: 0))
        try settle(textView)
        let band = try XCTUnwrap(textView.paintedBandRect)

        textView.repaintCurrentLineBand()
        XCTAssertTrue(invalidated.isEmpty)

        textView.insertText("x", replacementRange: textView.selectedRange())
        try settle(textView)
        XCTAssertEqual(textView.paintedBandRect, band, "typing keeps the band where it is")
    }

    // MARK: Repaints below an edited line

    /// NSRulerView doesn't report its own needsDisplay; its layer does.
    private func isMarkedForRedraw(_ ruler: NSRulerView) -> Bool {
        ruler.layer?.needsDisplay() == true
    }

    @MainActor
    func testTypingInsideALineRepaintsNothingBelowIt() throws {
        let textView = try mount(Self.lines(30))
        let line5 = location(of: "line 5 ", in: textView)
        textView.setSelectedRange(NSRange(location: line5 + 7, length: 0))
        try settle(textView)
        let ruler = try ruler(of: textView)

        for character in ["a", "b", "c"] {
            textView.insertText(character, replacementRange: textView.selectedRange())
            XCTAssertTrue(textView.isHoldingRepaintsBelowEdit)
            XCTAssertFalse(isMarkedForRedraw(ruler), "no line number moved")
            textView.displayIfNeeded()
            XCTAssertFalse(textView.isHoldingRepaintsBelowEdit, "the draw ends the hold")
            XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 5 ")), "the edited line is redrawn")
            XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 7 ")), "\(character): the lines below stay")
            XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 15 ")), "\(character): the lines below stay")
            try settle(textView)
        }
        textView.deleteBackward(nil)
        XCTAssertTrue(textView.isHoldingRepaintsBelowEdit, "Backspace inside a line")
        textView.displayIfNeeded()
        XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 9 ")), "Backspace inside a line")
        XCTAssertEqual(model.text, textView.string)

        // Several keystrokes before one draw: still one line's worth.
        try settle(textView)
        for character in ["x", "y", "z"] {
            textView.insertText(character, replacementRange: textView.selectedRange())
        }
        textView.displayIfNeeded()
        XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 7 ")))
        XCTAssertTrue(textView.string.contains("line 5 abxyzof"))
    }

    /// Without the band nothing asks for the line's rect during the edit;
    /// the hold still catches TextKit's repaint before the draw.
    @MainActor
    func testTypingInsideALineWithoutTheBandRepaintsNothingBelowIt() throws {
        let textView = try mount(Self.lines(30), band: false)
        textView.setSelectedRange(NSRange(location: location(of: "line 5 ", in: textView) + 7, length: 0))
        try settle(textView)
        for character in ["a", "b"] {
            textView.insertText(character, replacementRange: textView.selectedRange())
            XCTAssertTrue(textView.isHoldingRepaintsBelowEdit)
            textView.displayIfNeeded()
            XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 5 ")), "the edited line is redrawn")
            XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 8 ")), "\(character): the lines below stay")
            try settle(textView)
        }
    }

    @MainActor
    func testALineWrappingOntoAnotherLineRepaintsWhatMoved() throws {
        let textView = try mount("intro\n" + String(repeating: "word ", count: 8) + "\n" + Self.lines(20))
        let ruler = try ruler(of: textView)
        let paragraph = location(of: "word", in: textView)
        textView.setSelectedRange(NSRange(location: paragraph + 40, length: 0))
        try settle(textView)
        let height = try lineRect(textView, at: paragraph).height

        var wrapped = false
        for _ in 0..<40 {
            textView.insertText("more ", replacementRange: textView.selectedRange())
            textView.settleLineEdit()
            if try lineRect(textView, at: paragraph).height > height + 1 {
                wrapped = true
                XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 3 ")), "the lines below moved down")
                XCTAssertTrue(isMarkedForRedraw(ruler), "and so did their numbers")
                break
            }
            XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 3 ")), "nothing moved yet")
            XCTAssertFalse(isMarkedForRedraw(ruler), "nothing moved yet")
            try settle(textView)
        }
        XCTAssertTrue(wrapped, "the paragraph never wrapped")

        // Deleting back unwraps it: the lines below move up.
        try settle(textView)
        var unwrapped = false
        for _ in 0..<12 {
            textView.deleteBackward(nil)
            textView.settleLineEdit()
            if try lineRect(textView, at: paragraph).height < height + 1 {
                unwrapped = true
                XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 3 ")), "the lines below moved up")
                XCTAssertTrue(isMarkedForRedraw(ruler))
                break
            }
            try settle(textView)
        }
        XCTAssertTrue(unwrapped, "the paragraph never unwrapped")
    }

    @MainActor
    func testEditsAcrossLineBreaksRepaintBelow() throws {
        let textView = try mount(Self.lines(30))
        let line5 = location(of: "line 5 ", in: textView)
        textView.setSelectedRange(NSRange(location: line5 + 7, length: 0))
        try settle(textView)

        textView.insertNewline(nil)
        XCTAssertFalse(textView.isHoldingRepaintsBelowEdit)
        XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 9 ")), "Enter moves every line below")
        try settle(textView)

        textView.deleteBackward(nil)
        XCTAssertFalse(textView.isHoldingRepaintsBelowEdit, "joining lines moves them back")
        try settle(textView)

        textView.insertText("one\ntwo", replacementRange: textView.selectedRange())
        XCTAssertFalse(textView.isHoldingRepaintsBelowEdit, "a multi-line paste")
        XCTAssertEqual(model.text, textView.string)
    }

    @MainActor
    func testAnotherEditDuringTheHoldReleasesIt() throws {
        let textView = try mount(Self.lines(30))
        let line5 = location(of: "line 5 ", in: textView)
        textView.setSelectedRange(NSRange(location: line5 + 7, length: 0))
        try settle(textView)

        textView.insertText("a", replacementRange: textView.selectedRange())
        XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 9 ")), "held")
        // A highlight pass (any edit shouldChangeText didn't announce) before
        // the draw: what TextKit marked below can't be vouched for.
        let storage = try XCTUnwrap(textView.textStorage)
        storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 2))
        XCTAssertFalse(textView.isHoldingRepaintsBelowEdit)
        XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 9 ")))
    }

    /// TextKit gathers the repaints of edits before a draw into one range
    /// from the topmost edited line: after Enter further down, or a
    /// highlight pass, typing higher up must not hold that range back.
    @MainActor
    func testNothingIsHeldAfterAnotherEditBeforeTheDraw() throws {
        let textView = try mount(Self.lines(30))
        try settle(textView)

        let line14 = location(of: "line 14 ", in: textView)
        textView.setSelectedRange(NSRange(location: line14 + 7, length: 0))
        textView.insertNewline(nil)
        textView.setSelectedRange(NSRange(location: location(of: "line 5 ", in: textView) + 7, length: 0))
        textView.insertText("a", replacementRange: textView.selectedRange())
        XCTAssertFalse(textView.isHoldingRepaintsBelowEdit)
        textView.displayIfNeeded()
        XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 16 ")), "the lines Enter moved")
        try settle(textView)

        let storage = try XCTUnwrap(textView.textStorage)
        storage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: location(of: "line 12 ", in: textView), length: 6))
        textView.setSelectedRange(NSRange(location: location(of: "line 6 ", in: textView) + 7, length: 0))
        textView.insertText("b", replacementRange: textView.selectedRange())
        XCTAssertFalse(textView.isHoldingRepaintsBelowEdit)
        textView.displayIfNeeded()
        XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 12 ")), "the restyled line")

        // Once drawn, typing holds again.
        try settle(textView)
        textView.insertText("c", replacementRange: textView.selectedRange())
        XCTAssertTrue(textView.isHoldingRepaintsBelowEdit)
    }

    @MainActor
    func testAScrollDuringTheHoldReleasesIt() throws {
        let textView = try mount(Self.lines(60))
        let line5 = location(of: "line 5 ", in: textView)
        textView.setSelectedRange(NSRange(location: line5 + 7, length: 0))
        try settle(textView)

        textView.insertText("a", replacementRange: textView.selectedRange())
        let clip = try XCTUnwrap(textView.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 40))
        textView.settleLineEdit()
        XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 12 ")), "a scrolled view repaints what TextKit asked")
    }

    // MARK: Selection changes during the hold

    /// Keys queued behind a slow keystroke (or a key repeat) land in one
    /// run-loop pass: Shift-Down right after typing selects into the line
    /// below before the draw. NSTextView repaints that from the edited line
    /// down, which the hold took for TextKit's own and dropped.
    @MainActor
    private func assertShiftDownRightAfterTypingRepaintsTheLineBelow(band: Bool, line: UInt = #line) throws {
        let textView = try mount(Self.lines(30), band: band)
        textView.setSelectedRange(NSRange(location: location(of: "line 5 ", in: textView) + 7, length: 0))
        try settle(textView)

        textView.insertText("a", replacementRange: textView.selectedRange())
        XCTAssertTrue(textView.isHoldingRepaintsBelowEdit, line: line)
        textView.moveDownAndModifySelection(nil)
        XCTAssertGreaterThan(NSMaxRange(textView.selectedRange()), location(of: "line 6 ", in: textView), line: line)
        XCTAssertFalse(textView.isHoldingRepaintsBelowEdit, "the selection left the line", line: line)
        textView.displayIfNeeded()
        let line6 = try lineRect(textView, at: location(of: "line 6 ", in: textView)).insetBy(dx: 0, dy: 2)
        XCTAssertTrue(wasInvalidated(line6), "line 6, newly selected, is repainted", line: line)
    }

    @MainActor
    func testShiftDownRightAfterTypingRepaintsTheLineBelow() throws {
        try assertShiftDownRightAfterTypingRepaintsTheLineBelow(band: true)
    }

    @MainActor
    func testShiftDownRightAfterTypingWithoutTheBandRepaintsTheLineBelow() throws {
        try assertShiftDownRightAfterTypingRepaintsTheLineBelow(band: false)
    }

    @MainActor
    func testSelectAllRightAfterTypingRepaintsTheWholeSelection() throws {
        let textView = try mount(Self.lines(30))
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        try settle(textView)

        textView.insertText("a", replacementRange: textView.selectedRange())
        XCTAssertTrue(textView.isHoldingRepaintsBelowEdit)
        textView.selectAll(nil)
        textView.displayIfNeeded()
        for needle in ["line 2 ", "line 10 ", "line 18 "] {
            let rect = try lineRect(textView, at: location(of: needle, in: textView)).insetBy(dx: 0, dy: 2)
            XCTAssertTrue(wasInvalidated(rect), "\(needle)is repainted selected")
        }
    }

    /// A shift-click: the selection grows from the caret on the edited line
    /// to a few lines below it.
    @MainActor
    func testExtendingTheSelectionRightAfterTypingRepaintsIt() throws {
        let textView = try mount(Self.lines(30))
        textView.setSelectedRange(NSRange(location: location(of: "line 5 ", in: textView) + 7, length: 0))
        try settle(textView)

        textView.insertText("a", replacementRange: textView.selectedRange())
        let start = textView.selectedRange().location
        textView.setSelectedRange(NSRange(location: start, length: location(of: "line 9 ", in: textView) + 4 - start))
        textView.displayIfNeeded()
        let line7 = try lineRect(textView, at: location(of: "line 7 ", in: textView)).insetBy(dx: 0, dy: 2)
        XCTAssertTrue(wasInvalidated(line7))
    }

    /// The other way round: a selection over several lines, then an edit
    /// inside one line elsewhere. The selection's old lines lose their
    /// highlight and are repainted.
    @MainActor
    func testAnEditCollapsingASelectionOverLinesRepaintsThem() throws {
        let textView = try mount(Self.lines(30))
        let line5 = location(of: "line 5 ", in: textView)
        textView.setSelectedRange(NSRange(location: line5 + 2, length: location(of: "line 9 ", in: textView) - line5))
        try settle(textView)

        // An insert aimed at a range other than the selection, as an input
        // method's replacement range is: inside line 5.
        textView.insertText("a", replacementRange: NSRange(location: line5 + 7, length: 0))
        XCTAssertEqual(textView.selectedRange().length, 0)
        textView.displayIfNeeded()
        let line7 = try lineRect(textView, at: location(of: "line 7 ", in: textView)).insetBy(dx: 0, dy: 2)
        XCTAssertTrue(wasInvalidated(line7), "the old selection is erased")
    }

    /// Typing's own selection changes stay on the line, as old and new
    /// selections: Backspace and a word deletion at the line's end (the old
    /// caret is past the new end), typing over a word, the caret moving
    /// along the line, a composing input method selecting part of its
    /// marked text. The lines below are still left alone.
    @MainActor
    func testSelectionChangesOnTheLineKeepTheHold() throws {
        let textView = try mount(Self.lines(30))
        let line5 = location(of: "line 5 ", in: textView)
        let end5 = location(of: "line 6 ", in: textView) - 1
        textView.setSelectedRange(NSRange(location: end5, length: 0))
        try settle(textView)
        let noRange = NSRange(location: NSNotFound, length: 0)

        let steps: [(String, () -> Void)] = [
            ("typing at the line's end", { textView.insertText("abc", replacementRange: textView.selectedRange()) }),
            ("Backspace at the line's end", { textView.deleteBackward(nil) }),
            ("a word deleted backward", { textView.deleteWordBackward(nil) }),
            ("the caret moving along the line after a key", {
                textView.insertText("x", replacementRange: textView.selectedRange())
                textView.moveLeft(nil)
                textView.moveToBeginningOfLine(nil)
            }),
            ("typing over a word", {
                textView.insertText("y", replacementRange: textView.selectedRange())
                // "yline 5 of the x": "the".
                textView.setSelectedRange(NSRange(location: line5 + 11, length: 3))
                textView.insertText("a", replacementRange: textView.selectedRange())
            }),
            ("marked text selecting a clause", {
                textView.setMarkedText("かな", selectedRange: NSRange(location: 0, length: 2), replacementRange: noRange)
                textView.setMarkedText("仮名", selectedRange: NSRange(location: 2, length: 0), replacementRange: noRange)
                textView.insertText("仮名", replacementRange: noRange)
            }),
        ]
        for (name, step) in steps {
            step()
            XCTAssertTrue(textView.isHoldingRepaintsBelowEdit, name)
            textView.displayIfNeeded()
            XCTAssertTrue(wasInvalidated(try probe(textView, line: "line 5 ")), "\(name): the edited line is redrawn")
            XCTAssertFalse(wasInvalidated(try probe(textView, line: "line 7 ")), "\(name): the lines below stay")
            try settle(textView)
        }
        XCTAssertEqual(model.text, textView.string)
    }

    // MARK: Line index and IME

    /// Marked text is in the storage while composing (it never reaches the
    /// model): the index follows it, so the caret and the gutter count the
    /// view's text, and committing or cancelling leaves the index exact.
    @MainActor
    func testTheLineIndexFollowsMarkedText() throws {
        let textView = try mount("첫 줄\n둘째 줄\n셋째 줄\n넷째 줄")
        let second = location(of: "둘째", in: textView)
        textView.setSelectedRange(NSRange(location: second + 2, length: 0))
        try settle(textView)
        let noRange = NSRange(location: NSNotFound, length: 0)

        let index = try XCTUnwrap((textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.lineIndex)
        func assertCaret(_ message: String, line: UInt = #line) {
            let fresh = LineIndex()
            fresh.rebuild(from: textView.string as NSString)
            XCTAssertEqual(index.newlinePositions, fresh.newlinePositions, message, line: line)
            let expected = fresh.lineAndColumn(at: textView.selectedRange().location)
            spin(0.01)
            XCTAssertEqual(model.caret.line, expected.line, message, line: line)
            XCTAssertEqual(model.caret.column, expected.column, message, line: line)
        }

        for step in ["ㅎ", "하", "한"] {
            textView.setMarkedText(step, selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
            XCTAssertTrue(textView.hasMarkedText())
            XCTAssertTrue(textView.isHoldingRepaintsBelowEdit, "composing inside a line")
            assertCaret("composing \(step)")
        }
        textView.insertText("한", replacementRange: noRange)
        XCTAssertFalse(textView.hasMarkedText())
        assertCaret("committed")
        XCTAssertEqual(model.text, textView.string, "the committed syllable reached the model")

        // A later line, past the edit: its offset moved with the syllable.
        textView.setSelectedRange(NSRange(location: location(of: "넷째", in: textView) + 1, length: 0))
        assertCaret("a line after the edit")
        XCTAssertEqual(model.caret.line, 4)

        // A composition abandoned by moving the caret: the marked text goes.
        textView.setSelectedRange(NSRange(location: location(of: "셋째", in: textView), length: 0))
        textView.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        textView.unmarkText()
        textView.setSelectedRange(NSRange(location: location(of: "넷째", in: textView) + 2, length: 0))
        assertCaret("after a committed jamo")
        XCTAssertEqual(model.text, textView.string)
    }
}
