import XCTest
@testable import CmdMD

/// HTML fidelity against CommonMark 0.31 / GFM / Obsidian reading view: the
/// constructs that rendered visibly wrong before.
final class RenderFidelityTests: XCTestCase {
    private func body(_ markdown: String, configure: (inout MarkdownRenderOptions) -> Void = { _ in }) -> String {
        var options = MarkdownRenderOptions()
        configure(&options)
        let html = MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
        return String(html[html.range(of: "<body")!.lowerBound...])
    }

    // MARK: Lists

    func testTightAndLooseLists() {
        XCTAssertTrue(body("- a\n- b\n").contains("<ul>\n<li><p>a</p>"), "tight: no class, no empty class attribute")
        XCTAssertTrue(body("- a\n\n- b\n").contains("<ul class=\"loose\">"))
        XCTAssertTrue(body("- a\n- b\n\n  more\n").contains("<ul class=\"loose\">"), "two blocks with a blank line inside one item")
        XCTAssertTrue(body("- a\n  - b\n\n  - c\n- d\n").contains("<ul>\n<li><p>a</p>"), "a loose sublist leaves the outer list tight")
        XCTAssertTrue(body("- x\n  ```\n  a\n\n  b\n  ```\n- y\n").contains("<ul>\n"), "a blank line inside a fence doesn't loosen")
    }

    func testTaskCheckboxSitsInsideTheFirstParagraph() {
        let html = body("- [ ] todo\n- [x] done\n")
        XCTAssertTrue(html.contains("<li class=\"task-list-item\"><p><input type=\"checkbox\" data-task=\"0\" /> todo</p>"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" checked data-task=\"1\""))
    }

    func testQuotedTasksRenderReadOnlyAndDontShiftTheQueue() {
        let html = body("> - [ ] quoted\n\n- [ ] real\n")
        XCTAssertTrue(html.contains("<p><input type=\"checkbox\" disabled /> quoted</p>"))
        XCTAssertTrue(html.contains("data-task=\"0\""))
        XCTAssertEqual(MarkdownRenderer().renderBody(markdown: "> - [ ] quoted\n\n- [ ] real\n").taskLines, [3])
        XCTAssertFalse(html.contains("[ ] quoted"))
    }

    func testOrderedListKeepsItsStart() {
        XCTAssertTrue(body("3. three\n4. four\n").contains("<ol start=\"3\">"))
        XCTAssertTrue(body("1. one\n").contains("<ol>"))
    }

    // MARK: Tables

    func testTableColumnAlignment() {
        let html = body("| L | C | R | N |\n|:--|:-:|--:|---|\n| a | b | c | d |\n")
        XCTAssertTrue(html.contains("<th align=\"center\">C</th>"))
        XCTAssertTrue(html.contains("<td align=\"right\">c</td>"))
        XCTAssertTrue(html.contains("<td>d</td>"))
    }

    func testTablesScrollInsideTheirOwnBox() {
        let html = MarkdownRenderer().renderToHTML(markdown: "| a |\n|---|\n| b |\n")
        XCTAssertTrue(html.contains("<div class=\"table-scroll\"><table>\n<thead>"))
        XCTAssertTrue(html.contains("</table></div>"))
        XCTAssertTrue(html.contains(".table-scroll{overflow-x:auto;"))
    }

    // MARK: Code

    func testCodeLanguageIsTheInfoStringsFirstWord() {
        XCTAssertTrue(body("```swift title=\"a.swift\"\nx\n```").contains("<pre><code class=\"language-swift\">"))
        XCTAssertTrue(body("```{.python}\nx\n```").contains("<pre><code class=\"language-python\">"))
    }

    func testUnlabelledCodeIsNotAutoHighlighted() {
        let html = MarkdownRenderer().renderToHTML(markdown: "```\nplain text\n```\n\n    indented\n")
        XCTAssertTrue(html.contains("<pre><code>plain text"))
        XCTAssertTrue(html.contains("<pre><code>indented"))
        XCTAssertFalse(html.contains("highlight.min.js"), "no labelled block, no highlighter")
        let labelled = MarkdownRenderer().renderToHTML(markdown: "```js\nx\n```")
        XCTAssertTrue(labelled.contains("pre code[class^=\"language-\"]"))
    }

    // MARK: Callouts

    func testCalloutWithBlankLineInsideAFence() {
        let html = body("> [!note] Code\n> ```python\n> a = 1\n>\n> b = 2\n> ```\n> after\n")
        XCTAssertTrue(html.contains("<pre><code class=\"language-python\">a = 1\n\nb = 2\n</code></pre>"))
        XCTAssertTrue(html.contains("<p>after</p>\n</div></div>"))
    }

    func testNestedCalloutsAndCalloutInList() {
        let nested = body("> [!info] Outer\n> > [!danger] Inner\n> > text\n")
        XCTAssertTrue(nested.contains("callout-info"))
        XCTAssertTrue(nested.contains("<div class=\"callout callout-danger\">"))
        XCTAssertFalse(nested.contains("[!danger]"))
        XCTAssertTrue(body("- item\n  > [!tip] In list\n  > body\n").contains("callout-tip"))
    }

    func testCalloutTitleIsMarkdownAndEmptyTitleNamesTheType() {
        XCTAssertTrue(body("> [!example] With **bold**\n> x").contains("<span class=\"callout-title\">With <strong>bold</strong></span>"))
        XCTAssertTrue(body("> [!abstract]\n> x").contains("<span class=\"callout-title\">Abstract</span>"))
        XCTAssertTrue(body("> [!faq]- Q\n> x").contains("<details class=\"callout callout-faq\"><summary>"))
    }

    func testDisplayMathInACalloutLosesTheQuoteMarkers() {
        let html = body("> [!info] Math\n> $$\n> E=mc^2\n> $$\n", configure: { $0.enableKaTeX = true })
        XCTAssertTrue(html.contains("<span class='cmdmd-math'>$$\nE=mc^2\n$$</span>"))
    }

    func testMermaidInsideACalloutRenders() {
        XCTAssertTrue(body("> [!example] D\n> ```mermaid\n> graph TD; A-->B\n> ```\n").contains("<div class=\"cmdmd-diagram\"><pre class=\"mermaid\">"))
    }

    func testNestedHeadingsDontShiftTheTOCSequence() {
        let markdown = "## Intro\n\n> ## Intro\n\n- ## Intro\n\n## Intro\n"
        let html = body(markdown).replacingOccurrences(of: PreviewRuntime.marker, with: "")
        XCTAssertEqual(TOCBuilder.extractHeadings(from: markdown).map(\.slug), ["intro", "intro-1"])
        XCTAssertTrue(html.hasSuffix("<h2 id=\"intro-1\">Intro</h2>\n</body>\n</html>") || html.contains("</ul>\n<h2 id=\"intro-1\">Intro</h2>"),
                      "the last top-level heading is the TOC's second entry")
        XCTAssertEqual(Self.headingIDs(html), ["intro", "intro-2", "intro-3", "intro-1"],
                       "quoted / listed headings take ids the TOC never links to")
    }

    private static func headingIDs(_ html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"<h[1-6] id="([^"]*)""#)
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Every TOC entry's slug must be the id of THAT heading, and ids unique:
    /// a callout heading named like a later top-level one used to share its
    /// id (the TOC jumped into the callout), a list-continuation heading
    /// shifted later duplicates (dead TOC entries), a setext heading took
    /// the id of the ATX one the TOC lists.
    func testTOCSlugsPointAtTheirOwnHeadings() {
        let markdown = "# Top\n\n> [!note] H\n> ## Inner\n> text\n\n## Inner\n\n- item\n\n  ## Listed\n\n## Listed\n\nSetext\n------\n\n## Setext\n"
        let toc = TOCBuilder.extractHeadings(from: markdown)
        XCTAssertEqual(toc.map(\.slug), ["top", "inner", "listed", "listed-1", "setext"])
        let ids = Self.headingIDs(body(markdown))
        XCTAssertEqual(ids, ["top", "inner-1", "inner", "listed", "listed-1", "setext-1", "setext"])
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate heading ids")
    }

    func testEmptyTaskItemDoesNotLoosenTheList() {
        XCTAssertTrue(body("- [ ]\n- [ ] \n- [x] done\n").contains("<ul>\n"))
    }

    // MARK: Images

    func testMarkdownImageSizeInAltText() {
        XCTAssertTrue(body("![alt|300](https://x.com/a.png)").contains("<img src=\"https://x.com/a.png\" alt=\"alt\" width=\"300\" />"))
        XCTAssertTrue(body("![|200x100](https://x.com/a.png)").contains("alt=\"\" width=\"200\" height=\"100\""))
        XCTAssertTrue(body("![a|b](https://x.com/a.png)").contains("alt=\"a|b\""), "not a size: kept as alt text")
    }

    // MARK: CJK emphasis

    func testKoreanEmphasisNextToPunctuation() {
        let html = body("**AI(인공지능)**은 중요. 한국어**\"인용\"**입니다. **[[링크]]**는. *기울임.*다음. **보통**만.\n")
        XCTAssertTrue(html.contains("<strong>AI(인공지능)</strong>은"))
        XCTAssertTrue(html.contains("한국어<strong>&quot;인용&quot;</strong>입니다"))
        XCTAssertTrue(html.contains("class=\"wiki-link\">링크</a></strong>는"))
        XCTAssertTrue(html.contains("<em>기울임.</em>다음"))
        XCTAssertFalse(html.contains("\u{2060}"), "the joiner never reaches the page")
        XCTAssertTrue(body("`**\"c\"**는`").contains("<code>**&quot;c&quot;**는</code>"), "code is untouched")
        XCTAssertTrue(body("**English (note)**s\n").contains("**English (note)**s"), "non-CJK keeps CommonMark")
    }

    func testKoreanEmphasisHeadingSlugMatchesTOC() {
        let markdown = "## **AI(인공지능)**은 제목\n"
        XCTAssertEqual(TOCBuilder.extractHeadings(from: markdown).first?.text, "AI(인공지능)은 제목")
        XCTAssertTrue(body(markdown).contains("<h2 id=\"\(TOCBuilder.extractHeadings(from: markdown)[0].slug)\"><strong>AI(인공지능)</strong>은 제목</h2>"))
    }

    func testStrictLineBreaksSettingDefaultsToObsidian() throws {
        XCTAssertFalse(AppSettings().strictLineBreaks)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.strictLineBreaks)
    }

    func testCommentedHeadingsAndTasksAreSkipped() {
        let markdown = "# A\n\n%%\n# hidden\n- [ ] hidden task\n%%\n\n- [ ] real\n"
        XCTAssertEqual(TOCBuilder.extractHeadings(from: markdown).map(\.slug), ["a"])
        XCTAssertEqual(TaskLineQueue.scan(markdown), [8])
        XCTAssertTrue(body(markdown).contains("data-task=\"0\""), "a commented task no longer turns every box read-only")
        XCTAssertEqual(MarkdownRenderer().renderBody(markdown: markdown).taskLines, [8])
        XCTAssertEqual(TaskLineQueue.scan("- [ ] a `%%`\n- [ ] b\n"), [1, 2], "a %% in a code span opens nothing")
    }

    // MARK: Inline

    func testNoSmartPunctuationAndSlugsMatchTheTOC() {
        let html = body("Use --verbose and \"quotes\".\n\n# pre--post\n")
        XCTAssertTrue(html.contains("Use --verbose and &quot;quotes&quot;."))
        XCTAssertTrue(html.contains("<h1 id=\"pre-post\">"))
        XCTAssertEqual(TOCBuilder.extractHeadings(from: "# pre--post\n").map(\.slug), ["pre-post"])
    }

    func testSingleTildeIsNotStrikethrough() {
        let html = body("회의는 1~2시간, 준비는 3~4일. ~~gone~~\n")
        XCTAssertTrue(html.contains("1~2시간, 준비는 3~4일"))
        XCTAssertTrue(html.contains("<del>gone</del>"))
    }

    func testHighlightNeedsFlankingMarks() {
        XCTAssertFalse(body("if a == b and c == d\n").contains("<mark>"))
        XCTAssertTrue(body("==yes== and a==b==c\n").contains("<mark>yes</mark>"))
    }

    func testBareURLsBecomeLinks() {
        let html = body("See https://x.com/a_b?q=1&r=2, (https://y.com/p) or www.apple.com/kr. [t](https://z.com) `https://code.com`\n")
        XCTAssertTrue(html.contains("<a href=\"https://x.com/a_b?q=1&amp;r=2\">https://x.com/a_b?q=1&amp;r=2</a>,"))
        XCTAssertTrue(html.contains("(<a href=\"https://y.com/p\">https://y.com/p</a>)"))
        XCTAssertTrue(html.contains("<a href=\"http://www.apple.com/kr\">www.apple.com/kr</a>."))
        XCTAssertTrue(html.contains("<a href=\"https://z.com\">t</a>"), "an explicit link is left alone")
        XCTAssertTrue(html.contains("<code>https://code.com</code>"))
    }

    func testLinkAndImageTitles() {
        XCTAssertTrue(body("[a](https://x.com \"T\")").contains("<a href=\"https://x.com\" title=\"T\">a</a>"))
        XCTAssertTrue(body("![a](https://x.com/i.png \"T\")").contains("alt=\"a\" title=\"T\""))
    }

    func testObsidianLineBreaksOption() {
        XCTAssertTrue(body("one\ntwo").contains("<p>one\ntwo</p>"))
        XCTAssertTrue(body("one\ntwo", configure: { $0.obsidianLineBreaks = true }).contains("<p>one<br />\ntwo</p>"))
    }
}
