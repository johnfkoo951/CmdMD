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
    private static var lastSweepDay = ""

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
        AppState.dataDirectory.appendingPathComponent("logs")
    }

    // MARK: Public API

    /// `message` must be static text (counts and percentages are fine) — it is
    /// logged publicly. User-derived text (file/note/vault names, error strings
    /// that embed paths) goes in `detail`: the file log keeps it verbatim, the
    /// unified log (Console.app, sysdiagnose) only ever sees a hash of it.
    static func info(_ message: String, _ category: LogCategory = .app, detail: String? = nil) {
        if let detail {
            loggers[category]?.info("\(message, privacy: .public) \(detail, privacy: .private(mask: .hash))")
        } else {
            loggers[category]?.info("\(message, privacy: .public)")
        }
        appendToFile(level: "INFO", category: category, message: composedMessage(message, detail: detail))
    }

    static func error(_ message: String, _ category: LogCategory = .error, detail: String? = nil) {
        if let detail {
            loggers[category]?.error("\(message, privacy: .public) \(detail, privacy: .private(mask: .hash))")
        } else {
            loggers[category]?.error("\(message, privacy: .public)")
        }
        appendToFile(level: "ERROR", category: category, message: composedMessage(message, detail: detail))
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

    /// Blocks until every queued file write has been issued. AppKit exits
    /// right after applicationWillTerminate, so the last lines (a failed
    /// quit-time save among them) were often lost. Never call it from `queue`.
    static func flush() {
        queue.sync {}
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

    /// The file-log text of an entry: the message, then its detail (if any).
    static func composedMessage(_ message: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return message }
        return "\(message) \(detail)"
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
            // Before the sink check: retention also applies to files left
            // behind after "Write log files" was turned off.
            sweepExpiredLogsIfNeeded(asOf: now)
            guard fileSinkEnabled, let data = line.data(using: .utf8) else { return }
            rollHandleIfNeeded(for: now)
            try? handle?.write(contentsOf: data)
        }
    }

    /// Opens (and creates) today's file on first use or day change. Runs on
    /// `queue`.
    private static func rollHandleIfNeeded(for date: Date) {
        let day = dayString(for: date)
        guard handle == nil || handleDay != day else { return }

        try? handle?.close()
        handle = nil
        handleDay = day

        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        handle = openAppendHandle(at: logsDirectory.appendingPathComponent(fileName(for: date)))
    }

    /// Opens `url` for appending, creating it (0600 — it holds note names) if
    /// needed. O_APPEND puts every write at the current end of file, so two
    /// CmdMD processes sharing a logs folder interleave whole lines instead of
    /// overwriting each other from stale offsets.
    static func openAppendHandle(at url: URL) -> FileHandle? {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        }
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    /// Sweeps on the first log call of each day — at launch, and after every
    /// midnight in a long-running menu-bar instance. Runs on `queue`.
    private static func sweepExpiredLogsIfNeeded(asOf date: Date) {
        let day = dayString(for: date)
        guard day != lastSweepDay else { return }
        lastSweepDay = day
        sweepExpiredLogs(in: logsDirectory, asOf: date)
    }

    /// Deletes the expired daily logs in `directory`. Never creates it: with
    /// the sink off there may be no logs folder at all.
    static func sweepExpiredLogs(in directory: URL, asOf now: Date) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where isExpiredLogFile(name, asOf: now) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
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
