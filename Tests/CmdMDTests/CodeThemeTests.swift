import XCTest
@testable import CmdMD

/// The code theme a page links: the same bytes in the preview and in an
/// export, and the page theme's own palette when the theme isn't there.
final class CodeThemeTests: CheckoutLibrariesTestCase {
    /// Settings' named themes (the first, "github", is Auto: no stylesheet).
    private static let namedThemes = ["atom-one-dark", "atom-one-light", "monokai", "nord", "tokyo-night-dark"]

    private func render(_ theme: String, _ origin: PreviewLibraryOrigin) -> String {
        var options = MarkdownRenderOptions()
        options.libraries = origin
        options.preview.codeBlockTheme = theme
        return MarkdownRenderer().renderToHTML(markdown: "```swift\nlet x = 1\n```", options: options)
    }

    private func matches(_ pattern: String, in html: String, group: Int = 0) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: group)) }
    }

    /// The highlight.js stylesheet links: (href, integrity).
    private func themeLinks(_ html: String) -> [(href: String, integrity: String)] {
        let tags = matches(#"<link rel="stylesheet" href="[^"]*"[^>]*>"#, in: html)
        return tags.map { tag in
            (matches(#"href="([^"]*)""#, in: tag, group: 1).first ?? "", matches(#"integrity="([^"]*)""#, in: tag, group: 1).first ?? "")
        }
    }

    /// An export links what the preview shows: Highlightr's nord and
    /// monokai are highlight.js' base16 themes of those names, not the
    /// ones the export (and the preview before) linked.
    func testEachNamedThemeIsTheSameStylesheetInThePreviewAndTheExport() throws {
        for theme in Self.namedThemes {
            let preview = try XCTUnwrap(themeLinks(render(theme, .bundled)).first, theme)
            let export = try XCTUnwrap(themeLinks(render(theme, .cdn)).first, theme)
            XCTAssertTrue(preview.href.hasPrefix("cmdmd-lib://lib/") && preview.href.hasSuffix("/\(theme).min.css"), preview.href)
            XCTAssertTrue(export.href.hasSuffix("/styles/\(theme).min.css"), export.href)
            XCTAssertFalse(export.integrity.isEmpty, theme)
            XCTAssertEqual(preview.integrity, export.integrity, "\(theme): the preview's bytes are not the export's")
        }
    }

    func testTheExportPinsTheHighlightJSReleaseThePreviewRuns() throws {
        let bundled = try XCTUnwrap(PreviewLibrary.contents("\(PreviewLibrary.highlightrPrefix)/highlight.min.js"))
        let version = try XCTUnwrap(matches(#"Highlight\.js v(\d+\.\d+\.\d+)"#, in: String(bundled.prefix(300)), group: 1).first)
        let script = try XCTUnwrap(matches(#"<script defer src="([^"]*highlight\.min\.js)""#, in: render("github", .cdn), group: 1).first)
        XCTAssertEqual(script, "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@\(version)/highlight.min.js")
    }

    /// A name no build of the app offers (a hand-edited settings file): the
    /// block keeps its box and the page theme's token colors, in the
    /// preview and the export alike, and nothing unpinned is fetched.
    func testAThemeThatIsNotThereIsAuto() {
        let auto = render("github", .bundled)
        XCTAssertTrue(auto.contains(PreviewStyles.syntaxPalette))
        for theme in ["no-such-theme", "../katex/katex", "nord?x"] {
            for origin in [PreviewLibraryOrigin.bundled, .cdn] {
                let html = render(theme, origin)
                XCTAssertTrue(themeLinks(html).isEmpty, "\(theme) \(origin): \(themeLinks(html))")
                XCTAssertFalse(html.contains(PreviewStyles.namedCodeThemeBox), "\(theme) \(origin): the box is stripped")
                XCTAssertTrue(html.contains(PreviewStyles.syntaxPalette), "\(theme) \(origin): no token colors")
            }
        }
    }
}
