import XCTest
@testable import CmdMD

final class ZoomTests: XCTestCase {
    func testClampsToRange() {
        XCTAssertEqual(AppState.clampedZoom(0.1), 0.5)
        XCTAssertEqual(AppState.clampedZoom(9.0), 3.0)
        XCTAssertEqual(AppState.clampedZoom(1.0), 1.0)
    }

    func testRoundsFloatDust() {
        // Pinch deltas produce values like 1.4000000000000004; the editor's
        // re-highlight trigger compares pointSize exactly, so zoom must quantize.
        XCTAssertEqual(AppState.clampedZoom(1.4000000000000004), 1.4)
        XCTAssertEqual(AppState.clampedZoom(1.234567), 1.23)
        XCTAssertEqual(AppState.clampedZoom(0.999), 1.0)
    }

    func testEndpointsSurviveRounding() {
        XCTAssertEqual(AppState.clampedZoom(AppState.zoomRange.lowerBound), 0.5)
        XCTAssertEqual(AppState.clampedZoom(AppState.zoomRange.upperBound), 3.0)
    }
}

final class NewSettingsFieldsTests: XCTestCase {
    func testDefaultsSurviveEmptyJSON() throws {
        // Old settings.json files predate the new keys — the resilient decoder
        // must fall back to defaults instead of failing or zeroing them.
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.zoomLevel, 1.0)
        XCTAssertTrue(settings.copySelectionOnDrag)
        XCTAssertTrue(settings.fileLoggingEnabled)
    }

    func testExplicitValuesRoundTrip() throws {
        var settings = AppSettings()
        settings.zoomLevel = 1.5
        settings.copySelectionOnDrag = false
        settings.fileLoggingEnabled = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.zoomLevel, 1.5)
        XCTAssertFalse(decoded.copySelectionOnDrag)
        XCTAssertFalse(decoded.fileLoggingEnabled)
    }

    func testZoomShortcutDefaults() {
        XCTAssertEqual(AppShortcut.zoomIn.defaultBinding, KeyBinding(key: "=", command: true))
        XCTAssertEqual(AppShortcut.zoomOut.defaultBinding, KeyBinding(key: "-", command: true))
        XCTAssertEqual(AppShortcut.resetZoom.defaultBinding, KeyBinding(key: "0", command: true))
        XCTAssertEqual(AppShortcut.zoomIn.defaultBinding.displayString, "⌘=")
    }

    /// Every shortcut resolves to a usable KeyEquivalent and no two defaults
    /// collide — the audit that used to be done by hand.
    func testNoDefaultBindingCollisions() {
        var seen: [KeyBinding: AppShortcut] = [:]
        for shortcut in AppShortcut.allCases {
            let binding = shortcut.defaultBinding
            XCTAssertNotNil(binding.keyEquivalent, "\(shortcut) has an unrepresentable key")
            if let existing = seen[binding] {
                XCTFail("\(shortcut) and \(existing) share default \(binding.displayString)")
            }
            seen[binding] = shortcut
        }
    }
}

final class LogServiceTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var components = DateComponents(year: y, month: m, day: d, hour: 12)
        components.timeZone = TimeZone.current
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    func testFileNameFormat() {
        XCTAssertEqual(Log.fileName(for: date(2026, 7, 2)), "cmdmd-2026-07-02.log")
        XCTAssertEqual(Log.fileName(for: date(2026, 12, 31)), "cmdmd-2026-12-31.log")
    }

    func testFormatLine() {
        let line = Log.formatLine(date: date(2026, 7, 2), level: "INFO", category: .send, message: "sent x.md")
        XCTAssertTrue(line.hasPrefix("2026-07-02 12:00:00"))
        XCTAssertTrue(line.contains("[INFO] [send] sent x.md"))
        XCTAssertTrue(line.hasSuffix("\n"))
    }

    func testRetentionParsesFileNames() {
        let now = date(2026, 7, 10)
        XCTAssertTrue(Log.isExpiredLogFile("cmdmd-2026-07-01.log", asOf: now))
        XCTAssertFalse(Log.isExpiredLogFile("cmdmd-2026-07-09.log", asOf: now))
        XCTAssertFalse(Log.isExpiredLogFile(Log.fileName(for: now), asOf: now))
        // Foreign files in the directory are never deleted.
        XCTAssertFalse(Log.isExpiredLogFile("settings.json", asOf: now))
        XCTAssertFalse(Log.isExpiredLogFile("cmdmd-garbage.log", asOf: now))
    }
}
