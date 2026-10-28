import XCTest
@testable import CmdMD

/// swift-markdown parses neither footnotes nor Obsidian comments: `[^1]`,
/// its `[^1]: text` line and `%%notes to self%%` all showed as literal text.
final class FootnoteAndCommentTests: XCTestCase {
    private func body(_ markdown: String) -> String {
        let html = MarkdownRenderer().renderToHTML(markdown: markdown)
        return String(html[html.range(of: "<body")!.lowerBound...])
    }

    func testReferenceLinksToNumberedNoteAndBack() {
        let html = body("Claim[^src].\n\n[^src]: The **source**.\n")
        XCTAssertTrue(html.contains(##"<sup class="footnote-ref"><a href="#fn-1" id="fnref-1">1</a></sup>"##))
        XCTAssertTrue(html.contains(##"<section class="footnotes">"##))
        XCTAssertTrue(html.contains(##"<a id="fn-1"></a>The <strong>source</strong>."##), "note text is still Markdown")
        XCTAssertTrue(html.contains(##"href="#fnref-1" class="footnote-backref""##))
        XCTAssertFalse(html.contains("[^src]"))
    }

    func testNumbersFollowDefinitionOrderAndRepeatsShareANumber() {
        let html = body("A[^b] B[^a] again[^b]\n\n[^a]: first\n[^b]: second\n")
        XCTAssertTrue(html.contains(##"<a href="#fn-2" id="fnref-2">2</a>"##), "[^b] is the 2nd definition")
        XCTAssertTrue(html.contains(##"<a href="#fn-1" id="fnref-1">1</a>"##))
        XCTAssertTrue(html.contains(##"<a href="#fn-2">2</a>"##), "a repeat reference gets no duplicate id")
    }

    func testIndentedContinuationJoinsTheNote() {
        let html = body("x[^1]\n\n[^1]: line one\n    line two\n")
        XCTAssertTrue(html.contains("line one line two"))
    }

    func testUndefinedReferenceAndCodeStayLiteral() {
        let html = body("No note[^missing] and `[^1]`\n\n```\n[^1]: in code\n```\n\nx[^1]\n\n[^1]: real\n")
        XCTAssertTrue(html.contains("No note[^missing]"))
        XCTAssertTrue(html.contains("<code>[^1]</code>"))
        XCTAssertTrue(html.contains("[^1]: in code"))
    }

    func testCommentsAreHiddenButNotInsideCode() {
        let html = body("Visible %%secret%% text\n\n%%\nblock secret\n%%\n\n`%%kept%%`\n")
        XCTAssertFalse(html.contains("secret"))
        XCTAssertTrue(html.contains("Visible  text"))
        XCTAssertTrue(html.contains("<code>%%kept%%</code>"))
    }
}
