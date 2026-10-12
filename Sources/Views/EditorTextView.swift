import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let editorDidScroll = Notification.Name("editorDidScroll")
    /// Object: the id of a document whose text AppState just replaced, in
    /// place, with the version on disk.
    static let documentReloadedFromDisk = Notification.Name("documentReloadedFromDisk")
    /// Posted (synchronously) before the active document is swapped out or
    /// saved. An IME composition's marked text never reaches the model on its
    /// own, so the editor commits it into the document it was typed in.
    static let commitPendingComposition = Notification.Name("commitPendingComposition")
}

// MARK: - Line Index

/// Caches newline offsets (UTF-16) so line numbers, caret position, and
/// scroll-to-line are O(log n) lookups instead of rescanning the document.
final class LineIndex {
    private(set) var newlinePositions: [Int] = []
    /// Reused scan buffer — rebuilding runs on every keystroke, so a fresh
    /// 2×docSize allocation per keypress is real steady-state garbage.
    private var buffer: [unichar] = []

    func rebuild(from text: NSString) {
        let length = text.length
        guard length > 0 else {
            newlinePositions = []
            return
        }
        if buffer.count < length {
            buffer = [unichar](repeating: 0, count: length)
        }
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var positions: [Int] = []
        for i in 0..<length where buffer[i] == 0x0A {
            positions.append(i)
        }
        newlinePositions = positions
    }

    var lineCount: Int { newlinePositions.count + 1 }

    /// 1-based line number containing the given UTF-16 location.
    func lineNumber(at location: Int) -> Int {
        var low = 0, high = newlinePositions.count
        while low < high {
            let mid = (low + high) / 2
            if newlinePositions[mid] < location { low = mid + 1 } else { high = mid }
        }
        return low + 1
    }

    /// UTF-16 offset where the given 1-based line starts.
    func startLocation(ofLine line: Int) -> Int {
        guard line > 1 else { return 0 }
        let index = line - 2
        guard index < newlinePositions.count else {
            return newlinePositions.last.map { $0 + 1 } ?? 0
        }
        return newlinePositions[index] + 1
    }

    func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        let line = lineNumber(at: location)
        return (line, location - startLocation(ofLine: line) + 1)
    }
}

// MARK: - Text View

/// NSTextView with current-line highlighting, pinch-zoom forwarding, and
/// copy-on-drag-selection.
final class CmdMDTextView: NSTextView {
    var highlightCurrentLine = false
    var currentLineColor: NSColor = .clear

    /// False while preview mode keeps the editor mounted off-screen. A hidden
    /// editor must never take keyboard focus (a search-hit scroll, or the find
    /// bar handing focus back), or keystrokes edit the document invisibly.
    var isEditorVisible = true

    /// Called after the view gives up keyboard focus.
    var onResignFirstResponder: (() -> Void)?

    /// Where drawBackground last painted the current-line band.
    private(set) var paintedBandRect: NSRect?

    /// Pinch gesture delta sink — routes to the app-wide zoom level instead of
    /// AppKit's default (font-panel-based) magnification behavior.
    var onMagnify: ((CGFloat) -> Void)?

    /// When set, a selection made with the mouse is copied to the clipboard the
    /// moment the gesture ends.
    var copySelectionOnDrag = false

    /// Turns an image file dropped on the text into the markdown inserted at
    /// the drop point (copying it into ./assets); nil leaves the drop to AppKit.
    var onImageDrop: ((URL) -> String?)?

    /// The clipboard copy-on-drag writes to (tests substitute a private one).
    var pasteboard: NSPasteboard = .general

    /// Copy-on-drag makes "select the word, then ⌘V" paste the selection onto
    /// itself. Like X11's PRIMARY selection, remember what the clipboard held
    /// before the auto-copy, for a paste over exactly the auto-copied text.
    private var autoCopyChangeCount: Int?
    private var autoCopiedRange: NSRange?
    private var clipboardBeforeAutoCopy: String?

    override func magnify(with event: NSEvent) {
        guard let onMagnify else {
            super.magnify(with: event)
            return
        }
        onMagnify(event.magnification)
    }

    /// NSTextView's mouseDown runs a modal tracking loop that returns exactly
    /// at mouse-up, so "after super returns" IS the end of a drag selection
    /// (and of double/triple-click selections). Copying here — never during the
    /// drag — means each completed selection lands on the pasteboard as one
    /// distinct change that clipboard-history managers can capture, with no
    /// delay between rapid successive selections.
    override func mouseDown(with event: NSEvent) {
        let selectionBefore = selectedRange()
        super.mouseDown(with: event)
        guard copySelectionOnDrag else { return }
        let selection = selectedRange()
        guard selection.length > 0, selection != selectionBefore else { return }
        copyToPasteboard(selection)
    }

    func copyToPasteboard(_ range: NSRange) {
        let nsString = string as NSString
        guard range.location + range.length <= nsString.length else { return }
        let text = nsString.substring(with: range)
        // Back-to-back auto-copies keep the last explicit copy as "before".
        if pasteboard.changeCount != autoCopyChangeCount {
            clipboardBeforeAutoCopy = pasteboard.string(forType: .string)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        autoCopyChangeCount = pasteboard.changeCount
        autoCopiedRange = range
        Log.info("selection copied (\(text.count) chars)", .clipboard)
    }

    /// Markdown is plain text — pasting styled content (fonts, colors, image
    /// attachments from a browser or Pages) injected invisible rich attributes
    /// into the document. Always paste the plain-text representation.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// Also reached by Paste and Match Style. Pasting over the selection that
    /// copy-on-drag just copied would only write it back onto itself; paste
    /// what the clipboard held before instead (select-to-replace).
    override func pasteAsPlainText(_ sender: Any?) {
        if let previous = clipboardForSelfReplacingPaste() {
            insertAsSeparateEdit(FileService.normalizingLineEndings(previous).text, replacing: selectedRange())
            return
        }
        // Windows apps and web pages paste CRLF/CR breaks into an LF document:
        // the save came out mixed and the reload echo check misfired.
        if let text = pasteboard.string(forType: .string), text.contains("\r") {
            insertAsSeparateEdit(FileService.normalizingLineEndings(text).text, replacing: selectedRange())
            return
        }
        super.pasteAsPlainText(sender)
    }

    /// The pre-auto-copy clipboard when a paste now would replace the
    /// auto-copied selection with itself: the clipboard is untouched since
    /// the auto-copy and the same text is still selected. Nil otherwise —
    /// pasting elsewhere still pastes the auto-copied text.
    func clipboardForSelfReplacingPaste() -> String? {
        guard let previous = clipboardBeforeAutoCopy,
              pasteboard.changeCount == autoCopyChangeCount,
              let range = autoCopiedRange, selectedRange() == range,
              NSMaxRange(range) <= (string as NSString).length,
              (string as NSString).substring(with: range) == pasteboard.string(forType: .string)
        else { return nil }
        return previous
    }

    /// Copy, drag-out and Services write plain text only: with isRichText
    /// (kept for highlighting) they also wrote RTF carrying the editor theme's
    /// colors and font, so ⌘C → Mail/Notes pasted near-invisible text. Filters
    /// to the type a plain-text NSTextView writes — NSTextView can't write the
    /// modern `.string` name itself, so returning just that broke copying.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter { $0 == .string || $0.rawValue == "NSStringPboardType" }
    }

    /// Image files dropped on the text become markdown at the drop point
    /// (`onImageDrop` copies them into ./assets); AppKit's default inserted a
    /// raw, percent-encoded file:// URL. Text drags and other files keep it.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = Self.imageFileURLs(on: sender.draggingPasteboard)
        guard !images.isEmpty, onImageDrop != nil else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        return insertImages(images, at: index) || super.performDragOperation(sender)
    }

    /// The image files (by extension) among file URLs on a drag pasteboard.
    static func imageFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    /// Inserts the markdown for each image at `index` (one per line), caret
    /// after it. False when `onImageDrop` produced nothing.
    func insertImages(_ urls: [URL], at index: Int) -> Bool {
        guard let onImageDrop else { return false }
        let snippets = urls.compactMap(onImageDrop)
        guard !snippets.isEmpty else { return false }
        window?.makeFirstResponder(self)
        let location = min(max(0, index), (string as NSString).length)
        setSelectedRange(NSRange(location: location, length: 0))
        insertAsSeparateEdit(snippets.joined(separator: "\n"), replacing: selectedRange())
        return true
    }

    /// Inserts like typing (undoable, delegate notified, typing attributes)
    /// but as its own undo step rather than merged into adjacent typing.
    private func insertAsSeparateEdit(_ text: String, replacing range: NSRange) {
        breakUndoCoalescing()
        insertText(text, replacementRange: range)
        breakUndoCoalescing()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard highlightCurrentLine,
              selectedRange().length == 0,
              let layoutManager, let textContainer else { return }

        let caret = selectedRange().location
        let ns = string as NSString

        var lineRect: NSRect
        if ns.length == 0 {
            let height = layoutManager.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 14, weight: .regular))
            lineRect = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        } else if caret >= ns.length && ns.character(at: ns.length - 1) == 0x0A {
            // Caret on the trailing empty line after a final newline.
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let clamped = min(caret, ns.length - 1)
            let lineCharRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)
            lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        }

        lineRect.origin.x = 0
        lineRect.origin.y += textContainerInset.height
        lineRect.size.width = bounds.width
        paintedBandRect = lineRect

        guard rect.intersects(lineRect) else { return }
        currentLineColor.setFill()
        lineRect.fill()
    }

    /// Repaints the last band without it once the caret becomes a selection:
    /// NSTextView then redraws only the selected fragments, which left the
    /// rest of a wrapped line's band (and its margins) painted.
    func erasePaintedBand() {
        guard let band = paintedBandRect else { return }
        paintedBandRect = nil
        setNeedsDisplay(band)
    }

    /// Gated here, not in acceptsFirstResponder: makeFirstResponder and the
    /// find bar handing focus back never consult acceptsFirstResponder.
    override func becomeFirstResponder() -> Bool {
        isEditorVisible ? super.becomeFirstResponder() : false
    }

    /// Tab picks its destination by this, not by becomeFirstResponder: a
    /// hidden editor in the key-view loop took Tab from an unfocused window
    /// (or a field before it), refused focus and left it nowhere.
    override var canBecomeKeyView: Bool {
        isEditorVisible && super.canBecomeKeyView
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFirstResponder?() }
        return resigned
    }
}

// MARK: - Line Number Ruler

/// A real NSRulerView gutter. Unlike the old separate ScrollView of Text views,
/// this stays aligned with wrapped lines, scrolls with the text, and costs
/// nothing for offscreen lines.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let lineIndex: LineIndex

    var numberColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    /// The caret's line number is emphasized (Xcode-style) with this color.
    var emphasizedNumberColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    var gutterColor: NSColor = .clear { didSet { needsDisplay = true } }

    /// Gutter digits track the editor font size so the unified zoom scales the
    /// whole canvas, not just the text column.
    var editorFontSize: CGFloat = 14 {
        didSet {
            guard abs(editorFontSize - oldValue) > 0.01 else { return }
            numberFont = NSFont.monospacedDigitSystemFont(
                ofSize: max(9, (editorFontSize * 0.8).rounded()),
                weight: .regular
            )
            refreshThickness()
            needsDisplay = true
        }
    }

    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, lineIndex: LineIndex) {
        self.textView = textView
        self.lineIndex = lineIndex
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refreshThickness() {
        let digits = max(2, String(lineIndex.lineCount).count)
        let charWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        let needed = ceil(CGFloat(digits) * charWidth) + 20
        if abs(needed - ruleThickness) > 0.5 {
            ruleThickness = needed
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        gutterColor.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        // Emphasize the caret's line, matching the current-line highlight.
        let caretLine = textView.selectedRange().length == 0
            ? lineIndex.lineNumber(at: textView.selectedRange().location)
            : -1

        func draw(_ number: Int, atTextViewY y: CGFloat, fragmentHeight: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: number == caretLine ? emphasizedNumberColor : numberColor
            ]
            let str = NSAttributedString(string: "\(number)", attributes: attributes)
            let size = str.size()
            let point = convert(NSPoint(x: 0, y: y), from: textView)
            str.draw(at: NSPoint(
                x: ruleThickness - size.width - 10,
                y: point.y + (fragmentHeight - size.height) / 2
            ))
        }

        let content = textView.string as NSString
        let inset = textView.textContainerInset

        if content.length == 0 {
            let height = layoutManager.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 14, weight: .regular))
            draw(1, atTextViewY: inset.height, fragmentHeight: height)
            return
        }

        // Glyph rects live in container coordinates (no inset), the visible
        // rect is in view coordinates — offset before asking for glyphs.
        let visibleRect = textView.visibleRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineCharRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)

            var effectiveRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: lineGlyphRange.location,
                effectiveRange: &effectiveRange,
                withoutAdditionalLayout: true
            )

            let lineNumber = lineIndex.lineNumber(at: lineCharRange.location)
            draw(lineNumber, atTextViewY: fragmentRect.minY + inset.height, fragmentHeight: fragmentRect.height)

            glyphIndex = max(NSMaxRange(lineGlyphRange), glyphIndex + 1)
        }

        // Trailing empty line (document ends with a newline).
        if layoutManager.extraLineFragmentTextContainer != nil {
            let fragmentRect = layoutManager.extraLineFragmentRect
            draw(lineIndex.lineCount, atTextViewY: fragmentRect.minY + inset.height, fragmentHeight: fragmentRect.height)
        }
    }
}

// MARK: - Smart List Continuation

/// What Enter does on a list or quote line, as a pure text edit so the rules
/// are testable without a text view. Reads only the caret's line, keeping
/// Enter free of whole-document work.
enum ListContinuation {
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        /// Caret location once the edit is applied.
        let caret: Int
    }

    private static let unorderedRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+(\[[ xX]\](?:\s+|$))?(.*)$"#)
    private static let orderedRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])\s+(.*)$"#)
    private static let quoteRegex = try! NSRegularExpression(pattern: #"^(\s*>+\s?)(.*)$"#)
    /// `* * *` / `- - -` are thematic breaks, not list items.
    private static let thematicBreakRegex = try! NSRegularExpression(pattern: #"^\s{0,3}([-*_])(?:\s*\1){2,}\s*$"#)

    /// The edit for Enter at `caret`, or nil for a plain newline.
    /// - An item continues on a new line, taking the text after the caret
    ///   with it — so Enter right after the marker opens an item above
    ///   (`"- |Buy milk"` → `"- \n- |Buy milk"`, as in Obsidian). Judging
    ///   emptiness from the text before the caret alone deleted the marker.
    /// - An empty item (only whitespace after the caret too) is outdented one
    ///   level when nested, else its marker is cleared, ending the list.
    static func edit(forNewlineIn text: NSString, at caret: Int, tabSize: Int) -> Edit? {
        guard caret >= 0, caret <= text.length else { return nil }
        var lineStart = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        guard caret <= contentsEnd else { return nil }

        let lineToCaret = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        let afterCaret = text.substring(with: NSRange(location: caret, length: contentsEnd - caret))
        let line = lineToCaret + afterCaret
        if thematicBreakRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
            return nil
        }
        guard let marker = marker(for: lineToCaret) else { return nil }

        if marker.isEmptyItem, afterCaret.trimmingCharacters(in: .whitespaces).isEmpty {
            let indentLength = (marker.indent as NSString).length
            if indentLength > 0 {
                let removed = outdentLength(of: marker.indent, tabSize: tabSize)
                return Edit(
                    range: NSRange(location: lineStart + indentLength - removed, length: removed),
                    replacement: "",
                    caret: caret - removed
                )
            }
            return Edit(range: NSRange(location: lineStart, length: contentsEnd - lineStart), replacement: "", caret: lineStart)
        }

        let insertion = "\n" + marker.continuation
        return Edit(
            range: NSRange(location: caret, length: 0),
            replacement: insertion,
            caret: caret + (insertion as NSString).length
        )
    }

    /// `indent` is a list item's leading whitespace ("" for quotes, which
    /// are cleared rather than outdented).
    private static func marker(for line: String) -> (indent: String, continuation: String, isEmptyItem: Bool)? {
        let nsLine = line as NSString
        let full = NSRange(location: 0, length: nsLine.length)

        if let m = unorderedRegex.firstMatch(in: line, range: full) {
            let indent = nsLine.substring(with: m.range(at: 1))
            let bullet = nsLine.substring(with: m.range(at: 2))
            let hasTask = m.range(at: 3).location != NSNotFound
            let rest = nsLine.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            let continuation = "\(indent)\(bullet) " + (hasTask ? "[ ] " : "")
            return (indent, continuation, rest.isEmpty)
        }
        if let m = orderedRegex.firstMatch(in: line, range: full) {
            let indent = nsLine.substring(with: m.range(at: 1))
            let number = Int(nsLine.substring(with: m.range(at: 2))) ?? 0
            let delimiter = nsLine.substring(with: m.range(at: 3))
            let rest = nsLine.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            return (indent, "\(indent)\(number + 1)\(delimiter) ", rest.isEmpty)
        }
        if let m = quoteRegex.firstMatch(in: line, range: full) {
            let prefix = nsLine.substring(with: m.range(at: 1))
            let rest = nsLine.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return ("", prefix, rest.isEmpty)
        }
        return nil
    }

    /// UTF-16 length of one indent level at the end of `indent`: a tab, or
    /// up to `tabSize` spaces.
    private static func outdentLength(of indent: String, tabSize: Int) -> Int {
        let units = Array(indent.utf16)
        guard let last = units.last else { return 0 }
        guard last == 0x20 else { return 1 }
        let trailingSpaces = units.reversed().prefix { $0 == 0x20 }.count
        return min(trailingSpaces, max(1, tabSize))
    }
}

// MARK: - Editor Representable

struct MarkdownTextEditor: NSViewRepresentable {
    /// Identity of the document being edited. A change means a tab switch, which
    /// resets undo/scroll/selection (vs. an in-place text edit or disk reload).
    let documentID: UUID?
    /// False in preview mode, where the editor stays mounted but off-screen.
    var isVisible = true
    @Binding var text: String
    let font: NSFont
    let editorTheme: EditorTheme
    let softWrap: Bool
    let showLineNumbers: Bool
    let highlightCurrentLine: Bool
    let tabSize: Int
    let insertSpacesForTab: Bool
    let enableCompletion: Bool
    let scrollSyncEnabled: Bool
    let copySelectionOnDrag: Bool
    var onImageDrop: ((URL) -> String?)?
    var onSelectionChange: ((Int, Int) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var completionsProvider: ((CompletionContext) -> [CompletionItem])?

    /// The smallest edit turning `old` into `new`: the range of `old` to
    /// replace and the range of `new` replacing it, trimmed of their common
    /// UTF-16 prefix and suffix and widened to whole composed character
    /// sequences (never half a surrogate pair or a mark without its base).
    static func minimalEdit(from old: NSString, to new: NSString) -> (range: NSRange, replacement: NSRange) {
        let oldLength = old.length, newLength = new.length
        var a = [unichar](repeating: 0, count: oldLength)
        var b = [unichar](repeating: 0, count: newLength)
        old.getCharacters(&a, range: NSRange(location: 0, length: oldLength))
        new.getCharacters(&b, range: NSRange(location: 0, length: newLength))

        let limit = min(oldLength, newLength)
        var prefix = 0
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, a[oldLength - 1 - suffix] == b[newLength - 1 - suffix] { suffix += 1 }

        func sequenceStart(_ s: NSString, _ index: Int) -> Int {
            index < s.length ? s.rangeOfComposedCharacterSequence(at: index).location : index
        }
        func sequenceEnd(_ s: NSString, _ end: Int) -> Int {
            end > 0 ? NSMaxRange(s.rangeOfComposedCharacterSequence(at: end - 1)) : end
        }
        prefix = min(sequenceStart(old, prefix), sequenceStart(new, prefix))
        suffix = min(oldLength - sequenceEnd(old, oldLength - suffix),
                     newLength - sequenceEnd(new, newLength - suffix))
        return (NSRange(location: prefix, length: oldLength - suffix - prefix),
                NSRange(location: prefix, length: newLength - suffix - prefix))
    }

    /// Configures soft-wrap vs. horizontal-scroll behavior for the text view.
    /// Soft wrap sizes the container exactly as widthTracksTextView does (view
    /// width minus both insets). The raw clip width wrapped lines past the
    /// right inset, and tracking flipped it back on the next frame change, a
    /// whole-document relayout each time.
    static func applyWrapMode(softWrap: Bool, to textView: NSTextView, scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        let big = CGFloat.greatestFiniteMagnitude
        if softWrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            // Back from no-wrap the view may have grown wider than the clip.
            let clipWidth = scrollView.contentSize.width
            if clipWidth > 0, abs(textView.frame.width - clipWidth) > 0.5 {
                textView.setFrameSize(NSSize(width: clipWidth, height: textView.frame.height))
            }
            let tracked = max(0, textView.frame.width - 2 * textView.textContainerInset.width)
            if abs(container.size.width - tracked) > 0.5 {
                container.size = NSSize(width: tracked, height: big)
            }
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.size = NSSize(width: big, height: big)
        }
        textView.maxSize = NSSize(width: big, height: big)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CmdMDTextView(frame: .zero)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)

        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.font = font
        textView.copySelectionOnDrag = copySelectionOnDrag
        textView.onMagnify = onMagnify
        textView.isEditorVisible = isVisible
        textView.onResignFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.dismissCompletion()
        }
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFontPanel = false
        // Comfortable Apple-like content padding (Notes/Xcode sit around 16-20pt).
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.drawsBackground = true

        // Native find/replace bar (Find menu ⌘F, ⌥⌘F, ⌘G / ⇧⌘G, ⌘E).
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        Self.applyWrapMode(softWrap: softWrap, to: textView, scrollView: scrollView)
        applyTheme(to: textView, scrollView: scrollView)
        applyTypingAttributes(to: textView)
        // Baselines for updateNSView, so its first pass isn't taken for a
        // font or wrap change (each is re-applied over the whole document).
        context.coordinator.currentSoftWrap = softWrap
        context.coordinator.currentFontPointSize = font.pointSize
        context.coordinator.currentFontName = font.fontName
        context.coordinator.currentTabSize = tabSize

        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        // Read through the coordinator at drop time: `parent` always holds the
        // latest closure, so updateNSView needn't re-assign it.
        textView.onImageDrop = { [weak coordinator = context.coordinator] url in
            coordinator?.parent.onImageDrop?(url)
        }

        // Index BEFORE installing the text: setting `string` fires a selection
        // change, and reporting it against an empty index produced "Ln 1,
        // Col <doc length>" in the status bar until the first click.
        context.coordinator.currentDocumentID = documentID
        context.coordinator.lastPushedText = text
        context.coordinator.lineIndex.rebuild(from: text as NSString)
        textView.string = text
        context.coordinator.applyHighlightingNow()

        // Line-number gutter.
        let ruler = LineNumberRulerView(textView: textView, lineIndex: context.coordinator.lineIndex)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showLineNumbers
        context.coordinator.rulerView = ruler
        applyRulerTheme(ruler)
        ruler.refreshThickness()

        // Scroll-sync + ruler redraw on scroll.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(of: scrollView)
        context.coordinator.observeEdits(of: textView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? CmdMDTextView else { return }
        context.coordinator.parent = self

        // This runs on every keystroke (the pane re-renders with its document),
        // so only what changed is re-applied. NSTextView.font in particular
        // rewrites the font of the whole storage even when it is identical:
        // headings, bold and code collapsed to body size and the document
        // relaid out, per keystroke. Compared with the last-applied values,
        // never textView.font, which reports the first run's font.
        let fontChange = context.coordinator.currentFontPointSize != font.pointSize
            || context.coordinator.currentFontName != font.fontName
        // Tab size sets the tab stops in the base paragraph style.
        let themeChange = fontChange || context.coordinator.currentTheme != editorTheme
            || context.coordinator.currentTabSize != tabSize
        if themeChange || textView.highlightCurrentLine != highlightCurrentLine {
            applyTheme(to: textView, scrollView: nsView)
            textView.needsDisplay = true
        }
        if fontChange {
            textView.font = font
        }
        if themeChange {
            applyTypingAttributes(to: textView)
            if let ruler = context.coordinator.rulerView {
                applyRulerTheme(ruler)
            }
            context.coordinator.currentTheme = editorTheme
            context.coordinator.currentFontPointSize = font.pointSize
            context.coordinator.currentFontName = font.fontName
            context.coordinator.currentTabSize = tabSize
        }
        textView.copySelectionOnDrag = copySelectionOnDrag
        textView.onMagnify = onMagnify
        if context.coordinator.currentSoftWrap != softWrap {
            context.coordinator.currentSoftWrap = softWrap
            Self.applyWrapMode(softWrap: softWrap, to: textView, scrollView: nsView)
        }
        if nsView.rulersVisible != showLineNumbers {
            nsView.rulersVisible = showLineNumbers
        }
        context.coordinator.setEditorVisible(isVisible)

        let isDiskReload = context.coordinator.consumePendingDiskReload()
        let documentSwitch = context.coordinator.currentDocumentID != documentID
        let externalChange = !documentSwitch
            && Self.isModelChange(text, lastPushed: context.coordinator.lastPushedText)

        if documentSwitch {
            // Tab switch: reuse this NSTextView (no teardown) but reset its
            // editing state so undo history, scroll, and selection don't bleed
            // across documents.
            context.coordinator.currentDocumentID = documentID
            context.coordinator.dismissCompletion()
            // Base attributes for an empty document; text inherits its own.
            applyTypingAttributes(to: textView)
            context.coordinator.replaceAllText(with: text)
            context.coordinator.lineIndex.rebuild(from: text as NSString)
            context.coordinator.rulerView?.refreshThickness()
            context.coordinator.applyHighlightingNow()
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            context.coordinator.resetScrollTracking()
        } else if externalChange {
            // Same document, different text: a disk reload or a programmatic
            // update (preview task toggle, image drop).
            context.coordinator.applyModelText(text, isDiskReload: isDiskReload)
        } else if themeChange {
            // Debounced: a pinch gesture lands many font-size changes per
            // second, and a full token re-highlight per tick made zooming
            // chug. The base font applies instantly (textView.font above);
            // styled runs catch up ~120ms after the gesture pauses.
            context.coordinator.scheduleThemeRehighlight()
        }
    }

    /// Whether the model's text is a change the editor didn't make itself.
    /// Measured against what the editor last pushed (or was given), not the
    /// view's text: IME marked text never reaches the model, so the view
    /// legitimately differs from it mid-composition, and replacing the text
    /// then dropped the composition or re-committed it at a shifted offset.
    /// While typing both sides are the same string, so this is O(1) instead
    /// of a whole-document comparison per keystroke.
    static func isModelChange(_ text: String, lastPushed: String) -> Bool {
        text.differs(from: lastPushed)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    private func applyTheme(to textView: CmdMDTextView, scrollView: NSScrollView) {
        textView.backgroundColor = NSColor(editorTheme.backgroundColor)
        textView.insertionPointColor = NSColor(editorTheme.cursorColor)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(editorTheme.selectionColor)
        ]
        textView.highlightCurrentLine = highlightCurrentLine
        textView.currentLineColor = NSColor(editorTheme.currentLineColor).withAlphaComponent(0.35)
        scrollView.backgroundColor = NSColor(editorTheme.backgroundColor)
    }

    /// Base typing attributes: without these, text typed into an empty
    /// document (or an oversized one that skips highlighting) renders in the
    /// default black-on-white attributes until the next highlight pass. Only
    /// on a font/theme change: re-applied per update, they also restyled
    /// every character typed inside a heading or code span at body size.
    private func applyTypingAttributes(to textView: NSTextView) {
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor(editorTheme.textColor),
            .paragraphStyle: SyntaxHighlighter.paragraphStyle(font: font, tabSize: tabSize)
        ]
    }

    private func applyRulerTheme(_ ruler: LineNumberRulerView) {
        ruler.numberColor = NSColor(editorTheme.lineNumberColor)
        ruler.emphasizedNumberColor = NSColor(editorTheme.textColor).withAlphaComponent(0.85)
        ruler.gutterColor = NSColor(editorTheme.backgroundColor)
        ruler.editorFontSize = font.pointSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var currentTheme: EditorTheme
        var currentDocumentID: UUID?
        var currentFontPointSize: CGFloat = 0
        var currentFontName: String = ""
        var currentTabSize = 0
        var currentSoftWrap: Bool?
        /// The text this editor last pushed to the model, or was given by it.
        var lastPushedText = ""
        /// Set while the model's text is put into the view (tab switch,
        /// reload, task toggle): those are not user edits to push back.
        private var isApplyingModelText = false
        private var pendingDiskReload = false
        weak var textView: CmdMDTextView?
        weak var rulerView: LineNumberRulerView?
        let lineIndex = LineIndex()

        private let highlighter = SyntaxHighlighter()
        private var highlightDebounce: DispatchWorkItem?
        /// Storage edits not restyled yet (typing, paste, IME, undo, attribute
        /// changes from elsewhere), in current coordinates.
        private var pendingHighlightRange: NSRange?
        /// The highlighter's own attribute writes are not pending edits.
        private var isApplyingHighlights = false
        private var observers: [NSObjectProtocol] = []
        private let completionPopup = CompletionWindowController()
        private var activeCompletionContext: CompletionContext?
        private var lastSentScrollFraction: Double = -1

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
            self.currentTheme = parent.editorTheme
            super.init()

            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .scrollToLine, object: nil, queue: .main) { [weak self] note in
                guard let lineNumber = note.object as? Int else { return }
                self?.scrollToLine(lineNumber)
            })
            observers.append(center.addObserver(forName: .showDocumentSearch, object: nil, queue: .main) { [weak self] note in
                self?.performFindAction(note.object as? NSTextFinder.Action ?? .showFindInterface)
            })
            observers.append(center.addObserver(forName: .focusVisiblePane, object: nil, queue: .main) { [weak self] note in
                guard let request = note.object as? PaneFocus.Request, request.target == .editor else { return }
                self?.takeFocus(for: request)
            })
            observers.append(center.addObserver(forName: .formatBold, object: nil, queue: .main) { [weak self] _ in
                self?.wrapSelection(token: "**", placeholder: "bold")
            })
            observers.append(center.addObserver(forName: .formatItalic, object: nil, queue: .main) { [weak self] _ in
                self?.wrapSelection(token: "*", placeholder: "italic")
            })
            observers.append(center.addObserver(forName: .formatLink, object: nil, queue: .main) { [weak self] _ in
                self?.insertLink()
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = self.textView?.window, (note.object as? NSWindow) === window else { return }
                self.completionPopup.dismiss()
            })
            // A reload keeps the document id, so updateNSView applies it as a
            // same-document change; flagged, that change drops the undo history
            // (a revert) instead of becoming an undoable step. Synchronous, so
            // the flag is set before the update that carries the new text.
            observers.append(center.addObserver(forName: .documentReloadedFromDisk, object: nil, queue: nil) { [weak self] note in
                guard let self, let id = note.object as? UUID, id == self.currentDocumentID else { return }
                self.pendingDiskReload = true
            })
            // Synchronous: AppState posts this right before the active
            // document changes or is saved, and the commit must land first.
            observers.append(center.addObserver(forName: .commitPendingComposition, object: nil, queue: nil) { [weak self] _ in
                self?.endComposition()
            })
        }

        deinit {
            tearDown()
        }

        func tearDown() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            completionPopup.dismiss()
            highlightDebounce?.cancel()
        }

        func observeScroll(of scrollView: NSScrollView) {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.handleScrollChanged()
            })
        }

        /// Records every storage edit the highlighter didn't make, so a typing
        /// pause restyles only the lines edited since the last pass.
        func observeEdits(of textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            // queue: nil delivers inside processEditing, while editedRange and
            // changeInLength still describe this edit.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage,
                queue: nil
            ) { [weak self] note in
                guard let self, !self.isApplyingHighlights,
                      let storage = note.object as? NSTextStorage else { return }
                self.pendingHighlightRange = SyntaxHighlighter.union(
                    pending: self.pendingHighlightRange,
                    edited: storage.editedRange,
                    changeInLength: storage.changeInLength
                )
            })
        }

        private func handleScrollChanged() {
            rulerView?.needsDisplay = true
            // Keep the completion popup pinned to the caret instead of floating
            // at a stale position while the document scrolls under it — and
            // gone once the caret scrolls out of the editor's visible area.
            if completionPopup.isVisible, let textView {
                let sel = textView.selectedRange()
                let caretRect = textView.firstRect(
                    forCharacterRange: NSRange(location: sel.location, length: 0),
                    actualRange: nil
                )
                if let window = textView.window {
                    let local = textView.convert(window.convertFromScreen(caretRect), from: nil)
                    if textView.visibleRect.contains(NSPoint(x: local.minX, y: local.midY)) {
                        completionPopup.move(to: caretRect)
                    } else {
                        dismissCompletion()
                    }
                }
            }
            postScrollFraction()
        }

        /// Resets scroll-sync state after a document switch so the new document's
        /// scroll position re-syncs cleanly instead of inheriting the prior fraction.
        func resetScrollTracking() {
            lastSentScrollFraction = -1
        }

        func dismissCompletion() {
            completionPopup.dismiss()
            activeCompletionContext = nil
        }

        /// Preview mode keeps the editor mounted off-screen. Hidden, it must
        /// hold neither keyboard focus nor a completion popup: keystrokes or a
        /// row click would edit the document invisibly.
        func setEditorVisible(_ visible: Bool) {
            guard let textView, textView.isEditorVisible != visible else { return }
            textView.isEditorVisible = visible
            // Focus moves after this update rather than in the middle of it.
            guard !visible else {
                // Shown again: focus left with the hide, so hand it back unless
                // something else has taken it. The caret may sit on a search
                // hit placed while hidden.
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.isEditorVisible,
                          let window = textView.window, window.firstResponder === window else { return }
                    window.makeFirstResponder(textView)
                }
                return
            }
            dismissCompletion()
            // The gate stops new focus; give up focus it already has.
            guard Self.holdsFocus(textView) else { return }
            DispatchQueue.main.async { [weak textView] in
                guard let textView, !textView.isEditorVisible, Self.holdsFocus(textView) else { return }
                textView.window?.makeFirstResponder(nil)
            }
        }

        /// Source and Split: the editor takes keyboard focus when it is
        /// nowhere, or after ⌘1/⌘2 from the page (see PaneFocus).
        private func takeFocus(for request: PaneFocus.Request) {
            guard let textView, textView.isEditorVisible,
                  let window = textView.window, window.attachedSheet == nil,
                  PaneFocus.shouldTakeFocus(request, from: window.firstResponder, in: window) else { return }
            window.makeFirstResponder(textView)
        }

        /// Whether keyboard focus is in the editor: its text, or the field of
        /// its find bar, which lives in the same scroll view.
        private static func holdsFocus(_ textView: NSTextView) -> Bool {
            guard let responder = textView.window?.firstResponder as? NSView else { return false }
            return responder.isDescendant(of: textView.enclosingScrollView ?? textView)
        }

        /// Whether the change updateNSView is about to apply is a disk reload.
        /// Read once per update: its text arrives in the update right after the
        /// notification, or never when only the frontmatter changed.
        func consumePendingDiskReload() -> Bool {
            defer { pendingDiskReload = false }
            return pendingDiskReload
        }

        // MARK: Model text

        /// Ends an IME composition: unmarkText commits the marked text and
        /// posts textDidChange, which pushes it to the model (AppState asks for
        /// this before it swaps or saves the document). While the model's text
        /// is being applied the push is skipped, so the syllable is dropped
        /// rather than written into whichever document the binding points at
        /// by then. Unmark first, as NSTextView does when a selection change
        /// abandons marked text, then make the input method drop its copy.
        private func endComposition() {
            guard let textView, textView.hasMarkedText() else { return }
            textView.unmarkText()
            textView.inputContext?.discardMarkedText()
        }

        /// Swaps in another document's text wholesale (tab switch).
        func replaceAllText(with text: String) {
            guard let textView, let storage = textView.textStorage else { return }
            isApplyingModelText = true
            defer { isApplyingModelText = false }
            endComposition()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            lastPushedText = text
        }

        /// Applies text the model changed under the editor (disk reload,
        /// preview task toggle, image drop). Only the differing range is
        /// replaced, so the caret and selection move with the edit instead of
        /// being restored to stale offsets. The undo stack stays consistent: a
        /// reload is a revert and drops the history, whose entries hold offsets
        /// into the old text (⌘Z then deleted the wrong characters, or raised
        /// NSRangeException once the text got shorter); any other change is
        /// registered as one undoable step.
        func applyModelText(_ text: String, isDiskReload: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            isApplyingModelText = true
            defer { isApplyingModelText = false }
            endComposition()

            let newText = text as NSString
            let edit = MarkdownTextEditor.minimalEdit(from: storage.mutableString, to: newText)
            let replacement = newText.substring(with: edit.replacement)
            let isEmptyEdit = edit.range.length == 0 && edit.replacement.length == 0
            // NSTextView registers all of its undo actions on the storage, so
            // this drops the editor's history and nothing else in the window's
            // shared undo manager (Inspector fields).
            if isDiskReload, !isEmptyEdit {
                storage.replaceCharacters(in: edit.range, with: replacement)
                textView.undoManager?.removeAllActions(withTarget: storage)
            } else if !isEmptyEdit {
                textView.breakUndoCoalescing()
                if textView.shouldChangeText(in: edit.range, replacementString: replacement) {
                    storage.replaceCharacters(in: edit.range, with: replacement)
                    textView.didChangeText()
                } else {
                    storage.replaceCharacters(in: edit.range, with: replacement)
                    textView.undoManager?.removeAllActions(withTarget: storage)
                }
                textView.breakUndoCoalescing()
            }
            lastPushedText = text
            lineIndex.rebuild(from: newText)
            rulerView?.refreshThickness()
            rulerView?.needsDisplay = true
            applyHighlightingNow()
            // The caret moved with the edit while the index was stale.
            reportSelection(of: textView)
        }

        private func postScrollFraction() {
            guard parent.scrollSyncEnabled,
                  let textView,
                  let scrollView = textView.enclosingScrollView else { return }
            let clip = scrollView.contentView
            let maxOffset = max(1, textView.frame.height - clip.bounds.height)
            let fraction = min(1, max(0, clip.bounds.origin.y / maxOffset))
            guard abs(fraction - lastSentScrollFraction) > 0.001 else { return }
            lastSentScrollFraction = fraction
            NotificationCenter.default.post(name: .editorDidScroll, object: fraction)
        }

        /// Only the editor that currently owns focus should react to global
        /// format notifications. Menu-driven shortcuts don't change the window's
        /// first responder, so an exact match is correct (and avoids acting on an
        /// unfocused editor).
        private var isActiveEditor: Bool {
            guard let textView = textView, let window = textView.window else { return false }
            return window.firstResponder === textView
        }

        /// Find menu commands (show bar, next, previous) for the source pane.
        /// In Preview mode the editor is hidden yet mounted: its bar would open
        /// unseen and Esc would hand the hidden text keyboard focus, so typing
        /// edited the document invisibly. The menu routes Find to the preview
        /// there (`DocumentFind`); this guards any other sender.
        private func performFindAction(_ action: NSTextFinder.Action) {
            guard let textView = textView, textView.window != nil,
                  AppState.shared?.viewMode != .preview else { return }
            let item = NSMenuItem()
            item.tag = Int(action.rawValue)
            textView.performTextFinderAction(item)
        }

        private func scrollToLine(_ lineNumber: Int) {
            guard let textView = textView else { return }
            let length = (textView.string as NSString).length
            let location = min(lineIndex.startLocation(ofLine: lineNumber), length)
            let range = NSRange(location: location, length: 0)
            // Center the destination (Xcode/Safari find behavior) so the jump
            // target has context around it instead of hugging the viewport edge.
            if let layoutManager = textView.layoutManager,
               let container = textView.textContainer,
               let scrollView = textView.enclosingScrollView {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                lineRect.origin.y += textView.textContainerInset.height
                let clip = scrollView.contentView
                let targetY = min(
                    max(0, lineRect.midY - clip.bounds.height / 2),
                    max(0, textView.frame.height - clip.bounds.height)
                )
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
                scrollView.reflectScrolledClipView(clip)
            } else {
                textView.scrollRangeToVisible(range)
            }
            textView.setSelectedRange(range)
            // Hidden (preview), the caret still lands on the line for a later
            // switch to source, but keystrokes must not reach the hidden text.
            if parent.isVisible {
                textView.window?.makeFirstResponder(textView)
            }
        }

        // MARK: Markdown formatting

        private func wrapSelection(token: String, placeholder: String) {
            guard isActiveEditor, let textView = textView else { return }
            let sel = textView.selectedRange()
            let nsText = textView.string as NSString
            let selected = nsText.substring(with: sel)
            let inner = selected.isEmpty ? placeholder : selected
            let replacement = token + inner + token
            guard textView.shouldChangeText(in: sel, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: sel, with: replacement)
            textView.didChangeText()
            let innerLocation = sel.location + (token as NSString).length
            textView.setSelectedRange(NSRange(location: innerLocation, length: (inner as NSString).length))
        }

        private func insertLink() {
            guard isActiveEditor, let textView = textView else { return }
            let sel = textView.selectedRange()
            let nsText = textView.string as NSString
            let selected = nsText.substring(with: sel)
            let label = selected.isEmpty ? "text" : selected
            let replacement = "[\(label)](url)"
            guard textView.shouldChangeText(in: sel, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: sel, with: replacement)
            textView.didChangeText()
            // Select the "url" placeholder for immediate typing.
            let urlLocation = sel.location + (replacement as NSString).length - 4
            textView.setSelectedRange(NSRange(location: urlLocation, length: 3))
        }

        // MARK: Key commands

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if completionPopup.isVisible {
                switch commandSelector {
                case #selector(NSResponder.moveDown(_:)):
                    completionPopup.moveSelectionDown()
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    completionPopup.moveSelectionUp()
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    completionPopup.confirmSelection()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    completionPopup.dismiss()
                    activeCompletionContext = nil
                    return true
                default:
                    break
                }
            }

            if commandSelector == #selector(NSResponder.insertTab(_:)), parent.insertSpacesForTab {
                let spaces = String(repeating: " ", count: max(1, parent.tabSize))
                textView.insertText(spaces, replacementRange: textView.selectedRange())
                return true
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return handleNewline(in: textView)
            }
            return false
        }

        // MARK: Smart list continuation

        private func handleNewline(in textView: NSTextView) -> Bool {
            let sel = textView.selectedRange()
            guard sel.length == 0,
                  let edit = ListContinuation.edit(
                      forNewlineIn: textView.string as NSString,
                      at: sel.location,
                      tabSize: parent.tabSize
                  ) else { return false }

            guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return false }
            textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: edit.caret, length: 0))
            return true
        }

        // MARK: Text change

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isApplyingModelText else { return }

            let newText = textView.string
            lastPushedText = newText
            parent.text = newText

            lineIndex.rebuild(from: newText as NSString)
            rulerView?.refreshThickness()
            rulerView?.needsDisplay = true

            reportSelection(of: textView)
            updateCompletion(in: textView)
            scheduleHighlighting(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportSelection(of: textView)
            // Repaint for the current-line highlight — but only when the feature
            // can actually draw something. Unconditional needsDisplay forced a
            // full glyph redraw on every caret move and throughout drag-selection.
            // A new selection erases just the band last painted.
            if let cmdTextView = textView as? CmdMDTextView {
                if cmdTextView.selectedRange().length > 0 {
                    cmdTextView.erasePaintedBand()
                } else if cmdTextView.highlightCurrentLine {
                    cmdTextView.needsDisplay = true
                }
            }
            // The gutter emphasizes the caret's line number.
            rulerView?.needsDisplay = true

            if completionPopup.isVisible {
                let sel = textView.selectedRange()
                let context = sel.length == 0
                    ? CompletionService.detectContext(in: textView.string as NSString, cursorLocation: sel.location)
                    : nil
                if context == nil || context?.range.location != activeCompletionContext?.range.location {
                    completionPopup.dismiss()
                    activeCompletionContext = nil
                }
            }
        }

        private func reportSelection(of textView: NSTextView) {
            guard let onSelectionChange = parent.onSelectionChange else { return }
            let location = textView.selectedRange().location
            let (line, column) = lineIndex.lineAndColumn(at: location)
            onSelectionChange(line, column)
        }

        // MARK: Highlighting

        func applyHighlightingNow() {
            guard let textView, let storage = textView.textStorage else { return }
            isApplyingHighlights = true
            defer { isApplyingHighlights = false }
            highlighter.applyHighlights(to: storage, font: parent.font, theme: parent.editorTheme, tabSize: parent.tabSize)
            pendingHighlightRange = nil
        }

        /// Typing-pause pass: restyles just the lines edited since the last
        /// pass (the highlighter falls back to a full pass when it must).
        private func applyPendingHighlighting() {
            guard let textView, let storage = textView.textStorage,
                  let editedRange = pendingHighlightRange else { return }
            isApplyingHighlights = true
            defer { isApplyingHighlights = false }
            highlighter.applyHighlights(
                to: storage,
                font: parent.font,
                theme: parent.editorTheme,
                tabSize: parent.tabSize,
                editedRange: editedRange
            )
            pendingHighlightRange = nil
        }

        /// Short-debounced re-highlight for theme/font (zoom) changes. Unlike
        /// the typing path this must run even for oversized documents, because
        /// their base attributes carry the changed font.
        func scheduleThemeRehighlight() {
            highlightDebounce?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.applyHighlightingNow()
            }
            highlightDebounce = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        private func scheduleHighlighting(for textView: NSTextView) {
            // Oversized documents skip token passes anyway, and their base
            // attributes are already uniform — re-running the full-range reset
            // per typing pause only invalidated layout for the whole file.
            // Typed text inherits typingAttributes, so nothing goes stale.
            guard (textView.textStorage?.length ?? 0) <= SyntaxHighlighter.highlightSizeLimit else { return }
            highlightDebounce?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.applyPendingHighlighting()
            }
            highlightDebounce = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        // MARK: Completion

        private func updateCompletion(in textView: NSTextView) {
            guard parent.enableCompletion, let provider = parent.completionsProvider else {
                completionPopup.dismiss()
                return
            }

            let sel = textView.selectedRange()
            guard sel.length == 0,
                  let context = CompletionService.detectContext(in: textView.string as NSString, cursorLocation: sel.location) else {
                completionPopup.dismiss()
                activeCompletionContext = nil
                return
            }

            let items = provider(context)
            guard !items.isEmpty else {
                completionPopup.dismiss()
                activeCompletionContext = nil
                return
            }

            activeCompletionContext = context
            let caretRect = textView.firstRect(forCharacterRange: NSRange(location: sel.location, length: 0), actualRange: nil)
            completionPopup.show(
                items: items,
                at: caretRect,
                in: textView.window
            ) { [weak self] item in
                self?.acceptCompletion(item)
            }
        }

        private func acceptCompletion(_ item: CompletionItem) {
            guard parent.isVisible, let textView, var context = activeCompletionContext else { return }
            activeCompletionContext = nil
            // Marked text never reported a change, so the context predates it.
            // Commit the composition and re-read the context, or the syllable
            // was left behind after the inserted "]]".
            if textView.hasMarkedText() {
                textView.unmarkText()
                textView.inputContext?.discardMarkedText()
                guard let fresh = CompletionService.detectContext(
                    in: textView.string as NSString,
                    cursorLocation: textView.selectedRange().location
                ), fresh.type == context.type, fresh.range.location == context.range.location else { return }
                context = fresh
            }

            let replacement = context.replacement(for: item)
            let length = (textView.string as NSString).length
            guard context.range.location + context.range.length <= length,
                  textView.shouldChangeText(in: context.range, replacementString: replacement) else { return }

            textView.textStorage?.replaceCharacters(in: context.range, with: replacement)
            // Place the caret before announcing the edit, so the change handler
            // re-evaluates completion at the final spot instead of reopening the
            // popup inside the link that was just completed.
            let caret = context.caretLocation(afterAccepting: item, in: textView.string as NSString)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            textView.didChangeText()
        }
    }
}
