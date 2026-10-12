import Foundation

// MARK: - Reading Positions

/// Where each file was last read in the preview (its scroll offset), so a note
/// reopens where the user left off — after closing its tab, after a reload, or
/// after a relaunch. Least recently used first and capped, so the store (and
/// reading-positions.json) stays small however many notes pass through.
struct ReadingPositions: Equatable {
    struct Entry: Codable, Equatable {
        /// `ReadingPositions.key(for:)` of the document.
        var key: String
        /// The preview's `window.scrollY`, in CSS pixels.
        var offset: Double
    }

    /// A few hundred files: plenty for a review queue, tens of KB on disk.
    static let defaultCapacity = 300

    /// Least recently used first.
    private(set) var entries: [Entry] = []
    let capacity: Int

    /// Builds the store from persisted entries (oldest first). A repeated key
    /// keeps its latest offset, top-of-page and invalid offsets are dropped,
    /// and only the newest `capacity` entries survive.
    init(entries: [Entry] = [], capacity: Int = ReadingPositions.defaultCapacity) {
        self.capacity = max(1, capacity)
        var seen: Set<String> = []
        var newestFirst: [Entry] = []
        for entry in entries.reversed() where Self.isRestorable(entry.offset) {
            guard seen.insert(entry.key).inserted else { continue }
            newestFirst.append(entry)
            if newestFirst.count == self.capacity { break }
        }
        self.entries = newestFirst.reversed()
    }

    /// The key a document's position is filed under: its standardized path,
    /// or its id while it has no file (a draft keeps its id across launches).
    /// Not the document id of a file: every open mints a new one.
    static func key(for document: MarkdownDocument) -> String {
        document.fileURL?.standardizedFileURL.path ?? document.id.uuidString
    }

    func offset(forKey key: String) -> Double? {
        entries.last(where: { $0.key == key })?.offset
    }

    /// Makes `offset` the most recent position for `key`, evicting the least
    /// recently used entries beyond `capacity`. The top of the page is the
    /// default, so an offset of 0 just forgets the key. Returns whether the
    /// store changed (and needs saving).
    @discardableResult
    mutating func record(_ offset: Double, forKey key: String) -> Bool {
        let offset = offset.rounded()
        let index = entries.lastIndex(where: { $0.key == key })
        guard Self.isRestorable(offset) else {
            guard let index else { return false }
            entries.remove(at: index)
            return true
        }
        if let index {
            if index == entries.count - 1 && entries[index].offset == offset { return false }
            entries.remove(at: index)
        }
        entries.append(Entry(key: key, offset: offset))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        return true
    }

    private static func isRestorable(_ offset: Double) -> Bool {
        offset.isFinite && offset > 0
    }
}
