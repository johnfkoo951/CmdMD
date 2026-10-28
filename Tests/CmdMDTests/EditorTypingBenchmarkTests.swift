import XCTest
import AppKit
import SwiftUI
@testable import CmdMD

/// End-to-end main-thread cost of typing with the real editor (and, by
/// default, the preview beside it) hosted in an unshown window: NSTextView →
/// AppState → SwiftUI → EditorTextView / MarkdownPreviewView, through the
/// CA commit that draws the keystroke.
///
/// The headline is main-thread CPU per key (CLOCK_THREAD_CPUTIME_ID over the
/// burst), which holds up on a loaded machine where wall-clock busy time
/// includes preemption. Run-loop busy intervals are printed alongside.
///
/// Skipped unless CMDMD_HOSTED_BENCH=1 and CMDMD_BENCH_DIR names a folder of
/// fixtures; numbers only mean something in a release build:
///
///     CMDMD_HOSTED_BENCH=1 CMDMD_BENCH_DIR=/path/to/fixtures \
///         swift test -c release -Xswiftc -enable-testing \
///         --filter EditorTypingBenchmarkTests
///
/// CMDMD_BENCH_TYPING  fixtures, comma-separated (default: small, medium,
///                     korean-prose, large-mixed)
/// CMDMD_BENCH_ROOT    main (MainEditorView, default) | editorpane (the
///                     editor alone) | content (the whole window content)
/// CMDMD_BENCH_MODE    split (default) | source
/// CMDMD_BENCH_KEYS    keystrokes per burst (default 40)
/// CMDMD_BENCH_IME=1   Hangul syllables through marked text, as the Korean
///                     input method types them, instead of "a"
/// CMDMD_BENCH_NOBAND=1  current-line highlight off
final class EditorTypingBenchmarkTests: IsolatedDataDirTestCase {
    private var fixturesDir: String!
    private var notesDir: URL!
    private var window: NSWindow?
    private var host: NSHostingView<AnyView>?

    override func setUpWithError() throws {
        // The sandbox first: tearDown restores what it replaced either way.
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMDMD_HOSTED_BENCH"] == "1", let dir = environment["CMDMD_BENCH_DIR"] else {
            throw XCTSkip("set CMDMD_HOSTED_BENCH=1 and CMDMD_BENCH_DIR to run the editor typing benchmark")
        }
        fixturesDir = dir
        _ = NSApplication.shared
        notesDir = FileManager.default.temporaryDirectory.appendingPathComponent("CmdMDHostedBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unmount()
        if let notesDir { try? FileManager.default.removeItem(at: notesDir) }
        try super.tearDownWithError()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Meter

    /// Main-thread CPU over a window, plus the run loop's busy intervals
    /// (after-waiting → before-waiting, observed last so SwiftUI's update
    /// and the CA commit count).
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
            // .exit too: RunLoop.run(until:) returns after each handled
            // source without a beforeWaiting, and the next .entry would
            // otherwise drop that pass's busy time.
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

        func summary(_ label: String, keystrokes: Int = 0) -> String {
            let total = intervals.reduce(0, +)
            let sorted = intervals.sorted()
            let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let top = sorted.suffix(3).reversed().map { String(format: "%.1f", $0) }.joined(separator: ",")
            let perKey = keystrokes > 0 ? String(format: " (%.2f/key)", cpuMs / Double(keystrokes)) : ""
            return String(format: "HOSTED %@ | main CPU %.1f ms%@ | busy %.1f ms | passes %d | p50 %.2f | p95 %.2f | max [%@] | >16.7ms %d",
                          label, cpuMs, perKey, total, intervals.count, p50, p95, top, intervals.filter { $0 > 16.7 }.count)
        }
    }

    private static var loadAverage: String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "?" }
        return String(format: "%.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }

    // MARK: Mounting

    @MainActor
    private func mount(_ state: AppState) -> CmdMDTextView? {
        let environment = ProcessInfo.processInfo.environment
        let root: AnyView
        switch environment["CMDMD_BENCH_ROOT"] ?? "main" {
        case "content":
            state.settings.hasCompletedOnboarding = true
            root = AnyView(ContentView().environment(state))
        case "editorpane":
            root = AnyView(EditorPane().environment(state))
        default:
            root = AnyView(MainEditorView().environment(state))
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
        spin(2.5) // web process launch + first page
        return Self.find(CmdMDTextView.self, in: host)
    }

    private func unmount() {
        host?.rootView = AnyView(EmptyView())
        spin(0.1)
        window?.close()
        window = nil
        host = nil
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private func addDocument(_ state: AppState, fixture name: String) throws -> EditorTab {
        let source = try String(contentsOfFile: (fixturesDir as NSString).appendingPathComponent(name), encoding: .utf8)
        let url = notesDir.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        let body = FileService.parseFrontmatter(from: source).body
        let document = MarkdownDocument(content: body, fileURL: url)
        let tab = EditorTab(documentId: document.id, fileURL: url, title: name)
        state.documents[document.id] = document
        state.originalContents[document.id] = document.fullText
        state.tabs.append(tab)
        return tab
    }

    /// One keystroke per timer tick, as the event loop delivers them.
    @MainActor
    private func type(into textView: CmdMDTextView, keys: Int, interval: TimeInterval, ime: Bool) {
        // 한 = ㅎ → 하 → 한, committed by the next syllable's first jamo.
        let syllables: [[String]] = [["ㅎ", "하", "한"], ["ㄱ", "그", "글"]]
        var remaining = keys
        var syllable = 0
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            guard remaining > 0 else { timer.invalidate(); return }
            remaining -= 1
            if ime {
                let steps = syllables[syllable % syllables.count]
                for step in steps {
                    textView.setMarkedText(step, selectedRange: NSRange(location: (step as NSString).length, length: 0),
                                           replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                textView.insertText(steps.last!, replacementRange: NSRange(location: NSNotFound, length: 0))
                syllable += 1
            } else {
                textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spin(interval * Double(keys) + interval)
        timer.invalidate()
    }

    // MARK: Scenario

    @MainActor
    func testTypingMidDocument() throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtures = (environment["CMDMD_BENCH_TYPING"] ?? "small-note.md,medium-mixed.md,korean-prose.md,large-mixed.md")
            .split(separator: ",").map(String.init)
        let mode: ViewMode = environment["CMDMD_BENCH_MODE"] == "source" ? .source : .split
        let keys = Int(environment["CMDMD_BENCH_KEYS"] ?? "") ?? 40
        let ime = environment["CMDMD_BENCH_IME"] == "1"
        let rootName = environment["CMDMD_BENCH_ROOT"] ?? "main"
        print("HOSTED load \(Self.loadAverage) | root \(rootName) | mode \(mode) | keys \(keys) | ime \(ime)")

        for name in fixtures {
            let state = AppState()
            state.viewMode = mode
            if environment["CMDMD_BENCH_NOBAND"] == "1" { state.settings.highlightCurrentLine = false }
            let tab = try addDocument(state, fixture: name)
            state.activeTabId = tab.id
            guard let textView = mount(state) else { return XCTFail("no editor") }
            window?.makeFirstResponder(textView)
            let ns = textView.string as NSString
            let half = ns.length / 2
            let middle = ns.range(of: "\n", options: [], range: NSRange(location: half, length: ns.length - half)).location
            textView.setSelectedRange(NSRange(location: middle == NSNotFound ? ns.length : middle, length: 0))
            spin(0.5)

            let meter = BusyMeter()
            for burst in 1...2 {
                let before = (state.currentDocument?.content as NSString?)?.length ?? 0
                meter.start()
                type(into: textView, keys: keys, interval: 0.07, ime: ime)
                meter.stop()
                let grew = ((state.currentDocument?.content as NSString?)?.length ?? 0) - before
                print(meter.summary("\(name) burst\(burst) typing", keystrokes: keys) + " | model grew \(grew) | load \(Self.loadAverage)")
                meter.start()
                spin(1.5) // highlight debounce, preview render + reload
                meter.stop()
                print(meter.summary("\(name) burst\(burst) pause"))
            }
            XCTAssertEqual(textView.string, state.currentDocument?.content, "\(name): the model follows the editor")
            unmount()
        }
    }
}
