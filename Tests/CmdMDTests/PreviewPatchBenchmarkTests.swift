import AppKit
import WebKit
import XCTest
@testable import CmdMD

/// A typing pause's page update, patch against reload, in one web view:
/// each step types a character in the middle of the note and puts the new
/// page up, alternating a patch (`cmdmdPreview.patch`, then layout) with a
/// full load at the offset on screen (to didFinish, the diagrams and
/// layout: what the preview's debounce measures). Only interleaved
/// numbers of one run compare.
///
/// Skipped unless CMDMD_HOSTED_BENCH=1, with CMDMD_BENCH_DIR naming the
/// fixtures (CMDMD_BENCH_PATCH: which, comma-separated); meaningful in a
/// release build:
///
///     CMDMD_HOSTED_BENCH=1 CMDMD_BENCH_DIR=/path/to/fixtures swift test -c release \
///         -Xswiftc -enable-testing --filter PreviewPatchBenchmarkTests
final class PreviewPatchBenchmarkTests: CheckoutLibrariesTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        guard env["CMDMD_HOSTED_BENCH"] == "1", let dir = env["CMDMD_BENCH_DIR"] else {
            throw XCTSkip("set CMDMD_HOSTED_BENCH=1 and CMDMD_BENCH_DIR to run the patch benchmark")
        }
        self.dir = dir
        _ = NSApplication.shared
    }

    private final class Loads: NSObject, WKNavigationDelegate {
        var finished = 0
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.0005)) }
    }

    /// Runs `body` and returns its value with the round trip in ms.
    private func call(_ body: String, _ arguments: [String: Any] = [:], in webView: WKWebView) -> (Any?, Double) {
        var value: Any?
        var done = false
        let start = DispatchTime.now().uptimeNanoseconds
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .success(let answer) = result { value = answer }
            done = true
        }
        spin(until: { done })
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func p90(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    }

    func testPatchAgainstReload() throws {
        let names = (ProcessInfo.processInfo.environment["CMDMD_BENCH_PATCH"] ?? "medium-mixed.md,large-mixed.md,math-mermaid.md,korean-prose.md")
            .split(separator: ",").map(String.init)
        var options = MarkdownRenderOptions()
        options.enableKaTeX = true
        let renderer = MarkdownRenderer()

        for name in names {
            let raw = try String(contentsOfFile: (dir as NSString).appendingPathComponent(name), encoding: .utf8)
            var source = FileService.parseFrontmatter(from: raw).body
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(PreviewLibrarySchemeHandler(), forURLScheme: PreviewLibrary.scheme)
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 800), configuration: config)
            let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            let loads = Loads()
            webView.navigationDelegate = loads

            func page(_ text: String) -> PreviewPage {
                PreviewPage(rendered: renderer.renderPage(markdown: text, options: options), source: text,
                            baseURL: nil, options: options, generation: 0, renderMs: nil)
            }
            func load(_ page: PreviewPage, at offset: Double) -> Double {
                let before = loads.finished
                let start = DispatchTime.now().uptimeNanoseconds
                let html = offset > 0
                    ? MarkdownRenderer.insertingHeadScript("addEventListener('DOMContentLoaded',function(){window.scrollTo(0,\(offset));});", into: page.html)
                    : page.html
                webView.loadHTMLString(html, baseURL: nil)
                spin(until: { loads.finished > before })
                _ = call("await window.cmdmdDiagrams; document.body.offsetHeight; return true;", in: webView)
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }

            var shown = page(source)
            _ = load(shown, at: 0)
            _ = call("window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) / 2); return true;", in: webView)
            var patchMs: [Double] = [], reloadMs: [Double] = [], editMs: [Double] = [], replaced: [Int] = []
            // Typing at the end of the middle line.
            let ns = source as NSString
            var caret = ns.range(of: "\n", range: NSRange(location: ns.length / 2, length: ns.length - ns.length / 2)).location
            if caret == NSNotFound { caret = ns.length }

            for step in 0..<16 {
                source = (source as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "a")
                caret += 1
                let next = page(source)
                let start = DispatchTime.now().uptimeNanoseconds
                let edit = PreviewEdit(from: shown, to: next)
                editMs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                if step % 2 == 0, let edit {
                    let (reply, ms) = call("const r = window.cmdmdPreview.patch(edit); document.body.offsetHeight; return r;",
                                           ["edit": edit.argument(forPage: shown.rendered.nonce)], in: webView)
                    XCTAssertEqual((reply as? [String: Any])?["done"] as? Bool, true, "\(name) step \(step)")
                    patchMs.append(ms)
                    replaced.append(edit.runs.reduce(0) { $0 + $1.blocks.count })
                    // The page keeps the nonce it loaded with.
                    shown = PreviewPage(rendered: MarkdownRenderer.RenderedPage(
                        html: next.html, blocks: next.rendered.blocks, taskLines: next.rendered.taskLines,
                        head: next.rendered.head, language: next.rendered.language, nonce: shown.rendered.nonce
                    ), source: source, baseURL: nil, options: options, generation: 0, renderMs: nil)
                } else {
                    let offset = call("return window.scrollY;", in: webView).0 as? Double ?? 0
                    reloadMs.append(load(next, at: offset))
                    shown = next
                }
            }
            window.close()
            let blocks = shown.rendered.blocks?.count ?? -1
            print(String(format: "PATCHBENCH %@ | %d blocks | patch median %.1f ms p90 %.1f | reload median %.1f ms p90 %.1f | x%.0f | edit diff %.2f ms | blocks sent %@",
                         name, blocks, Self.median(patchMs), Self.p90(patchMs), Self.median(reloadMs), Self.p90(reloadMs),
                         Self.median(reloadMs) / max(Self.median(patchMs), 0.01), Self.median(editMs),
                         replaced.map(String.init).joined(separator: ",")))
        }
    }
}
