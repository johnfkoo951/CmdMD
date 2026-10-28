import XCTest
@testable import CmdMD

/// Obsidian writes `![[pic.png]]` for a picture anywhere in the vault (the
/// shortest unique link); resolved only against the note's folder, it showed
/// as a broken image whenever the picture sat in `assets/` or similar.
final class AttachmentEmbedTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("embeds-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        for folder in ["Projects", "assets", "Archive/assets", "node_modules/pkg"] {
            try FileManager.default.createDirectory(
                at: vault.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        for file in ["Projects/Note.md", "assets/diagram.png", "Archive/assets/old.jpg",
                     "Projects/beside.png", "assets/beside.png", "node_modules/pkg/logo.png"] {
            FileManager.default.createFile(atPath: vault.appendingPathComponent(file).path, contents: Data())
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    private func path(_ relative: String) -> String {
        vault.appendingPathComponent(relative).standardizedFileURL.path
    }

    private func imagePath(_ target: String, index: AttachmentIndex) -> String {
        MarkdownRenderer.embeddedImagePath(target, baseURL: vault.appendingPathComponent("Projects"), attachments: index)
    }

    func testWalkIndexesImagesBesideNotesAndSkipsToolFolders() {
        let (notes, index) = NoteIndexService.buildIndexes(roots: [vault])
        XCTAssertEqual(notes.map(\.title), ["Note"])
        XCTAssertEqual(index.filesByName["diagram.png"]?.map(\.path), [path("assets/diagram.png")])
        XCTAssertEqual(index.filesByName["beside.png"]?.count, 2)
        XCTAssertNil(index.filesByName["logo.png"], "node_modules is never walked")
    }

    func testBareNameFindsPictureInAnotherFolder() {
        let index = NoteIndexService.buildIndexes(roots: [vault]).attachments
        XCTAssertEqual(imagePath("diagram.png", index: index), path("assets/diagram.png"))
        XCTAssertEqual(imagePath("DIAGRAM.PNG", index: index), path("assets/diagram.png"), "case-insensitive")
    }

    func testFileBesideTheNoteWins() {
        let index = NoteIndexService.buildIndexes(roots: [vault]).attachments
        XCTAssertEqual(imagePath("beside.png", index: index), path("Projects/beside.png"))
    }

    func testFolderQualifiedTargetMustMatchTrailingFolders() {
        let index = NoteIndexService.buildIndexes(roots: [vault]).attachments
        XCTAssertEqual(imagePath("assets/old.jpg", index: index), path("Archive/assets/old.jpg"))
        XCTAssertEqual(imagePath("Archive/assets/old.jpg", index: index), path("Archive/assets/old.jpg"))
        XCTAssertEqual(imagePath("Other/old.jpg", index: index), path("Projects/Other/old.jpg"),
                       "no match falls back to the note's folder")
    }

    func testRenderedEmbedIsServedFromTheVault() {
        var options = MarkdownRenderOptions()
        options.localAssetRoots = [vault]
        options.attachments = NoteIndexService.buildIndexes(roots: [vault]).attachments
        let html = MarkdownRenderer().renderToHTML(
            markdown: "![[diagram.png|300]]", baseURL: vault.appendingPathComponent("Projects"), options: options
        )
        XCTAssertTrue(html.contains("cmdmd-asset://local\(path("assets/diagram.png"))"), html)
        XCTAssertTrue(html.contains(#"width="300""#))
    }

    func testEqualityIsPerBuildButContentCanBeCompared() {
        let first = NoteIndexService.buildIndexes(roots: [vault]).attachments
        let second = NoteIndexService.buildIndexes(roots: [vault]).attachments
        XCTAssertNotEqual(first, second, "cheap identity compare for the preview's options check")
        XCTAssertTrue(first.hasSameFiles(as: second), "AppState keeps the old build when nothing moved")
    }
}
