import Foundation

/// Defense-in-depth cleanup for raw HTML that a note passes through to the
/// preview (the renderer's own wiki-link / callout / tag markup takes the same
/// path). The page's Content-Security-Policy is the primary control; this
/// strips what would run script if that policy were missing or bypassed:
/// `<script>` elements, `on*` handler attributes, `srcdoc`, javascript: /
/// vbscript: values and non-image data: URLs, `<meta>` (refresh), `<base>`,
/// plugin elements and comments.
///
/// Tags are tokenized the way the HTML tokenizer does it (a quoted value may
/// hold `>`, `/` separates attributes) and every tag is re-emitted normalized:
/// double-quoted values with `"`, `<` and `>` escaped. Each raw node is cleaned
/// on its own, so the output must never leave the browser inside a tag,
/// comment or raw-text element — an unterminated quote or `<style>` in one
/// node would otherwise swallow the markup after it and turn it into
/// attributes. Anything that does not close inside the node is escaped to
/// text instead.
enum RawHTMLSanitizer {
    /// Elements removed outright (the tag only; `<script>` with its content).
    private static let droppedElements: Set<String> = ["script", "meta", "base", "object", "embed", "applet"]
    /// Elements whose content the browser reads as text up to their end tag.
    private static let rawTextElements: Set<String> = [
        "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript"
    ]
    /// Attributes holding a URL the browser loads or navigates to.
    private static let urlAttributes: Set<String> = [
        "href", "src", "xlink:href", "action", "formaction", "data", "poster", "background", "srcset", "ping"
    ]
    /// SVG animation values, which can retarget a link's href.
    private static let animationValueAttributes: Set<String> = ["values", "to", "from", "by"]

    private static let lessThan = UInt8(ascii: "<")
    private static let greaterThan = UInt8(ascii: ">")
    private static let slash = UInt8(ascii: "/")
    private static let equals = UInt8(ascii: "=")
    private static let dash = UInt8(ascii: "-")
    private static let bang = UInt8(ascii: "!")
    private static let escapedLessThan = Array("&lt;".utf8)

    private struct Tag {
        var name: String
        var attributes: [(name: String, value: String?)]
        var selfClosing: Bool
        /// Index just past the closing `>`.
        var end: Int
    }

    static func sanitize(_ html: String) -> String {
        guard html.utf8.contains(lessThan) else { return html }
        let bytes = Array(html.utf8)
        let count = bytes.count
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var i = 0

        while i < count {
            guard bytes[i] == lessThan else {
                out.append(bytes[i])
                i += 1
                continue
            }
            let next: UInt8? = i + 1 < count ? bytes[i + 1] : nil

            // Comments, doctypes, CDATA, processing instructions: invisible
            // anyway, and dropping the opener means the browser can never end
            // one somewhere other than where this scanner did.
            if next == bang || next == UInt8(ascii: "?") {
                if let end = endOfMarkupDeclaration(bytes, from: i) {
                    i = end
                } else {
                    out += escapedLessThan
                    i += 1
                }
                continue
            }

            if next == slash {
                if i + 2 < count, isASCIILetter(bytes[i + 2]) {
                    if let tag = parseTag(bytes, nameStart: i + 2) {
                        let name = tag.name.lowercased()
                        if isValidName(tag.name), !droppedElements.contains(name) {
                            out += Array("</\(tag.name)>".utf8)
                        }
                        i = tag.end
                    } else {
                        out += escapedLessThan
                        i += 1
                    }
                } else if let close = bytes[(i + 2)...].firstIndex(of: greaterThan) {
                    // `</>` is ignored by browsers; `</ x…>` is a bogus comment.
                    i = close + 1
                } else {
                    out += escapedLessThan
                    i += 1
                }
                continue
            }

            if let next, isASCIILetter(next),
               let tag = parseTag(bytes, nameStart: i + 1), isValidName(tag.name) {
                let name = tag.name.lowercased()
                if name == "script" {
                    i = endOfScriptElement(bytes, from: tag.end) ?? tag.end
                    continue
                }
                if droppedElements.contains(name) {
                    i = tag.end
                    continue
                }
                if name == "plaintext" {
                    out += escapedLessThan
                    i += 1
                    continue
                }
                if rawTextElements.contains(name) {
                    guard let close = rawTextEnd(bytes, named: name, from: tag.end) else {
                        out += escapedLessThan
                        i += 1
                        continue
                    }
                    out += serialize(tag)
                    // Text to the browser in HTML, markup inside <svg>/<math>:
                    // escaping `<` keeps it inert either way.
                    for k in tag.end..<close {
                        if bytes[k] == lessThan { out += escapedLessThan } else { out.append(bytes[k]) }
                    }
                    i = close
                    continue
                }
                out += serialize(tag)
                i = tag.end
                continue
            }

            out += escapedLessThan
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Tokenizing

    /// Parses a start or end tag whose name begins at `nameStart`, following
    /// the HTML tokenizer's tag/attribute states. Nil when the node ends
    /// before the tag does.
    private static func parseTag(_ bytes: [UInt8], nameStart: Int) -> Tag? {
        let count = bytes.count
        var j = nameStart
        while j < count, !isSpace(bytes[j]), bytes[j] != slash, bytes[j] != greaterThan { j += 1 }
        let name = String(decoding: bytes[nameStart..<j], as: UTF8.self)
        var attributes: [(name: String, value: String?)] = []
        var selfClosing = false

        while true {
            // Before attribute name: whitespace and stray `/` separate.
            while j < count, isSpace(bytes[j]) || bytes[j] == slash {
                if bytes[j] == slash, j + 1 < count, bytes[j + 1] == greaterThan { selfClosing = true }
                j += 1
            }
            guard j < count else { return nil }
            if bytes[j] == greaterThan {
                return Tag(name: name, attributes: attributes, selfClosing: selfClosing, end: j + 1)
            }

            // Attribute name (its first character is taken even when it is `=`).
            let attributeStart = j
            j += 1
            while j < count, !isSpace(bytes[j]), bytes[j] != slash, bytes[j] != greaterThan, bytes[j] != equals { j += 1 }
            let attributeName = String(decoding: bytes[attributeStart..<j], as: UTF8.self)

            while j < count, isSpace(bytes[j]) { j += 1 }
            guard j < count else { return nil }
            guard bytes[j] == equals else {
                attributes.append((attributeName, nil))
                continue
            }
            j += 1
            while j < count, isSpace(bytes[j]) { j += 1 }
            guard j < count else { return nil }

            let quote = bytes[j]
            if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                guard let close = bytes[(j + 1)...].firstIndex(of: quote) else { return nil }
                attributes.append((attributeName, String(decoding: bytes[(j + 1)..<close], as: UTF8.self)))
                j = close + 1
            } else if quote == greaterThan {
                attributes.append((attributeName, ""))
            } else {
                let valueStart = j
                while j < count, !isSpace(bytes[j]), bytes[j] != greaterThan { j += 1 }
                guard j < count else { return nil }
                attributes.append((attributeName, String(decoding: bytes[valueStart..<j], as: UTF8.self)))
            }
        }
    }

    /// End of a `<!…>` / `<?…>` construct: comments close at `-->` / `--!>`
    /// (or at once for `<!-->` / `<!--->`), everything else at the first `>`.
    private static func endOfMarkupDeclaration(_ bytes: [UInt8], from start: Int) -> Int? {
        let count = bytes.count
        let isComment = start + 3 < count && bytes[start + 1] == bang
            && bytes[start + 2] == dash && bytes[start + 3] == dash
        guard isComment else {
            return bytes[(start + 2)...].firstIndex(of: greaterThan).map { $0 + 1 }
        }
        var j = start + 4
        if j < count, bytes[j] == greaterThan { return j + 1 }
        if j + 1 < count, bytes[j] == dash, bytes[j + 1] == greaterThan { return j + 2 }
        while j + 2 < count {
            if bytes[j] == dash, bytes[j + 1] == dash {
                if bytes[j + 2] == greaterThan { return j + 3 }
                if j + 3 < count, bytes[j + 2] == bang, bytes[j + 3] == greaterThan { return j + 4 }
            }
            j += 1
        }
        return nil
    }

    /// Index of the `<` of the first complete `</name …>` at or after `start`.
    private static func rawTextEnd(_ bytes: [UInt8], named name: String, from start: Int) -> Int? {
        let nameBytes = Array(name.utf8)
        var j = start
        while let open = bytes[j...].firstIndex(of: lessThan) {
            let nameStart = open + 2
            let nameEnd = nameStart + nameBytes.count
            if nameEnd < bytes.count, bytes[open + 1] == slash,
               zip(bytes[nameStart..<nameEnd], nameBytes).allSatisfy({ ($0 | 0x20) == $1 }),
               isSpace(bytes[nameEnd]) || bytes[nameEnd] == slash || bytes[nameEnd] == greaterThan,
               parseTag(bytes, nameStart: nameStart) != nil {
                return open
            }
            j = open + 1
            guard j < bytes.count else { return nil }
        }
        return nil
    }

    /// Index just past the `</script>` closing a script element, so the whole
    /// element (and its code) is dropped. Nil when there is none in the node:
    /// then only the start tag goes — an unclosed `<script>` block would
    /// otherwise take the rest of the note with it.
    private static func endOfScriptElement(_ bytes: [UInt8], from start: Int) -> Int? {
        guard let close = rawTextEnd(bytes, named: "script", from: start) else { return nil }
        return parseTag(bytes, nameStart: close + 2)?.end
    }

    // MARK: Re-emitting

    private static func serialize(_ tag: Tag) -> [UInt8] {
        var html = "<" + tag.name
        for attribute in tag.attributes where isAllowed(attribute) {
            html += " " + attribute.name
            if let value = attribute.value {
                html += "=\"" + escapeAttributeValue(value) + "\""
            }
        }
        html += tag.selfClosing ? " />" : ">"
        return Array(html.utf8)
    }

    private static func isAllowed(_ attribute: (name: String, value: String?)) -> Bool {
        guard isValidAttributeName(attribute.name) else { return false }
        let name = attribute.name.lowercased()
        if name.hasPrefix("on") || name == "srcdoc" || name == "nonce" { return false }
        guard let value = attribute.value else { return true }
        let decoded = decodeCharacterReferences(value)
        if urlAttributes.contains(name) {
            return !isScriptBearingURL(decoded)
        }
        if animationValueAttributes.contains(name) {
            // SVG <animate>/<set> can move these into an href, anywhere in a
            // `values` list.
            let probe = scriptSchemeProbe(decoded)
            return !(probe.contains("javascript:") || probe.contains("vbscript:") || probe.contains("data:"))
        }
        return true
    }

    /// Raw values keep their character references; only the characters that
    /// could end the attribute or open a tag are escaped.
    private static func escapeAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Character references

    private static let namedReferences: [(name: String, value: Unicode.Scalar)] = [
        ("amp;", "&"), ("lt;", "<"), ("gt;", ">"), ("quot;", "\""), ("apos;", "'"),
        ("colon;", ":"), ("Tab;", "\t"), ("NewLine;", "\n"), ("nbsp;", "\u{A0}")
    ]

    /// Decodes numeric references (with or without `;`) and the named ones
    /// that matter for telling a URL's scheme (`&colon;`, `&Tab;`,
    /// `&NewLine;`) or that the renderer itself emits. Other named references
    /// stay as written — none of them produces an ASCII letter.
    static func decodeCharacterReferences(_ string: String) -> String {
        guard string.contains("&") else { return string }
        let scalars = Array(string.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0

        while i < scalars.count {
            guard scalars[i] == "&" else {
                out.append(scalars[i])
                i += 1
                continue
            }
            if i + 1 < scalars.count, scalars[i + 1] == "#" {
                var j = i + 2
                var radix: UInt32 = 10
                if j < scalars.count, scalars[j] == "x" || scalars[j] == "X" {
                    radix = 16
                    j += 1
                }
                let digitsStart = j
                var value: UInt32 = 0
                while j < scalars.count, let digit = digitValue(scalars[j], radix: radix) {
                    if value <= 0x10FFFF { value = value * radix + digit }
                    j += 1
                }
                if j > digitsStart {
                    if j < scalars.count, scalars[j] == ";" { j += 1 }
                    out.append(value == 0 ? "\u{FFFD}" : (Unicode.Scalar(value) ?? "\u{FFFD}"))
                    i = j
                    continue
                }
            } else if let reference = namedReferences.first(where: { hasPrefix(scalars, at: i + 1, $0.name) }) {
                out.append(reference.value)
                i += 1 + reference.name.unicodeScalars.count
                continue
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    private static func digitValue(_ scalar: Unicode.Scalar, radix: UInt32) -> UInt32? {
        switch scalar.value {
        case 0x30...0x39: return scalar.value - 0x30
        case 0x61...0x66 where radix == 16: return scalar.value - 0x61 + 10
        case 0x41...0x46 where radix == 16: return scalar.value - 0x41 + 10
        default: return nil
        }
    }

    private static func hasPrefix(_ scalars: [Unicode.Scalar], at index: Int, _ prefix: String) -> Bool {
        let prefixScalars = Array(prefix.unicodeScalars)
        guard index + prefixScalars.count <= scalars.count else { return false }
        return Array(scalars[index..<(index + prefixScalars.count)]) == prefixScalars
    }

    // MARK: Character classes

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        let lower = byte | 0x20
        return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
    }

    /// Tag names a note can reasonably use (custom elements, `o:p`); anything
    /// odder is shown as text rather than re-emitted.
    private static func isValidName(_ name: String) -> Bool {
        guard let first = name.utf8.first, isASCIILetter(first) else { return false }
        return name.utf8.allSatisfy { isASCIILetter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == dash || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".") }
    }

    private static func isValidAttributeName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              isASCIILetter(first) || first == UInt8(ascii: "_") || first == UInt8(ascii: ":") else { return false }
        return name.utf8.allSatisfy { isASCIILetter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == dash || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".") }
    }
}
