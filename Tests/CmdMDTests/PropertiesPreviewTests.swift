import XCTest
@testable import CmdMD

/// The note's properties above its text in the live preview (Obsidian's
/// reading view), and nowhere else.
final class PropertiesPreviewTests: XCTestCase {
    private let block = """
    ---
    type: note
    aliases:
      - 월간 옵시디언 023 런처
      - "a <b> & c"
    description: Stage launcher, see https://example.com/session-23/. Session omnicontrol://focus?x=1
    session-link: "omnicontrol://focus?workspace=0000-1111-2222-3333&surface=4444-5555-6666-7777&revive=1"
    author: "[[홍길동]]"
    date created: 2026-11-25T11:20
    tags:
      - monthly-obsidian
      - "#lecture-launcher"
    CMDS: "[[840 Lectures|📚 840 Lectures]]"
    published: false
    done: true
    count: 7
    empty:
    nested:
      a: 1
    ---

    """

    private func render(_ block: String) -> String { PropertiesRenderer.html(block: block) }

    func testRowsFollowTheFileOrder() {
        let html = render(block)
        let keys = ["type", "aliases", "description", "session-link", "author", "date created", "tags", "CMDS", "published", "done", "count", "empty", "nested"]
        let positions = keys.map { html.range(of: "<div class=\"cmdmd-prop-key\">\($0)</div>")?.lowerBound }
        XCTAssertFalse(positions.contains(nil), "\(zip(keys, positions).filter { $0.1 == nil }.map(\.0))")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertTrue(html.hasPrefix("<details class=\"cmdmd-properties\" open>\n<summary>Properties</summary>"))
    }

    func testValuesByKind() {
        let html = render(block)
        // Lists as chips, escaped.
        XCTAssertTrue(html.contains("<span class=\"cmdmd-prop-chip\">월간 옵시디언 023 런처</span>"))
        XCTAssertTrue(html.contains("<span class=\"cmdmd-prop-chip\">a &lt;b&gt; &amp; c</span>"))
        XCTAssertFalse(html.contains("<b>"))
        // Tags as tags, one #.
        XCTAssertTrue(html.contains("<span class=\"tag\" data-tag=\"monthly-obsidian\">#monthly-obsidian</span>"))
        XCTAssertTrue(html.contains("<span class=\"tag\" data-tag=\"lecture-launcher\">#lecture-launcher</span>"))
        // Wiki links open the note; an alias is the label.
        XCTAssertTrue(html.contains("<a href=\"cmdmd://open?note=%ED%99%8D%EA%B8%B8%EB%8F%99\" class=\"wiki-link\">홍길동</a>"))
        XCTAssertTrue(html.contains("class=\"wiki-link\">📚 840 Lectures</a>"))
        // Web links open; trailing punctuation stays outside; other schemes stay text.
        XCTAssertTrue(html.contains("<a href=\"https://example.com/session-23/\">https://example.com/session-23/</a>."))
        XCTAssertFalse(html.contains("href=\"omnicontrol"))
        XCTAssertTrue(html.contains("omnicontrol://focus?x=1"))
        // Booleans as read-only boxes, numbers as written, empties marked.
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled aria-label=\"published\">"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked aria-label=\"done\">"))
        XCTAssertFalse(html.contains("data-task"), "a property box must never toggle a task")
        XCTAssertTrue(html.contains("<div class=\"cmdmd-prop-value\">7</div>"))
        XCTAssertTrue(html.contains("<div class=\"cmdmd-prop-value\"><span class=\"cmdmd-prop-empty\">Empty</span></div>"))
        // A date and time in the system's format, the original kept.
        let shown = try? XCTUnwrap(PropertiesRenderer.formattedDate("2026-11-25T11:20"))
        XCTAssertTrue(html.contains("<time datetime=\"2026-11-25T11:20\">\(PropertiesRenderer.htmlEscape(shown ?? ""))</time>"))
        // One long unbroken value on one line, whole on hover.
        XCTAssertTrue(html.contains("<span class=\"cmdmd-prop-long\" title=\"omnicontrol://focus?workspace=0000-1111-2222-3333&amp;surface=4444-5555-6666-7777&amp;revive=1\">"))
        XCTAssertFalse(html.contains("<span class=\"cmdmd-prop-long\" title=\"Stage"), "prose wraps")
        // A nested map as its YAML.
        XCTAssertTrue(html.contains("<span class=\"cmdmd-prop-raw\">a: 1</span>"))
    }

    func testDatesAreOnlyRealDates() {
        XCTAssertNotNil(PropertiesRenderer.formattedDate("2026-11-25"))
        XCTAssertNotNil(PropertiesRenderer.formattedDate("2026-11-25 09:05:30"))
        XCTAssertNil(PropertiesRenderer.formattedDate("2026-02-31"))
        XCTAssertNil(PropertiesRenderer.formattedDate("2026-11-25T25:00"))
        XCTAssertNil(PropertiesRenderer.formattedDate("2026-11"))
        XCTAssertNil(PropertiesRenderer.formattedDate("v2026-11-25"))
    }

    func testUnreadablePropertiesShowTheirText() {
        let html = render("---\nkey: [unclosed\n<script>x</script>\n---\n")
        XCTAssertTrue(html.contains("<pre class=\"cmdmd-prop-raw\">key: [unclosed\n&lt;script&gt;x&lt;/script&gt;</pre>"))
        XCTAssertEqual(render("---\n---\n"), "")
        XCTAssertEqual(render("---\n\n---\n\n"), "")
    }

    // MARK: The page

    private func page(_ markdown: String, properties: String?) -> PreviewPage {
        var options = MarkdownRenderOptions()
        options.properties = properties
        return PreviewPage(rendered: MarkdownRenderer().renderPage(markdown: markdown, options: options), source: markdown,
                           baseURL: nil, options: options, generation: 1, renderMs: nil)
    }

    func testTheBlockSitsAboveTheNoteOutsideThePatchedRoot() throws {
        let markdown = "# Title\n\nBody text\n\n- [ ] task\n"
        let with = page(markdown, properties: block)
        let without = page(markdown, properties: nil)
        let html = with.html
        let properties = try XCTUnwrap(html.range(of: "<details class=\"cmdmd-properties\""))
        let body = try XCTUnwrap(html.range(of: "<body class=\"markdown-body\">"))
        let root = try XCTUnwrap(html.range(of: PreviewRuntime.rootOpening))
        XCTAssertLessThan(body.upperBound, properties.lowerBound)
        XCTAssertLessThan(properties.lowerBound, root.lowerBound)
        XCTAssertTrue(html.contains(".cmdmd-props {"), "the styles come with the block")
        XCTAssertFalse(without.html.contains("cmdmd-properties"))

        // The note's blocks are the same blocks with or without it.
        func blocks(_ page: PreviewPage) throws -> [String] {
            let utf8 = Array(page.html.utf8)
            return try XCTUnwrap(page.rendered.blocks).map { String(decoding: utf8[$0], as: UTF8.self) }
        }
        XCTAssertEqual(try blocks(with), try blocks(without))
        XCTAssertEqual(with.rendered.taskLines, without.rendered.taskLines)
    }

    func testTypingPatchesAndAPropertyEditReloads() {
        let before = page("# Title\n\nOne\n", properties: block)
        XCTAssertNotNil(PreviewEdit(from: before, to: page("# Title\n\nOne two\n", properties: block)),
                        "an edit of the text still patches")
        let edited = block.replacingOccurrences(of: "type: note", with: "type: lecture")
        XCTAssertNil(PreviewEdit(from: before, to: page("# Title\n\nOne\n", properties: edited)),
                     "a property edit must reload the page: the block is outside what a patch replaces")
    }

    func testExportsHaveNoPropertiesBlock() {
        let html = MarkdownRenderer().renderToHTML(markdown: "# Title\n", options: MarkdownRenderOptions())
        XCTAssertFalse(html.contains("cmdmd-properties"))
    }
}

/// Which properties the preview gets: the current note's, as edited, when
/// the setting is on.
final class PropertiesPreviewOptionsTests: IsolatedDataDirTestCase {
    @MainActor
    func testThePreviewGetsTheNotesPropertiesAndExportsDoNot() async throws {
        let note = dataDir.appendingPathComponent("note.md")
        try "---\ntitle: Launcher\ntags: [a]\n# a comment\n---\n\n# Body\n".write(to: note, atomically: true, encoding: .utf8)
        var document = try await FileService().loadDocument(from: note)
        XCTAssertEqual(document.propertiesBlock, "---\ntitle: Launcher\ntags: [a]\n# a comment\n---\n\n")

        let state = AppState()
        let tab = EditorTab(documentId: document.id, fileURL: note)
        state.documents[document.id] = document
        state.tabs = [tab]
        state.activeTabId = tab.id

        XCTAssertEqual(state.previewRenderOptions().properties, document.propertiesBlock)
        XCTAssertNil(state.renderOptions().properties, "exports and the TOC take no properties")

        // An edit in the Inspector shows up (the comment line kept).
        document.frontmatter?.tags = ["a", "b"]
        state.documents[document.id] = document
        let edited = try XCTUnwrap(state.previewRenderOptions().properties)
        XCTAssertTrue(PropertiesRenderer.html(block: edited).contains("data-tag=\"b\""))

        state.settings.showPropertiesInPreview = false
        XCTAssertNil(state.previewRenderOptions().properties)
        state.tabs.forEach { state.closeTab($0) }
    }

    func testSettingsWithoutTheKeyShowProperties() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{\"theme\":\"Light\"}".utf8))
        XCTAssertTrue(decoded.showPropertiesInPreview)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data("{\"showPropertiesInPreview\":false}".utf8))
        XCTAssertFalse(off.showPropertiesInPreview)
    }
}
