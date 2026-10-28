import XCTest
@testable import CmdMD

/// `renderBody`'s block ranges: each top-level block's bytes in the final
/// body (after math restore and the asset rewrite), back to back.
final class RenderBodyTests: XCTestCase {
    private func blocks(_ body: MarkdownRenderer.RenderedBody, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let bytes = Array(body.html.utf8)
        var expectedStart = 0
        for range in body.blockRanges {
            XCTAssertEqual(range.lowerBound, expectedStart, "blocks are back to back", file: file, line: line)
            expectedStart = range.upperBound
        }
        XCTAssertEqual(expectedStart, bytes.count, "blocks cover the body", file: file, line: line)
        return body.blockRanges.map { String(decoding: bytes[$0], as: UTF8.self) }
    }

    func testBlockRangesIndexTheFinalBody() {
        var options = MarkdownRenderOptions()
        options.enableKaTeX = true
        options.localAssetRoots = []
        let markdown = """
        # 제목 $x$

        문단 $y$ ![p](p.png)

        - [ ] 할 일

        > [!note] 콜아웃
        > 본문 $z$

        <div>raw</div>

        | a |
        |---|
        | ![q](q.png) |
        """
        let baseURL = URL(fileURLWithPath: "/notes", isDirectory: true)
        let renderer = MarkdownRenderer()
        let body = renderer.renderBody(markdown: markdown, baseURL: baseURL, options: options)
        let html = blocks(body)

        XCTAssertEqual(html.count, 6)
        XCTAssertEqual(html[0], "<h1 id=\"제목-x\">제목 <span class='cmdmd-math'>$x$</span></h1>\n")
        XCTAssertEqual(html[1], "<p>문단 <span class='cmdmd-math'>$y$</span> <img src=\"cmdmd-asset://local/notes/p.png\" alt=\"p\" /></p>\n")
        XCTAssertEqual(html[2], "<ul>\n<li class=\"task-list-item\"><p><input type=\"checkbox\" data-task=\"0\" />할 일</p>\n</li>\n</ul>\n")
        XCTAssertEqual(body.taskLines, [5])
        XCTAssertTrue(html[3].hasPrefix("<div class=\"callout callout-note\">"), html[3])
        XCTAssertTrue(html[3].hasSuffix("본문 <span class='cmdmd-math'>$z$</span></p>\n</div></div>\n"), html[3])
        XCTAssertEqual(html[4], "<div>raw</div>\n")
        XCTAssertTrue(html[5].contains("<img src=\"cmdmd-asset://local/notes/q.png\" alt=\"q\" />"), html[5])
        XCTAssertTrue(html[5].hasSuffix("</table></div>\n"), html[5])

        // The live page's blocks hold the body, back to back; an export page holds it whole.
        let page = renderer.renderPage(markdown: markdown, baseURL: baseURL, options: options)
        let pageBytes = Array(page.html.utf8)
        XCTAssertEqual(page.blocks?.map { String(decoding: pageBytes[$0], as: UTF8.self) }.joined(), body.html)
        options.interactiveTasks = false
        let exportBody = renderer.renderBody(markdown: markdown, baseURL: baseURL, options: options).html
        XCTAssertTrue(renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options).contains(exportBody))
    }

    func testBlockRangesFromTheReadOnlyRender() {
        // The scan sees a task inside display math; the render doesn't, so
        // every box goes read-only through a second visit.
        var options = MarkdownRenderOptions()
        options.enableKaTeX = true
        let html = blocks(MarkdownRenderer().renderBody(markdown: "$$\n- [ ] a\n$$\n\n- [ ] b\n", options: options))
        XCTAssertEqual(html.count, 2)
        XCTAssertTrue(html[0].hasPrefix("<p><span class='cmdmd-math'>$$"), html[0])
        XCTAssertEqual(html[1], "<ul>\n<li class=\"task-list-item\"><p><input type=\"checkbox\" disabled />b</p>\n</li>\n</ul>\n")
    }

    func testEmptyNoteHasNoBlocks() {
        let body = MarkdownRenderer().renderBody(markdown: "")
        XCTAssertEqual(body.html, "")
        XCTAssertEqual(body.blockRanges, [])
    }

    func testOffsetTrackerFollowsCopiesAndSwaps() {
        // Source 0..<25: bytes 8..<14 become 12 bytes (8..<20).
        var tracker = OffsetTracker([0, 5, 8, 10, 14, 20, 25])
        tracker.copied(upTo: 8, rebuilt: 8)
        tracker.swapped(upTo: 14, rebuilt: 20)
        tracker.finished(source: 25, rebuilt: 31)
        XCTAssertEqual(tracker.offsets, [0, 5, 8, 20, 20, 26, 31], "an offset inside the swap moves to its end")

        // The next pass starts from the first offset again.
        tracker.copied(upTo: 0, rebuilt: 0)
        tracker.swapped(upTo: 1, rebuilt: 3)
        tracker.finished(source: 31, rebuilt: 33)
        XCTAssertEqual(tracker.offsets, [0, 7, 10, 22, 22, 28, 33])
    }
}
