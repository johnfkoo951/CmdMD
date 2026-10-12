import Foundation
import os

// MARK: - Log Categories

/// One category per functional area so Console.app filtering and the file log
/// stay greppable (`[send]`, `[zoom]`, …).
enum LogCategory: String, CaseIterable {
    case app, file, send, editor, preview, zoom, clipboard, error
}

// MARK: - Log

/// Central logging. Every entry goes to `os.Logger` (Console.app, subsystem
/// `com.cmdmd.app`) and — when the file sink is enabled — to a daily log file
/// under `Application Support/CmdMD/logs/`, kept for the last 7 days.
///
/// Safe to call from any thread: file writes are serialized on a utility
/// queue. The file sink is forced off while running under XCTest so unit
/// tests never write into the real Application Support directory.
enum Log {
    static let subsystem = "com.cmdmd.app"

    /// Days of log files to keep on disk.
    static let retentionDays = 7

    private static let queue = DispatchQueue(label: "com.cmdmd.log", qos: .utility)
    private static let isRunningTests = NSClassFromString("XCTestCase") != nil

    // Guarded by `queue`.
    private static var fileSinkEnabled = true
    private static var handle: FileHandle?
    private static var handleDay = ""
    private static var didSweep = false

    private static let loggers: [LogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map {
            ($0, Logger(subsystem: subsystem, category: $0.rawValue))
        }
    )

    /// `Application Support/CmdMD/logs/` — a subdirectory so the data JSONs
    /// (settings/vaults/session/…) in the parent folder are never confused
    /// with log output. Honors CMDMD_DATA_DIR like AppState, so an isolated
    /// dev instance never appends to the installed app's log files.
    static var logsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("logs")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CmdMD")
            .appendingPathComponent("logs")
    }

    // MARK: Public API

    static func info(_ message: String, _ category: LogCategory = .app) {
        loggers[category]?.info("\(message, privacy: .public)")
        appendToFile(level: "INFO", category: category, message: message)
    }

    static func error(_ message: String, _ category: LogCategory = .error) {
        loggers[category]?.error("\(message, privacy: .public)")
        appendToFile(level: "ERROR", category: category, message: message)
    }

    /// Mirrors `settings.fileLoggingEnabled`. Called by AppState after settings
    /// load and on every settings save, so toggling in Settings takes effect
    /// immediately.
    static func setFileLoggingEnabled(_ enabled: Bool) {
        queue.async {
            fileSinkEnabled = enabled
            if !enabled {
                try? handle?.close()
                handle = nil
                handleDay = ""
            }
        }
    }

    // MARK: Formatting helpers (pure — unit-tested)

    /// "cmdmd-2026-07-02.log" for the given date.
    static func fileName(for date: Date) -> String {
        "cmdmd-\(dayString(for: date)).log"
    }

    /// "2026-07-02" — also the day-roll key for the open file handle.
    static func dayString(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// One formatted log line, newline-terminated.
    static func formatLine(date: Date, level: String, category: LogCategory, message: String) -> String {
        "\(timestampFormatter.string(from: date)) [\(level)] [\(category.rawValue)] \(message)\n"
    }

    /// Whether a file in the logs directory is an expired daily log. Parses the
    /// date out of "cmdmd-YYYY-MM-DD.log"; unknown names are left alone.
    static func isExpiredLogFile(_ name: String, asOf now: Date, retentionDays: Int = retentionDays) -> Bool {
        guard name.hasPrefix("cmdmd-"), name.hasSuffix(".log") else { return false }
        let day = String(name.dropFirst("cmdmd-".count).dropLast(".log".count))
        guard let fileDate = dayFormatter.date(from: day) else { return false }
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 3600)
        return fileDate < cutoff
    }

    // MARK: File sink

    private static func appendToFile(level: String, category: LogCategory, message: String) {
        guard !isRunningTests else { return }
        let now = Date()
        let line = formatLine(date: now, level: level, category: category, message: message)
        queue.async {
            guard fileSinkEnabled, let data = line.data(using: .utf8) else { return }
            rollHandleIfNeeded(for: now)
            try? handle?.write(contentsOf: data)
        }
    }

    /// Opens (and creates) today's file on first use or day change, and sweeps
    /// expired files once per launch. Runs on `queue`.
    private static func rollHandleIfNeeded(for date: Date) {
        let day = dayString(for: date)
        guard handle == nil || handleDay != day else { return }

        try? handle?.close()
        handle = nil
        handleDay = day

        let fm = FileManager.default
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        if !didSweep {
            didSweep = true
            let names = (try? fm.contentsOfDirectory(atPath: logsDirectory.path)) ?? []
            for name in names where isExpiredLogFile(name, asOf: date) {
                try? fm.removeItem(at: logsDirectory.appendingPathComponent(name))
            }
        }

        let url = logsDirectory.appendingPathComponent(fileName(for: date))
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    // DateFormatter is thread-safe on modern macOS; both formatters are shared.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
