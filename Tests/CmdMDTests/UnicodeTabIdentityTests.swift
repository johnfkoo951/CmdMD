import XCTest
@testable import CmdMD

/// One note, one tab, whichever way it was opened. A name stored composed
/// (NFC: what Obsidian and most tools write) reaches the app spelled two ways:
/// as stored from folder listings (the sidebar, content search) and decomposed
/// from anything standardized (the note index behind Omnisearch file hits,
/// wiki links). The URLs differ byte for byte though they name one file.
final class UnicodeTabIdentityTests: IsolatedDataDirTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Under /Users like a vault: under /var/folders every walked path is
        // standardized, which hides the difference.
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmdmd-tab-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try super.tearDownWithError()
    }

    /// Writes `name` composed, as raw bytes; Foundation would store it decomposed.
    private func makeComposedNote(_ name: String) throws {
        let path = folder.path + "/" + name.precomposedStringWithCanonicalMapping
        let descriptor = open(path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        _ = "# 회의\n".withCString { Darwin.write(descriptor, $0, strlen($0)) }
        close(descriptor)
    }

    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testSidebarAndOmnisearchOpenOneTabForAComposedName() async throws {
        try makeComposedNote("업무 데스크.md")
        let listed = try XCTUnwrap(AppState.listFolder(at: folder).first { !$0.isDirectory }?.url)
        let indexed = try XCTUnwrap(NoteIndexService.buildIndex(roots: [folder]).first?.url)
        XCTAssertNotEqual(listed, indexed, "precondition: the two spellings differ")

        let state = AppState()
        state.openDocument(at: listed, inNewTab: true)
        try await wait { state.tabs.count == 1 }
        state.openDocument(at: indexed, inNewTab: true)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state.tabs.count, 1, "the same note opened in a second tab")
        state.tabs.forEach { state.closeTab($0) }
    }
}
