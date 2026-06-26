import Foundation
import AppKit
import Highlightr

class SyntaxHighlighter {
    /// Highlightr boots a JavaScript engine on init — expensive. One shared
    /// instance serves every editor; the active theme is tracked so repeated
    /// highlight passes don't re-load the theme JSON.
    private static let sharedHighlightr: Highlightr? = SyntaxHighlighter.makeHighlightr()
    private static var activeHighlightrTheme: String = ""

    /// `Highlightr()` reaches for its SwiftPM resource bundle
    /// (`Highlightr_Highlightr.bundle` — highlight.js + CSS themes) through the
    /// synthesized `Bundle.module` accessor, which **traps** (not throws) when the
    /// bundle was not shipped next to the app. That is exactly what crashed 1.4.6.
    /// Probe for the bundle first so a mis-packaged build degrades to "no code
    /// highlighting" instead of taking the whole app down on first render.
    private static func makeHighlightr() -> Highlightr? {
        guard highlightrResourceBundleIsPresent() else {
            NSLog("[CmdMD] Highlightr resource bundle not found next to the app — "
                + "syntax highlighting disabled. Re-package with scripts/package_app.sh.")
            return nil
        }
        return Highlightr()
    }

    /// Mirrors the locations SwiftPM's `Bundle.module` accessor searches for the
    /// Highlightr resource bundle: the app's `Resources/` (packaged) and the
    /// executable's own directory (`swift run`). If none contain it, instantiating
    /// `Highlightr` would trap.
    private static func highlightrResourceBundleIsPresent() -> Bool {
        let bundleName = "Highlightr_Highlightr.bundle"
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(exeDir)
        }
        let fm = FileManager.default
        return roots.contains { fm.fileExists(atPath: $0.appendingPathComponent(bundleName).path) }
    }

    /// Documents past this size (UTF-16 units) skip token highlighting and get
    /// base attributes only, keeping typing latency flat on huge files.
    static let highlightSizeLimit = 300_000

    private let headingPattern = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$", options: .anchorsMatchLines)
    private let boldPattern = try! NSRegularExpression(pattern: "(\\*\\*|__)(.*?)\\1", options: [])
    private let italicPattern = try! NSRegularExpression(pattern: "(\\*|_)(.*?)\\1", options: [])
    private let codeInlinePattern = try! NSRegularExpression(pattern: "`([^`]+)`", options: [])
    private let linkPattern = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", options: [])
    private let wikiLinkPattern = try! NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(\\|([^\\]]+))?\\]\\]", options: [])
    private let tagPattern = try! NSRegularExpression(pattern: "(?<![\\w#])#([a-zA-Z][a-zA-Z0-9_/-]*)", options: [])
    private let blockquotePattern = try! NSRegularExpression(pattern: "^>\\s*(.*)$", options: .anchorsMatchLines)
    private let listPattern = try! NSRegularExpression(pattern: "^(\\s*)([-*+]|\\d+\\.)\\s+", options: .anchorsMatchLines)
    private let codeBlockPattern = try! NSRegularExpression(pattern: "```(\\w+)?\\n([\\s\\S]*?)```", options: [])
    private let hrPattern = try! NSRegularExpression(pattern: "^([-*_]){3,}\\s*$", options: .anchorsMatchLines)
    private let calloutPattern = try! NSRegularExpression(pattern: "^>\\s*\\[!([a-zA-Z]+)\\]([+-])?\\s*(.*)?$", options: .anchorsMatchLines)
    private let markHighlightPattern = try! NSRegularExpression(pattern: "==([^=\\n]+)==", options: [])

    private func highlightr(for theme: EditorTheme) -> Highlightr? {
        guard let highlightr = Self.sharedHighlightr else { return nil }
        let name = theme.highlightrThemeName
        if Self.activeHighlightrTheme != name {
            highlightr.setTheme(to: name)
            Self.activeHighlightrTheme = name
        }
        return highlightr
    }

    /// Builds a fresh highlighted string. Used for one-shot rendering.
    func highlight(markdown: String, font: NSFont, theme: EditorTheme) -> NSAttributedString {
        let string = NSMutableAttributedString(string: markdown)
        applyHighlights(to: string, font: font, theme: theme)
        return string
    }

    /// Applies highlighting attributes IN PLACE on the storage. Because no
    /// characters change, the text view's undo stack, selection, and scroll
    /// position all survive — unlike setAttributedString, which rebuilt the
    /// storage on every debounce tick.
    func applyHighlights(to string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let fullRange = NSRange(location: 0, length: string.length)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4

        let textColor = NSColor(theme.textColor)

        string.beginEditing()
        defer { string.endEditing() }

        string.setAttributes([
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ], range: fullRange)

        guard string.length <= Self.highlightSizeLimit else { return }

        highlightHeadings(in: string, font: font, theme: theme)
        highlightCallouts(in: string, font: font, theme: theme)
        highlightCodeBlocks(in: string, font: font, theme: theme)
        highlightInlineCode(in: string, font: font, theme: theme)
        highlightBold(in: string, font: font, theme: theme)
        highlightItalic(in: string, font: font, theme: theme)
        highlightMarks(in: string, theme: theme)
        highlightLinks(in: string, theme: theme)
        highlightWikiLinks(in: string, theme: theme)
        highlightTags(in: string, theme: theme)
        highlightBlockquotes(in: string, theme: theme)
        highlightLists(in: string, theme: theme)
        highlightHorizontalRules(in: string, theme: theme)
    }

    private func highlightHeadings(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        headingPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            let hashRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            let level = hashRange.length

            let headingSizes: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 18, 5: 16, 6: 14]
            let fontSize = headingSizes[level] ?? font.pointSize
            let headingFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)

            string.addAttributes([
                .foregroundColor: NSColor(theme.commentColor),
                .font: font
            ], range: hashRange)

            string.addAttributes([
                .font: headingFont,
                .foregroundColor: NSColor(theme.headingColor)
            ], range: contentRange)
        }
    }

    private func highlightBold(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        boldPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            let boldFont = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
            string.addAttribute(.font, value: boldFont, range: match.range)
        }
    }

    private func highlightItalic(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        italicPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            let matchText = (text as NSString).substring(with: match.range)
            let isBoldMarker = matchText.hasPrefix("**") || matchText.hasPrefix("__")
            if isBoldMarker { return }

            let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            string.addAttribute(.font, value: italicFont, range: match.range)
        }
    }

    private func highlightInlineCode(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        codeInlinePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            let monoFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            string.addAttributes([
                .font: monoFont,
                .foregroundColor: NSColor(theme.stringColor),
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.5)
            ], range: match.range)
        }
    }

    private func highlightCodeBlocks(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        codeBlockPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            let monoFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            let langRange = match.range(at: 1)
            let codeRange = match.range(at: 2)

            string.addAttributes([
                .font: monoFont,
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.3)
            ], range: match.range)

            let hasLanguage = langRange.location != NSNotFound && codeRange.location != NSNotFound
            if hasLanguage, let highlightr = highlightr(for: theme) {
                let lang = (text as NSString).substring(with: langRange)
                let code = (text as NSString).substring(with: codeRange)

                if let highlighted = highlightr.highlight(code, as: lang) {
                    highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attrs, attrRange, _ in
                        let targetRange = NSRange(location: codeRange.location + attrRange.location, length: attrRange.length)
                        let isValidRange = targetRange.location + targetRange.length <= string.length
                        if isValidRange {
                            for (key, value) in attrs where key != .font {
                                string.addAttribute(key, value: value, range: targetRange)
                            }
                        }
                    }
                }
            }
        }
    }

    private func highlightMarks(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        markHighlightPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            string.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(theme.isDark ? 0.25 : 0.35),
                range: match.range
            )
        }
    }

    private func highlightLinks(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        linkPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            let linkTextRange = match.range(at: 1)
            let linkUrlRange = match.range(at: 2)

            string.addAttributes([
                .foregroundColor: NSColor(theme.linkColor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: linkTextRange)

            string.addAttribute(.foregroundColor, value: NSColor(theme.commentColor), range: linkUrlRange)
        }
    }

    private func highlightWikiLinks(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        wikiLinkPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            string.addAttributes([
                .foregroundColor: NSColor(theme.keywordColor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }

    private func highlightTags(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        tagPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            string.addAttributes([
                .foregroundColor: NSColor(theme.linkColor),
                .backgroundColor: NSColor(theme.linkColor).withAlphaComponent(0.15)
            ], range: match.range)
        }
    }

    private func highlightBlockquotes(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        blockquotePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            string.addAttributes([
                .foregroundColor: NSColor(theme.commentColor),
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.2)
            ], range: match.range)
        }
    }

    private func highlightLists(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        listPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            let markerRange = match.range(at: 2)
            string.addAttribute(.foregroundColor, value: NSColor(theme.keywordColor), range: markerRange)
        }
    }

    private func highlightHorizontalRules(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        hrPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            string.addAttribute(.foregroundColor, value: NSColor(theme.commentColor), range: match.range)
        }
    }

    private func highlightCallouts(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)

        calloutPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }

            let typeRange = match.range(at: 1)
            let calloutType = (text as NSString).substring(with: typeRange).lowercased()

            let color = calloutColor(for: calloutType)

            string.addAttributes([
                .foregroundColor: color,
                .backgroundColor: color.withAlphaComponent(0.1)
            ], range: match.range)

            let calloutTypeFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            string.addAttribute(.font, value: calloutTypeFont, range: typeRange)
        }
    }

    private func calloutColor(for type: String) -> NSColor {
        switch type {
        case "note": return .systemBlue
        case "abstract", "summary", "tldr": return .systemCyan
        case "info": return .systemTeal
        case "todo": return .systemMint
        case "tip", "hint", "important": return .systemYellow
        case "success", "check", "done": return .systemGreen
        case "question", "help", "faq": return .systemYellow
        case "warning", "caution", "attention": return .systemOrange
        case "failure", "fail", "missing": return .systemRed
        case "danger", "error": return .systemRed
        case "bug": return .systemPink
        case "example": return .systemPurple
        case "quote", "cite": return .systemGray
        default: return .systemGray
        }
    }
}
