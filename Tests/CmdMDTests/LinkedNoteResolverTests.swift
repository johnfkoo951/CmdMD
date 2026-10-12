import XCTest
@testable import CmdMD

final class LinkedNoteResolverTests: XCTestCase {
    func testResolvesEncodedFragmentTargetFromVaultRoot() throws {
        let vaultRoot = try makeTemporaryDirectory()
        let notesFolder = vaultRoot.appendingPathComponent("Knowledge")
        try FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        let noteURL = notesFolder.appendingPathComponent("Nested Note.md")
        try "# Nested Note\n".write(to: noteURL, atomically: true, encoding: .utf8)

        let resolver = LinkedNoteResolver(roots: [vaultRoot])
        // Decoded once, by URLComponents, as AppState.openInternalURL reads it.
        let target = URLComponents(string: "cmdmd://open?note=Knowledge/Nested%20Note%23Overview")?
            .queryItems?.first?.value ?? ""

        XCTAssertEqual(
            resolver.resolve(target),
            noteURL.standardizedFileURL
        )
    }

    func testMalformedOrMissingTargetDoesNotResolve() throws {
        let vaultRoot = try makeTemporaryDirectory()
        let resolver = LinkedNoteResolver(roots: [vaultRoot])

        XCTAssertNil(resolver.resolve(""))
        XCTAssertNil(resolver.resolve("   "))
        XCTAssertNil(resolver.resolve("%"))
        XCTAssertNil(resolver.resolve("Missing Note"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
