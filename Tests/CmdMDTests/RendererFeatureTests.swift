import XCTest
@testable import CmdMD

final class RendererFeatureTests: XCTestCase {
    private func render(_ markdown: String, configure: (inout MarkdownRenderOptions) -> Void = { _ in }) -> String {
        var options = MarkdownRenderOptions()
        configure(&options)
        return MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
    }

    // MARK: Callouts

    func testCalloutContentRendersMarkdown() {
        let html = render("> [!note] Title\n> Some **bold** text")
        XCTAssertTrue(html.contains("callout-note"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"), "callout bodies must render markdown, not escaped text")
    }

    func testWikiLinkInsideCalloutStaysALink() {
        let html = render("> [!tip]\n> See [[Other Note]]")
        XCTAssertTrue(html.contains("class=\"wiki-link\""), "wiki links inside callouts were previously escaped to literal text")
        XCTAssertFalse(html.contains("&lt;a href"), "anchor markup must not be double-escaped")
    }

    func testCalloutsDisabledLeavesBlockquote() {
        let html = render("> [!note] Title\n> body", configure: { $0.enableCallouts = false })
        XCTAssertFalse(html.contains("class=\"callout"))
    }

    // MARK: Inline extensions

    func testStrikethroughRendersDelTag() {
        let html = render("some ~~gone~~ text")
        XCTAssertTrue(html.contains("<del>gone</del>"))
    }

    func testHighlightSyntaxRendersMark() {
        let html = render("this is ==important== stuff")
        XCTAssertTrue(html.contains("<mark>important</mark>"))
    }

    func testHighlightInsideCodeIsUntouched() {
        let html = render("`a ==b== c`")
        XCTAssertFalse(html.contains("<mark>"))
    }

    func testManyInlineCodeTokensRestoreWithoutExtensionRewriting() {
        let snippets = (0..<25).map { index in
            "`#tag-\(index) [[Note \(index)]] ==mark-\(index)==`"
        }
        let html = render(snippets.joined(separator: " "))

        for index in 0..<25 {
            XCTAssertTrue(
                html.contains("<code>#tag-\(index) [[Note \(index)]] ==mark-\(index)==</code>"),
                "code token \(index) must be restored exactly"
            )
        }
        XCTAssertFalse(html.contains("class=\"wiki-link\""))
        XCTAssertFalse(html.contains("<mark>"))
    }

    // MARK: Wiki links / tags toggle

    func testWikiLinksDisabledRendersPlainText() {
        let html = render("[[Note]]", configure: { $0.enableWikiLinks = false })
        // The .wiki-link CSS class definition is always present in the style
        // block; what matters is that no anchor was generated.
        XCTAssertFalse(html.contains("class=\"wiki-link\""))
        XCTAssertFalse(html.contains("cmdmd://open"))
    }

    // MARK: Math

    func testKaTeXMasksInlineMathFromEmphasisParsing() {
        let html = render("Euler: $a_b + c_d$", configure: { $0.enableKaTeX = true })
        XCTAssertTrue(html.contains("$a_b + c_d$"), "math must survive as literal text for in-DOM rendering")
        XCTAssertFalse(html.contains("<em>"), "underscores inside math must not become emphasis")
        XCTAssertTrue(html.contains("katex"), "KaTeX assets must be included when enabled")
    }

    func testManyMathTokensRestoreExactly() {
        let expressions = (0..<15).map { "$a_\($0) + b_\($0)$" }
        let html = render(expressions.joined(separator: " "), configure: { $0.enableKaTeX = true })

        for expression in expressions {
            XCTAssertTrue(html.contains(expression), "math token must be restored exactly: \(expression)")
        }
        XCTAssertFalse(html.contains("<em>"))
    }

    func testKaTeXDisabledHasNoKatexAssets() {
        let html = render("$a_b$")
        XCTAssertFalse(html.contains("katex"))
    }

    // MARK: Code highlighting

    func testHighlightJSIncludedForCodeBlocks() {
        let html = render("```swift\nlet x = 1\n```")
        XCTAssertTrue(html.contains("highlight.min.js"))
    }

    func testHighlightJSAbsentWhenDisabled() {
        let html = render("```swift\nlet x = 1\n```", configure: { $0.enableCodeHighlight = false })
        XCTAssertFalse(html.contains("highlight.min.js"))
    }

    func testHighlightJSAbsentWithoutCode() {
        let html = render("just text")
        XCTAssertFalse(html.contains("highlight.min.js"))
    }

    // MARK: Mermaid toggle

    func testMermaidDisabledRendersPlainCodeBlock() {
        let html = render("```mermaid\ngraph TD;\n```", configure: { $0.enableMermaid = false })
        XCTAssertFalse(html.contains("class=\"mermaid\""))
        XCTAssertTrue(html.contains("language-mermaid"))
    }

    func testMermaidEnabledRendersDiagramContainer() {
        let html = render("```mermaid\ngraph TD;\n```")
        XCTAssertTrue(html.contains("class=\"mermaid\""))
    }

    // MARK: Heading slugs

    func testDuplicateHeadingSlugsAreDeduplicated() {
        let html = render("# Intro\n\ntext\n\n# Intro")
        XCTAssertTrue(html.contains("id=\"intro\""))
        XCTAssertTrue(html.contains("id=\"intro-1\""))
    }

    func testTOCSlugsMatchRendererIds() {
        let markdown = "# Intro\n\n## Setup\n\n# Intro\n\n```\n# not a heading\n```\n\n## Setup"
        let headings = TOCBuilder.extractHeadings(from: markdown)
        let html = render(markdown)

        XCTAssertEqual(headings.map(\.slug), ["intro", "setup", "intro-1", "setup-1"])
        for heading in headings {
            XCTAssertTrue(html.contains("id=\"\(heading.slug)\""), "renderer must emit anchor for TOC slug \(heading.slug)")
        }
    }

    func testKoreanHeadingGetsUsableSlug() {
        let headings = TOCBuilder.extractHeadings(from: "# 한국어 제목")
        XCTAssertEqual(headings.first?.slug, "한국어-제목")
    }

    // MARK: Settings CSS

    func testPreviewSettingsAreInjected() {
        let html = render("hello", configure: {
            $0.preview.fontSize = 19
            $0.preview.maxWidth = 750
            $0.preview.customCSS = ".x { color: red; }"
        })
        XCTAssertTrue(html.contains("font-size: 19px"))
        XCTAssertTrue(html.contains("max-width: 750px"))
        XCTAssertTrue(html.contains(".x { color: red; }"))
    }

    func testLegacyHeadingColorDefaultIsIgnored() {
        var settings = PreviewSettings()
        settings.headingColor = "#333333"
        XCTAssertNil(settings.effectiveHeadingColor)

        settings.headingColor = "#ff0000"
        XCTAssertEqual(settings.effectiveHeadingColor, "#ff0000")
    }

    // MARK: Interactive tasks

    func testTaskCheckboxCarriesSourceLine() {
        let html = render("intro\n\n- [ ] first\n- [x] second")
        XCTAssertTrue(html.contains("data-line=\"3\""))
        XCTAssertTrue(html.contains("data-line=\"4\""))
    }

    func testExportTasksAreDisabled() {
        let html = render("- [ ] item", configure: { $0.interactiveTasks = false })
        XCTAssertFalse(html.contains("data-line"))
        XCTAssertTrue(html.contains("disabled"))
    }

    func testTaskScanSkipsFencesAndCallouts() {
        let markdown = """
        - [ ] real one
        ```
        - [ ] inside fence
        ```
        > [!todo]
        > - [ ] inside callout
        - [ ] real two
        """
        XCTAssertEqual(TaskLineQueue.scan(markdown), [1, 7])
    }
}
