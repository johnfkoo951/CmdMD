import XCTest
import AppKit
@testable import CmdMD

/// Preview render timings over a folder of Markdown fixtures. Skipped unless
/// CMDMD_BENCH_DIR points at the folder; numbers only mean something in a
/// release build:
///
///     CMDMD_BENCH_DIR=/path/to/fixtures swift test -c release \
///         -Xswiftc -enable-testing --filter RenderBenchmarkTests
final class RenderBenchmarkTests: CheckoutLibrariesTestCase {
    func testRenderTimings() throws {
        guard let dir = ProcessInfo.processInfo.environment["CMDMD_BENCH_DIR"] else {
            throw XCTSkip("set CMDMD_BENCH_DIR to run the render benchmark")
        }
        let iterations = Int(ProcessInfo.processInfo.environment["CMDMD_BENCH_ITERATIONS"] ?? "") ?? 9
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".md") }
            .sorted()
        var options = MarkdownRenderOptions()
        options.theme = .cmds
        options.enableKaTeX = true
        let renderer = MarkdownRenderer()
        let folder = URL(fileURLWithPath: dir, isDirectory: true)

        print("BENCH file | bytes | render ms (median) | toc ms | html bytes")
        for file in files {
            let markdown = try Self.body(of: (dir as NSString).appendingPathComponent(file))
            var html = ""
            let renderMs = Self.median(iterations) {
                html = renderer.renderToHTML(markdown: markdown, baseURL: nil, options: options)
            }
            let tocMs = Self.median(iterations) {
                _ = TOCBuilder.extractHeadings(from: markdown, options: options)
            }
            print(String(format: "BENCH %@ | %d | %.2f | %.2f | %d",
                         file, markdown.utf8.count, renderMs, tocMs, html.utf8.count))

            // The editor's render: the preview gets an NSTextView's string
            // (NSString-backed UTF-16, not the native String read from disk)
            // and rewrites the note's local image sources.
            let textView = NSTextView()
            textView.string = markdown
            let editorText = textView.string
            var live = options
            live.localAssetRoots = [folder]
            let editorRenderMs = Self.median(iterations) {
                html = renderer.renderToHTML(markdown: editorText, baseURL: folder, options: live)
            }
            let editorTocMs = Self.median(iterations) {
                _ = TOCBuilder.extractHeadings(from: editorText, options: live)
            }
            print(String(format: "BENCH %@ [editor] | %d | %.2f | %.2f | %d",
                         file, markdown.utf8.count, editorRenderMs, editorTocMs, html.utf8.count))
        }

        // CMDMD_BENCH_OUT=<dir>: also write every fixture's page per theme
        // (<dir>/<theme>/<file>.html) for screenshots and WebView timings.
        if let out = ProcessInfo.processInfo.environment["CMDMD_BENCH_OUT"] {
            for theme in PreviewTheme.allCases {
                let themeDir = (out as NSString).appendingPathComponent(theme.rawValue.replacingOccurrences(of: " ", with: ""))
                try FileManager.default.createDirectory(atPath: themeDir, withIntermediateDirectories: true)
                var themed = options
                themed.theme = theme
                for file in files {
                    let markdown = try Self.body(of: (dir as NSString).appendingPathComponent(file))
                    let html = renderer.renderToHTML(markdown: markdown, baseURL: nil, options: themed)
                    try html.write(toFile: (themeDir as NSString).appendingPathComponent(file + ".html"), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// The note body the preview renders: the app hands the renderer the
    /// document without its frontmatter.
    private static func body(of path: String) throws -> String {
        FileService.parseFrontmatter(from: try String(contentsOfFile: path, encoding: .utf8)).body
    }

    private static func median(_ iterations: Int, _ body: () -> Void) -> Double {
        body() // warm-up
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }
}
