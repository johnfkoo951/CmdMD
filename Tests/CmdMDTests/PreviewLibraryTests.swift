import CryptoKit
import XCTest
import WebKit
@testable import CmdMD

/// A scheme task that records what the handler answers.
private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let done: XCTestExpectation
    private(set) var response: HTTPURLResponse?
    private(set) var data = Data()
    private(set) var error: Error?

    init(_ url: URL, done: XCTestExpectation) {
        request = URLRequest(url: url)
        self.done = done
    }

    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { done.fulfill() }
    func didFailWithError(_ error: Error) {
        self.error = error
        done.fulfill()
    }
}

private func sha384(_ data: Data) -> String {
    "sha384-" + Data(SHA384.hash(data: data)).base64EncodedString()
}

extension PreviewLibrary.Roots {
    /// What package_app.sh copies into the app: this checkout's PreviewLibs
    /// and the Highlightr bundle built beside the test bundle.
    static let checkout: PreviewLibrary.Roots = {
        let build = Bundle(for: CheckoutLibrariesTestCase.self).bundleURL.deletingLastPathComponent()
        var roots = PreviewLibrary.roots(resourceURL: build, bundleURL: build)
        roots.libraries = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CmdMDTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/PreviewLibs", isDirectory: true)
        return roots
    }()
}

/// Renders pages against the checkout's libraries. Only a debug build falls
/// back to the checkout by itself; this keeps a `-c release` run (the render
/// benchmark among them) linking the same files.
class CheckoutLibrariesTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        PreviewLibrary.installed = .checkout
    }
}

/// What `cmdmd-lib://lib/<path>` may serve: script, style and font files
/// inside the two library roots, nothing else.
final class PreviewLibraryPathTests: XCTestCase {
    private var root: URL!
    private var roots: PreviewLibrary.Roots!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMD-PreviewLibs-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let libraries = root.appendingPathComponent("PreviewLibs", isDirectory: true)
        let highlightr = root.appendingPathComponent("Highlightr", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        for dir in ["katex/fonts", "dir.js"].map(libraries.appendingPathComponent) + [highlightr, outside] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for file in ["katex/katex.min.js", "katex/katex.min.css", "katex/fonts/KaTeX_Main-Regular.woff2",
                     "katex/LICENSE", "LICENSES.md", "katex/fonts/KaTeX_Main-Regular.woff", ".hidden.js"] {
            try Data(file.utf8).write(to: libraries.appendingPathComponent(file))
        }
        try Data("hljs".utf8).write(to: highlightr.appendingPathComponent("highlight.min.js"))
        try Data("theme".utf8).write(to: highlightr.appendingPathComponent("qtcreator_dark.min.css"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.js"))
        try fm.createSymbolicLink(at: libraries.appendingPathComponent("escape.js"),
                                  withDestinationURL: outside.appendingPathComponent("secret.js"))
        try fm.createSymbolicLink(at: libraries.appendingPathComponent("alias.js"),
                                  withDestinationURL: libraries.appendingPathComponent("katex/katex.min.js"))
        roots = PreviewLibrary.Roots(libraries: libraries, highlightr: highlightr)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func served(_ url: String) -> String? {
        guard let url = URL(string: url),
              let file = PreviewLibrary.fileURL(for: url, roots: roots) else { return nil }
        return String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
    }

    func testServesLibraryFilesFromBothRoots() {
        XCTAssertEqual(served("cmdmd-lib://lib/katex/katex.min.js"), "katex/katex.min.js")
        XCTAssertEqual(served("cmdmd-lib://lib/katex/katex.min.css"), "katex/katex.min.css")
        XCTAssertEqual(served("cmdmd-lib://lib/katex/fonts/KaTeX_Main-Regular.woff2"), "katex/fonts/KaTeX_Main-Regular.woff2")
        XCTAssertEqual(served("cmdmd-lib://lib/highlightr/highlight.min.js"), "hljs")
        XCTAssertEqual(served("cmdmd-lib://lib/highlightr/qtcreator_dark.min.css"), "theme")
        XCTAssertEqual(served("cmdmd-lib://lib/alias.js"), "katex/katex.min.js", "a link that stays inside its root")
    }

    func testOnlyScriptStyleAndFontFiles() {
        for path in ["LICENSES.md", "katex/LICENSE", "katex/fonts/KaTeX_Main-Regular.woff", "dir.js", "katex/katex.min.JS"] {
            XCTAssertNil(served("cmdmd-lib://lib/\(path)"), path)
        }
    }

    func testTraversalAndEncodedPathsAreRejected() {
        for path in ["../outside/secret.js", "katex/../../outside/secret.js", "katex/./katex.min.js",
                     "%2e%2e/outside/secret.js", "katex%2fkatex.min.js", "katex/katex%2Emin.js",
                     "katex//katex.min.js", "/katex/katex.min.js", "\(root.path)/outside/secret.js",
                     "katex\\katex.min.js", ".hidden.js", "highlightr/", "highlightr/../outside/secret.js",
                     "escape.js"] {
            XCTAssertNil(served("cmdmd-lib://lib/\(path)"), path)
            XCTAssertNil(PreviewLibrary.fileURL(forPath: path, roots: roots), path)
        }
    }

    func testOnlyTheLibraryHostWithAPlainPath() {
        for url in ["cmdmd-lib://lib/katex/katex.min.js?v=1", "cmdmd-lib://lib/katex/katex.min.js?",
                    "cmdmd-lib://lib/katex/katex.min.js#x", "cmdmd-lib://LIB/katex/katex.min.js",
                    "cmdmd-lib://other/katex/katex.min.js", "cmdmd-lib://lib:80/katex/katex.min.js",
                    "cmdmd-lib://me@lib/katex/katex.min.js", "cmdmd-lib:///katex/katex.min.js",
                    "cmdmd-lib:katex/katex.min.js", "cmdmd-asset://lib/katex/katex.min.js",
                    "file://\(root.path)/PreviewLibs/katex/katex.min.js"] {
            XCTAssertNil(served(url), url)
        }
    }

    func testMissingRootServesNothing() {
        let bare = PreviewLibrary.Roots(libraries: nil, highlightr: nil)
        XCTAssertNil(PreviewLibrary.fileURL(forPath: "katex/katex.min.js", roots: bare))
        XCTAssertNil(PreviewLibrary.fileURL(forPath: "highlightr/highlight.min.js", roots: bare))
    }

    func testHandlerServesWithCORSAndCachingHeaders() throws {
        let handler = PreviewLibrarySchemeHandler(roots: roots)
        let webView = WKWebView(frame: .zero)
        let url = try XCTUnwrap(URL(string: "cmdmd-lib://lib/katex/katex.min.css"))
        let task = RecordingSchemeTask(url, done: expectation(description: "served"))
        handler.webView(webView, start: task)
        waitForExpectations(timeout: 5)

        let response = try XCTUnwrap(task.response)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/css; charset=utf-8")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertTrue(response.value(forHTTPHeaderField: "Cache-Control")?.contains("immutable") ?? false)
        XCTAssertEqual(String(decoding: task.data, as: UTF8.self), "katex/katex.min.css")
    }

    func testHandlerFailsRejectedRequests() throws {
        let handler = PreviewLibrarySchemeHandler(roots: roots)
        let task = RecordingSchemeTask(try XCTUnwrap(URL(string: "cmdmd-lib://lib/escape.js")),
                                       done: expectation(description: "failed"))
        handler.webView(WKWebView(frame: .zero), start: task)
        waitForExpectations(timeout: 5)
        XCTAssertNotNil(task.error)
        XCTAssertNil(task.response)
        XCTAssertTrue(task.data.isEmpty)
    }
}

/// Where the libraries are found: the packaged app's Contents/Resources,
/// then, in a debug build only, this checkout (swift run, swift test, a dev
/// bundle). Run with `-c release` too: a release build never looks outside.
final class PreviewLibraryLookupTests: XCTestCase {
    private static let checkout = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CmdMDTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()

    func testPackagedAppLooksInContentsResourcesFirst() {
        let resources = URL(fileURLWithPath: "/Applications/CmdMD.app/Contents/Resources", isDirectory: true)
        var expected = [resources.appendingPathComponent("PreviewLibs").path]
        #if DEBUG
        expected.append(Self.checkout.appendingPathComponent("Resources/PreviewLibs").path)
        #endif
        XCTAssertEqual(PreviewLibrary.librariesCandidates(resourceURL: resources).map(\.path), expected)
    }

    func testHighlightrIsLookedUpWhereTheEditorFindsIt() {
        let app = URL(fileURLWithPath: "/Applications/CmdMD.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources")
        let editor = SyntaxHighlighter.highlightrBundleCandidates(resourceURL: resources, bundleURL: app)
        let preview = PreviewLibrary.highlightrCandidates(resourceURL: resources, bundleURL: app)
        XCTAssertEqual(Array(preview.prefix(editor.count)), editor)
        #if DEBUG
        let checkoutBuilds = ["debug", "release"].map {
            Self.checkout.appendingPathComponent(".build/\($0)/Highlightr_Highlightr.bundle").path
        }
        #else
        let checkoutBuilds: [String] = []
        #endif
        XCTAssertEqual(preview.dropFirst(editor.count).map(\.path), checkoutBuilds)
    }

    func testPackagedLayoutResolvesIntoTheBundlesResources() throws {
        // package_app.sh's layout: the Xcode build system's Highlightr bundle
        // keeps its files in Contents/Resources.
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMD-Lookup-\(UUID().uuidString)/CmdMD.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let bundleResources = resources.appendingPathComponent("Highlightr_Highlightr.bundle/Contents/Resources")
        let katex = resources.appendingPathComponent("PreviewLibs/katex")
        for dir in [bundleResources, katex] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("hljs".utf8).write(to: bundleResources.appendingPathComponent("highlight.min.js"))
        try Data("katex".utf8).write(to: katex.appendingPathComponent("katex.min.js"))

        let roots = PreviewLibrary.roots(resourceURL: resources, bundleURL: app)
        XCTAssertEqual(roots.libraries?.standardizedFileURL.path,
                       resources.appendingPathComponent("PreviewLibs").standardizedFileURL.path)
        XCTAssertEqual(PreviewLibrary.fileURL(forPath: "highlightr/highlight.min.js", roots: roots)?.lastPathComponent,
                       "highlight.min.js")
        XCTAssertNotNil(PreviewLibrary.fileURL(forPath: "katex/katex.min.js", roots: roots))
    }

    func testOnlyADebugTestRunnerFindsTheCheckoutsLibraries() throws {
        // The runner's main bundle is xctest, so the checkout is all there is.
        let roots = PreviewLibrary.roots(resourceURL: Bundle.main.resourceURL, bundleURL: Bundle.main.bundleURL)
        #if DEBUG
        XCTAssertEqual(roots.libraries?.standardizedFileURL.path,
                       Self.checkout.appendingPathComponent("Resources/PreviewLibs").standardizedFileURL.path)
        XCTAssertNotNil(PreviewLibrary.fileURL(forPath: "highlightr/highlight.min.js", roots: roots),
                        "Highlightr's bundle from the checkout's build folder")
        #else
        XCTAssertNil(roots.libraries)
        XCTAssertNil(roots.highlightr)
        #endif
    }

    func testSettingTheRootsDropsHashesOfTheOldFiles() throws {
        let saved = PreviewLibrary.installed
        defer { PreviewLibrary.installed = saved }
        let dirs = try (0..<2).map { index -> URL in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CmdMD-Roots-\(UUID().uuidString)/katex", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("katex \(index)".utf8).write(to: dir.appendingPathComponent("katex.min.js"))
            return dir.deletingLastPathComponent()
        }
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

        let hashes = dirs.map { dir -> String? in
            PreviewLibrary.installed = PreviewLibrary.Roots(libraries: dir, highlightr: nil)
            return PreviewLibrary.resource("katex/katex.min.js")?.integrity
        }
        XCTAssertEqual(hashes, ["katex 0", "katex 1"].map { PreviewLibrary.integrity(of: Data($0.utf8)) })
    }
}

/// Resources/PreviewLibs holds everything a bundled page can link, and only that.
final class PreviewLibsContentTests: XCTestCase {
    private static let libraries = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CmdMDTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/PreviewLibs", isDirectory: true)

    func testKaTeXShipsEveryFontItsCSSNamesAsWOFF2Only() throws {
        let katex = Self.libraries.appendingPathComponent("katex")
        let css = try String(contentsOf: katex.appendingPathComponent("katex.min.css"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"url\((fonts/[^)]+\.woff2)\)"#)
        let named = Set(regex.matches(in: css, range: NSRange(css.startIndex..., in: css)).compactMap {
            Range($0.range(at: 1), in: css).map { String(css[$0]) }
        })
        XCTAssertEqual(named.count, 20)
        let shipped = try FileManager.default.contentsOfDirectory(atPath: katex.appendingPathComponent("fonts").path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(shipped.map { "fonts/" + $0 }), named, "woff2 only, every one the CSS names")
        for file in ["katex.min.js", "contrib/mhchem.min.js", "contrib/auto-render.min.js", "LICENSE"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: katex.appendingPathComponent(file).path), file)
        }
    }

    func testCmdsPeleIsTheCopyItsStampDescribes() throws {
        // pele-sync.py writes the stamp with the files: a hand edit or a half
        // sync shows up as a hash mismatch.
        let folder = Self.libraries.appendingPathComponent("cmds-pele")
        let stamp = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("cmds-pele.version.json"))
        ) as? [String: Any])
        let hashes = try XCTUnwrap(stamp["files"] as? [String: String])
        for file in ["pele.global.js", "cmds-pele.js", "cmds-pele.css", "LICENSE-pele.txt"] {
            let data = try Data(contentsOf: folder.appendingPathComponent(file))
            let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hashes[file], sha256, file)
        }
        XCTAssertNotNil(stamp["pele"] as? String)
    }

    func testLicensesCoverEveryLibrary() throws {
        let licenses = try String(contentsOf: Self.libraries.appendingPathComponent("LICENSES.md"), encoding: .utf8)
        for needle in ["KaTeX", "0.16.47", "MIT", "Pele", "highlight.js", "BSD-3-Clause",
                       "https://github.com/KaTeX/KaTeX", "https://github.com/obsidianmd/pele",
                       "https://github.com/highlightjs/highlight.js", "Copyright (c) 2006, Ivan Sagalaev."] {
            XCTAssertTrue(licenses.contains(needle), needle)
        }
    }
}

/// Pages the preview and PDF export render link only the app's own copies,
/// pinned by hashes of the bytes the handler serves; exports keep the CDN.
final class BundledLibraryPageTests: CheckoutLibrariesTestCase {
    private let mixed = "```swift\nlet x = 1\n```\n\n$e^{i\\pi} + 1 = 0$ and $\\ce{H2O}$"

    private func render(_ markdown: String, configure: (inout MarkdownRenderOptions) -> Void = { _ in }) -> String {
        var options = MarkdownRenderOptions()
        options.enableKaTeX = true
        configure(&options)
        return MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
    }

    private func matches(_ pattern: String, in html: String, group: Int = 0) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: group)) }
    }

    private func directive(_ name: String, in html: String) -> String {
        let policy = matches(#"<meta http-equiv="Content-Security-Policy" content="([^"]*)""#, in: html, group: 1).first ?? ""
        return policy.components(separatedBy: "; ").first { $0.hasPrefix(name + " ") } ?? ""
    }

    /// Every external script and stylesheet tag. An inline script's text is
    /// text, not tags (an exported page inlines cmds-pele's bootstrap, whose
    /// comments show a `<script src=…>` example).
    private func libraryTags(in html: String) -> [String] {
        let tags = html.replacingOccurrences(of: #"(<script\b[^>]*>)[\s\S]*?</script>"#, with: "$1</script>", options: .regularExpression)
        return matches(#"<script\b[^>]*\bsrc="[^"]*"[^>]*>|<link\b[^>]*\bhref="[^"]*"[^>]*>"#, in: tags)
    }

    private func url(in tag: String) -> String {
        matches(#"(?:src|href)="([^"]*)""#, in: tag, group: 1).first ?? ""
    }

    private func integrity(in tag: String) -> String? {
        matches(#"integrity="([^"]*)""#, in: tag, group: 1).first
    }

    /// What the scheme handler sends for `url`.
    private func servedBytes(_ url: String) throws -> Data {
        let handler = PreviewLibrarySchemeHandler()
        let task = RecordingSchemeTask(try XCTUnwrap(URL(string: url)), done: expectation(description: url))
        handler.webView(WKWebView(frame: .zero), start: task)
        waitForExpectations(timeout: 5)
        XCTAssertNil(task.error, url)
        return task.data
    }

    func testBundledPageLinksNoNetworkScriptStyleOrFont() {
        let html = render(mixed)
        let tags = libraryTags(in: html)
        // hljs light + dark theme, hljs, KaTeX CSS + 3 scripts.
        XCTAssertEqual(tags.count, 5, tags.joined(separator: "\n"))
        for tag in tags {
            XCTAssertTrue(url(in: tag).hasPrefix("cmdmd-lib://lib/"), tag)
        }
        for name in ["script-src", "style-src", "font-src"] {
            XCTAssertFalse(directive(name, in: html).contains("https:"), name)
            XCTAssertFalse(directive(name, in: html).contains("http:"), name)
        }
        XCTAssertEqual(directive("style-src", in: html), "style-src 'unsafe-inline' cmdmd-lib://lib")
        XCTAssertEqual(directive("font-src", in: html), "font-src cmdmd-lib://lib data:")
    }

    func testScriptSourceIsTheExactBundledFiles() {
        let html = render(mixed)
        let scriptURLs = matches(#"<script\b[^>]*\bsrc="([^"]*)""#, in: html, group: 1)
        XCTAssertEqual(scriptURLs.count, 4)
        let sources = directive("script-src", in: html).components(separatedBy: " ").dropFirst()
        XCTAssertTrue(sources.first?.hasPrefix("'nonce-") ?? false)
        XCTAssertEqual(Set(sources.dropFirst()), Set(scriptURLs))
        for source in sources.dropFirst() {
            XCTAssertTrue(source.hasPrefix("cmdmd-lib://lib/") && source.hasSuffix(".js"), "a whole scheme or host: \(source)")
        }
    }

    func testIntegrityIsTheHashOfTheServedBytes() throws {
        let html = render(mixed, configure: { $0.preview.codeBlockTheme = "nord" })
        let tags = libraryTags(in: html)
        XCTAssertEqual(tags.count, 6)
        for tag in tags {
            XCTAssertTrue(tag.contains("crossorigin=\"anonymous\""), tag)
            let bytes = try servedBytes(url(in: tag))
            XCTAssertFalse(bytes.isEmpty, tag)
            XCTAssertEqual(integrity(in: tag), sha384(bytes), tag)
        }
    }

    func testBundledKaTeXIsThePinnedRelease() {
        // Same bytes as the CDN's katex@0.16.47 (whose hashes are pinned).
        func katexHashes(_ origin: PreviewLibraryOrigin) -> [String: String] {
            let tags = libraryTags(in: render("$x$", configure: { $0.libraries = origin }))
            return Dictionary(uniqueKeysWithValues: tags.map {
                ((url(in: $0) as NSString).lastPathComponent, integrity(in: $0) ?? "")
            })
        }
        let bundled = katexHashes(.bundled)
        XCTAssertEqual(bundled.count, 4)
        XCTAssertEqual(bundled, katexHashes(.cdn))
    }

    /// The default code theme is the page theme's own palette (no
    /// stylesheet); a named one links the editor's bundled copy, except
    /// nord and monokai, which Highlightr has only as their base16 themes.
    func testHighlightJSIsDeferredAndNamedThemesComeFromHighlightr() {
        let html = render("```js\nx\n```")
        let script = matches(#"<script\b[^>]*highlight\.min\.js[^>]*>"#, in: html).first ?? ""
        XCTAssertTrue(script.contains(" defer"), script)
        XCTAssertEqual(matches(#"<link\b[^>]*highlightr/"#, in: html).count, 0)
        let atom = render("```js\nx\n```", configure: { $0.preview.codeBlockTheme = "atom-one-dark" })
        XCTAssertTrue(atom.contains("href=\"cmdmd-lib://lib/highlightr/atom-one-dark.min.css\""))
        let nord = render("```js\nx\n```", configure: { $0.preview.codeBlockTheme = "nord" })
        XCTAssertTrue(nord.contains("href=\"cmdmd-lib://lib/highlight-themes/nord.min.css\""))
    }

    func testUnknownOrEscapingThemeLinksNoStylesheet() {
        for theme in ["no-such-theme", "../katex/katex", "nord?x"] {
            let html = render("```js\nx\n```", configure: { $0.preview.codeBlockTheme = theme })
            XCTAssertEqual(matches(#"<link\b"#, in: html).count, 0, theme)
            XCTAssertTrue(html.contains("cmdmd-lib://lib/highlightr/highlight.min.js"), theme)
        }
    }

    func testCustomCSSFromTheWebKeepsHTTPSForStylesAndFonts() {
        let html = render("text", configure: {
            $0.preview.customCSS = "@import url('https://fonts.example.com/css2?family=Pretendard');"
        })
        XCTAssertEqual(directive("style-src", in: html), "style-src 'unsafe-inline' cmdmd-lib://lib https:")
        XCTAssertEqual(directive("font-src", in: html), "font-src cmdmd-lib://lib https: data:")
    }

    func testHTMLExportLinksTheCDNEvenFromPreviewOptions() {
        let document = MarkdownDocument(
            content: mixed + "\n\n```mermaid\ngraph TD; A-->B\n```",
            fileURL: URL(fileURLWithPath: "/tmp/notes/n.md")
        )
        var options = MarkdownRenderOptions()
        options.enableKaTeX = true
        XCTAssertEqual(options.libraries, .bundled, "the preview's default")
        let html = ExportService().exportToHTML(document: document, options: options)
        XCTAssertFalse(html.contains("cmdmd-lib"))
        let tags = libraryTags(in: html)
        // Pele isn't a tag: it loads after first paint (see PeleDiagramTests).
        XCTAssertEqual(tags.count, 5)
        for tag in tags {
            XCTAssertTrue(url(in: tag).hasPrefix("https://cdn.jsdelivr.net/npm/"), tag)
        }
        XCTAssertTrue(directive("script-src", in: html).contains(" https://cdn.jsdelivr.net/npm/pele@"))
        XCTAssertEqual(directive("style-src", in: html), "style-src 'unsafe-inline' https:")
    }

    func testPDFExportViewServesTheBundledLibraries() {
        let webView = PDFExporter.makeWebView(assetRoots: [])
        XCTAssertTrue(webView.configuration.urlSchemeHandler(forURLScheme: PreviewLibrary.scheme) is PreviewLibrarySchemeHandler)
    }
}
