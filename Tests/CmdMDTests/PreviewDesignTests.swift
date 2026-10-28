import WebKit
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
        for theme in PreviewTheme.allCases {
            for (name, segment) in Self.appearances(of: theme) {
                guard let comment = Self.hex("hl-comment", in: segment), let background = Self.hex("code-bg", in: segment) else {
                    XCTFail("\(theme) \(name): no hex --hl-comment / --code-bg"); continue
                }
                let ratio = Self.contrast(comment, background)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme) \(name) comment contrast \(String(format: "%.2f", ratio))")
            }
        }
    }

    /// Diagrams are drawn as in the main vault: the page fills the roles
    /// Obsidian gives the vault theme, and the palette is cmds-pele's own.
    func testEveryThemeFeedsPeleDiagrams() {
        XCTAssertFalse(render("x").contains("--cp-bg"), "diagram tokens ship on diagram pages only")
        for theme in PreviewTheme.allCases {
            let html = render("```mermaid\ngraph TD; A-->B\n```", configure: { $0.theme = theme })
            for token in ["--cp-bg:var(--bg-primary)", "--cp-fg:var(--text-primary)", "--cp-muted:var(--text-secondary)",
                          "--cp-line:var(--text-primary)", "--cp-surface:var(--bg-secondary)", "--cp-surface-alt:var(--bg-secondary)",
                          "--cp-border:var(--border-color)", "--cp-font:var(--font-body)", "--cp-font-mono:var(--font-mono)"] {
                XCTAssertTrue(html.contains(token), "\(theme): \(token)")
            }
        }
    }

    /// The vault palette now draws on every theme's page, and Pele paints
    /// some labels in the page color on series fills (pie slices, timeline
    /// headers): cmds-pele's rule is 4.5:1 for each series color against the
    /// background. Sepia's cream is the one page that dips below it, to 4.37
    /// for the vault's green #2f7a62; the palette stays the vault's.
    func testVaultDiagramPaletteHoldsOnEveryThemeBackground() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let css = try String(contentsOf: root.appendingPathComponent("Resources/PreviewLibs/cmds-pele/cmds-pele.css"), encoding: .utf8)
        let blocks = css.components(separatedBy: "}")
        func series(_ block: String?) -> [(Double, Double, Double)] {
            guard let block else { return [] }
            return (1...8).compactMap { Self.hex("cpd-series-\($0)", in: Substring(block)) }
        }
        let light = series(blocks.first { $0.contains(".cmds-pele{--cpd-") })
        let dark = series(blocks.first { $0.contains(".cmds-pele[data-cp-theme=\"dark\"]") && $0.contains("--cpd-series-1:") })
        XCTAssertEqual(light.count, 8)
        XCTAssertEqual(dark.count, 8)
        for theme in PreviewTheme.allCases {
            for (name, segment) in Self.appearances(of: theme) {
                guard let background = Self.hex("bg-primary", in: segment) else {
                    XCTFail("\(theme) \(name): no hex --bg-primary"); continue
                }
                let floor = theme == .sepia && name == "light" ? 4.3 : 4.5
                for color in name == "dark" ? dark : light {
                    let ratio = Self.contrast(color, background)
                    XCTAssertGreaterThanOrEqual(ratio, floor, "\(theme) \(name) series contrast \(String(format: "%.2f", ratio))")
                }
            }
        }
    }

    /// The theme's light tokens, then the whole sheet (whose last value wins)
    /// for dark. Shared semantic tokens come first; the theme's own win.
    private static func appearances(of theme: PreviewTheme) -> [(String, Substring)] {
        let css = PreviewStyles.base + theme.css
        let parts = css.components(separatedBy: "prefers-color-scheme")
        return theme == .darkPro ? [("dark", Substring(css))] : [("light", Substring(parts[0])), ("dark", Substring(css))]
    }

    private static func hex(_ name: String, in css: Substring) -> (Double, Double, Double)? {
        guard let range = css.range(of: "--\(name):#", options: .backwards) else { return nil }
        let digits = css[range.upperBound...].prefix(6)
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return (Double(value >> 16 & 0xff) / 255, Double(value >> 8 & 0xff) / 255, Double(value & 0xff) / 255)
    }

    private static func contrast(_ x: (Double, Double, Double), _ y: (Double, Double, Double)) -> Double {
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func f(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(c.0) + 0.7152 * f(c.1) + 0.0722 * f(c.2)
        }
        let (a, b) = (luminance(x), luminance(y))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: Final markup is styled

    func testStylesTargetTheRenderedMarkup() {
        let html = render("- [ ] task\n\n| a |\n|:-:|\n| 1 |")
        XCTAssertTrue(html.contains("<li class=\"task-list-item\"><p><input"))
        XCTAssertTrue(html.contains(".task-list-item > p > input[type=\"checkbox\"]:first-child"))
        XCTAssertTrue(html.contains("<div class=\"table-scroll\"><table>"))
        XCTAssertTrue(html.contains(".table-scroll{overflow-x:auto"))
    }

    /// The box hangs in the bullet's gutter, so a task's first line, its
    /// wrapped lines and a plain item's text all start at one x. A space
    /// after the box pushed the first line about 4 px right of the rest.
    func testWrappedTaskTextLinesUpInWebKit() throws {
        let long = String(repeating: "업체 등록 신청의 정식 명칭은 입찰참가자격등록신청입니다. ", count: 6)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }
        webView.loadHTMLString(render("- [ ] \(long)\n- plain"), baseURL: nil)

        var lefts: [Double]?
        let measured = expectation(description: "laid out")
        func ask() {
            webView.callAsyncJavaScript("""
                const item = document.querySelector('li.task-list-item > p');
                const plain = document.querySelector('li:not(.task-list-item)');
                if (!item || !plain || document.readyState !== 'complete') return null;
                await document.fonts.ready;
                // From the first letter: a range from the box would start
                // at the space and line up even when the letters don't.
                const first = item.querySelector('input').nextSibling;
                const text = document.createRange();
                text.setStart(first, first.textContent.search(/\\S/));
                text.setEnd(item, item.childNodes.length);
                const other = document.createRange();
                other.selectNodeContents(plain);
                return [other.getClientRects()[0].left].concat(Array.from(text.getClientRects(), r => r.left));
                """, arguments: [:], in: nil, in: .page) { value in
                if case .success(let array as [Double]) = value {
                    lefts = array
                    measured.fulfill()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: ask)
                }
            }
        }
        ask()
        let outcome = XCTWaiter.wait(for: [measured], timeout: 10)
        try XCTSkipUnless(outcome == .completed, "the page did not load in this environment")
        let values = try XCTUnwrap(lefts)
        XCTAssertGreaterThan(values.count, 2, "the task should wrap: \(values)")
        for left in values { XCTAssertEqual(left, values[0], accuracy: 0.5, "\(values)") }
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
