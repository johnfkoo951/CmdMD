import SwiftUI
import WebKit
import XCTest
@testable import CmdMD

/// Save As of a draft, a move or a renamed folder: the note's text stays,
/// its folder changes, and the page must follow without an edit.
final class PreviewFolderChangeTests: PreviewPageTestCase {
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

    @MainActor
    func testANewFolderAloneReachesThePage() throws {
        let folder = dataDir.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A 1x1 PNG beside where the note is saved.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        try png.write(to: folder.appendingPathComponent("pic.png"))

        let model = Model()
        model.options.localAssetRoots = []
        model.markdown = "# Draft\n\n![](pic.png)\n\nbody text"
        let hosting = NSHostingView(rootView: AnyView(Harness(model: model)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        hosting.layoutSubtreeIfNeeded()
        self.window = window
        host = hosting
        let webView = try XCTUnwrap(R3bFocusHostedTestCase.find(PreviewWebView.self, in: hosting))
        waitUntil(timeout: 30) { !webView.isLoading && run("return !!document.getElementById('cmdmd-root');", in: webView) as? Bool == true }
        try XCTSkipUnless(run("return !!document.getElementById('cmdmd-root');", in: webView) as? Bool == true, "the page did not load in this environment")
        try settle(webView)
        XCTAssertEqual(run("return document.querySelector('img').getAttribute('src');", in: webView) as? String, "pic.png", "a draft has no folder")

        model.baseURL = folder
        let probe = "const i = document.querySelector('img'); return {src: i.getAttribute('src'), loaded: i.complete && i.naturalWidth > 0};"
        var state: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(20)
        repeat {
            spin(0.1)
            if webView.isLoading { continue }
            state = run(probe, in: webView) as? [String: Any] ?? [:]
        } while state["loaded"] as? Bool != true && Date() < deadline
        XCTAssertEqual((state["src"] as? String)?.hasPrefix(LocalAssetURL.scheme + ":"), true, "\(state)")
        XCTAssertEqual(state["loaded"] as? Bool, true, "the picture beside the saved note shows: \(state)")
    }
}
