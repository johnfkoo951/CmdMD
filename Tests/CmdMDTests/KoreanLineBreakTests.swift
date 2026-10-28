import XCTest
@testable import CmdMD

/// Korean text broke mid-word at line ends ("점검" → "점 / 검"): the preview
/// needs `word-break: keep-all`, but only for Korean — Japanese and Chinese
/// have no spaces, so keep-all would leave them nowhere to break.
final class KoreanLineBreakTests: XCTestCase {
    private func html(_ markdown: String) -> String {
        MarkdownRenderer().renderToHTML(markdown: markdown)
    }

    func testKoreanDocumentGetsKoreanLanguage() {
        XCTAssertTrue(html("# 렌더링 점검\n\n리뷰 퍼스트 리더").contains("<html lang=\"ko\">"))
    }

    func testMixedKoreanAndEnglishIsStillKorean() {
        XCTAssertEqual(MarkdownRenderer.documentLanguage(of: "Agent report 에이전트 보고서"), "ko")
    }

    func testEnglishAndJapaneseAreLeftAlone() {
        XCTAssertNil(MarkdownRenderer.documentLanguage(of: "Plain English text"))
        XCTAssertNil(MarkdownRenderer.documentLanguage(of: "日本語の文章と한국어"))
        XCTAssertTrue(html("Plain English").contains("<html>"))
    }

    func testWrappingRulesShipWithEveryTheme() {
        for theme in PreviewTheme.allCases {
            let page = MarkdownRenderer().renderToHTML(markdown: "본문", theme: theme)
            XCTAssertTrue(page.contains("html:lang(ko) body { word-break: keep-all; }"), "\(theme)")
            XCTAssertTrue(page.contains("overflow-wrap: break-word"), "\(theme)")
        }
    }
}
