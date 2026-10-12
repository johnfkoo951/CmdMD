import XCTest
@testable import CmdMD

/// Repo-hygiene guards for the CI / release / docs fixes: plain-text checks on
/// the checked-in files (found via #filePath), so they run offline and fail
/// `swift test` — and with it the release workflow — if a fix is reverted.
final class RepoHygieneTests: XCTestCase {
    /// Tests/CmdMDTests/<this file> → repo root.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CmdMDTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// A workflow's text minus `#` comment lines, so comments that name a
    /// forbidden flag (or a required one) can't satisfy or trip a check.
    private func workflow(_ name: String) throws -> String {
        try read(".github/workflows/\(name)")
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    func testClaudeReviewWorkflowIsReviewOnly() throws {
        // No workflow may void Claude Code's tool permissions: they read
        // issue / PR text that anyone can write.
        let names = try FileManager.default.contentsOfDirectory(
            atPath: Self.repoRoot.appendingPathComponent(".github/workflows").path
        ).filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        XCTAssertFalse(names.isEmpty)
        for name in names {
            XCTAssertFalse(try workflow(name).contains("--dangerously-skip-permissions"), name)
        }

        let review = try workflow("claude-review.yml")
        // Job token (contents: read), not the Claude App token minted via OIDC.
        XCTAssertTrue(review.contains("github_token: ${{ secrets.GITHUB_TOKEN }}"))
        XCTAssertFalse(review.contains("id-token: write"))
        // Only trusted authors can start a run, for comments and issues alike.
        XCTAssertTrue(review.contains("github.event.comment.author_association"))
        XCTAssertTrue(review.contains("github.event.issue.author_association"))
    }

    func testPackageResolvedIsCommittedAndEnforced() throws {
        let ignoreRules = try read(".gitignore")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(ignoreRules.contains("Package.resolved"))
        XCTAssertFalse(ignoreRules.contains("/Package.resolved"))

        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("Package.resolved"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
        let identities = Set(pins.compactMap { $0["identity"] as? String })
        XCTAssertTrue(identities.isSuperset(of: ["highlightr", "swift-markdown", "yams"]), "\(identities)")

        // CI and release must build the pins, not silently re-resolve.
        XCTAssertTrue(try workflow("ci.yml").contains("--force-resolved-versions"))
        XCTAssertTrue(try workflow("release.yml").contains("--force-resolved-versions"))
    }

    func testReleaseRunsTestsAndCIExercisesPackaging() throws {
        // release.yml races ci.yml on the same commit, so it must gate itself.
        XCTAssertTrue(try workflow("release.yml").contains("swift test"))
        // Packaging regressions should surface on PRs, not first at tag time.
        XCTAssertTrue(try workflow("ci.yml").contains("scripts/test_package_app.sh"))
    }

    func testReadmesAreBilingualCreditedAndSanitized() throws {
        for name in ["README.md", "README.ko.md"] {
            let readme = try read(name)
            XCTAssertTrue(readme.contains("](README.md)"), name)
            XCTAssertTrue(readme.contains("](README.ko.md)"), name)
            XCTAssertTrue(readme.contains("Yohan Koo (CMDSPACE)"), name)
            XCTAssertTrue(readme.contains("https://cmdspace.work"), name)
        }

        // Public docs must not leak a personal filesystem path.
        let docs = try FileManager.default.contentsOfDirectory(
            atPath: Self.repoRoot.appendingPathComponent("docs").path
        ).filter { $0.hasSuffix(".md") }.map { "docs/\($0)" }
        for name in ["README.md", "README.ko.md"] + docs {
            XCTAssertFalse(try read(name).contains("/Users/"), name)
        }
    }
}
