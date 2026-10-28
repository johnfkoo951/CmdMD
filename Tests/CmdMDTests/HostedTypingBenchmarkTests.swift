import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import CmdMD

/// End-to-end main-thread cost of typing and tab switching with the real
/// editor and preview hosted in an unshown window: AppState → SwiftUI →
/// EditorTextView / MarkdownPreviewView → renderer → WKWebView. Main-thread
/// CPU time is the number that holds on a loaded machine; compare builds
/// interleaved, never against a number from another run.
///
/// Skipped unless CMDMD_HOSTED_BENCH=1, with CMDMD_BENCH_DIR naming the
/// fixture folder; meaningful in a release build only:
///
///     CMDMD_HOSTED_BENCH=1 CMDMD_BENCH_DIR=/path/to/fixtures swift test -c release \
///         -Xswiftc -enable-testing --filter HostedTypingBenchmarkTests
///
/// CMDMD_BENCH_ROOT: main (MainEditorView, default), content (the whole
/// window), editorpane, previewpane (one pane alone).
final class HostedTypingBenchmarkTests: IsolatedDataDirTestCase {
    private var dir: String!
    private var notesDir: URL!
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        guard env["CMDMD_HOSTED_BENCH"] == "1", let dir = env["CMDMD_BENCH_DIR"] else {
            throw XCTSkip("set CMDMD_HOSTED_BENCH=1 and CMDMD_BENCH_DIR to run the hosted benchmark")
        }
        self.dir = dir
        _ = NSApplication.shared
        notesDir = dataDir.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unmount()
        try super.tearDownWithError()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Meters

    /// Main-thread CPU over a window, and the busy time of each run-loop
    /// pass (after-waiting → before-waiting).
    final class BusyMeter {
        private var begin: CFRunLoopObserver?
        private var end: CFRunLoopObserver?
        private var wakeAt: UInt64 = 0
        private var cpuStart: UInt64 = 0
        private(set) var intervals: [Double] = []
        private(set) var cpuMs: Double = 0

        func start() {
            intervals = []
            cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.entry.rawValue, true, CFIndex.min) { [unowned self] _, _ in
                wakeAt = DispatchTime.now().uptimeNanoseconds
            }
            // .exit too: RunLoop.run(until:) returns after each handled source
            // without a beforeWaiting, and the next .entry would drop that pass.
            end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, CFIndex.max) { [unowned self] _, _ in
                guard wakeAt != 0 else { return }
                intervals.append(Double(DispatchTime.now().uptimeNanoseconds - wakeAt) / 1_000_000)
                wakeAt = 0
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), begin, .commonModes)
            CFRunLoopAddObserver(CFRunLoopGetMain(), end, .commonModes)
        }

        func stop() {
            cpuMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
            if let begin { CFRunLoopRemoveObserver(CFRunLoopGetMain(), begin, .commonModes) }
            if let end { CFRunLoopRemoveObserver(CFRunLoopGetMain(), end, .commonModes) }
            begin = nil
            end = nil
        }

        func summary(_ label: String, keystrokes: Int = 0, loads: LoadWatcher? = nil, patches: Int? = nil, web: WebProcessMeter? = nil) {
            let sorted = intervals.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let top = sorted.suffix(3).reversed().map { String(format: "%.1f", $0) }.joined(separator: ",")
            let perKey = keystrokes > 0 ? String(format: " (%.2f/key)", cpuMs / Double(keystrokes)) : ""
            let loadLine = (loads.map { " | loads \($0.finished)" } ?? "") + (patches.map { " | patches \($0)" } ?? "")
                + (web.map { String(format: " | web CPU %.1f ms", $0.cpuMs) } ?? "")
            print(String(format: "HOSTED %@ | main CPU %.1f ms%@ | busy %.1f ms | p95 %.2f | max [%@] | >16.7ms %d | >50ms %d",
                         label, cpuMs, perKey, intervals.reduce(0, +), p95, top,
                         intervals.filter { $0 > 16.7 }.count, intervals.filter { $0 > 50 }.count) + loadLine)
        }
    }

    /// Counts the preview's finished page loads (isLoading → false).
    final class LoadWatcher {
        private var observation: NSKeyValueObservation?
        private(set) var finished = 0
        private(set) var lastFinish: UInt64 = 0

        init(_ webView: WKWebView) {
            observation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                guard change.newValue == false, let self else { return }
                finished += 1
                lastFinish = DispatchTime.now().uptimeNanoseconds
            }
        }

        func reset() { finished = 0 }
    }

    /// Counts the preview's patches: changes to the note's root (the body
    /// on a page without one), one batch per patch. A load starts over.
    final class PatchWatcher {
        private let webView: WKWebView

        init(_ webView: WKWebView) {
            self.webView = webView
        }

        private func evaluate(_ script: String) -> Any? {
            var value: Any?
            var done = false
            webView.evaluateJavaScript(script) { result, _ in
                value = result
                done = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
            return value
        }

        func reset() {
            _ = evaluate("""
                if (window.benchObserver) window.benchObserver.disconnect();
                window.benchPatches = 0;
                window.benchObserver = new MutationObserver(function () { window.benchPatches += 1; });
                window.benchObserver.observe(document.getElementById('cmdmd-root') || document.body, {childList: true});
                true
                """)
        }

        var count: Int { evaluate("window.benchPatches || 0") as? Int ?? 0 }
    }

    /// CPU time of the preview's WebContent process (parse, layout, the
    /// page's scripts), which the main-thread meter doesn't see.
    final class WebProcessMeter {
        private let webView: WKWebView
        private var start: UInt64 = 0
        private(set) var cpuMs: Double = 0

        init(_ webView: WKWebView) {
            self.webView = webView
        }

        private var cpuTicks: UInt64? {
            // WebKit SPI, read in this benchmark only.
            guard let pid = webView.value(forKey: "_webProcessIdentifier") as? pid_t, pid > 0 else { return nil }
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            return status == 0 ? usage.ri_user_time + usage.ri_system_time : nil
        }

        func begin() { start = cpuTicks ?? 0 }

        func end() {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let ticks = (cpuTicks ?? start) &- start
            cpuMs = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        }
    }

    // MARK: Mounting

    @MainActor
    private func mount(_ state: AppState) {
        let env = ProcessInfo.processInfo.environment
        let root: AnyView
        switch env["CMDMD_BENCH_ROOT"] ?? "main" {
        case "content":
            state.settings.hasCompletedOnboarding = true
            root = AnyView(ContentView().environment(state))
        case "editorpane": root = AnyView(EditorPane().environment(state))
        case "previewpane": root = AnyView(PreviewPane().environment(state))
        default: root = AnyView(MainEditorView().environment(state))
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        self.host = host
        self.window = window
    }

    private func unmount() {
        host?.rootView = AnyView(EmptyView())
        spin(0.1)
        window?.close()
        window = nil
        host = nil
    }

    private func find<T: NSView>(_ type: T.Type) -> T? {
        func search(_ view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return host.flatMap(search)
    }

    private func waitForLoad(_ loads: LoadWatcher, beyond count: Int, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while loads.finished <= count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
    }

    @MainActor
    private func addDocument(_ state: AppState, fixture name: String) throws -> EditorTab {
        let source = try String(contentsOfFile: (dir as NSString).appendingPathComponent(name), encoding: .utf8)
        let url = notesDir.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        let document = MarkdownDocument(content: FileService.parseFrontmatter(from: source).body, fileURL: url)
        let tab = EditorTab(documentId: document.id, fileURL: url, title: name)
        state.documents[document.id] = document
        state.originalContents[document.id] = document.fullText
        state.tabs.append(tab)
        return tab
    }

    @MainActor
    private func type(into textView: CmdMDTextView, keys: Int, interval: TimeInterval) {
        var remaining = keys
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            guard remaining > 0 else { return timer.invalidate() }
            remaining -= 1
            textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        RunLoop.main.add(timer, forMode: .common)
        spin(interval * Double(keys) + interval)
        timer.invalidate()
    }

    private func fixtures(_ variable: String, default fallback: String) -> [String] {
        (ProcessInfo.processInfo.environment[variable] ?? fallback).split(separator: ",").map(String.init)
    }

    // MARK: Scenarios

    /// Two bursts of keys in the middle of each note, then the pause in
    /// which the preview catches up.
    @MainActor
    func testTypingInSplitView() throws {
        let keys = Int(ProcessInfo.processInfo.environment["CMDMD_BENCH_KEYS"] ?? "") ?? 30
        for name in fixtures("CMDMD_BENCH_TYPING", default: "small-note.md,medium-mixed.md,korean-prose.md,large-mixed.md") {
            let state = AppState()
            state.viewMode = .split
            state.activeTabId = try addDocument(state, fixture: name).id
            mount(state)
            spin(2.5) // web process launch + first page
            let textView = try XCTUnwrap(find(CmdMDTextView.self))
            let webView = try XCTUnwrap(find(PreviewWebView.self))
            let loads = LoadWatcher(webView)
            let patches = PatchWatcher(webView)
            let web = WebProcessMeter(webView)
            let text = textView.string as NSString
            let middle = text.range(of: "\n", range: NSRange(location: text.length / 2, length: text.length - text.length / 2)).location
            textView.setSelectedRange(NSRange(location: middle == NSNotFound ? text.length : middle, length: 0))
            spin(0.5)

            let meter = BusyMeter()
            for burst in 1...2 {
                loads.reset()
                patches.reset()
                web.begin()
                meter.start()
                type(into: textView, keys: keys, interval: 0.07)
                meter.stop()
                web.end()
                meter.summary("[split] \(name) burst\(burst) typing \(keys) keys @70ms", keystrokes: keys, loads: loads, patches: patches.count, web: web)
                loads.reset()
                patches.reset()
                web.begin()
                meter.start()
                spin(1.5)
                meter.stop()
                web.end()
                meter.summary("[split] \(name) burst\(burst) pause", loads: loads, patches: patches.count, web: web)
            }
            unmount()
        }
    }

    /// Flips between three notes in preview mode, twice.
    @MainActor
    func testTabSwitching() throws {
        let state = AppState()
        state.viewMode = .preview
        let names = fixtures("CMDMD_BENCH_TABS", default: "korean-prose.md,large-mixed.md,medium-mixed.md")
        let tabs = try names.map { try addDocument(state, fixture: $0) }
        state.activeTabId = tabs[0].id
        mount(state)
        spin(2.5)
        let loads = LoadWatcher(try XCTUnwrap(find(PreviewWebView.self)))
        let meter = BusyMeter()
        let order = Array(zip(tabs, names).dropFirst()) + [(tabs[0], names[0])]
        for round in 1...2 {
            for (tab, name) in order {
                loads.reset()
                meter.start()
                let start = DispatchTime.now().uptimeNanoseconds
                state.activeTabId = tab.id
                let syncMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                waitForLoad(loads, beyond: 0, timeout: 3)
                let pageMs = Double(loads.lastFinish &- start) / 1_000_000
                spin(0.8)
                meter.stop()
                meter.summary(String(format: "tab switch round%d → %@ | sync %.1f ms | page at %.0f ms", round, name, syncMs, loads.finished > 0 ? pageMs : -1))
            }
        }
    }

    /// Mount → first preview page in preview mode: the launch path for a
    /// restored note (web process launch, render, load), a second after the
    /// window opened. Only the first fixture of a test process meets a cold
    /// WebKit; CMDMD_BENCH_PREWARM=1 warms it up when the window opens, as
    /// the app does.
    @MainActor
    func testFirstPaint() throws {
        if ProcessInfo.processInfo.environment["CMDMD_BENCH_PREWARM"] == "1" { PreviewWarmup.begin() }
        spin(1)
        for name in fixtures("CMDMD_BENCH_FIRSTPAINT", default: "small-note.md,medium-mixed.md,korean-prose.md,large-mixed.md") {
            let state = AppState()
            state.viewMode = .preview
            state.activeTabId = try addDocument(state, fixture: name).id
            let meter = BusyMeter()
            meter.start()
            let start = DispatchTime.now().uptimeNanoseconds
            mount(state)
            let mountMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let loads = LoadWatcher(try XCTUnwrap(find(PreviewWebView.self)))
            waitForLoad(loads, beyond: 0)
            let pageMs = Double(loads.lastFinish &- start) / 1_000_000
            meter.stop()
            meter.summary(String(format: "first paint %@ | mount %.1f ms | page at %.0f ms", name, mountMs, loads.finished > 0 ? pageMs : -1))
            unmount()
        }
    }
}
