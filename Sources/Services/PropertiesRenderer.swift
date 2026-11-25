import Foundation
import Yams

/// The note's properties (its frontmatter) as a block above the live
/// preview's text, the way Obsidian's reading view shows them: keys in the
/// file's order, lists as chips, `tags` as tags, `[[links]]` and web links
/// clickable, booleans as boxes, dates in the system's format.
///
/// Live preview only (`MarkdownRenderOptions.properties`): exports are left
/// as they were. The block sits before `#cmdmd-root`, outside the blocks a
/// patch counts; a change to it changes the options, which reloads the page.
enum PropertiesRenderer {
    /// The block for `block` (the properties as the file writes them, `---`
    /// fences included), or "" when there are none.
    static func html(block: String) -> String {
        let yaml = self.yaml(inBlock: block)
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        let rows: String
        if let node = try? Yams.compose(yaml: yaml), case .mapping(let mapping) = node {
            rows = mapping.map { key, value in
                let name = key.scalar?.string ?? (try? Yams.serialize(node: key))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return """
                <div class="cmdmd-prop"><div class="cmdmd-prop-key">\(htmlEscape(name))</div>\
                <div class="cmdmd-prop-value">\(valueHTML(value, key: name))</div></div>
                """
            }.joined(separator: "\n")
        } else {
            // Obsidian shows unreadable properties as their text.
            rows = "<pre class=\"cmdmd-prop-raw\">\(htmlEscape(yaml))</pre>"
        }
        return """
        <details class="cmdmd-properties" open>
        <summary>Properties</summary>
        <div class="cmdmd-props">
        \(rows)
        </div>
        </details>
        """
    }

    /// The YAML between the fences: the opening line dropped, and the
    /// closing `---` (or `...`) with the blank lines after it.
    static func yaml(inBlock block: String) -> String {
        var lines = block.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return block }
        lines.removeFirst()
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if let last = lines.last, ["---", "..."].contains(last.trimmingCharacters(in: .whitespaces)) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func valueHTML(_ node: Node, key: String) -> String {
        switch node {
        case .scalar(let scalar):
            switch FrontmatterValue(node: node) {
            case .bool(let value)?:
                return "<input type=\"checkbox\" disabled\(value ? " checked" : "") aria-label=\"\(htmlEscape(key))\">"
            case .int?, .double?:
                return htmlEscape(scalar.string)
            default:
                let text = scalar.string
                guard !text.isEmpty else { return empty }
                // One long unbroken token (a session URL, a hash) on one line,
                // cut short as in Obsidian; the whole of it on hover.
                if text.count > 60, !text.contains(where: \.isWhitespace) {
                    return "<span class=\"cmdmd-prop-long\" title=\"\(htmlEscape(text))\">\(inline(text))</span>"
                }
                return inline(text)
            }
        case .sequence(let sequence):
            let items = sequence.map { item -> String in
                item.scalar?.string ?? (try? Yams.serialize(node: item))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return empty }
            let isTags = ["tags", "tag"].contains(key.lowercased())
            return items.map { item in
                if isTags {
                    let name = item.hasPrefix("#") ? String(item.dropFirst()) : item
                    return "<span class=\"tag\" data-tag=\"\(htmlEscape(name))\">#\(htmlEscape(name))</span>"
                }
                return "<span class=\"cmdmd-prop-chip\">\(inline(item))</span>"
            }.joined(separator: " ")
        default:
            // A nested map (or an alias): its YAML, as Obsidian shows it.
            let text = (try? Yams.serialize(node: node))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? empty : "<span class=\"cmdmd-prop-raw\">\(htmlEscape(text))</span>"
        }
    }

    private static let empty = "<span class=\"cmdmd-prop-empty\">Empty</span>"

    // MARK: Text values

    /// `[[target|alias]]`, or a URL with one of the schemes the preview opens
    /// (anything else, e.g. `omnicontrol://`, stays text: clicking it would
    /// do nothing).
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"\[\[([^\[\]|]+)(?:\|([^\[\]]*))?\]\]|\b(?:https?://|mailto:|obsidian://)[^\s<>"']+"#,
        options: [.caseInsensitive]
    )

    private static let linkValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        return allowed
    }()

    /// A text value: a date as a date, else the text with its links.
    static func inline(_ text: String) -> String {
        if let date = formattedDate(text) {
            return "<time datetime=\"\(htmlEscape(text))\">\(htmlEscape(date))</time>"
        }
        let ns = text as NSString
        var html = ""
        var last = 0
        for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            html += htmlEscape(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            if match.range(at: 1).location != NSNotFound {
                let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let alias = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : ""
                let encoded = target.addingPercentEncoding(withAllowedCharacters: linkValueAllowed) ?? target
                let label = alias.trimmingCharacters(in: .whitespaces).isEmpty ? target : alias
                html += "<a href=\"\(htmlEscape("cmdmd://open?note=\(encoded)"))\" class=\"wiki-link\">\(htmlEscape(label))</a>"
            } else {
                var url = ns.substring(with: match.range)
                // Sentence punctuation after a link isn't part of it.
                var trailing = ""
                while let character = url.last, ".,;:!?)".contains(character) {
                    trailing = String(character) + trailing
                    url.removeLast()
                }
                html += "<a href=\"\(htmlEscape(url))\">\(htmlEscape(url))</a>" + htmlEscape(trailing)
            }
            last = match.range.location + match.range.length
        }
        html += htmlEscape(ns.substring(from: last))
        return html
    }

    /// `2026-11-25` or `2026-11-25T11:20` (Obsidian's date and date & time
    /// properties) in the system's format, read as local time; nil for
    /// anything else.
    static func formattedDate(_ text: String) -> String? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?$"#
        guard let match = try? NSRegularExpression(pattern: pattern)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ index: Int) -> Int? {
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
        var components = DateComponents(year: part(1), month: part(2), day: part(3))
        let hasTime = part(4) != nil
        if hasTime {
            components.hour = part(4)
            components.minute = part(5)
            components.second = part(6) ?? 0
        }
        // Rejects 2026-02-31 and 25:00 instead of rolling them over.
        guard components.isValidDate(in: Calendar.current), let date = Calendar.current.date(from: components) else { return nil }
        return date.formatted(date: .numeric, time: hasTime ? .shortened : .omitted)
    }

    static func htmlEscape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    // MARK: Styles

    static let css = """
    .cmdmd-properties { margin: 0 0 1.75em; padding-bottom: 0.9em; border-bottom: 1px solid var(--border-color); font-size: 0.88em; line-height: 1.5; }
    .cmdmd-properties > summary { cursor: pointer; list-style: none; color: var(--text-secondary); font-weight: 600; margin-bottom: 0.55em; user-select: none; }
    .cmdmd-properties > summary::-webkit-details-marker { display: none; }
    .cmdmd-properties > summary::before { content: ''; display: inline-block; width: 0.4em; height: 0.4em; margin: 0 0.6em 0.25em 0.1em; vertical-align: middle; border-right: 1.5px solid currentColor; border-bottom: 1.5px solid currentColor; transform: rotate(45deg); transition: transform 0.15s; }
    .cmdmd-properties:not([open]) > summary::before { transform: rotate(-45deg); margin-bottom: 0.1em; }
    .cmdmd-properties:not([open]) > summary { margin-bottom: 0; }
    .cmdmd-props { display: grid; grid-template-columns: minmax(6em, max-content) minmax(0, 1fr); column-gap: 1.5em; row-gap: 0.4em; }
    .cmdmd-prop { display: contents; }
    .cmdmd-prop-key { color: var(--text-secondary); max-width: 12em; overflow-wrap: anywhere; }
    .cmdmd-prop-value { min-width: 0; overflow-wrap: anywhere; color: var(--text-primary); }
    .cmdmd-prop-value .tag, .cmdmd-prop-chip { display: inline-block; margin: 0 0.15em 0.2em 0; }
    .cmdmd-prop-chip { background: var(--tag-bg); padding: 0.05em 0.6em; border-radius: 999px; }
    .cmdmd-prop-value input[type="checkbox"] { margin: 0; vertical-align: -2px; }
    .cmdmd-prop-empty { color: var(--text-secondary); opacity: 0.7; }
    .cmdmd-prop-long { display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .cmdmd-prop-raw { font-family: var(--font-mono); font-size: 0.9em; white-space: pre-wrap; }
    pre.cmdmd-prop-raw { grid-column: 1 / -1; margin: 0; padding: 0.6em 0.8em; background: var(--code-bg); border-radius: var(--radius); }
    """
}
