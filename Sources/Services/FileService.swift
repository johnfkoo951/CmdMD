import Foundation
import Yams

actor FileService {
    
    func loadDocument(from url: URL) async throws -> MarkdownDocument {
        try loadDocumentWithText(from: url).document
    }

    /// Loads a document together with the text it was parsed from (decoded,
    /// LF line breaks, no byte order mark), in one read. The file watcher and
    /// the save-conflict check compare it with what the app last wrote; the
    /// document's `fullText` is that same text until the user edits it.
    func loadDocumentWithText(from url: URL) throws -> (document: MarkdownDocument, text: String) {
        let data = try Data(contentsOf: url)
        let decoded = try Self.decodeText(data, declaredEncoding: Self.declaredEncoding(of: url), fileName: url.lastPathComponent)
        let (content, lineEnding) = Self.normalizingLineEndings(decoded.text)
        let parsed = Self.parseFrontmatter(from: content)
        let frontmatter = parsed.frontmatter
        let body = parsed.body
        
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let createdAt = attributes[.creationDate] as? Date ?? Date()
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
        
        let document = MarkdownDocument(
            title: frontmatter?.title ?? url.deletingPathExtension().lastPathComponent,
            content: body,
            fileURL: url,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            frontmatter: frontmatter,
            frontmatterSource: parsed.source,
            fileFormat: TextFileFormat(encoding: decoded.encoding, lineEnding: lineEnding, hasByteOrderMark: decoded.hasByteOrderMark)
        )
        return (document, content)
    }
    
    func saveDocument(_ document: MarkdownDocument, to url: URL) async throws {
        // Writes `fullText` so the frontmatter block is never stripped on
        // save, in the file's own encoding, line breaks and BOM.
        try Self.writeText(document.fullText, to: url, format: document.fileFormat ?? .standard, fileName: url.lastPathComponent)
    }

    /// Writes `text` to `url` in `format`, keeping the file's metadata (see
    /// `replaceContents(of:with:)`).
    static func writeText(_ text: String, to url: URL, format: TextFileFormat = .standard, fileName: String? = nil) throws {
        try replaceContents(of: url, with: encodedData(text, format: format, fileName: fileName ?? url.lastPathComponent))
    }

    /// Replaces a file's contents the way a document save should. The bytes go
    /// to a temporary file that `replaceItemAt` swaps in, which keeps the
    /// file's creation date, Finder tags and other extended attributes, and
    /// permissions; a plain atomic write replaced all of them. A symlink is
    /// followed, so its target is updated instead of the link turning into a
    /// diverging copy, and a read-only file is reported instead of overwritten.
    static func replaceContents(of url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: target.path) else {
            try data.write(to: target, options: .atomic)
            return
        }
        guard fileManager.isWritableFile(atPath: target.path) else {
            throw TextFileError.readOnly(fileName: target.lastPathComponent)
        }
        guard let scratch = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: target, create: true) else {
            // No replacement directory on this volume: the old atomic write.
            try data.write(to: target, options: .atomic)
            return
        }
        defer { try? fileManager.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(target.lastPathComponent)
        try data.write(to: temporary)
        _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
    }

    // MARK: - Encodings and line breaks

    /// Decodes a text file without guessing. A byte order mark names the
    /// encoding; otherwise the data must be valid UTF-8, the encoding the file
    /// declares (com.apple.TextEncoding), or unmistakably Korean CP949/EUC-KR.
    /// NUL bytes mean a binary file, which is refused: the old fallbacks read
    /// almost anything as UTF-16 or Latin-1, and a save then wrote that
    /// garbage back as UTF-8.
    static func decodeText(_ data: Data, declaredEncoding: String.Encoding? = nil, fileName: String) throws
        -> (text: String, encoding: String.Encoding, hasByteOrderMark: Bool) {
        let bytes = [UInt8](data.prefix(4))
        let marked: [(mark: [UInt8], encoding: String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        if let bom = marked.first(where: { bytes.starts(with: $0.mark) }) {
            guard let text = String(data: data.dropFirst(bom.mark.count), encoding: bom.encoding),
                  !text.contains("\u{0}") else {
                throw TextFileError.unreadableEncoding(fileName: fileName)
            }
            return (text, bom.encoding, true)
        }
        // A legacy encoding only when bytes round-trip through it unchanged,
        // so a save writes back exactly what was read.
        func roundTrip(_ encoding: String.Encoding) -> String? {
            guard let text = String(data: data, encoding: encoding),
                  text.data(using: encoding, allowLossyConversion: false) == data else { return nil }
            return text
        }
        // UTF-16/32 without a byte-order mark is full of NUL bytes, so the
        // binary test below refused it; a declared encoding (TextEdit writes
        // com.apple.TextEncoding) that round-trips vouches for it first.
        let wideEncodings: [String.Encoding] = [.utf16, .utf16LittleEndian, .utf16BigEndian,
                                                .utf32, .utf32LittleEndian, .utf32BigEndian]
        if let declared = declaredEncoding, wideEncodings.contains(declared),
           let text = roundTrip(declared), !text.contains("\u{0}") {
            return (text, declared, false)
        }
        let isBinary = data.withUnsafeBytes { memchr($0.baseAddress, 0, $0.count) != nil }
        if isBinary {
            throw TextFileError.binary(fileName: fileName)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8, false)
        }
        if let declared = declaredEncoding, declared != .utf8, let text = roundTrip(declared) {
            return (text, declared, false)
        }
        if let text = roundTrip(cp949), isKorean(text, bytes: data) {
            return (text, cp949, false)
        }
        throw TextFileError.unreadableEncoding(fileName: fileName)
    }

    /// Korean Windows code page 949, a superset of EUC-KR.
    static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    /// Whether CP949-decoded text is really Korean rather than other 8-bit text
    /// that happens to decode (German "Ärger" does): most of its non-ASCII
    /// characters are Hangul, and nearly all of its two-byte characters use
    /// the EUC-KR range, where both bytes are 0xA1 or above.
    private static func isKorean(_ text: String, bytes data: Data) -> Bool {
        var nonASCII = 0, hangul = 0
        for scalar in text.unicodeScalars where scalar.value >= 0x80 {
            nonASCII += 1
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            default: break
            }
        }
        var eucPairs = 0, otherPairs = 0
        var index = data.startIndex
        while index < data.endIndex {
            guard data[index] >= 0x80 else { index += 1; continue }
            let next = data.index(after: index)
            if next < data.endIndex, data[next] >= 0xA1 { eucPairs += 1 } else { otherPairs += 1 }
            index = data.index(next, offsetBy: 1, limitedBy: data.endIndex) ?? data.endIndex
        }
        return hangul * 2 >= nonASCII && otherPairs * 10 <= eucPairs
    }

    /// The encoding a file declares in its com.apple.TextEncoding extended
    /// attribute (TextEdit writes it), such as "x-mac-korean;3".
    static func declaredEncoding(of url: URL) -> String.Encoding? {
        let name = "com.apple.TextEncoding"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0, size < 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, 0) == size,
              let value = String(bytes: buffer, encoding: .utf8) else { return nil }
        let parts = value.split(separator: ";")
        var cfEncoding = kCFStringEncodingInvalidId
        if parts.count > 1, let number = UInt32(parts[1].trimmingCharacters(in: .whitespaces)) {
            cfEncoding = number
        } else if let charset = parts.first {
            cfEncoding = CFStringConvertIANACharSetNameToEncoding(String(charset) as CFString)
        }
        guard cfEncoding != kCFStringEncodingInvalidId, CFStringIsEncodingAvailable(cfEncoding) else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// The text with CRLF and CR line breaks turned into LF, which the editor,
    /// the renderer and the frontmatter parser all count on, and the style the
    /// file mostly used, which a save restores.
    static func normalizingLineEndings(_ text: String) -> (text: String, lineEnding: TextFileFormat.LineEnding) {
        var crlf = 0, cr = 0, lf = 0
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
            } else if byte == 0x0D {
                cr += 1
            }
            previousWasCR = byte == 0x0D
        }
        guard crlf + cr > 0 else { return (text, .lf) }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if crlf >= lf && crlf >= cr { return (normalized, .crlf) }
        return (normalized, cr > lf ? .cr : .lf)
    }

    /// `text` as the bytes of a file in `format`. Fails, rather than writing
    /// "?" in their place, when the encoding can't represent every character.
    static func encodedData(_ text: String, format: TextFileFormat, fileName: String) throws -> Data {
        // Normalized in every case: a CR/CRLF that reached the text (a paste,
        // a drop) made an LF file mixed.
        var text = normalizingLineEndings(text).text
        if format.lineEnding != .lf {
            text = text.replacingOccurrences(of: "\n", with: format.lineEnding == .crlf ? "\r\n" : "\r")
        }
        let encoding = format.stringEncoding
        guard var data = text.data(using: encoding, allowLossyConversion: false) else {
            throw TextFileError.unrepresentable(fileName: fileName, encoding: String.localizedName(of: encoding))
        }
        if format.hasByteOrderMark {
            switch encoding {
            case .utf8: data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
            case .utf16LittleEndian: data.insert(contentsOf: [0xFF, 0xFE], at: 0)
            case .utf16BigEndian: data.insert(contentsOf: [0xFE, 0xFF], at: 0)
            case .utf32LittleEndian: data.insert(contentsOf: [0xFF, 0xFE, 0x00, 0x00], at: 0)
            case .utf32BigEndian: data.insert(contentsOf: [0x00, 0x00, 0xFE, 0xFF], at: 0)
            default: break
            }
        }
        return data
    }
    
    func watchFile(at url: URL, onChange: @escaping (URL) -> Void) -> DispatchSourceFileSystemObject? {
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return nil }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        
        source.setEventHandler {
            onChange(url)
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        return source
    }
    
    // MARK: - Frontmatter

    /// Frontmatter YAML past this size is kept as text without being parsed.
    static let maxFrontmatterBytes = 256 * 1024

    /// Splits a note (LF line breaks, no byte order mark) into its frontmatter
    /// block and body. A block between `---` fences is kept verbatim in
    /// `source` even when it isn't valid YAML or can't be read as properties
    /// (frontmatter nil then): returning just the body deleted it on save.
    static func parseFrontmatter(from content: String) -> (frontmatter: Frontmatter?, source: FrontmatterSource?, body: String) {
        guard let block = frontmatterBlock(in: content) else {
            return (nil, nil, content)
        }
        let yaml = String(content[block.yaml])
        let source = FrontmatterSource(
            opening: String(content[..<block.yaml.lowerBound]),
            yaml: yaml,
            closing: String(content[block.yaml.upperBound..<block.bodyStart]),
            parsed: properties(fromYAML: yaml)
        )
        return (source.parsed, source, String(content[block.bodyStart...]))
    }

    /// Where a note's (LF line breaks, no byte order mark) frontmatter block
    /// is: the YAML between its `---` fences, and where the body starts; nil
    /// when it has none. Search numbers its hits from `bodyStart`, as the
    /// editor numbers lines, and a send splits a template's block off with it.
    static func frontmatterBlock(in content: String) -> (yaml: Range<String.Index>, bodyStart: String.Index)? {
        let utf8 = content.utf8
        guard content.hasPrefix("---"), let openingEnd = utf8.firstIndex(of: 0x0A),
              content[..<openingEnd].trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        let yamlStart = utf8.index(after: openingEnd)
        var lineStart = yamlStart
        var closingFence: Range<String.Index>?
        while lineStart < utf8.endIndex {
            let lineEnd = utf8[lineStart...].firstIndex(of: 0x0A) ?? utf8.endIndex
            let line = content[lineStart..<lineEnd]
            // Trim so a closing fence with trailing whitespace ("--- ") still
            // matches. It starts the line: an indented `---` is YAML text (a
            // line of a `|` block), not the end of the block.
            if let first = line.first, first == "-" || first == ".",
               ["---", "..."].contains(line.trimmingCharacters(in: .whitespaces)) {
                closingFence = lineStart..<lineEnd
                break
            }
            lineStart = lineEnd == utf8.endIndex ? lineEnd : utf8.index(after: lineEnd)
        }
        guard let closingFence else {
            return nil
        }

        // The fence's line break and one blank line after it belong to the
        // block, so the body starts at the text and saving adds nothing.
        var bodyStart = closingFence.upperBound
        if bodyStart < utf8.endIndex {
            bodyStart = utf8.index(after: bodyStart)
            if bodyStart < utf8.endIndex, utf8[bodyStart] == 0x0A {
                bodyStart = utf8.index(after: bodyStart)
            }
        }
        return (yamlStart..<closingFence.lowerBound, bodyStart)
    }

    /// The properties in a frontmatter block's YAML, or nil when it can't be
    /// read as properties both safely and exactly: invalid YAML, not a map,
    /// over the size limit, anchors used with aliases, or lines other than
    /// plain `key: value` entries (an edit rewrites a key's own lines).
    static func properties(fromYAML yaml: String) -> Frontmatter? {
        guard yaml.utf8.count <= maxFrontmatterBytes, !mayExpandAliases(yaml),
              let spans = FrontmatterSource.keySpans(in: FrontmatterSource.lines(of: yaml)) else { return nil }
        let keys = spans.map(\.key)
        return onLargeStack {
            // `compose` only builds nodes. Yams' Swift-value constructor
            // force-unwraps a key that is a map (`created: {{date}}` from
            // Obsidian's Templates crashed the app) and overflows on a long
            // `1:00:00:…` number, and both traps take the app down.
            let root: Node?
            do {
                root = try Yams.compose(yaml: yaml)
            } catch {
                return nil
            }
            guard let root else { return keys.isEmpty ? Frontmatter() : nil }
            guard case .mapping(let mapping) = root else { return nil }
            var frontmatter = Frontmatter()
            var composedKeys: [String] = []
            for (keyNode, value) in mapping {
                guard case .scalar(let key) = keyNode else { return nil }
                composedKeys.append(key.string)
                assign(value, forKey: key.string, to: &frontmatter)
            }
            return composedKeys == keys ? frontmatter : nil
        }
    }

    private static func assign(_ value: Node, forKey key: String, to frontmatter: inout Frontmatter) {
        switch key {
        case "title": frontmatter.title = text(of: value)
        // Bare dates and full timestamps; anything else stays in the text.
        case "date": frontmatter.date = text(of: value).flatMap(parseDate)
        case "tags": frontmatter.tags = strings(in: value, splittingCommas: true)
        case "aliases": frontmatter.aliases = strings(in: value, splittingCommas: false)
        case "cssclass": frontmatter.cssclass = text(of: value)
        default:
            // Preserve ALL unknown keys with their original YAML type instead
            // of dropping bools/doubles/lists. A nested map is left out: it
            // stays in the block's text, untouched.
            if let typed = FrontmatterValue(node: value) {
                frontmatter.custom[key] = typed
            }
        }
    }

    /// A scalar's text; nil for an empty value, a map or a list.
    private static func text(of node: Node) -> String? {
        guard case .scalar(let scalar) = node, !FrontmatterValue.isNull(scalar) else { return nil }
        return scalar.string
    }

    /// A list's items (numbers included), or one value as a list: split on
    /// commas for tags.
    private static func strings(in node: Node, splittingCommas: Bool) -> [String] {
        if case .sequence = node {
            guard case .list(let items) = FrontmatterValue(node: node) else { return [] }
            return items.filter { !$0.isEmpty }
        }
        guard let text = text(of: node) else { return [] }
        guard splittingCommas else { return [text] }
        return text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether YAML may use an anchor (`&a`) together with an alias (`*a`).
    /// Expanding them can take exponential time and memory (a "billion laughs"
    /// block is a few hundred bytes), and Yams expands them even to check a
    /// map for duplicate keys, so such a block isn't parsed. Errs towards yes:
    /// any `&` or `*` that starts a word counts.
    static func mayExpandAliases(_ yaml: String) -> Bool {
        var anchor = false, alias = false
        var previous = UInt8(ascii: "\n")
        for byte in yaml.utf8 {
            if byte == UInt8(ascii: "&") || byte == UInt8(ascii: "*"),
               " \t\n[{,:-?".utf8.contains(previous) {
                if byte == UInt8(ascii: "&") { anchor = true } else { alias = true }
            }
            previous = byte
        }
        return anchor && alias
    }

    private final class ParseResult: @unchecked Sendable {
        var value: Frontmatter?
    }

    /// Runs `work` on a thread with a 16 MB stack and waits for it. Composing
    /// YAML recurses once per nesting level (libyaml allows 1000), which
    /// overflows the 512 KB stack of a concurrency thread a few hundred
    /// levels in.
    private static func onLargeStack(_ work: @escaping @Sendable () -> Frontmatter?) -> Frontmatter? {
        let result = ParseResult()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.value = work()
            done.signal()
        }
        thread.stackSize = 16 << 20
        // Someone is waiting on the open; don't let the wait outrank the work.
        thread.qualityOfService = .userInitiated
        thread.start()
        done.wait()
        return result.value
    }

    /// Parses a frontmatter date string, accepting both a bare date and a full
    /// ISO-8601 timestamp.
    private static func parseDate(_ string: String) -> Date? {
        let fullDate = ISO8601DateFormatter()
        fullDate.formatOptions = [.withFullDate]
        if let date = fullDate.date(from: string) { return date }

        let dateTime = ISO8601DateFormatter()
        dateTime.formatOptions = [.withInternetDateTime]
        if let date = dateTime.date(from: string) { return date }

        return nil
    }
}

/// Why a file couldn't be read or written as text, worded for the alert.
enum TextFileError: LocalizedError, Equatable {
    case binary(fileName: String)
    case unreadableEncoding(fileName: String)
    case unrepresentable(fileName: String, encoding: String)
    case readOnly(fileName: String)

    var errorDescription: String? {
        switch self {
        case .binary(let fileName):
            return "\u{201C}\(fileName)\u{201D} isn't a text file."
        case .unreadableEncoding(let fileName):
            return "\u{201C}\(fileName)\u{201D} isn't UTF-8 text, and its encoding couldn't be recognized for sure, so it wasn't opened."
        case .unrepresentable(let fileName, let encoding):
            return "\u{201C}\(fileName)\u{201D} is stored as \(encoding), which can't hold some of its characters. Use Save As\u{2026} to save a UTF-8 copy."
        case .readOnly(let fileName):
            return "\u{201C}\(fileName)\u{201D} is read-only."
        }
    }
}
