import Foundation

/// The blocks a live preview page is patched by: runs of the renderer's
/// top-level blocks (`RenderedBody.blockRanges`) after each of which the
/// HTML parser is back at the page's top level with nothing left open. A
/// note's raw `<details>` … `</details>` and the footnotes' `<section>`
/// span several Markdown blocks; they become one.
///
/// Each block is parsed on its own when a patch brings it (in a
/// `<template>`), so it must parse there as it does inside the full page.
/// Markup that parses differently out of the page's context (stray table
/// parts, `<body>`, an end tag closing what an earlier block opened) or that
/// never closes leaves the page unpatchable: nil, and it reloads in full.
/// The page itself checks the result: each block boundary is a marker
/// comment that must come out at the top level.
enum PreviewBlocks {
    static func coalesce(_ html: String, ranges: [Range<Int>]) -> [Range<Int>]? {
        var html = html
        return html.withUTF8 { bytes -> [Range<Int>]? in
            var scanner = TopLevelScanner(bytes)
            var blocks: [Range<Int>] = []
            var start = 0
            for range in ranges {
                guard scanner.scan(to: range.upperBound) else { return nil }
                if scanner.isAtTopLevel(range.upperBound) {
                    blocks.append(start..<range.upperBound)
                    start = range.upperBound
                }
            }
            return start == bytes.count ? blocks : nil
        }
    }
}

/// Just enough of HTML's tokenizer to follow which elements are open:
/// tags with their quoted attributes, comments, raw text, void elements and
/// SVG/MathML self-closing tags. End tags must close the innermost open
/// element; the parser's repairs (implied ends, misnested formatting) are
/// never modelled, they fail the scan instead.
private struct TopLevelScanner {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var position = 0
    private var open: [String] = []
    private var tables = 0
    private var foreign = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    func isAtTopLevel(_ offset: Int) -> Bool {
        position == offset && open.isEmpty
    }

    private static let void: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "hr", "image", "img",
        "input", "keygen", "link", "meta", "param", "source", "track", "wbr"
    ]
    /// Their text is not markup.
    private static let rawText: Set<String> = [
        "style", "xmp", "iframe", "noembed", "noframes", "textarea", "title"
    ]
    /// The page's own structure, or what ends parsing as HTML. And
    /// `<noscript>`: raw text in the page, which runs script, but markup in
    /// a `<template>`, which doesn't, so a patched one parsed otherwise.
    private static let unpatchable: Set<String> = ["html", "head", "body", "frameset", "frame", "plaintext", "script", "noscript"]
    /// A `<template>` parses these outside a table as table parts; the page drops them.
    private static let tableParts: Set<String> = ["caption", "colgroup", "col", "tbody", "thead", "tfoot", "tr", "td", "th"]

    /// Follows the markup up to `end` (a token running past it is read
    /// whole). False when the markup can't be followed or patched.
    mutating func scan(to end: Int) -> Bool {
        while position < end {
            guard let base = bytes.baseAddress,
                  let lt = memchr(base + position, Int32(UInt8(ascii: "<")), end - position) else {
                position = end
                return true
            }
            position = base.distance(to: lt.assumingMemoryBound(to: UInt8.self))
            guard tag() else { return false }
        }
        return true
    }

    private func byte(_ offset: Int) -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    private static func isLetter(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }

    /// The offset just past `needle` at or after `from`.
    private func after(_ needle: String, from: Int) -> Int? {
        guard from < bytes.count, let base = bytes.baseAddress else { return nil }
        var needle = needle
        return needle.withUTF8 { n in
            memmem(base + from, bytes.count - from, n.baseAddress, n.count).map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) + n.count
            }
        }
    }

    /// The token at `position`, a `<`.
    private mutating func tag() -> Bool {
        let next = byte(position + 1)
        if next == UInt8(ascii: "!") {
            return declaration()
        }
        if next == UInt8(ascii: "?") {
            return skip(past: ">", from: position + 2)
        }
        if next == UInt8(ascii: "/") {
            if Self.isLetter(byte(position + 2)) { return endTag() }
            if byte(position + 2) == UInt8(ascii: ">") {
                position += 3
                return true
            }
            return skip(past: ">", from: position + 2)
        }
        if Self.isLetter(next) { return startTag() }
        position += 1
        return true
    }

    private mutating func skip(past needle: String, from: Int) -> Bool {
        guard let end = after(needle, from: from) else { return false }
        position = end
        return true
    }

    /// A comment, or a doctype/CDATA, which HTML reads as a comment up to `>`.
    private mutating func declaration() -> Bool {
        let start = position + 2
        if byte(start) == UInt8(ascii: "-"), byte(start + 1) == UInt8(ascii: "-") {
            // `<!-->` and `<!--->` are whole (empty) comments; others end at
            // `-->` or `--!>`.
            var from = start + 2
            if byte(from) == UInt8(ascii: ">") { return skip(past: ">", from: from) }
            if byte(from) == UInt8(ascii: "-"), byte(from + 1) == UInt8(ascii: ">") { return skip(past: ">", from: from) }
            while let dashes = after("--", from: from) {
                if byte(dashes) == UInt8(ascii: ">") { return skip(past: ">", from: dashes) }
                if byte(dashes) == UInt8(ascii: "!"), byte(dashes + 1) == UInt8(ascii: ">") { return skip(past: ">", from: dashes) }
                from = dashes - 1
            }
            return false
        }
        if foreign > 0, starts(with: "[CDATA[", at: start) {
            return skip(past: "]]>", from: start + 7)
        }
        return skip(past: ">", from: start)
    }

    /// Whether the bytes at `offset` are `prefix`, ASCII case aside.
    private func starts(with prefix: String, at offset: Int, ignoringCase: Bool = false) -> Bool {
        guard offset + prefix.utf8.count <= bytes.count else { return false }
        for (index, expected) in prefix.utf8.enumerated() {
            let actual = bytes[offset + index]
            guard actual == expected || (ignoringCase && Self.isLetter(actual) && actual | 0x20 == expected) else { return false }
        }
        return true
    }

    /// Reads a tag's name from `position` (a letter), lowercased.
    private mutating func name() -> String {
        let start = position
        while let byte = byte(position), !Self.isSpace(byte), byte != UInt8(ascii: "/"), byte != UInt8(ascii: ">") {
            position += 1
        }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self).lowercased()
    }

    /// Reads attributes through the closing `>`; whether the tag ended `/>`.
    private mutating func attributes() -> Bool? {
        while true {
            while let byte = byte(position), Self.isSpace(byte) { position += 1 }
            guard let byte = byte(position) else { return nil }
            if byte == UInt8(ascii: ">") {
                position += 1
                return false
            }
            if byte == UInt8(ascii: "/") {
                position += 1
                if self.byte(position) == UInt8(ascii: ">") {
                    position += 1
                    return true
                }
                continue
            }
            // A name (its first character can be anything, even `=`).
            position += 1
            while let byte = self.byte(position), !Self.isSpace(byte),
                  byte != UInt8(ascii: "/"), byte != UInt8(ascii: ">"), byte != UInt8(ascii: "=") {
                position += 1
            }
            while let byte = self.byte(position), Self.isSpace(byte) { position += 1 }
            guard self.byte(position) == UInt8(ascii: "=") else { continue }
            position += 1
            while let byte = self.byte(position), Self.isSpace(byte) { position += 1 }
            guard let quote = self.byte(position) else { return nil }
            if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                guard let end = after(quote == UInt8(ascii: "\"") ? "\"" : "'", from: position + 1) else { return nil }
                position = end
            } else {
                while let byte = self.byte(position), !Self.isSpace(byte), byte != UInt8(ascii: ">") {
                    position += 1
                }
            }
        }
    }

    private mutating func startTag() -> Bool {
        position += 1
        let tag = name()
        guard let selfClosing = attributes(), !Self.unpatchable.contains(tag),
              tables > 0 || !Self.tableParts.contains(tag) else { return false }
        if Self.void.contains(tag) || (foreign > 0 && selfClosing) { return true }
        if foreign == 0, Self.rawText.contains(tag) {
            return rawText(closing: tag)
        }
        open.append(tag)
        if tag == "table" { tables += 1 }
        if tag == "svg" || tag == "math" { foreign += 1 }
        return true
    }

    /// Skips the text of a raw-text element through its end tag, which
    /// matches in any case.
    private mutating func rawText(closing tag: String) -> Bool {
        var from = position
        while let close = after("</", from: from) {
            let end = close + tag.utf8.count
            if starts(with: tag, at: close, ignoringCase: true),
               let byte = byte(end), Self.isSpace(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">") {
                position = end
                return attributes() != nil
            }
            from = close
        }
        return false
    }

    private mutating func endTag() -> Bool {
        position += 2
        let tag = name()
        guard attributes() != nil, open.last == tag else { return false }
        open.removeLast()
        if tag == "table" { tables -= 1 }
        if tag == "svg" || tag == "math" { foreign -= 1 }
        return true
    }
}
