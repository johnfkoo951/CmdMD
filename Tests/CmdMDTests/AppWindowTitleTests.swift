import XCTest
@testable import CmdMD

/// Sandboxed: AppState() reads the data directory (and its session-restore
/// Task rewrites it), which must never be the developer's real one.
final class AppWindowTitleTests: IsolatedDataDirTestCase {
    func testWindowTitleFallsBackToAppNameWithoutDocument() {
        XCTAssertEqual(AppState.dataDirectory.standardizedFileURL, dataDir.standardizedFileURL)
        let appState = AppState()

        XCTAssertEqual(appState.windowTitle, "CmdMD")
    }

    func testWindowTitleUsesActiveDocumentDisplayTitle() {
        let appState = AppState()
        let document = MarkdownDocument(title: "A & B")
        let tab = EditorTab(documentId: document.id, title: document.displayTitle)

        appState.tabs = [tab]
        appState.activeTabId = tab.id
        appState.documents[document.id] = document

        XCTAssertEqual(appState.windowTitle, "A & B")
    }
}
