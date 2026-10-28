import XCTest
@testable import CmdMD

/// The shared parse of the untouched note: it must hand back exactly what
/// the in-line passes found, on whatever thread the render runs.
final class SourceParseTests: XCTestCase {
    private let section = "Para\n\n    code [[x]]\n    - [ ] in code\n\n- [ ] task\n%% c\n- [ ] hidden\n%%\n- [x] done\n\n"

    func testLongNoteGivesTheScanLines() {
        let markdown = String(repeating: section, count: 400)
        let parse = SourceParse(markdown, taskLines: true, indentedCode: true)
        XCTAssertEqual(parse.taskLines, TaskLineQueue.scan(markdown))
        XCTAssertEqual(parse.taskLines.count, 800, "the commented task is skipped")
        XCTAssertEqual(parse.indentedCode.count, 400)

        let html = MarkdownRenderer().renderToHTML(markdown: markdown)
        XCTAssertTrue(html.contains("<pre><code>code [[x]]\n- [ ] in code\n</code></pre>"))
        XCTAssertEqual(html.components(separatedBy: "data-task=\"").count - 1, 800)
        XCTAssertFalse(html.contains("disabled />"))
    }

    func testSectionLinesAndRanges() {
        let parse = SourceParse(section, taskLines: true, indentedCode: true)
        XCTAssertEqual(parse.taskLines, [6, 10])
        XCTAssertEqual(parse.indentedCode, [NSRange(location: 6, length: 33)], "lines 3-4, whole")
    }

    func testNothingWantedParsesNothing() {
        let parse = SourceParse(section, taskLines: false, indentedCode: false)
        XCTAssertEqual(parse.taskLines, [])
        XCTAssertEqual(parse.indentedCode, [])
    }

    /// Long notes' source parse once ran on a GCD worker, whose 512 KB
    /// stack overflowed on nesting the main thread renders (from 80 quote or
    /// 60 list levels in a release build, 450 or 200 in a debug one).
    func testDeepNestingParsesOnTheCallersStack() {
        let padding = "\n\n" + String(repeating: "padding text line\n", count: 1200)
        let quotes = String(repeating: ">", count: 600) + " deep - [ ] task\n" + padding
        XCTAssertEqual(MarkdownRenderer().renderBody(markdown: quotes).html.components(separatedBy: "<blockquote>").count - 1, 600)

        let lists = (0..<200).map { String(repeating: "  ", count: $0) + "- [ ] l\($0)" }.joined(separator: "\n") + padding
        XCTAssertEqual(MarkdownRenderer().renderBody(markdown: lists).taskLines.count, 200)
    }

    /// Renders from many pool threads at once agree with a serial one. A
    /// render that waited on a parse queued to the same pool deadlocked once
    /// every pool thread was such a render.
    func testConcurrentRendersFromThePool() {
        let markdown = String(repeating: section, count: 400)
        let expected = MarkdownRenderer().renderBody(markdown: markdown).html
        let matches = Counter()
        let group = DispatchGroup()
        for _ in 0..<256 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                if MarkdownRenderer().renderBody(markdown: markdown).html.utf8.elementsEqual(expected.utf8) { matches.increment() }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        XCTAssertEqual(matches.value, 256)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
}
