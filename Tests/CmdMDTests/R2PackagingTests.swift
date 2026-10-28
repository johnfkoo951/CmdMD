import XCTest
@testable import CmdMD

/// The Highlightr probe must test exactly the paths `Bundle.module` tries, so a
/// copy of the app anywhere (DMG, Downloads, ~/Applications, a renamed .app) finds
/// the bundle in Contents/Resources, and a bundle-less build degrades instead of
/// trapping.
final class HighlightrBundleProbeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMD-R2Packaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A renamed app outside /Applications, laid out like package_app.sh's output.
    private func makeApp(named name: String = "CmdMD Copy.app") throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        for sub in ["Contents/MacOS", "Contents/Resources"] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        return app
    }

    /// A Highlightr_Highlightr.bundle (as the Xcode build system lays it out) in `dir`.
    @discardableResult
    private func makeHighlightrBundle(in dir: URL) throws -> URL {
        let bundle = dir.appendingPathComponent("Highlightr_Highlightr.bundle", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "/* highlight.js */".write(to: resources.appendingPathComponent("highlight.min.js"),
                                       atomically: true, encoding: .utf8)
        return bundle
    }

    private func candidates(for app: URL) -> [URL] {
        SyntaxHighlighter.highlightrBundleCandidates(
            resourceURL: app.appendingPathComponent("Contents/Resources"), bundleURL: app)
    }

    func testAppCandidatesFollowTheAccessorOrder() throws {
        let app = try makeApp()
        XCTAssertEqual(candidates(for: app).map(\.path), [
            app.appendingPathComponent("Contents/Resources/Highlightr_Highlightr.bundle").path,
            app.appendingPathComponent("Highlightr_Highlightr.bundle").path,
        ])
    }

    func testBareExecutableHasOneCandidateNextToIt() {
        // `swift run`: resourceURL == bundleURL == the executable's directory.
        let dir = URL(fileURLWithPath: "/tmp/cmdmd-build/debug", isDirectory: true)
        let expected = [dir.appendingPathComponent("Highlightr_Highlightr.bundle").path]
        XCTAssertEqual(SyntaxHighlighter.highlightrBundleCandidates(resourceURL: dir, bundleURL: dir)
            .map(\.path), expected)
        XCTAssertEqual(SyntaxHighlighter.highlightrBundleCandidates(resourceURL: nil, bundleURL: dir)
            .map(\.path), expected)
    }

    func testRenamedCopyOutsideApplicationsFindsTheBundleInResources() throws {
        let app = try makeApp()
        let bundle = try makeHighlightrBundle(in: app.appendingPathComponent("Contents/Resources"))
        let resolved = try XCTUnwrap(SyntaxHighlighter.resolvedHighlightrBundle(among: candidates(for: app)))
        XCTAssertEqual(resolved.standardizedFileURL.path, bundle.standardizedFileURL.path)
        XCTAssertNotNil(Bundle(url: resolved)?.path(forResource: "highlight.min", ofType: "js"))
    }

    func testMissingBundleResolvesToNothing() throws {
        // A mis-packaged app: no bundle anywhere the accessor looks → highlighting
        // off instead of the Bundle.module trap.
        XCTAssertNil(SyntaxHighlighter.resolvedHighlightrBundle(among: candidates(for: try makeApp())))
    }

    func testBundleNextToTheExecutableInsideAnAppDoesNotCount() throws {
        // Contents/MacOS is a root the old probe checked, but neither accessor tries it.
        let app = try makeApp()
        try makeHighlightrBundle(in: app.appendingPathComponent("Contents/MacOS"))
        XCTAssertNil(SyntaxHighlighter.resolvedHighlightrBundle(among: candidates(for: app)))
    }

    func testResourcesWinOverTheAppRoot() throws {
        let app = try makeApp()
        let inResources = try makeHighlightrBundle(in: app.appendingPathComponent("Contents/Resources"))
        try makeHighlightrBundle(in: app)
        XCTAssertEqual(SyntaxHighlighter.resolvedHighlightrBundle(among: candidates(for: app))?
            .standardizedFileURL.path, inResources.standardizedFileURL.path)
    }

    func testAPlainFileIsNotABundle() throws {
        // Same test as the accessor (`Bundle(url:)`): a file by that name doesn't load.
        let app = try makeApp()
        try "not a bundle".write(
            to: app.appendingPathComponent("Contents/Resources/Highlightr_Highlightr.bundle"),
            atomically: true, encoding: .utf8)
        XCTAssertNil(SyntaxHighlighter.resolvedHighlightrBundle(among: candidates(for: app)))
    }
}

/// `swift run` / `swift build` binaries carry no Info.plist: they report "dev"
/// (not a stale literal) and never compare themselves with the latest release.
final class AppVersionInfoTests: XCTestCase {
    func testNoInfoPlistMeansDevBuild() {
        XCTAssertEqual(AppInfo.version(from: nil), "dev")
        XCTAssertFalse(AppInfo.isPackaged(info: nil))
        XCTAssertEqual(AppInfo.version(from: [:]), "dev")
        XCTAssertFalse(AppInfo.isPackaged(info: ["CFBundleShortVersionString": 15]))
    }

    func testPackagedBuildReportsItsPlistVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.5.0", "CFBundleVersion": "15"]
        XCTAssertEqual(AppInfo.version(from: info), "1.5.0")
        XCTAssertTrue(AppInfo.isPackaged(info: info))
    }
}

/// Plain-text guards on the packaging and release scripts (found via #filePath),
/// so reverting a fix fails `swift test`, which the release workflow runs first.
final class PackagingScriptTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CmdMDTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Non-comment lines of a shell script.
    private func code(_ script: String) throws -> [String] {
        try read(script).components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    private func firstLine(in lines: [String], containing needle: String,
                           file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try XCTUnwrap(lines.firstIndex { $0.contains(needle) }, "no line contains \(needle)",
                      file: file, line: line)
    }

    func testVersionFileIsTheSingleSourceOfTruth() throws {
        var values: [String: String] = [:]
        for line in try read("VERSION").components(separatedBy: .newlines) where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        let version = try XCTUnwrap(values["CFBundleShortVersionString"])
        let build = try XCTUnwrap(values["CFBundleVersion"])
        XCTAssertNotNil(version.range(of: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression), version)
        XCTAssertNotNil(Int(build), build)

        // Info.plist takes both values from VERSION, never from a literal.
        let package = try read("scripts/package_app.sh").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for (key, value) in [("CFBundleShortVersionString", "${APP_VERSION}"), ("CFBundleVersion", "${APP_BUILD}")] {
            let keyLine = try XCTUnwrap(package.firstIndex(of: "<key>\(key)</key>"), key)
            XCTAssertEqual(package[keyLine + 1], "<string>\(value)</string>", key)
        }
        XCTAssertTrue(try read(".github/workflows/release.yml").contains("< VERSION"))
    }

    func testPackagingBuildsUniversalWithoutBinaryPatching() throws {
        let package = try code("scripts/package_app.sh").joined(separator: "\n")
        XCTAssertTrue(package.contains("--arch arm64 --arch x86_64"))
        XCTAssertFalse(package.contains("fix-highlightr-bundle"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Self.repoRoot.appendingPathComponent("scripts/fix-highlightr-bundle.py").path))
    }

    func testPackagingShipsThePreviewLibraries() throws {
        // The preview loads them only from Contents/Resources/PreviewLibs (or a checkout).
        let package = try code("scripts/package_app.sh")
        XCTAssertTrue(package.contains { $0.contains(#"cp -R "$PREVIEW_LIBS" "$RESOURCES_DIR/PreviewLibs""#) })
        XCTAssertTrue(package.contains { $0.contains(#"PREVIEW_LIBS="$ROOT_DIR/Resources/PreviewLibs""#) })
        XCTAssertTrue(package.contains { $0.contains(#"! -f "$PREVIEW_LIBS/cmds-pele/pele.global.js""#) },
                      "a build without Pele has no diagrams")
        XCTAssertTrue(try code("scripts/test_package_app.sh").contains {
            $0.contains(#"diff -rq "$ROOT_DIR/Resources/PreviewLibs" "$APP_DIR/Contents/Resources/PreviewLibs""#)
        })
    }

    func testPackagingRefusesABinaryThatNamesTheCheckout() throws {
        // A source path in a release build publishes the builder's home folder.
        for script in ["scripts/package_app.sh", "scripts/test_package_app.sh"] {
            XCTAssertTrue(try code(script).contains {
                $0.contains(#"grep -qF -e "$ROOT_DIR" -e "$ROOT_DIR_PHYSICAL" <<<"$slice_strings""#)
            }, script)
        }
    }

    func testReleaseCodeUsesNoSourcePath() throws {
        // #filePath (and Swift 5's #file) compile to the checkout's absolute
        // path; only debug builds, which never ship, may use them.
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let sourcePath = try NSRegularExpression(pattern: #"#file(Path)?(?![A-Za-z])"#)
        for file in files {
            var conditions: [String] = []
            for (index, line) in try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if ") { conditions.append(String(trimmed.dropFirst(4))) }
                if trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif"), !conditions.isEmpty {
                    conditions[conditions.count - 1] = "else"
                }
                if trimmed.hasPrefix("#endif") { _ = conditions.popLast() }
                guard !trimmed.hasPrefix("//"), !conditions.contains("DEBUG"),
                      sourcePath.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                else { continue }
                XCTFail("\(file.lastPathComponent):\(index + 1) uses a source path outside #if DEBUG")
            }
        }
    }

    func testSigningArmsCleanupBeforeCreatingTheKeychain() throws {
        let lines = try code("scripts/sign_and_notarize.sh")
        let trap = try firstLine(in: lines, containing: "trap cleanup EXIT")
        XCTAssertLessThan(trap, try firstLine(in: lines, containing: "base64 --decode"))
        XCTAssertLessThan(trap, try firstLine(in: lines, containing: "security create-keychain"))
        XCTAssertTrue(lines.contains { $0.contains("mktemp -d") })
    }

    func testDMGIsSignedAndNotarizedBeforeStapling() throws {
        let lines = try code("scripts/sign_and_notarize.sh")
        let staple = try firstLine(in: lines, containing: #"stapler staple "$DMG""#)
        XCTAssertLessThan(try firstLine(in: lines, containing: #"codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$DMG""#), staple)
        XCTAssertLessThan(try firstLine(in: lines, containing: #"notarize "$DMG""#), staple)
        XCTAssertTrue(lines.contains { $0.contains(#"stapler validate "$DMG""#) && !$0.contains("|| true") })
    }
}
