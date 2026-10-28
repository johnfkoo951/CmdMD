import Foundation
import WebKit

/// Where preview pages render: off the main thread, which a 500 KB note held
/// for 100-280 ms per typing pause and per tab switch. One serial thread
/// with the main thread's 8 MB stack, not a GCD queue: a worker's 512 KB
/// overflowed on nesting the main thread renders (80 quote levels in a
/// release build).
final class PreviewRenderThread: Thread {
    static let shared: PreviewRenderThread = {
        let thread = PreviewRenderThread()
        thread.name = "CmdMD preview render"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
        return thread
    }()

    private let condition = NSCondition()
    private var jobs: [(owner: ObjectIdentifier, work: () -> Void)] = []

    /// Runs `work` after the jobs queued before it. A job of the same owner
    /// still waiting is dropped: only a preview's newest render is wanted.
    func enqueue(for owner: AnyObject, _ work: @escaping () -> Void) {
        condition.lock()
        let id = ObjectIdentifier(owner)
        jobs.removeAll { $0.owner == id }
        jobs.append((id, work))
        condition.signal()
        condition.unlock()
    }

    /// Drops `owner`'s waiting job (a render that has started runs to its end).
    func cancel(for owner: AnyObject) {
        condition.lock()
        let id = ObjectIdentifier(owner)
        jobs.removeAll { $0.owner == id }
        condition.unlock()
    }

    override func main() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job.work() }
        }
    }
}

/// How long typing must pause before the preview refreshes: about one and a
/// half refreshes (render + patch, or render + page load), so the previous
/// one is done when the next starts. Small notes refresh as you type (40 ms); the longest wait is
/// the fixed 250 ms every note used to get.
struct PreviewDebounce {
    static let shortest: TimeInterval = 0.04
    static let longest: TimeInterval = 0.25
    private(set) var delay: TimeInterval = longest

    mutating func record(refreshMs: Double) {
        delay = min(Self.longest, max(Self.shortest, refreshMs * 1.5 / 1000))
    }
}

/// A rendered preview page and what it was rendered from.
struct PreviewPage {
    let rendered: MarkdownRenderer.RenderedPage
    let source: String
    let baseURL: URL?
    let options: MarkdownRenderOptions
    /// Orders a preview's pages: one older than the page loaded is never shown.
    let generation: Int
    /// Nil for a page from the cache, which costs no render.
    let renderMs: Double?

    var html: String { rendered.html }

    /// Lengths first: an unchanged note is the same String, equal in O(1).
    func matches(_ source: String, baseURL: URL?, options: MarkdownRenderOptions) -> Bool {
        self.options == options && self.baseURL == baseURL && !self.source.differs(from: source)
    }
}

/// The last page of each recently shown note, so flipping back to an
/// unchanged tab loads at once instead of rendering again. A few notes only:
/// a 500 KB note's page is about 1 MB.
struct PreviewPageCache {
    let limit: Int
    /// Least recently shown first.
    private var pages: [(id: UUID, page: PreviewPage)] = []

    init(limit: Int = 6) {
        self.limit = limit
    }

    /// `documentID`'s page if it was rendered from this text and these
    /// settings, under a fresh CSP nonce for the new load.
    mutating func page(for documentID: UUID?, source: String, baseURL: URL?, options: MarkdownRenderOptions, generation: Int) -> PreviewPage? {
        guard let documentID, let index = pages.firstIndex(where: { $0.id == documentID }),
              pages[index].page.matches(source, baseURL: baseURL, options: options) else { return nil }
        let cached = pages.remove(at: index)
        pages.append(cached)
        return PreviewPage(rendered: cached.page.rendered.refreshingNonce(), source: cached.page.source,
                           baseURL: baseURL, options: options, generation: generation, renderMs: nil)
    }

    mutating func store(_ page: PreviewPage, for documentID: UUID?) {
        guard let documentID else { return }
        pages.removeAll { $0.id == documentID }
        pages.append((documentID, page))
        if pages.count > limit { pages.removeFirst(pages.count - limit) }
    }
}

/// What turns the page on screen into a newer page of the same note: the
/// runs of blocks that changed, as `cmdmdPreview.patch` takes them
/// (`PreviewRuntime`). Nil when only a load can: other settings, folder or
/// head (`PageHead`), or a page without blocks to patch.
struct PreviewEdit: Equatable {
    /// `remove` blocks of the page on screen from `at`, replaced by `blocks`.
    struct Run: Equatable {
        let at: Int
        let remove: Int
        let blocks: [String]
    }

    /// The blocks on screen.
    let count: Int
    /// In page order, apart: the blocks between them stay as they are.
    let runs: [Run]
    let language: String?

    /// Past this many blocks added and removed inside the changed stretch,
    /// it is replaced whole: a rewrite has nothing between its changes to keep.
    static let maxEdits = 128

    /// Compares the pages' blocks byte for byte from each end: a few
    /// hundred kilobytes of memcmp at most. One edit can change blocks far
    /// apart (a task added under the first renumbers the last one's box, a
    /// duplicate heading re-slugs a later one, a new footnote renumbers the
    /// rest): the blocks between them are matched up (a shortest edit
    /// script), so they stay on the page, with the reader's place and
    /// whatever the reader opened.
    init?(from old: PreviewPage, to new: PreviewPage) {
        guard let before = old.rendered.blocks, let after = new.rendered.blocks, old.options == new.options,
              old.baseURL == new.baseURL, old.rendered.head == new.rendered.head else { return nil }
        var oldHTML = old.html
        var newHTML = new.html
        runs = oldHTML.withUTF8 { a in
            newHTML.withUTF8 { b -> [Run] in
                func same(_ i: Int, _ j: Int) -> Bool {
                    let x = before[i], y = after[j]
                    return x.count == y.count && memcmp(a.baseAddress! + x.lowerBound, b.baseAddress! + y.lowerBound, x.count) == 0
                }
                let shorter = min(before.count, after.count)
                var prefix = 0
                while prefix < shorter, same(prefix, prefix) { prefix += 1 }
                var suffix = 0
                while suffix < shorter - prefix, same(before.count - 1 - suffix, after.count - 1 - suffix) { suffix += 1 }
                let oldEnd = before.count - suffix, newEnd = after.count - suffix
                guard prefix < oldEnd || prefix < newEnd else { return [] }

                // Matched blocks inside the stretch, as (old, new) pairs.
                let matched = Self.matches(oldCount: oldEnd - prefix, newCount: newEnd - prefix, maxEdits: Self.maxEdits) {
                    same(prefix + $0, prefix + $1)
                } ?? []
                var runs: [Run] = []
                var i = prefix, j = prefix
                for (x, y) in matched.map({ (prefix + $0.0, prefix + $0.1) }) + [(oldEnd, newEnd)] {
                    if i < x || j < y {
                        runs.append(Run(at: i, remove: x - i, blocks: after[j..<y].map {
                            String(decoding: UnsafeBufferPointer(rebasing: b[$0]), as: UTF8.self)
                        }))
                    }
                    i = x + 1
                    j = y + 1
                }
                return runs
            }
        }
        count = before.count
        language = new.rendered.language
    }

    /// The pairs of equal elements of two sequences, in order, by Myers'
    /// O((N+M)D) algorithm; nil when they differ by more than `maxEdits`
    /// insertions and deletions.
    static func matches(oldCount n: Int, newCount m: Int, maxEdits: Int, same: (Int, Int) -> Bool) -> [(Int, Int)]? {
        let limit = min(maxEdits, n + m)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        for d in 0...limit {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, same(x, y) {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                guard x >= n, y >= m else { continue }
                // Back from the end along the path, collecting its diagonals.
                var pairs: [(Int, Int)] = []
                var (px, py) = (n, m)
                for step in stride(from: d, through: 0, by: -1) {
                    let at = trace[step]
                    let kk = px - py
                    let previousK = kk == -step || (kk != step && at[offset + kk - 1] < at[offset + kk + 1]) ? kk + 1 : kk - 1
                    let previousX = at[offset + previousK]
                    let previousY = previousX - previousK
                    while px > previousX, py > previousY {
                        px -= 1
                        py -= 1
                        pairs.append((px, py))
                    }
                    if step > 0 {
                        px = previousX
                        py = previousY
                    }
                }
                return pairs.reversed()
            }
        }
        return nil
    }

    /// The same blocks: the new page differs only in what Swift keeps
    /// (its source lines and task lines).
    var isEmpty: Bool { runs.isEmpty }

    func argument(forPage nonce: String) -> [String: Any] {
        ["page": nonce, "count": count, "lang": language ?? "",
         "runs": runs.map { ["at": $0.at, "remove": $0.remove, "blocks": $0.blocks] as [String: Any] }]
    }
}

/// Starts WebKit's helper processes while the editor window opens on the
/// welcome screen or a session is restoring, so the first preview page
/// doesn't wait for them. A throwaway web view, released once a preview
/// has its own; never for a launch that only shows the menu bar.
enum PreviewWarmup {
    private static var webView: WKWebView?
    private static var isOver = false

    static func begin() {
        guard !isOver, webView == nil else { return }
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString("", baseURL: nil)
        self.webView = webView
    }

    /// A preview made its web view: warming up is pointless from here on.
    static func end() {
        isOver = true
        webView = nil
    }
}
