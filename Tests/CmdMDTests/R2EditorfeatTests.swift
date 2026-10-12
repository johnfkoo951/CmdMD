import XCTest
import AppKit
@testable import CmdMD

final class R2EditorfeatTests: XCTestCase {
    // MARK: Smart list continuation (F014)

    /// Presses Enter at the `|` in `marked`; returns the text with `|` at the
    /// new caret, or nil when Enter should insert a plain newline.
    private func enter(_ marked: String, tabSize: Int = 4) -> String? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
        guard let edit = ListContinuation.edit(forNewlineIn: text, at: caret, tabSize: tabSize) else { return nil }
        let result = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        return result.replacingCharacters(in: NSRange(location: edit.caret, length: 0), with: "|")
    }

    func testEnterRightAfterTheMarkerOpensAnItemAboveInsteadOfDeletingTheMarker() {
        XCTAssertEqual(enter("- |Buy milk"), "- \n- |Buy milk")
        XCTAssertEqual(enter("- [ ] |Call Bob"), "- [ ] \n- [ ] |Call Bob")
        XCTAssertEqual(enter("1. |First step"), "1. \n2. |First step")
        XCTAssertEqual(enter("> |quoted"), "> \n> |quoted")
    }

    func testEnterContinuesNonEmptyItems() {
        XCTAssertEqual(enter("- item|"), "- item\n- |")
        XCTAssertEqual(enter("* a|b"), "* a\n* |b")
        XCTAssertEqual(enter("9) nine|"), "9) nine\n10) |")
        XCTAssertEqual(enter("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(enter("  - nested|"), "  - nested\n  - |")
    }

    func testEnterOnAnEmptyTopLevelItemEndsTheList() {
        XCTAssertEqual(enter("- a\n- |\nnext"), "- a\n|\nnext")
        XCTAssertEqual(enter("- |   "), "|")
        XCTAssertEqual(enter("1. |"), "|")
        XCTAssertEqual(enter("> |"), "|")
        // An empty task item, with or without the space after the box.
        XCTAssertEqual(enter("- [ ]|"), "|")
        XCTAssertEqual(enter("- [ ] |"), "|")
        // CRLF line endings: the clear stops at the line's contents.
        XCTAssertEqual(enter("- a\r\n- |\r\nb"), "- a\r\n|\r\nb")
    }

    func testEnterOnAnEmptyNestedItemOutdentsOneLevel() {
        XCTAssertEqual(enter("- a\n    - |", tabSize: 4), "- a\n- |")
        XCTAssertEqual(enter("        - |", tabSize: 4), "    - |")
        XCTAssertEqual(enter("\t\t- [ ] |"), "\t- [ ] |")
        XCTAssertEqual(enter("  1. |", tabSize: 4), "1. |")
    }

    func testEnterLeavesThematicBreaksAndPlainLinesAlone() {
        XCTAssertNil(enter("* * *|"))
        XCTAssertNil(enter("- - -|"))
        XCTAssertNil(enter("plain text|"))
        XCTAssertNil(enter("|- item"))
        XCTAssertNil(enter("-|"))
        XCTAssertNil(enter("|"))
    }

    // MARK: Plain-text copy (F008)

    @MainActor
    func testCopyWritesPlainTextWithoutThemeColors() {
        let textView = CmdMDTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.isRichText = true
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "see **bold** 한글",
            attributes: [.foregroundColor: NSColor.white, .backgroundColor: NSColor.darkGray]
        ))
        textView.setSelectedRange(NSRange(location: 4, length: 11))

        let types = textView.writablePasteboardTypes
        XCTAssertFalse(types.isEmpty)
        XCTAssertFalse(types.contains(.rtf))
        XCTAssertFalse(types.contains(.rtfd))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmdmd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: types), "writing must actually succeed")
        XCTAssertEqual(pasteboard.string(forType: .string), "**bold** 한글")
        XCTAssertFalse(pasteboard.types?.contains(.rtf) ?? false)
        XCTAssertFalse(pasteboard.types?.contains(.rtfd) ?? false)

        // No selection: nothing writable, as before.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.writablePasteboardTypes.isEmpty)
    }

    // MARK: Copy-on-drag vs. select-to-replace (F009)

    @MainActor
    private func makeAutoCopyEditor(_ text: String, clipboard: String) -> (CmdMDTextView, NSPasteboard) {
        let textView = CmdMDTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.string = text
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmdmd-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(clipboard, forType: .string)
        textView.pasteboard = pasteboard
        return (textView, pasteboard)
    }

    @MainActor
    func testPastingOverTheAutoCopiedSelectionPastesThePreviousClipboard() {
        let (textView, pasteboard) = makeAutoCopyEditor("see link here", clipboard: "URL")
        defer { pasteboard.releaseGlobally() }

        let link = NSRange(location: 4, length: 4)
        textView.setSelectedRange(link)
        textView.copyToPasteboard(link)
        XCTAssertEqual(pasteboard.string(forType: .string), "link", "copy-on-drag still copies")

        textView.pasteAsPlainText(nil)
        XCTAssertEqual(textView.string, "see URL here")

        // A second select-to-replace still pastes the explicit copy.
        let here = NSRange(location: 8, length: 4)
        textView.setSelectedRange(here)
        textView.copyToPasteboard(here)
        textView.pasteAsPlainText(nil)
        XCTAssertEqual(textView.string, "see URL URL")
    }

    @MainActor
    func testOtherPastesKeepTheAutoCopiedText() {
        let (textView, pasteboard) = makeAutoCopyEditor("see link here", clipboard: "URL")
        defer { pasteboard.releaseGlobally() }

        let link = NSRange(location: 4, length: 4)
        textView.setSelectedRange(link)
        textView.copyToPasteboard(link)

        // Pasting somewhere else pastes the auto-copied selection.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(textView.clipboardForSelfReplacingPaste())

        // A newer explicit copy wins over the remembered clipboard.
        textView.setSelectedRange(link)
        XCTAssertEqual(textView.clipboardForSelfReplacingPaste(), "URL")
        pasteboard.clearContents()
        pasteboard.setString("other", forType: .string)
        XCTAssertNil(textView.clipboardForSelfReplacingPaste())
    }

    // MARK: Image drops (F007)

    func testImageMarkdownEncodesSpacesAndKeepsKoreanReadable() {
        XCTAssertEqual(
            EditorPane.imageMarkdown(name: "Screenshot 1", path: "assets/Screenshot 1.png"),
            "![Screenshot 1](assets/Screenshot%201.png)"
        )
        XCTAssertEqual(
            EditorPane.imageMarkdown(name: "스크린샷 2026-10-12 오후 3.04.12", path: "assets/스크린샷 2026-10-12 오후 3.04.12.png"),
            "![스크린샷 2026-10-12 오후 3.04.12](assets/스크린샷%202026-10-12%20오후%203.04.12.png)"
        )
        // uniquified() names, URL-significant characters, narrow no-break space.
        XCTAssertEqual(
            EditorPane.imageMarkdown(name: "a (1)", path: "assets/a (1).png"),
            "![a (1)](assets/a%20%281%29.png)"
        )
        XCTAssertEqual(
            EditorPane.imageMarkdown(name: "x", path: "assets/100% #1?.png"),
            "![x](assets/100%25%20%231%3F.png)"
        )
        XCTAssertEqual(
            EditorPane.imageMarkdown(name: "x", path: "assets/3.04\u{202F}PM.png"),
            "![x](assets/3.04%E2%80%AFPM.png)"
        )
    }

    func testImageMarkdownRendersAsAnImage() {
        let markdown = EditorPane.imageMarkdown(name: "Screenshot 1", path: "assets/Screenshot 1.png")
        let html = MarkdownRenderer().renderToHTML(markdown: markdown)
        XCTAssertTrue(html.contains("<img"), "a destination with a raw space rendered as literal text")
    }

    @MainActor
    func testOnlyImageFilesOnTheDragPasteboardAreTakenOver() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmdmd-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let png = URL(fileURLWithPath: "/tmp/Screenshot 1.PNG")
        let note = URL(fileURLWithPath: "/tmp/note.md")
        pasteboard.writeObjects([png as NSURL, note as NSURL])

        XCTAssertEqual(CmdMDTextView.imageFileURLs(on: pasteboard).map(\.lastPathComponent), ["Screenshot 1.PNG"])

        pasteboard.clearContents()
        pasteboard.setString("dragged text", forType: .string)
        XCTAssertTrue(CmdMDTextView.imageFileURLs(on: pasteboard).isEmpty)
    }

    @MainActor
    func testDroppedImagesAreInsertedAtTheDropPoint() {
        let textView = CmdMDTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.string = "before after"
        textView.setSelectedRange(NSRange(location: 12, length: 0))
        var dropped: [URL] = []
        textView.onImageDrop = { url in
            dropped.append(url)
            return "![\(url.deletingPathExtension().lastPathComponent)](assets/\(url.lastPathComponent))"
        }

        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        XCTAssertTrue(textView.insertImages(urls, at: 7))
        XCTAssertEqual(dropped, urls)
        XCTAssertEqual(textView.string, "before ![a](assets/a.png)\n![b](assets/b.png)after")
        XCTAssertEqual(textView.selectedRange().location, 7 + ("![a](assets/a.png)\n![b](assets/b.png)" as NSString).length)

        // A handler that declines leaves the drop to AppKit.
        textView.onImageDrop = { _ in nil }
        XCTAssertFalse(textView.insertImages(urls, at: 0))
    }

    // MARK: Find routing (F126)

    func testFindCommandsGoToTheVisiblePane() {
        XCTAssertEqual(DocumentFind.notificationName(for: .preview), .previewFindCommand)
        XCTAssertEqual(DocumentFind.notificationName(for: .split), .showDocumentSearch)
        XCTAssertEqual(DocumentFind.notificationName(for: .source), .showDocumentSearch)
    }

    func testFindInPreviewPostsTheMenuAction() {
        let expectation = expectation(forNotification: .previewFindCommand, object: nil) { note in
            note.object as? NSTextFinder.Action == .previousMatch
        }
        DocumentFind.perform(.previousMatch, in: .preview)
        wait(for: [expectation], timeout: 1)
    }

    func testPreviewFindConfiguration() {
        let forward = PreviewFindRequest(query: "alpha").configuration
        XCTAssertFalse(forward.backwards)
        XCTAssertFalse(forward.caseSensitive)
        XCTAssertTrue(forward.wraps)
        XCTAssertTrue(PreviewFindRequest(query: "alpha", backwards: true).configuration.backwards)
    }
}
