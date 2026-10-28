import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import CmdMD

/// A picture typed in above the reader has no size until it loads: when it
/// does, the reader stays where they were.
final class PreviewImageAnchorTests: PreviewPageTestCase {
    @Observable
    final class Model {
        var documentID = UUID()
        var markdown = ""
        var baseURL: URL?
        var options = MarkdownRenderOptions()
    }

    private struct Harness: View {
        let model: Model
        var body: some View {
            MarkdownPreviewView(documentID: model.documentID, positionKey: nil, source: PreviewSource(model.markdown),
                                baseURL: model.baseURL, options: model.options, scrollSyncEnabled: false, zoom: 1)
        }
    }

    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?

    override func tearDownWithError() throws {
        host?.rootView = AnyView(EmptyView())
        spin(0.05)
        window?.close()
        window = nil
        host = nil
        try super.tearDownWithError()
    }

    private static func writePNG(_ url: URL, width: Int, height: Int) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    @MainActor
    private func mount(_ model: Model) throws -> WKWebView {
        let hosting = NSHostingView(rootView: AnyView(Harness(model: model)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        hosting.layoutSubtreeIfNeeded()
        self.window = window
        host = hosting
        let webView = try XCTUnwrap(R3bFocusHostedTestCase.find(PreviewWebView.self, in: hosting))
        let loaded = "return !!document.getElementById('cmdmd-root');"
        waitUntil(timeout: 30) { !webView.isLoading && run(loaded, in: webView) as? Bool == true }
        try XCTSkipUnless(run(loaded, in: webView) as? Bool == true, "the page did not load in this environment")
        try settle(webView)
        return webView
    }

    private static let readerTop = """
        const p = Array.from(document.querySelectorAll('#cmdmd-root > p')).find(p => p.textContent.startsWith('Paragraph 60 '));
        return p.getBoundingClientRect().top;
        """

    /// Without WebKit's scroll anchoring (switched off here, as macOS 14's
    /// WebKit has none), and with it.
    @MainActor
    func testANewImageAboveTheReaderKeepsTheirPlaceWhenItLoads() throws {
        let folder = dataDir.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writePNG(folder.appendingPathComponent("new.png"), width: 600, height: 300)
        let middle = (0..<120).map { "Paragraph \($0) " + String(repeating: "words in a line ", count: 10) }.joined(separator: "\n\n")

        for native in [false, true] {
            let model = Model()
            model.baseURL = folder
            model.options.localAssetRoots = []
            model.markdown = "Top para.\n\n" + middle
            let webView = try mount(model)
            if !native {
                _ = run("document.documentElement.style.overflowAnchor = 'none'; document.body.style.overflowAnchor = 'none'; return true;", in: webView)
            }
            _ = run("""
                const p = Array.from(document.querySelectorAll('#cmdmd-root > p')).find(p => p.textContent.startsWith('Paragraph 60 '));
                window.scrollTo(0, p.offsetTop + 7); return true;
                """, in: webView)
            spin(0.2)
            let before = try XCTUnwrap(run(Self.readerTop, in: webView) as? Double)

            model.markdown = "Top para.\n\n![](new.png)\n\n" + middle
            try settle(webView)
            waitUntil(timeout: 20) {
                run("const i = document.images[0]; return !!i && i.complete && i.naturalHeight > 0;", in: webView) as? Bool == true
            }
            spin(0.5)
            let height = run("return document.images[0].getBoundingClientRect().height;", in: webView) as? Double ?? 0
            XCTAssertGreaterThan(height, 100, "the picture loaded (native=\(native))")
            let after = try XCTUnwrap(run(Self.readerTop, in: webView) as? Double)
            XCTAssertEqual(after, before, accuracy: 1, "native=\(native): the reader moved when the picture above loaded")

            host?.rootView = AnyView(EmptyView())
            spin(0.05)
            window?.close()
            window = nil
            host = nil
        }
    }
}
