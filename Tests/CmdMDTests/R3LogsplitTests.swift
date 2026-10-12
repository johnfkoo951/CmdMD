import XCTest
@testable import CmdMD

// MARK: - Log file sink: flush, retention sweep, append handles

final class R3LogFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMD-R3Logsplit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var components = DateComponents(year: y, month: m, day: d, hour: 12)
        components.timeZone = TimeZone.current
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // G034/G052: applicationWillTerminate calls flush() on the main thread.
    func testFlushReturnsPromptlyFromAnyThread() {
        Log.info("flush smoke test", .app)
        let returned = expectation(description: "flush returned off the main thread")
        DispatchQueue.global().async {
            Log.flush()
            returned.fulfill()
        }
        wait(for: [returned], timeout: 5)
        Log.flush()
    }

    // G051: the sweep is its own step now, run whether or not the sink is on.
    func testSweepDeletesOnlyExpiredDailyLogs() throws {
        let names = ["cmdmd-2026-07-01.log", "cmdmd-2026-07-09.log", "cmdmd-2026-07-10.log",
                     "settings.json", "cmdmd-garbage.log"]
        for name in names {
            try Data().write(to: dir.appendingPathComponent(name))
        }

        Log.sweepExpiredLogs(in: dir, asOf: date(2026, 7, 10))

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(Set(left), Set(names.dropFirst()))
    }

    func testSweepNeverCreatesTheLogsFolder() {
        let logs = dir.appendingPathComponent("logs", isDirectory: true)

        Log.sweepExpiredLogs(in: logs, asOf: date(2026, 7, 10))

        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))
    }

    // G053: two processes (two opens) sharing one daily file.
    func testTwoAppendHandlesInterleaveWholeLines() throws {
        let url = dir.appendingPathComponent("cmdmd-2026-07-10.log")
        let a = try XCTUnwrap(Log.openAppendHandle(at: url))
        let b = try XCTUnwrap(Log.openAppendHandle(at: url))

        try a.write(contentsOf: Data("A1\n".utf8))
        try b.write(contentsOf: Data("B1\n".utf8))
        try a.write(contentsOf: Data("A2\n".utf8))
        try b.write(contentsOf: Data("B2\n".utf8))
        try a.close()
        try b.close()

        XCTAssertEqual(try read(url), "A1\nB1\nA2\nB2\n")
    }

    func testAppendHandleCreatesAPrivateFileAndKeepsEarlierLines() throws {
        let url = dir.appendingPathComponent("cmdmd-2026-07-10.log")
        let first = try XCTUnwrap(Log.openAppendHandle(at: url))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        try first.write(contentsOf: Data("launched\n".utf8))
        try first.close()

        let second = try XCTUnwrap(Log.openAppendHandle(at: url))
        try second.write(contentsOf: Data("terminating\n".utf8))
        try second.close()

        XCTAssertEqual(try read(url), "launched\nterminating\n")
    }

    func testAppendHandleIsNilWhenTheFolderIsMissing() {
        let url = dir.appendingPathComponent("missing/cmdmd-2026-07-10.log")

        XCTAssertNil(Log.openAppendHandle(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Tests never touch the real data directory (G017)

/// A test class that builds an AppState must point the data-dir override at a
/// sandbox — in its own body or through a base class — or init reads (and its
/// session-restore Task rewrites) the developer's real app data. Plain-text
/// scan of this folder, like RepoHygieneTests.
final class R3TestSandboxHygieneTests: XCTestCase {
    func testEveryTestBuildingAppStateIsSandboxed() throws {
        // Assembled, so this file's own text never matches.
        let buildsAppState = "AppState" + "()"
        let sandboxes = "CMDMD" + "_DATA_DIR"

        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: testsDir.path)
            .filter { $0.hasSuffix(".swift") }
        // Top-level (column 0) declarations split a file into segments.
        let declaration = try NSRegularExpression(
            pattern: #"^(?:@\w+\s+)*(?:(?:final|private|fileprivate|internal|public|open)\s+)*(class|struct|enum|extension|actor|func)\s+(\w+)(?:\s*:\s*(\w+))?"#
        )

        var superclass: [String: String] = [:]
        var sandboxed: Set<String> = []
        var builders: [String: String] = [:]   // segment → file
        for file in files {
            let text = try String(contentsOf: testsDir.appendingPathComponent(file), encoding: .utf8)
            var segments: [(name: String, body: String)] = [("\(file) (top level)", "")]
            for line in text.components(separatedBy: .newlines) {
                // Comments neither build nor sandbox anything (and a doc
                // comment sits above its declaration, in the previous segment).
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if let match = declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let kind = Range(match.range(at: 1), in: line),
                   let name = Range(match.range(at: 2), in: line) {
                    if line[kind] == "class", let parent = Range(match.range(at: 3), in: line) {
                        superclass[String(line[name])] = String(line[parent])
                    }
                    segments.append((String(line[name]), ""))
                }
                segments[segments.count - 1].body += line + "\n"
            }
            for segment in segments {
                if segment.body.contains(sandboxes) { sandboxed.insert(segment.name) }
                if segment.body.contains(buildsAppState) { builders[segment.name] = file }
            }
        }

        func isSandboxed(_ name: String) -> Bool {
            var current: String? = name
            var seen: Set<String> = []
            while let candidate = current, seen.insert(candidate).inserted {
                if sandboxed.contains(candidate) { return true }
                current = superclass[candidate]
            }
            return false
        }

        XCTAssertFalse(builders.isEmpty, "scan found no AppState-building tests in \(testsDir.path)")
        for (name, file) in builders.sorted(by: { $0.key < $1.key }) where !isSandboxed(name) {
            XCTFail("\(file): \(name) builds an AppState against the real data directory — subclass IsolatedDataDirTestCase")
        }
    }
}
