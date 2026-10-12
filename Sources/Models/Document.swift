import Foundation
import SwiftUI
import Yams

// MARK: - Document Model
struct MarkdownDocument: Identifiable, Equatable, Codable {
    let id: UUID
    /// Declared before `content` on purpose: the synthesized `==` compares in
    /// declaration order, SwiftUI runs it on every render of each view that
    /// takes a document, and every edit stamps this. A keystroke's comparison
    /// then stops here instead of walking the whole body, which is slow on
    /// text bridged from NSTextView.
    var modifiedAt: Date
    var title: String
    var content: String
    var fileURL: URL?
    var createdAt: Date
    var frontmatter: Frontmatter?
    var isDraft: Bool
    var sourceDevice: String?
    /// The frontmatter block exactly as the file had it (nil when there was
    /// none, or for a document not read from a file).
    var frontmatterSource: FrontmatterSource?
    /// How the file stores its text; nil is UTF-8 with LF line breaks.
    var fileFormat: TextFileFormat?

    init(
        id: UUID = UUID(),
        title: String = "Untitled",
        content: String = "",
        fileURL: URL? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        frontmatter: Frontmatter? = nil,
        isDraft: Bool = false,
        sourceDevice: String? = nil,
        frontmatterSource: FrontmatterSource? = nil,
        fileFormat: TextFileFormat? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.frontmatter = frontmatter
        self.isDraft = isDraft
        self.sourceDevice = sourceDevice
        self.frontmatterSource = frontmatterSource
        self.fileFormat = fileFormat
    }

    /// Lines searched for a title heading. This runs on every keystroke in an
    /// untitled tab, so it must not walk (or split) a whole long document.
    private static let titleScanLineLimit = 1000

    /// The title shown for the document and given to the files made from it
    /// (Send, Save As, Export): its properties' title, else its file name,
    /// else a title it was given, else one read from its text. Worked out
    /// from the document as it is now: a title stored when it was opened
    /// stayed behind after a Save As or a Properties edit, and every ⌘N
    /// draft was sent as "Untitled Draft" whatever had been typed into it.
    var displayTitle: String {
        ownTitle ?? (isDraft ? "Untitled Draft" : "Untitled")
    }

    /// `displayTitle` when the document has a title at all; nil when it would
    /// only be the "Untitled" placeholder, which isn't one to keep.
    var ownTitle: String? {
        if let title = frontmatter?.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let url = fileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        if !title.isEmpty && title != "Untitled" {
            return title
        }
        return Self.contentTitle(of: content, firstLine: isDraft)
    }

    /// The title `text` gives itself: its first `# ` heading near the top or,
    /// with `firstLine` (drafts), its first line of text without Markdown
    /// markers, cut to 50 characters. A leading `---` properties block and
    /// fenced code are skipped, so a draft isn't titled "---" and a `# comment`
    /// in a snippet isn't a heading. nil when there is none.
    static func contentTitle(of text: String, firstLine: Bool, skippingProperties: Bool = true) -> String? {
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        var linesLeft = titleScanLineLimit
        var inProperties = false, inFence = false
        while lineStart < utf8.endIndex, linesLeft > 0 {
            let lineEnd = utf8[lineStart...].firstIndex { $0 == 0x0A || $0 == 0x0D } ?? utf8.endIndex
            let line = text[lineStart..<lineEnd].drop { $0.isWhitespace }
            if inProperties {
                if isFence(line, "---") || isFence(line, "...") { inProperties = false }
            } else if skippingProperties, lineStart == utf8.startIndex, isFence(line, "---") {
                inProperties = true
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
            } else if !inFence {
                if firstLine {
                    let title = withoutLineMarkers(line)
                    if !title.allSatisfy({ "-*_=".contains($0) || $0.isWhitespace }) {
                        return String(title.trimmingCharacters(in: .whitespaces).prefix(50))
                    }
                } else if line.hasPrefix("# ") {
                    return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                }
            }
            guard lineEnd < utf8.endIndex else { break }
            lineStart = utf8.index(after: lineEnd)
            // CRLF is one line break.
            if utf8[lineEnd] == 0x0D, lineStart < utf8.endIndex, utf8[lineStart] == 0x0A {
                lineStart = utf8.index(after: lineStart)
            }
            linesLeft -= 1
        }
        // A `---` that never closes was a rule, not a properties block.
        return inProperties ? contentTitle(of: text, firstLine: firstLine, skippingProperties: false) : nil
    }

    /// Whether an unindented line is `fence` and nothing else.
    private static func isFence(_ line: Substring, _ fence: String) -> Bool {
        line.hasPrefix(fence) && line.dropFirst(fence.count).allSatisfy(\.isWhitespace)
    }

    /// `line` without the Markdown that opens it: heading `#`s, quote `>`,
    /// list bullets and numbers, and task boxes.
    private static func withoutLineMarkers(_ line: Substring) -> Substring {
        var rest = line
        while true {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            let hashes = rest.prefix { $0 == "#" }.count
            let digits = rest.prefix { $0.isASCII && $0.isNumber }.count
            let marker: Int
            if hashes > 0, hashes <= 6, rest.dropFirst(hashes).first?.isWhitespace ?? true {
                marker = hashes
            } else if rest.first == ">" {
                marker = 1
            } else if let first = rest.first, "-*+".contains(first), rest.dropFirst().first?.isWhitespace == true {
                marker = 1
            } else if digits > 0, digits <= 9, let next = rest.dropFirst(digits).first, next == "." || next == ")",
                      rest.dropFirst(digits + 1).first?.isWhitespace ?? true {
                marker = digits + 1
            } else if ["[ ]", "[x]", "[X]"].contains(where: { rest.hasPrefix($0) }), rest.dropFirst(3).first?.isWhitespace ?? true {
                marker = 3
            } else {
                return rest
            }
            rest = rest.dropFirst(marker)
        }
    }

    /// The complete on-disk representation: frontmatter block (if any) + body.
    /// `content` is kept body-only after parsing, so this is the single source of
    /// truth for what gets written to disk / exported / sent. We intentionally do
    /// NOT guard on `content.hasPrefix("---")`: a body legitimately starting with a
    /// `---` horizontal rule must not suppress the frontmatter block (that would
    /// silently drop the document's metadata on save).
    /// A block read from the file is written back as it was, with only the
    /// properties edited since then rewritten; re-serializing all of it
    /// rewrote dates, empty values, comments and key order on every save.
    var fullText: String {
        if let source = frontmatterSource {
            let block = source.text(for: frontmatter)
            // A closing fence at the very end of the file has no line break yet.
            return block.hasSuffix("\n") || content.isEmpty ? block + content : block + "\n" + content
        }
        guard let frontmatter = frontmatter else { return content }
        let yaml = frontmatter.toYAML()
        guard !yaml.isEmpty else { return content }
        return yaml + "\n\n" + content
    }

    /// `fullText.utf16.count` without assembling the full text, for the
    /// per-keystroke dirty check. `fullText` ends with the body, so only what
    /// precedes it is built, with a one-character stand-in for a non-empty
    /// body; whatever `fullText` writes before the body is counted as is.
    var fullTextUTF16Count: Int {
        guard !content.isEmpty else { return fullText.utf16.count }
        var shell = self
        shell.content = "x"
        return shell.fullText.utf16.count - 1 + content.utf16.count
    }

    /// A cheap stand-in for `content` as a SwiftUI change key (`.task(id:)`):
    /// keyed on the text itself, every render compared two whole bodies.
    /// Every content mutation stamps `modifiedAt`; the length backs it up.
    struct ContentRevision: Hashable {
        let id: UUID
        let modifiedAt: Date
        let length: Int
    }

    var contentRevision: ContentRevision {
        ContentRevision(id: id, modifiedAt: modifiedAt, length: content.utf16.count)
    }
}

// MARK: - Inline Tags

extension MarkdownDocument {
    /// Body of an inline `#tag`: Unicode letters (Obsidian accepts `#회의록`),
    /// marks, digits, `_`, `-` and `/`, with at least one letter so `#1984`
    /// stays text. Shared by the preview renderer and the editor highlighter.
    static let tagNamePattern = #"[\p{N}_/-]*\p{L}[\p{L}\p{M}\p{N}_/-]*"#

    /// Same `#tag` grammar as the preview renderer.
    private static let inlineTagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)#("# + tagNamePattern + ")"
    )
    private static let inlineCodePattern = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    /// Inline `#tags` in a body, skipping fenced code blocks and inline code
    /// spans so `#include` in a snippet is not a tag. A `# Heading` never
    /// matches: a tag can't start with a space.
    static func inlineTags(in content: String) -> [String] {
        var tags: [String] = []
        var inFence = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, line.contains("#") else { continue }
            // Mask code spans with a non-space placeholder, as the renderer
            // does, so neither their contents nor a `#word` glued to one count.
            let masked = inlineCodePattern.stringByReplacingMatches(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length),
                withTemplate: "\u{FFFC}"
            ) as NSString
            for match in inlineTagPattern.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)) {
                tags.append(masked.substring(with: match.range(at: 1)))
            }
        }
        return tags
    }

    /// Frontmatter tags plus inline `#tags`, without a leading '#' (the
    /// Inspector stores a typed "#tag" verbatim). Computed on demand for
    /// routing and tag harvesting, never on the typing path.
    var allTags: [String] {
        let declared = (frontmatter?.tags ?? []).map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        return declared + Self.inlineTags(in: content)
    }
}

// MARK: - Frontmatter Value (type-preserving for custom keys)

/// Preserves the original YAML type of a custom frontmatter value so that
/// booleans, numbers, and lists survive a parse -> edit -> serialize round-trip
/// instead of being flattened to strings or dropped (a data-loss bug against
/// Obsidian vaults). UI edits go through `edited(_:keeping:)`, which keeps the
/// type the value had; untouched keys keep their type.
enum FrontmatterValue: Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case list([String])

    /// Human-readable form used by the Properties editor.
    var displayString: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .list(let arr): return arr.joined(separator: ", ")
        }
    }

    /// Native value handed to Yams so it emits the correct YAML scalar/sequence.
    var yamlValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .list(let arr): return arr
        }
    }

    /// Build from a composed YAML node: a scalar, or a list of scalars. Nested
    /// maps and lists have no form here (nil); they stay in the file's text.
    /// Plain scalars are typed by the YAML 1.2 core rules, so `14:00`, `0123`,
    /// `yes` and dates stay the text they are instead of becoming 840, 83,
    /// true and a Swift `Date` description.
    init?(node: Node) {
        switch node {
        case .scalar(let scalar):
            self = Self.typed(scalar)
        case .sequence(let sequence):
            var items: [String] = []
            for item in sequence {
                guard case .scalar(let scalar) = item else { return nil }
                items.append(Self.isNull(scalar) ? "" : scalar.string)
            }
            self = .list(items)
        default:
            return nil
        }
    }

    /// An empty value, `~` or `null`, written without quotes.
    static func isNull(_ scalar: Node.Scalar) -> Bool {
        scalar.style == .plain && scalar.tag == .implicit
            && ["", "~", "null", "Null", "NULL"].contains(scalar.string)
    }

    private static func typed(_ scalar: Node.Scalar) -> FrontmatterValue {
        let text = scalar.string
        // Quoted, block and explicitly tagged scalars are text.
        guard scalar.style == .plain, scalar.tag == .implicit else { return .string(text) }
        if isNull(scalar) { return .string("") }
        switch text {
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if text.range(of: #"^[-+]?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil, let int = Int(text) {
            return .int(int)
        }
        if text.range(of: #"^[-+]?(\.[0-9]+|(0|[1-9][0-9]*)(\.[0-9]*)?)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil,
           let double = Double(text) {
            return .double(double)
        }
        return .string(text)
    }

    /// The value a property takes when its text is edited in the Inspector,
    /// in the type it had before (`original`): a list splits on commas, a
    /// bool or number parses, and text that doesn't fit the type is a string.
    /// Storing every edit as a string turned `[a, b]` into "a, b" and `true`
    /// into 'true'.
    static func edited(_ text: String, keeping original: FrontmatterValue?) -> FrontmatterValue {
        switch original {
        case .list:
            return .list(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        case .bool:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return .string(text)
            }
        case .int:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let int = Int(trimmed) { return .int(int) }
            if let double = Double(trimmed), double.isFinite { return .double(double) }
            return .string(text)
        case .double:
            if let double = Double(text.trimmingCharacters(in: .whitespaces)), double.isFinite { return .double(double) }
            return .string(text)
        case .string, nil:
            return .string(text)
        }
    }
}

// MARK: - Frontmatter
struct Frontmatter: Equatable, Codable {
    var title: String?
    var date: Date?
    var tags: [String]
    var aliases: [String]
    var cssclass: String?
    var custom: [String: FrontmatterValue]

    init(
        title: String? = nil,
        date: Date? = nil,
        tags: [String] = [],
        aliases: [String] = [],
        cssclass: String? = nil,
        custom: [String: FrontmatterValue] = [:]
    ) {
        self.title = title
        self.date = date
        self.tags = tags
        self.aliases = aliases
        self.cssclass = cssclass
        self.custom = custom
    }

    /// Keys with a typed field, in the order `toYAML` writes them.
    static let knownKeys = ["title", "date", "tags", "aliases", "cssclass"]

    /// Generate a `---`-delimited YAML block. Values are emitted through Yams so
    /// quoting/escaping is spec-correct (a stray quote no longer produces invalid
    /// YAML that wipes the whole block on reload). Keys are emitted in a stable
    /// order (known keys first, then custom keys sorted) for clean diffs.
    func toYAML() -> String {
        let keys = Self.knownKeys + custom.keys.filter { !Self.knownKeys.contains($0) }.sorted()
        let body = keys.compactMap { yamlEntry(forKey: $0) }.joined()
        guard !body.isEmpty else { return "" }
        let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
        return "---\n\(trimmed)\n---"
    }

    /// The `key: value` YAML line(s) for one property, ending in a line break;
    /// nil when it has no value (unset, or an empty title, list or class).
    /// A custom value under a known key's name is the one written.
    func yamlEntry(forKey key: String) -> String? {
        if let value = custom[key] { return Self.yamlEntry(key, value.yamlValue) }
        switch key {
        case "title": return title.flatMap { $0.isEmpty ? nil : Self.yamlEntry(key, $0) }
        // Unquoted, as Obsidian writes it: Yams quoted it as a string.
        case "date": return date.map { "date: \(Self.dateString($0))\n" }
        case "tags": return tags.isEmpty ? nil : Self.yamlEntry(key, tags)
        case "aliases": return aliases.isEmpty ? nil : Self.yamlEntry(key, aliases)
        case "cssclass": return cssclass.flatMap { $0.isEmpty ? nil : Self.yamlEntry(key, $0) }
        default: return nil
        }
    }

    /// Korean and other non-ASCII text is written as is (Yams escapes it to
    /// `\uXXXX` by default) and long values stay on one line.
    private static func yamlEntry(_ key: String, _ value: Any) -> String? {
        try? Yams.dump(object: [key: value], width: -1, allowUnicode: true)
    }

    /// The keys whose value differs between two versions of the properties,
    /// each with its new YAML (nil when the key is gone), known keys first.
    static func changedEntries(from old: Frontmatter, to new: Frontmatter) -> [(key: String, yaml: String?)] {
        let customKeys = Set(old.custom.keys).union(new.custom.keys).subtracting(knownKeys)
        return (knownKeys + customKeys.sorted()).compactMap { key in
            old.hasSameValue(as: new, forKey: key) ? nil : (key, new.yamlEntry(forKey: key))
        }
    }

    private func hasSameValue(as other: Frontmatter, forKey key: String) -> Bool {
        guard custom[key] == other.custom[key] else { return false }
        switch key {
        case "title": return title == other.title
        case "date": return date == other.date
        case "tags": return tags == other.tags
        case "aliases": return aliases == other.aliases
        case "cssclass": return cssclass == other.cssclass
        default: return true
        }
    }

    /// A frontmatter `date` is a calendar day held as midnight UTC, which is
    /// what a bare `2024-01-15` parses to and what `dateString` writes back.
    static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    /// `date`'s calendar day in `timeZone` (the user's by default) as such a
    /// value. Stamping `Date()` itself wrote yesterday's date for anything
    /// created before 09:00 in Korea.
    static func calendarDay(_ date: Date = Date(), in timeZone: TimeZone = .current) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? timeZone
        return utc.date(from: local.dateComponents([.year, .month, .day], from: date)) ?? date
    }

    /// Sets a property typed into Properties › Add property and returns the
    /// key it went under; nil when the key is empty or the date unreadable.
    /// A key the note has already is edited in its own type, and a built-in
    /// key in any case sets its field (tags and aliases are added to): as a
    /// custom key, `title` or `cssclass` hid the value the Inspector shows
    /// and edits. Other keys keep the case they were typed in.
    @discardableResult
    mutating func setProperty(_ key: String, to value: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespaces)
        let text = value.trimmingCharacters(in: .whitespaces)
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !key.isEmpty else { return nil }
        let known = key.lowercased()
        guard custom[key] == nil, Self.knownKeys.contains(known) else {
            let existing = custom[key] != nil ? key : custom.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame } ?? key
            custom[existing] = .edited(value, keeping: custom[existing])
            return existing
        }
        switch known {
        case "title": title = text.isEmpty ? nil : text
        case "cssclass": cssclass = text.isEmpty ? nil : text
        case "tags": for tag in items where !tags.contains(tag) { tags.append(tag) }
        case "aliases": for alias in items where !aliases.contains(alias) { aliases.append(alias) }
        default:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            guard let day = formatter.date(from: text) else { return nil }
            date = day
        }
        return known
    }
}

// MARK: - Frontmatter Source

/// A frontmatter block as the file had it. Saving writes it back byte for
/// byte (comments, key order, quoting, dates, nested values), and an edited
/// property rewrites only that key's lines. Re-serializing the whole block
/// turned `created: 2024-01-15` into `2024-01-15 00:00:00 +0000` and
/// `status:` into `<null>`, and dropped comments, on every save.
struct FrontmatterSource: Equatable, Codable {
    /// The opening `---` line with its line break.
    var opening: String
    /// The YAML between the fences; each line ends with "\n".
    var yaml: String
    /// The closing fence line, its line break and the one blank line after
    /// it, as far as the file has them.
    var closing: String
    /// What `yaml` parsed to; nil when it couldn't be read as properties
    /// (invalid YAML, not a mapping, or not plain `key: value` lines), and is
    /// then only ever written back as it is.
    var parsed: Frontmatter?

    var text: String { opening + yaml + closing }

    /// The block with `frontmatter`'s changes from `parsed` written into it:
    /// a changed key's lines are replaced, a removed key's lines dropped and a
    /// new key added at the end. Every other line stays as it was.
    func text(for frontmatter: Frontmatter?) -> String {
        guard let parsed, let frontmatter, frontmatter != parsed else { return text }
        var lines = Self.lines(of: yaml)
        guard let spans = Self.keySpans(in: lines) else { return text }
        var replacements: [(lines: Range<Int>, with: [String])] = []
        var added: [String] = []
        for change in Frontmatter.changedEntries(from: parsed, to: frontmatter) {
            let entry = change.yaml.map(Self.lines(of:)) ?? []
            if let span = spans.first(where: { $0.key == change.key }) {
                replacements.append((span.lines, entry))
            } else {
                added += entry
            }
        }
        // Bottom up, so the line numbers of the spans above stay valid.
        for replacement in replacements.sorted(by: { $0.lines.lowerBound > $1.lines.lowerBound }) {
            lines.replaceSubrange(replacement.lines, with: replacement.with)
        }
        lines += added
        return opening + lines.map { $0 + "\n" }.joined() + closing
    }

    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Each top-level key with the lines that hold it: its `key:` line and
    /// the indented or `- ` lines under it. Blank and comment lines between
    /// keys go with what follows. nil when a line doesn't fit that shape
    /// (flow style, complex or anchored keys...), so such a block is never
    /// patched by guesswork.
    static func keySpans(in lines: [String]) -> [(key: String, lines: Range<Int>)]? {
        var spans: [(key: String, lines: Range<Int>)] = []
        var current: (key: String, start: Int, end: Int)?
        for (index, line) in lines.enumerated() {
            let unindented = line.drop { $0 == " " || $0 == "\t" }
            if unindented.isEmpty { continue }
            // Column-0 comments stand alone. An indented '#' line is content of
            // the key above (a `|` block scalar's "# run twice"): skipping it
            // left it behind, inside the previous key's block, when that key
            // was removed or replaced.
            if unindented.hasPrefix("#"), unindented.startIndex == line.startIndex || current == nil { continue }
            if unindented.startIndex != line.startIndex || line == "-" || line.hasPrefix("- ") || line.hasPrefix("-\t") {
                guard current != nil else { return nil }
                current?.end = index + 1
            } else if let key = keyName(in: line) {
                if let current { spans.append((current.key, current.start..<current.end)) }
                current = (key, index, index + 1)
            } else {
                return nil
            }
        }
        if let current { spans.append((current.key, current.start..<current.end)) }
        return spans
    }

    /// The key of a `key: value` line at column 0, plain or quoted.
    static func keyName(in line: String) -> String? {
        guard let first = line.first else { return nil }
        var key = ""
        var rest: Substring
        switch first {
        case "'":
            // A doubled quote is a quote.
            var index = line.index(after: line.startIndex)
            while true {
                guard let quote = line[index...].firstIndex(of: "'") else { return nil }
                key += line[index..<quote]
                index = line.index(after: quote)
                guard index < line.endIndex, line[index] == "'" else { break }
                key += "'"
                index = line.index(after: index)
            }
            rest = line[index...]
        case "\"":
            let start = line.index(after: line.startIndex)
            guard let quote = line[start...].firstIndex(of: "\""), !line[start..<quote].contains("\\") else { return nil }
            key = String(line[start..<quote])
            rest = line[line.index(after: quote)...]
        default:
            // A plain key can't start with an indicator, and ends at the first
            // ": " (or a ":" ending the line); " #" before that is a comment.
            guard !"-?:,[]{}#&*!|>%@`".contains(first) else { return nil }
            var searchStart = line.startIndex
            while let colon = line[searchStart...].firstIndex(of: ":") {
                let next = line.index(after: colon)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" {
                    let name = line[..<colon]
                    guard !name.contains(" #"), !name.contains("\t#") else { return nil }
                    return name.trimmingCharacters(in: .whitespaces)
                }
                searchStart = next
            }
            return nil
        }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        guard rest.first == ":" else { return nil }
        let value = rest.dropFirst()
        guard value.isEmpty || value.first == " " || value.first == "\t" else { return nil }
        return key
    }
}

// MARK: - Text File Format

/// How a file stores its text, so saving writes it back the same way: in
/// its encoding, with its line breaks (in memory the text always uses LF)
/// and its byte order mark. Saving everything as UTF-8 with LF garbled legacy
/// Korean (CP949) notes and rewrote every line of a CRLF file.
struct TextFileFormat: Equatable, Codable {
    enum LineEnding: String, Codable {
        case lf, crlf, cr
    }

    /// A `String.Encoding` raw value.
    var encoding: UInt
    var lineEnding: LineEnding
    var hasByteOrderMark: Bool

    init(encoding: String.Encoding = .utf8, lineEnding: LineEnding = .lf, hasByteOrderMark: Bool = false) {
        self.encoding = encoding.rawValue
        self.lineEnding = lineEnding
        self.hasByteOrderMark = hasByteOrderMark
    }

    static let standard = TextFileFormat()

    var stringEncoding: String.Encoding { String.Encoding(rawValue: encoding) }

    /// This format in UTF-8, for writing a new copy of the file.
    var inUTF8: TextFileFormat {
        TextFileFormat(lineEnding: lineEnding, hasByteOrderMark: hasByteOrderMark && stringEncoding == .utf8)
    }
}

// MARK: - Draft (local-only, kept in drafts.json)
struct Draft: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var sourceDevice: String
    var tags: [String]
    var status: DraftStatus
    var attachments: [DraftAttachment]
    /// Properties added in the Inspector; a draft has no file to hold them.
    var frontmatter: Frontmatter?
    
    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceDevice: String = Host.current().localizedName ?? "Mac",
        tags: [String] = [],
        status: DraftStatus = .active,
        attachments: [DraftAttachment] = [],
        frontmatter: Frontmatter? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceDevice = sourceDevice
        self.tags = tags
        self.status = status
        self.attachments = attachments
        self.frontmatter = frontmatter
    }

    // Resilient decoding (like AppSettings): drafts are local-only, so a key
    // missing from an older or newer drafts.json must fall back to its default
    // rather than fail the draft.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        sourceDevice = try c.decodeIfPresent(String.self, forKey: .sourceDevice) ?? "Mac"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        // A status this version doesn't know reads as active, not as a lost draft.
        status = (try? c.decodeIfPresent(DraftStatus.self, forKey: .status)) ?? .active
        attachments = try c.decodeIfPresent([DraftAttachment].self, forKey: .attachments) ?? []
        // Properties that don't decode cost only themselves, not the draft.
        frontmatter = (try? c.decodeIfPresent(Frontmatter.self, forKey: .frontmatter)) ?? nil
    }
    
    /// The same title its open document shows (MarkdownDocument.displayTitle).
    /// Only the first lines are read: the sidebar row re-reads this on every
    /// keystroke, and splitting the whole body into lines made that O(n).
    var displayTitle: String {
        if let title = frontmatter?.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if !title.isEmpty {
            return title
        }
        return MarkdownDocument.contentTitle(of: body, firstLine: true) ?? "Untitled Draft"
    }
    
    // Convert to MarkdownDocument
    func toDocument() -> MarkdownDocument {
        MarkdownDocument(
            id: id,
            // Only a title of its own: the document reads one from its text
            // as it is edited. Storing displayTitle froze it at "Untitled
            // Draft", or at the raw "# Heading" line, for good.
            title: title,
            content: body,
            createdAt: createdAt,
            modifiedAt: updatedAt,
            frontmatter: frontmatter,
            isDraft: true,
            sourceDevice: sourceDevice
        )
    }
}

enum DraftStatus: String, Codable, CaseIterable {
    case active = "Active"
    case sent = "Sent"
    case archived = "Archived"
}

struct DraftAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    var filename: String
    var data: Data
    var mimeType: String
    
    init(id: UUID = UUID(), filename: String, data: Data, mimeType: String) {
        self.id = id
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
    }
}

