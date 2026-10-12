import XCTest
import AppKit
@testable import CmdMD

final class R2HighlighterTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private let theme = EditorTheme.github
    private let sentinel = NSAttributedString.Key("R2HighlighterSentinel")

    private func highlighted(_ markdown: String) -> NSAttributedString {
        SyntaxHighlighter().highlight(markdown: markdown, font: font, theme: theme)
    }

    private func attribute(_ key: NSAttributedString.Key, at needle: String, in string: NSAttributedString,
                           file: StaticString = #filePath, line: UInt = #line) -> Any? {
        let location = (string.string as NSString).range(of: needle).location
        guard location != NSNotFound else {
            XCTFail("\"\(needle)\" not in text", file: file, line: line)
            return nil
        }
        return string.attribute(key, at: location, effectiveRange: nil)
    }

    private func pointSize(at needle: String, in string: NSAttributedString) -> CGFloat? {
        (attribute(.font, at: needle, in: string) as? NSFont)?.pointSize
    }

    private func isBold(at needle: String, in string: NSAttributedString) -> Bool {
        guard let font = attribute(.font, at: needle, in: string) as? NSFont else { return false }
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    private func foreground(at needle: String, in string: NSAttributedString) -> NSColor? {
        attribute(.foregroundColor, at: needle, in: string) as? NSColor
    }

    private func background(at needle: String, in string: NSAttributedString) -> NSColor? {
        attribute(.backgroundColor, at: needle, in: string) as? NSColor
    }

    private var tagBackground: NSColor { NSColor(theme.linkColor).withAlphaComponent(0.15) }

    // MARK: Inline code vs fences (F005)

    func testInlineCodeNeverSpansFencedBlocks() {
        let string = highlighted("```python\nx = 1\n```\n\n## Section\n\nProse with `inline` code.\n\n```swift\nlet y = 2\n```\n")

        XCTAssertNil(background(at: "Prose", in: string), "prose between fences is not inline code")
        XCTAssertEqual(pointSize(at: "Section", in: string), 24)
        XCTAssertNotNil(background(at: "inline", in: string))
        XCTAssertEqual(pointSize(at: "inline", in: string), 13)
        XCTAssertEqual(pointSize(at: "x = 1", in: string), 13)
        XCTAssertEqual(pointSize(at: "let y", in: string), 13)
        XCTAssertNotEqual(foreground(at: "x = 1", in: string), NSColor(theme.stringColor),
                          "a fence body keeps its own colors, not inline-code string color")
    }

    func testInlineCodeStaysOnOneLine() {
        let string = highlighted("a `b\nc` d")
        XCTAssertNil(background(at: "b", in: string))
        XCTAssertNil(background(at: "c", in: string))
    }

    // MARK: Pass order, line spill, code exclusion (F019)

    func testCalloutColorWinsOverTheQuotePass() {
        let string = highlighted("> [!warning] Careful\n> body")
        XCTAssertEqual(foreground(at: "Careful", in: string), NSColor.systemOrange)
        XCTAssertEqual(foreground(at: "body", in: string), NSColor(theme.commentColor))

        // The callout no longer swallows the next line through `\s*`.
        let next = highlighted("> [!note]\n> x")
        XCTAssertEqual(foreground(at: "x", in: next), NSColor(theme.commentColor))
    }

    func testHeadingQuoteAndListPatternsStayOnTheirLine() {
        XCTAssertEqual(pointSize(at: "Plain", in: highlighted("#\nPlain")), 14)
        XCTAssertEqual(pointSize(at: "Plain", in: highlighted("## \nPlain")), 14)
        XCTAssertNil(background(at: "Plain", in: highlighted(">\n\nPlain")))

        let list = highlighted("-\n\n  - x")
        XCTAssertEqual(foreground(at: "-", in: list), NSColor(theme.keywordColor), "a bare marker is still a list item")
        let nested = (list.string as NSString).range(of: "- x").location
        XCTAssertEqual(list.attribute(.foregroundColor, at: nested, effectiveRange: nil) as? NSColor,
                       NSColor(theme.keywordColor), "a marker after blank lines is still styled")
    }

    func testCodeIsExcludedFromMarkdownStyling() {
        let string = highlighted("""
        ```c
        #include <stdio.h>
        # not a heading
        int __init__ = 1;
        - not a list
        ```
        see `#todo` and `__x__` then #real **bold `code` bold**
        """)

        XCTAssertNotEqual(background(at: "#include", in: string), tagBackground)
        XCTAssertEqual(pointSize(at: "not a heading", in: string), 13)
        XCTAssertFalse(isBold(at: "__init__", in: string))
        XCTAssertNotEqual(foreground(at: "- not", in: string), NSColor(theme.keywordColor))
        XCTAssertNotEqual(background(at: "#todo", in: string), tagBackground)
        XCTAssertFalse(isBold(at: "__x__", in: string))
        XCTAssertEqual(background(at: "#real", in: string), tagBackground)
        XCTAssertTrue(isBold(at: "bold `", in: string), "emphasis around a code span still applies")
    }

    func testQuoteLinesInsideACodeFenceAreCode() {
        let string = highlighted("```python\n>>> print(1)\n```\n> real quote")
        XCTAssertNotEqual(foreground(at: ">>>", in: string), NSColor(theme.commentColor))
        XCTAssertEqual(foreground(at: "real quote", in: string), NSColor(theme.commentColor))
    }

    // MARK: Fence detection (F018)

    func testFencesWithSymbolInfoWordsAndCRLFPairCorrectly() {
        let documents = [
            "```c++\nint x;\n```\n\nProse\n\n```python\nprint(1)\n```\n",
            "```c++\r\nint x;\r\n```\r\n\r\nProse\r\n\r\n```python\r\nprint(1)\r\n```\r\n",
            "```js title=\"a.js\"\nint x;\n```\n\nProse\n\n```objective-c\nprint(1)\n```\n",
            "```c#\nint x;\n```\n\nProse\n\n```ad-note\nprint(1)\n```\n"
        ]
        for markdown in documents {
            let string = highlighted(markdown)
            XCTAssertEqual(pointSize(at: "int x", in: string), 13, markdown)
            XCTAssertEqual(pointSize(at: "print", in: string), 13, markdown)
            XCTAssertEqual(pointSize(at: "Prose", in: string), 14, markdown)
            XCTAssertNil(background(at: "Prose", in: string), markdown)
        }
    }

    func testTildeNestedQuotedAndUnclosedFences() {
        let tilde = highlighted("~~~js\nlet a\n~~~\nProse")
        XCTAssertEqual(pointSize(at: "let a", in: tilde), 13)
        XCTAssertEqual(pointSize(at: "Prose", in: tilde), 14)

        let nested = highlighted("````md\n```js\ninner\n```\n````\nAfter")
        XCTAssertEqual(pointSize(at: "inner", in: nested), 13)
        XCTAssertEqual(pointSize(at: "After", in: nested), 14)

        // A code block inside a callout is code, and keeps the quote colors.
        let quoted = highlighted("> [!example]\n> ```python\n> print(1) #tag\n> ```\nAfter")
        XCTAssertEqual(pointSize(at: "print", in: quoted), 13)
        XCTAssertEqual(foreground(at: "print", in: quoted), NSColor(theme.commentColor))
        XCTAssertNotEqual(background(at: "#tag", in: quoted), tagBackground)
        XCTAssertEqual(pointSize(at: "After", in: quoted), 14)

        // Inline triple backticks don't open a fence; an unclosed fence stays prose.
        XCTAssertEqual(pointSize(at: "Prose", in: highlighted("```inline code```\nProse\n```\nx")), 14)
        XCTAssertEqual(pointSize(at: "code", in: highlighted("```js\ncode")), 14)
    }

    func testFenceWordsMapToHighlightJSLanguages() {
        let supported: Set<String> = ["cpp", "csharp", "javascript", "objectivec", "python", "bash"]
        XCTAssertEqual(SyntaxHighlighter.highlightrLanguage(for: "c++", supported: supported), "cpp")
        XCTAssertEqual(SyntaxHighlighter.highlightrLanguage(for: "C#", supported: supported), "csharp")
        XCTAssertEqual(SyntaxHighlighter.highlightrLanguage(for: "JS", supported: supported), "javascript")
        XCTAssertEqual(SyntaxHighlighter.highlightrLanguage(for: "dataviewjs", supported: supported), "javascript")
        XCTAssertEqual(SyntaxHighlighter.highlightrLanguage(for: "objective-c", supported: supported), "objectivec")
        XCTAssertEqual(SyntaxHighlighter.highlightrLanguage(for: "Python", supported: supported), "python")
        XCTAssertEqual(SyntaxHighlighter.highlightrLanguage(for: "zsh", supported: supported), "bash")
        // No grammar: no Highlightr call (it would auto-detect over every grammar).
        for word in ["mermaid", "dataview", "ad-note", "vue", ""] {
            XCTAssertNil(SyntaxHighlighter.highlightrLanguage(for: word, supported: supported), word)
        }
    }

    // MARK: Unicode tags (F022)

    func testUnicodeTagsAreHighlighted() {
        let string = highlighted("#회의록 #meeting #아이디어/하위 #café #1위 #1984 C#언어")
        for needle in ["#회의록", "#meeting", "#아이디어", "하위", "#café", "#1위"] {
            XCTAssertEqual(background(at: needle, in: string), tagBackground, needle)
        }
        XCTAssertNil(background(at: "#1984", in: string))
        XCTAssertNil(background(at: "언어", in: string))
    }

    func testUnicodeTagsAreHarvestedAndRendered() {
        XCTAssertEqual(
            MarkdownDocument.inlineTags(in: "메모 #회의록 끝 #아이디어/하위, #café #1984 C#언어"),
            ["회의록", "아이디어/하위", "café"]
        )

        let html = MarkdownRenderer().renderToHTML(markdown: "메모 #회의록 끝 #1984", options: MarkdownRenderOptions())
        XCTAssertTrue(html.contains("data-tag=\"회의록\""))
        XCTAssertFalse(html.contains("data-tag=\"1984\""))
    }

    // MARK: Typing-pause region passes (F102)

    func testUnionFoldsEditsIntoPostEditCoordinates() {
        // Typing two characters at 10.
        var pending = SyntaxHighlighter.union(pending: nil, edited: NSRange(location: 10, length: 1), changeInLength: 1)
        pending = SyntaxHighlighter.union(pending: pending, edited: NSRange(location: 11, length: 1), changeInLength: 1)
        XCTAssertEqual(pending, NSRange(location: 10, length: 2))

        // An insertion before the pending range moves it.
        XCTAssertEqual(
            SyntaxHighlighter.union(pending: NSRange(location: 10, length: 2), edited: NSRange(location: 0, length: 3), changeInLength: 3),
            NSRange(location: 0, length: 15)
        )
        // A deletion swallowing it collapses to the edit point.
        XCTAssertEqual(
            SyntaxHighlighter.union(pending: NSRange(location: 10, length: 2), edited: NSRange(location: 8, length: 0), changeInLength: -6),
            NSRange(location: 8, length: 0)
        )
        // An edit after it: the hull of both.
        XCTAssertEqual(
            SyntaxHighlighter.union(pending: NSRange(location: 2, length: 1), edited: NSRange(location: 20, length: 2), changeInLength: 2),
            NSRange(location: 2, length: 20)
        )
    }

    /// Fully highlights `before`, marks every character, replaces the first
    /// `target` with `replacement`, runs the typing-pause pass, and returns
    /// the characters it restyled (the ones that lost the mark).
    private func restyledText(before: String, replacing target: String, with replacement: String,
                              theme passTheme: EditorTheme? = nil) -> (restyled: String, storage: NSTextStorage) {
        let storage = NSTextStorage(string: before)
        let highlighter = SyntaxHighlighter()
        highlighter.applyHighlights(to: storage, font: font, theme: theme)
        storage.addAttribute(sentinel, value: true, range: NSRange(location: 0, length: storage.length))

        let range = (before as NSString).range(of: target)
        storage.replaceCharacters(in: range, with: replacement)
        let edited = NSRange(location: range.location, length: (replacement as NSString).length)
        highlighter.applyHighlights(to: storage, font: font, theme: passTheme ?? theme, editedRange: edited)

        var restyled = ""
        storage.enumerateAttribute(sentinel, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value == nil { restyled += (storage.string as NSString).substring(with: range) }
        }
        return (restyled, storage)
    }

    func testTypingRestylesOnlyTheEditedLine() {
        let before = "# Title\n\nfirst line\nsecond line\n\n```js\nlet a = 1\n```\n"
        XCTAssertEqual(restyledText(before: before, replacing: "first line", with: "first line!").restyled, "first line!\n")
    }

    func testTypingInAFenceRestylesTheWholeFence() {
        let before = "intro\n\n```js\nlet a = 1\nlet b = 2\n```\noutro\n"
        XCTAssertEqual(
            restyledText(before: before, replacing: "a = 1", with: "a = 12").restyled,
            "```js\nlet a = 12\nlet b = 2\n```\n"
        )
    }

    func testSplittingAHeadingRestylesBothHalves() {
        let result = restyledText(before: "# Heading here\nnext\n", replacing: "Heading here", with: "Head\ning here")
        XCTAssertEqual(result.restyled, "# Head\ning here\n")
        XCTAssertEqual(pointSize(at: "ing here", in: result.storage), 14)
    }

    func testRePairingFencesOrChangingThemeRestylesEverything() {
        let before = "a\n\n```js\nx\n```\n\nb\n"
        let opened = restyledText(before: before, replacing: "a\n", with: "```\na\n")
        XCTAssertEqual(opened.restyled, opened.storage.string, "a new fence re-pairs every later fence")

        let themed = restyledText(before: before, replacing: "b", with: "bc", theme: .oneDark)
        XCTAssertEqual(themed.restyled, themed.storage.string)
    }

    /// The region pass must leave the text exactly as a full pass would, for
    /// any edit sequence — fence openers, CRLF, quotes, Korean tags included.
    func testRegionPassesMatchAFullPassAcrossRandomEdits() {
        let snippets = ["a", "b ", "\n", "#", "## ", "**", "*", "_", "`", "```", "```js\n", "~~~", "\n```\n",
                        "> ", "> [!note] ", "- ", "1. ", "[[", "]]", "[x](y)", "==", " #태그", "회의", "\r\n", "---\n"]
        let storage = NSTextStorage(string: """
        # Title

        Some **bold** and `code` with #tag.

        ```swift
        let x = 1 // #nottag
        ```

        > [!tip] Hint
        > quoted [[Link]]

        - item ==mark==

        """)
        let highlighter = SyntaxHighlighter()
        highlighter.applyHighlights(to: storage, font: font, theme: theme)

        let log = EditLog()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [log] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            log.pending = SyntaxHighlighter.union(pending: log.pending, edited: storage.editedRange, changeInLength: storage.changeInLength)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var random = SplitMix64(seed: 0x5EED)
        for step in 0..<600 {
            let length = storage.length
            let location = Int.random(in: 0...length, using: &random)
            let deleted = Bool.random(using: &random) ? 0 : Int.random(in: 0...min(8, length - location), using: &random)
            let inserted = Bool.random(using: &random) ? snippets.randomElement(using: &random)! : ""
            storage.replaceCharacters(in: NSRange(location: location, length: deleted), with: inserted)

            guard step % 3 == 2, let edited = log.pending else { continue }
            highlighter.applyHighlights(to: storage, font: font, theme: theme, editedRange: edited)
            log.pending = nil

            let expected = NSTextStorage(string: storage.string)
            SyntaxHighlighter().applyHighlights(to: expected, font: font, theme: theme)
            if let index = firstDifference(storage, expected) {
                XCTFail("step \(step): attributes differ at \(index) in \(storage.string.debugDescription)")
                return
            }
        }
    }

    private func firstDifference(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> Int? {
        guard lhs.string == rhs.string else { return 0 }
        for index in 0..<lhs.length {
            let left = lhs.attributes(at: index, effectiveRange: nil) as NSDictionary
            let right = rhs.attributes(at: index, effectiveRange: nil) as NSDictionary
            if !left.isEqual(right) { return index }
        }
        return nil
    }
}

private final class EditLog {
    var pending: NSRange?
}

/// Deterministic generator so a failing edit sequence replays exactly.
private struct SplitMix64: RandomNumberGenerator {
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
