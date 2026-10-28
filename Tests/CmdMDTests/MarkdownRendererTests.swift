import XCTest
@testable import CmdMD

final class MarkdownRendererTests: XCTestCase {
    func testWikiLinkAmpersandIsPercentEncodedInInternalLinkQuery() {
        let html = MarkdownRenderer().renderToHTML(markdown: "[[A & B]]")
        let href = firstHref(in: html)

        XCTAssertEqual(href, "cmdmd://open?note=A%20%26%20B")
        XCTAssertFalse(href.contains("&amp;%20B"))
    }

    /// Raw HTML pieces that differ only by normalization each keep their
    /// own bytes (macOS file names are NFD; typed text is NFC).
    func testRawHTMLKeepsEachPiecesNormalization() {
        for (first, second) in [("caf\u{E9}", "cafe\u{301}"), ("\u{D55C}", "\u{1112}\u{1161}\u{11AB}")] {
            for (a, b) in [(first, second), (second, first)] {
                let html = MarkdownRenderer().renderBody(markdown: "<span title=\"\(a)\">x</span> <span title=\"\(b)\">y</span>\n\n<div title=\"\(a)\">\n\n<div title=\"\(b)\">\n").html
                let bytes = Data(html.utf8)
                XCTAssertEqual(bytes, Data("<p><span title=\"\(a)\">x</span> <span title=\"\(b)\">y</span></p>\n<div title=\"\(a)\">\n<div title=\"\(b)\">\n".utf8), html)
            }
        }
    }

    private func firstHref(in html: String) -> String {
        guard let start = html.range(of: "href=\"")?.upperBound,
              let end = html[start...].firstIndex(of: "\"") else {
            return ""
        }
        return String(html[start..<end])
    }
}
