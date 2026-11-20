import XCTest
@testable import CmdMD

/// `NoteIndexService.buildIndexes` dropped per-file standardizing, path
/// hashing for roots that don't overlap, and canonical prefix compares. The
/// index must come out exactly as the per-file version built it.
class NoteIndexEquivalenceTests: XCTestCase {
    private var sandbox: URL!

    /// Under /var/folders, itself a link to /private/var/folders: the walk
    /// reports every file under /private. `NoteIndexEquivalenceUserFolderTests`
    /// runs the same checks where vaults live, under /Users.
    class var sandboxBase: URL { FileManager.default.temporaryDirectory }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = Self.sandboxBase
            .appendingPathComponent("cmdmd-note-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        try super.tearDownWithError()
    }

    @discardableResult
    private func make(_ path: String, age: Int) throws -> URL {
        let url = sandbox.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(age) * 60)],
            ofItemAtPath: url.path
        )
        return url
    }

    /// A file whose name is stored composed (NFC), as tools writing raw bytes
    /// leave it; Foundation's own writes store names decomposed.
    private func makeComposed(folder: String, name: String, age: Int) throws {
        let directory = sandbox.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.path + "/" + name.precomposedStringWithCanonicalMapping
        let descriptor = open(path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        close(descriptor)
        var times = [timespec(tv_sec: 1_700_000_000 - age * 60, tv_nsec: 0), timespec(tv_sec: 1_700_000_000 - age * 60, tv_nsec: 0)]
        XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0)
        let stored = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(stored.contains { Array($0.utf8) == Array(name.precomposedStringWithCanonicalMapping.utf8) },
                      "the name should be stored composed")
    }

    /// The walk as it was: every file standardized, every path hashed.
    static func referenceIndexes(roots: [URL], limit: Int) -> (notes: [VaultNote], attachments: AttachmentIndex) {
        var notes: [VaultNote] = []
        var images: [URL] = []
        var seenPaths: Set<String> = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var rootCount = 0
            var rootImageCount = 0
            for case let fileURL as URL in enumerator {
                if NoteIndexService.skippedFolderNames.contains(fileURL.lastPathComponent),
                   (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = fileURL.pathExtension.lowercased()
                if LocalAssetURL.imageExtensions.contains(ext) {
                    if rootImageCount < limit, seenPaths.insert(fileURL.standardizedFileURL.path).inserted {
                        images.append(fileURL)
                        rootImageCount += 1
                    }
                    continue
                }
                guard NoteIndexService.supportedExtensions.contains(ext) else { continue }
                let standardized = fileURL.standardizedFileURL
                guard seenPaths.insert(standardized.path).inserted else { continue }
                let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rootPrefix = root.standardizedFileURL.path + "/"
                let path = standardized.path.hasPrefix(rootPrefix)
                    ? String(standardized.path.dropFirst(rootPrefix.count)) : standardized.lastPathComponent
                notes.append(VaultNote(
                    path: path,
                    title: standardized.deletingPathExtension().lastPathComponent,
                    modifiedAt: modified,
                    url: standardized
                ))
                rootCount += 1
                if rootCount >= limit { break }
            }
        }
        let sorted = notes.sorted { $0.modifiedAt > $1.modifiedAt }
        return (Array(sorted.prefix(limit)), AttachmentIndex(files: images))
    }

    private func assertSameIndexes(roots: [URL], limit: Int = 100_000, file: StaticString = #filePath, line: UInt = #line) {
        let built = NoteIndexService.buildIndexes(roots: roots, limit: limit)
        let reference = Self.referenceIndexes(roots: roots, limit: limit)
        func describe(_ notes: [VaultNote]) -> [String] {
            // Bytes, not Strings: String == calls composed and decomposed spellings equal.
            notes.map { "\(Array($0.path.utf8))|\(Array($0.title.utf8))|\($0.url.absoluteString)|\($0.modifiedAt.timeIntervalSince1970)|\($0.titleKey)|\($0.pathKey)" }
        }
        XCTAssertEqual(describe(built.notes), describe(reference.notes), file: file, line: line)
        XCTAssertEqual(built.notes.map(\.url), reference.notes.map(\.url), file: file, line: line)
        XCTAssertTrue(built.attachments.hasSameFiles(as: reference.attachments), file: file, line: line)
    }

    func testIndexMatchesThePerFileWalk() throws {
        let names = [
            "회의록.md", "주간 회의/2026-10-01 회의.md", "Projects/CmdMD 기획.MD", "Projects/deep/a/b/c/note.markdown",
            "2024.05.01.md", "Read Me.txt", "image.png", "Projects/assets/스크린샷.JPG", "vault/inside.md",
            "vault/sub/여기.md", "vault/pic.png", "node_modules/pkg/readme.md", ".obsidian/workspace.md", "other.pdf",
        ]
        for (age, name) in names.enumerated() {
            // Korean names as the file system tends to store them: decomposed.
            try make("A/" + name.decomposedStringWithCanonicalMapping, age: age / 2)
        }
        try makeComposed(folder: "A/업무", name: "업무 데스크.md", age: 4)
        try makeComposed(folder: "A", name: "작업 로그.md", age: 5)
        // `;` is escaped (%3B) in the walk's URLs, not in URL(fileURLWithPath:)'s.
        try makeComposed(folder: "A", name: "더닝 크루거 효과(effect; Kruger & Dunning, 1999).md", age: 8)
        try make("A/semi;colon #1?.md", age: 9)
        try makeComposed(folder: "B", name: "회의 사진.png", age: 6)
        try make("B/b-note.md", age: 3)
        // A root with a Korean name, handed over composed while the walk spells it decomposed.
        try make("패캠 강의/노트.md".decomposedStringWithCanonicalMapping, age: 7)
        let koreanRoot = URL(fileURLWithPath: sandbox.path + "/" + "패캠 강의".precomposedStringWithCanonicalMapping, isDirectory: true)
        try make("B/한글 노트.md".decomposedStringWithCanonicalMapping, age: 30)

        let a = sandbox.appendingPathComponent("A", isDirectory: true)
        let nested = a.appendingPathComponent("vault", isDirectory: true)
        let b = sandbox.appendingPathComponent("B", isDirectory: true)
        // The same folder spelled through /private, as an open panel may hand it over.
        let privateB = URL(fileURLWithPath: "/private" + b.path, isDirectory: true)

        assertSameIndexes(roots: [a, b])
        assertSameIndexes(roots: [a, nested, b])
        assertSameIndexes(roots: [nested, a])
        assertSameIndexes(roots: [privateB, a])
        assertSameIndexes(roots: [b, b])
        assertSameIndexes(roots: [a, b], limit: 3)
        assertSameIndexes(roots: [koreanRoot, a])
        XCTAssertEqual(NoteIndexService.buildIndex(roots: [koreanRoot]).first?.path, "노트.md".decomposedStringWithCanonicalMapping)

        let notes = NoteIndexService.buildIndex(roots: [a, b])
        XCTAssertFalse(notes.contains { $0.path.contains("node_modules") || $0.path.contains(".obsidian") })
        XCTAssertTrue(notes.contains { $0.title == "2024.05.01" })
        XCTAssertTrue(notes.contains { $0.title == "CmdMD 기획".decomposedStringWithCanonicalMapping })
    }
}

/// The same checks outside /private, where the user's vaults live: here the
/// walk hands back composed names as stored instead of standardizing them.
final class NoteIndexEquivalenceUserFolderTests: NoteIndexEquivalenceTests {
    override class var sandboxBase: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}
