import XCTest
@testable import CmdMD

/// Vault-scale costs that grow with the number of notes, not with the open
/// note: the completion/Omnisearch index walk (run at launch and on every
/// switch back to CmdMD) and resolving a clicked `[[wiki link]]`.
///
/// Skipped unless CMDMD_VAULT_BENCH_ROOTS lists the roots (colon-separated,
/// e.g. the registered vaults). Meaningful in a release build only:
///
///     CMDMD_VAULT_BENCH_ROOTS="/path/vault1:/path/vault2" swift test -c release \
///         -Xswiftc -enable-testing --filter VaultIndexBenchmarkTests
final class VaultIndexBenchmarkTests: XCTestCase {
    private func roots() throws -> [URL] {
        guard let list = ProcessInfo.processInfo.environment["CMDMD_VAULT_BENCH_ROOTS"], !list.isEmpty else {
            throw XCTSkip("set CMDMD_VAULT_BENCH_ROOTS to run the vault benchmark")
        }
        return list.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    private static func ms(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func median(_ runs: Int, _ body: () -> Void) -> Double {
        let samples = (0..<runs).map { _ in ms(body) }.sorted()
        return samples[samples.count / 2]
    }

    func testIndexWalk() throws {
        let roots = try roots()
        var notes = 0
        var images = 0
        let walk = Self.median(5) {
            let result = NoteIndexService.buildIndexes(roots: roots)
            notes = result.notes.count
            images = result.attachments.filesByName.values.reduce(0) { $0 + $1.count }
        }
        print(String(format: "BENCH index walk | notes %d | images %d | %.1f ms (median of 5)", notes, images, walk))

        var reference: (notes: [VaultNote], attachments: AttachmentIndex) = ([], .empty)
        let referenceWalk = Self.median(3) { reference = NoteIndexEquivalenceTests.referenceIndexes(roots: roots, limit: 100_000) }
        print(String(format: "BENCH index walk per-file reference | %.1f ms (median of 3)", referenceWalk))
        let built = NoteIndexService.buildIndexes(roots: roots)
        let lhs = built.notes.map { "\($0.path)|\($0.title)|\($0.url.absoluteString)|\($0.modifiedAt.timeIntervalSince1970)" }
        let rhs = reference.notes.map { "\($0.path)|\($0.title)|\($0.url.absoluteString)|\($0.modifiedAt.timeIntervalSince1970)" }
        if lhs != rhs {
            let onlyBuilt = Set(lhs).subtracting(rhs), onlyReference = Set(rhs).subtracting(lhs)
            print("BENCH index diff | counts \(lhs.count) vs \(rhs.count) | only new: \(onlyBuilt.prefix(3)) | only reference: \(onlyReference.prefix(3))")
            if let first = zip(lhs, rhs).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
                print("BENCH index first difference at \(first.offset): \(first.element.0) <> \(first.element.1)")
            }
        }
        XCTAssertEqual(lhs, rhs)
        XCTAssertTrue(built.attachments.hasSameFiles(as: reference.attachments))
    }

    /// Omnisearch's file-name ranking runs on the main thread for every
    /// keystroke, over the whole index. Queries grow a key at a time, as typed.
    func testOmnisearchKeystroke() throws {
        let notes = NoteIndexService.buildIndex(roots: try roots())
        let typed = ["c", "cm", "cmd", "cmds", "회", "회의", "회의록", "pkm", "agent", "claude"]
        var hits: [OmnisearchView.Hit] = []
        let recents = Array(notes.prefix(40).map(\.url))
        for query in typed {
            let perKey = Self.median(5) {
                hits = OmnisearchView.fileHits(query: query, notes: notes, recentFiles: recents)
            }
            print(String(format: "BENCH omnisearch key '%@' | %d notes | hits %d | %.1f ms", query, notes.count, hits.count, perKey))
            XCTAssertEqual(hits.map(\.subtitle),
                           R1AppmiscOmnisearchHitTests.referenceFileHits(query: query, notes: notes, recentFiles: recents),
                           "ranking differs from the Character version for \(query)")
        }
    }

    /// Omnisearch's content hits: time until the 12 shown hits are in, for a
    /// common word and for a rare one (which reads every note).
    func testContentSearch() async throws {
        let roots = try roots()
        for query in ["claude", "회의록", "zq9-no-such-text"] {
            var samples: [Double] = []
            var count = 0
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                count = await AppState.performSearch(query: query, in: roots, limit: 12).count
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            print(String(format: "BENCH content search '%@' | hits %d | %.0f ms (median of 3)", query, count, samples.sorted()[1]))
        }
        // The sidebar's folder search keeps up to 500 hits.
        for query in ["claude", "회의록"] {
            let start = DispatchTime.now().uptimeNanoseconds
            let results = await AppState.performSearch(query: query, in: roots, limit: 500)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print(String(format: "BENCH folder search '%@' (limit 500) | hits %d | %.0f ms", query, results.count, elapsed))
            let lines = results.map { "\($0.fileURL.path)|\($0.lineNumber.map(String.init) ?? "-")|\($0.lineContent)|\($0.lineContent[$0.matchRange])" }
            let referenceStart = DispatchTime.now().uptimeNanoseconds
            let reference = R1AppmiscContentSearchTests.referenceSearch(query: query, in: roots, limit: 500)
            print(String(format: "BENCH folder search '%@' one-by-one reference | %.0f ms", query,
                         Double(DispatchTime.now().uptimeNanoseconds - referenceStart) / 1_000_000))
            XCTAssertEqual(lines, reference, query)
        }
    }

    /// A click on `[[name]]` for notes spread through the vault (deep ones
    /// miss the direct `<root>/<name>.md` check), and for a missing note,
    /// which walks every root to the end.
    func testWikiLinkResolve() throws {
        let roots = try roots()
        let index = NoteIndexService.buildIndex(roots: roots)
        guard !index.isEmpty else { throw XCTSkip("no notes under the roots") }
        // Oldest notes come last in the index; take a spread of nested ones.
        let nested = index.filter { $0.path.contains("/") }
        let stride = max(1, nested.count / 8)
        let targets = Swift.stride(from: 0, to: nested.count, by: stride).prefix(8).map { nested[$0].title }

        var resolved = 0
        let hit = Self.median(3) {
            resolved = 0
            for target in targets where LinkedNoteResolver(roots: roots).resolve(target) != nil { resolved += 1 }
        }
        print(String(format: "BENCH wiki link (8 nested notes) | resolved %d/%d | %.1f ms per click", resolved, targets.count, hit / Double(targets.count)))

        let miss = Self.median(3) {
            _ = LinkedNoteResolver(roots: roots).resolve("no such note \(UUID().uuidString)")
        }
        print(String(format: "BENCH wiki link (missing note) | %.1f ms", miss))
    }
}
