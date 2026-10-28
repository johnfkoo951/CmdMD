import XCTest
@testable import CmdMD

/// Token-driven preview styles: settings only override what the user tuned,
/// every theme's tokens stay in sync with the native background, and the
/// stylesheet targets the renderer's final markup.
final class PreviewDesignTests: XCTestCase {
    private func render(_ markdown: String, configure: (inout MarkdownRenderOptions) -> Void = { _ in }) -> String {
        var options = MarkdownRenderOptions()
        configure(&options)
        return MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
    }

    // MARK: Settings no longer mask the theme

    func testDefaultSettingsEmitNoTypographyOverride() {
        let html = render("x", configure: { $0.theme = .sepia })
        XCTAssertFalse(html.contains("html:root {"), "default settings flattened every theme's typography")
        XCTAssertFalse(html.contains("max-width: 800px"))
        XCTAssertTrue(html.contains("'Iowan Old Style'"))
        XCTAssertTrue(html.contains("--fs:18px"))
    }

    func testTunedSettingsStillWin() {
        let html = render("x", configure: {
            $0.theme = .sepia; $0.preview.fontSize = 15; $0.preview.headingScale = 1.2
            $0.preview.lineHeight = 1.9; $0.preview.fontFamily = "Georgia, serif"
        })
        XCTAssertTrue(html.contains("--fs: 15px;"))
        XCTAssertTrue(html.contains("--hs: 1.200;"))
        XCTAssertTrue(html.contains("--lh: 1.90; --lh-ko: 1.90;"), "a tuned line height holds on Korean pages too")
        XCTAssertTrue(html.contains("--font-body: Georgia, serif;"))
        // Tuned values come after (and outrank) the theme's `:root` tokens.
        let themeAt = html.range(of: "--fs:18px")!.lowerBound
        XCTAssertLessThan(themeAt, html.range(of: "html:root {")!.lowerBound)
    }

    // MARK: Themes

    func testDarkProIsDarkInEveryAppearance() {
        let css = PreviewTheme.darkPro.css
        XCTAssertTrue(css.contains("color-scheme:dark"))
        XCTAssertFalse(css.contains("prefers-color-scheme"), "Dark Pro's components must not flip to light tokens")
    }

    /// PreviewView paints the web view's native background before the page
    /// loads; a drift from the theme's --bg-primary flashes on every load.
    func testEveryThemeBackgroundMatchesItsToken() {
        for theme in PreviewTheme.allCases {
            for dark in [false, true] {
                let hex = NSColor(theme.backgroundColor(forDark: dark)).usingColorSpace(.sRGB)!
                let token = String(format: "#%02x%02x%02x", Int(round(hex.redComponent * 255)), Int(round(hex.greenComponent * 255)), Int(round(hex.blueComponent * 255)))
                XCTAssertTrue(theme.css.contains("--bg-primary:\(token)"), "\(theme) \(dark ? "dark" : "light") --bg-primary drifted from backgroundColor(forDark:) \(token)")
            }
        }
    }

    /// Code comments are text: WCAG AA (4.5:1) on the code block background,
    /// in every theme and appearance (the first token palette fell to 2.8:1).
    func testCodeCommentsMeetAAOnTheCodeBackground() {
        func hex(_ name: String, in css: Substring) -> (Double, Double, Double)? {
            guard let range = css.range(of: "--\(name):#", options: .backwards) else { return nil }
            let digits = css[range.upperBound...].prefix(6)
            guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
            return (Double(value >> 16 & 0xff) / 255, Double(value >> 8 & 0xff) / 255, Double(value & 0xff) / 255)
        }
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func f(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(c.0) + 0.7152 * f(c.1) + 0.0722 * f(c.2)
        }
        for theme in PreviewTheme.allCases {
            // Shared semantic tokens first, then the theme's own (which win).
            let css = PreviewStyles.base + theme.css
            let parts = css.components(separatedBy: "prefers-color-scheme")
            let appearances = theme == .darkPro ? [("dark", Substring(css))] : [("light", Substring(parts[0])), ("dark", Substring(css))]
            for (name, segment) in appearances {
                guard let comment = hex("hl-comment", in: segment), let background = hex("code-bg", in: segment) else {
                    XCTFail("\(theme) \(name): no hex --hl-comment / --code-bg"); continue
                }
                let (a, b) = (luminance(comment), luminance(background))
                let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme) \(name) comment contrast \(String(format: "%.2f", ratio))")
            }
        }
    }

    func testEveryThemeFeedsPeleDiagrams() {
        XCTAssertFalse(render("x").contains("--cp-bg"), "diagram tokens ship on diagram pages only")
        let html = render("```mermaid\ngraph TD; A-->B\n```")
        for token in ["--cp-bg", "--cp-fg", "--cp-muted", "--cp-line", "--cp-surface", "--cp-surface-alt", "--cp-border", "--cp-accent", "--cp-font", "--cp-font-mono"] {
            XCTAssertTrue(html.contains("\(token):"), token)
        }
    }

    // MARK: Final markup is styled

    func testStylesTargetTheRenderedMarkup() {
        let html = render("- [ ] task\n\n| a |\n|:-:|\n| 1 |")
        XCTAssertTrue(html.contains("<li class=\"task-list-item\"><p><input"))
        XCTAssertTrue(html.contains(".task-list-item > p > input[type=\"checkbox\"]:first-child"))
        XCTAssertTrue(html.contains("<div class=\"table-scroll\"><table>"))
        XCTAssertTrue(html.contains(".table-scroll{overflow-x:auto"))
    }

    func testDefaultCodePaletteNeedsNoStylesheetFetch() {
        let html = render("```swift\nlet x = 1\n```")
        XCTAssertFalse(html.contains("/styles/github"))
        XCTAssertTrue(html.contains(".hljs-keyword"))
        let named = render("```swift\nlet x = 1\n```", configure: { $0.preview.codeBlockTheme = "monokai" })
        XCTAssertTrue(named.contains("monokai"))
        XCTAssertTrue(named.contains("pre:has(> code.hljs)"), "a named theme's block is the one box")
    }

    func testCalloutCSSOnlyForTypesOnThePage() {
        let html = render("> [!warning] Careful\n> body")
        XCTAssertTrue(html.contains(".callout-warning{--c:var(--c-orange)"))
        XCTAssertFalse(html.contains(".callout-bug{"))
        XCTAssertFalse(render("plain").contains(".callout{"))
    }
}
