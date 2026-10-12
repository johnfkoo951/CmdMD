import Foundation

// MARK: - Completion Types

struct CompletionItem: Identifiable, Equatable {
    let id = UUID()
    /// Raw value inserted into the document (note title or tag name).
    let text: String
    let displayText: String
    let detail: String?
    let type: CompletionContext.Kind
}

struct CompletionContext: Equatable {
    enum Kind {
        case wikiLink
        case tag
    }

    let type: Kind
    let query: String
    /// UTF-16 range in the document from the trigger ("[[" or "#") through the
    /// caret (see `closesExistingLink`). Replaced wholesale when a completion
    /// is accepted.
    let range: NSRange
    /// Wiki links only: the caret sits inside an existing "[[…]]". `range` then
    /// also covers the rest of the link target, and the link's own "|alias",
    /// "#heading" suffix and closing "]]" are kept instead of duplicated.
    var closesExistingLink = false

    /// The full text to insert when `item` is accepted.
    func replacement(for item: CompletionItem) -> String {
        switch type {
        case .wikiLink: return closesExistingLink ? "[[\(item.text)" : "[[\(item.text)]]"
        case .tag: return "#\(item.text) "
        }
    }

    /// Caret location once the replacement for `item` is in `text` (the updated
    /// document): right after the inserted text, or after the link's closing
    /// "]]" when completing inside an existing link — the same place a freshly
    /// completed link leaves it.
    func caretLocation(afterAccepting item: CompletionItem, in text: NSString) -> Int {
        let end = range.location + (replacement(for: item) as NSString).length
        guard closesExistingLink, end <= text.length else { return end }
        let lineEnd = NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0)))
        let close = text.range(of: "]]", options: [], range: NSRange(location: end, length: lineEnd - end))
        return close.location == NSNotFound ? end : NSMaxRange(close)
    }
}

// MARK: - Completion Engine

/// Stateless completion logic. All offsets are UTF-16 (NSRange's unit) — the
/// previous implementation mixed grapheme-cluster counts with NSRange, which
/// corrupted replacements in documents containing emoji or Korean text.
enum CompletionService {
    static let maxResults = 12
    /// Characters that end a wiki-link target ("[[Note|alias]]", "[[Note#Heading]]").
    private static let linkTargetTerminators = CharacterSet(charactersIn: "|#^")

    /// Detects whether the caret sits inside an unclosed "[[…" or "#…" run on
    /// the current line.
    static func detectContext(in text: NSString, cursorLocation: Int) -> CompletionContext? {
        guard cursorLocation > 0, cursorLocation <= text.length else { return nil }

        let lineRange = text.lineRange(for: NSRange(location: min(cursorLocation, max(0, text.length - 1)), length: 0))
        let lineStart = lineRange.location
        guard cursorLocation >= lineStart else { return nil }
        let searchRange = NSRange(location: lineStart, length: cursorLocation - lineStart)

        // Wiki link: last "[[" before the caret with no closing "]]" after it.
        let wikiOpen = text.range(of: "[[", options: .backwards, range: searchRange)
        if wikiOpen.location != NSNotFound {
            let queryStart = wikiOpen.location + 2
            let queryRange = NSRange(location: queryStart, length: cursorLocation - queryStart)
            let query = text.substring(with: queryRange)
            if !query.contains("]]") {
                // Editing inside an existing link ("[[Proj‸ct Plan]]", caret at
                // ‸): when a "]]" follows on this line with no other "[[" before
                // it, replace the whole target up to that link's "|", "#", "^"
                // or "]]".
                var end = cursorLocation
                var closesExistingLink = false
                let rest = NSRange(location: cursorLocation, length: NSMaxRange(lineRange) - cursorLocation)
                let close = text.range(of: "]]", options: [], range: rest)
                if close.location != NSNotFound {
                    let target = NSRange(location: cursorLocation, length: close.location - cursorLocation)
                    if text.range(of: "[[", options: [], range: target).location == NSNotFound {
                        closesExistingLink = true
                        let suffix = text.rangeOfCharacter(from: Self.linkTargetTerminators, options: [], range: target)
                        end = suffix.location != NSNotFound ? suffix.location : close.location
                    }
                }
                return CompletionContext(
                    type: .wikiLink,
                    query: query,
                    range: NSRange(location: wikiOpen.location, length: end - wikiOpen.location),
                    closesExistingLink: closesExistingLink
                )
            }
        }

        // Tag: "#" preceded by start-of-line/whitespace, no whitespace after it.
        let hash = text.range(of: "#", options: .backwards, range: searchRange)
        if hash.location != NSNotFound {
            let validStart: Bool
            if hash.location == lineStart {
                validStart = true
            } else {
                let before = text.character(at: hash.location - 1)
                validStart = before == 0x20 || before == 0x09 // space or tab
            }

            if validStart {
                let queryStart = hash.location + 1
                let query = text.substring(with: NSRange(location: queryStart, length: cursorLocation - queryStart))
                if !query.contains(" ") && !query.contains("\t") && !query.contains("#") {
                    return CompletionContext(
                        type: .tag,
                        query: query,
                        range: NSRange(location: hash.location, length: cursorLocation - hash.location)
                    )
                }
            }
        }

        return nil
    }

    static func completions(for context: CompletionContext, notes: [VaultNote], tags: Set<String>) -> [CompletionItem] {
        switch context.type {
        case .wikiLink:
            return wikiLinkCompletions(query: context.query, notes: notes)
        case .tag:
            return tagCompletions(query: context.query, tags: tags)
        }
    }

    /// Runs on the main thread for every keystroke after "[[", over the whole
    /// index — so it matches the notes' precomputed keys and keeps a bounded,
    /// ranked top list instead of lowercasing and sorting every match.
    /// Rank: title prefix, then title substring, then path-only match; newest
    /// first within a rank. A bare "[[" therefore lists the most recent notes.
    private static func wikiLinkCompletions(query: String, notes: [VaultNote]) -> [CompletionItem] {
        let key = VaultNote.searchKey(for: query)

        // Positions in `notes`: the loop reads fields in place instead of
        // copying (and retaining) a whole VaultNote per entry.
        var top: [(index: Int, rank: Int)] = []
        top.reserveCapacity(maxResults + 1)
        func ranksBefore(_ lhs: (index: Int, rank: Int), _ rhs: (index: Int, rank: Int)) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return notes[lhs.index].modifiedAt > notes[rhs.index].modifiedAt
        }

        for index in notes.indices {
            // Once the list is full, skip the substring searches that could only
            // produce a rank worse than its last entry.
            let worstUseful = top.count == maxResults ? top[maxResults - 1].rank : 2
            let rank: Int
            if notes[index].titleKey.starts(with: key) {
                rank = 0
            } else if worstUseful >= 1, bytes(notes[index].titleKey, contain: key) {
                rank = 1
            } else if worstUseful >= 2, bytes(notes[index].pathKey, contain: key) {
                rank = 2
            } else {
                continue
            }

            let candidate = (index: index, rank: rank)
            if top.count == maxResults, !ranksBefore(candidate, top[maxResults - 1]) { continue }
            top.insert(candidate, at: top.firstIndex { ranksBefore(candidate, $0) } ?? top.count)
            if top.count > maxResults { top.removeLast() }
        }

        return top.map {
            let note = notes[$0.index]
            return CompletionItem(text: note.title, displayText: note.title, detail: note.path, type: .wikiLink)
        }
    }

    /// Substring test over UTF-8 match keys (both sides from `VaultNote.searchKey`).
    private static func bytes(_ haystack: [UInt8], contain needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil
            }
        }
    }

    private static func tagCompletions(query: String, tags: Set<String>) -> [CompletionItem] {
        let lowered = query.lowercased()

        return tags
            .filter { lowered.isEmpty || $0.lowercased().contains(lowered) }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.lowercased().hasPrefix(lowered)
                let rhsPrefix = rhs.lowercased().hasPrefix(lowered)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs < rhs
            }
            .prefix(maxResults)
            .map { CompletionItem(text: $0, displayText: "#\($0)", detail: nil, type: .tag) }
    }
}
