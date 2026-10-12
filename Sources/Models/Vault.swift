import Foundation
import SwiftUI
import Yams

struct Vault: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var name: String
    var rootPath: URL
    var inboxPath: String
    var templateId: UUID?
    var bookmarkData: Data?
    var createdAt: Date
    var isDefault: Bool
    
    init(
        id: UUID = UUID(),
        name: String,
        rootPath: URL,
        // Empty means "use the app-wide default send folder"
        // (see AppState.effectiveSendFolder). A non-empty value is a
        // vault-specific Inbox that takes priority over the global default.
        inboxPath: String = "",
        templateId: UUID? = nil,
        bookmarkData: Data? = nil,
        createdAt: Date = Date(),
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.inboxPath = inboxPath
        self.templateId = templateId
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.isDefault = isDefault
    }

    // Resilient decoding (like AppSettings): a missing key falls back to its
    // default instead of failing the vault. Only the root folder is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        rootPath = try c.decode(URL.self, forKey: .rootPath)
        inboxPath = try c.decodeIfPresent(String.self, forKey: .inboxPath) ?? ""
        templateId = try c.decodeIfPresent(UUID.self, forKey: .templateId)
        bookmarkData = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
    
    var inboxURL: URL {
        rootPath.appendingPathComponent(inboxPath)
    }

    var displayName: String {
        name.isEmpty ? rootPath.lastPathComponent : name
    }

    /// Obsidian names a vault by its folder name; `name` is only a display
    /// alias inside CmdMD. Using the alias broke obsidian:// links for renamed
    /// vault entries.
    var obsidianVaultName: String {
        rootPath.lastPathComponent
    }

    /// Builds an obsidian://open URL, optionally targeting a file inside the vault.
    /// A file is opened by its absolute path, which Obsidian maps to the most
    /// specific vault containing it: `vault=<folder name>` opened whichever
    /// vault came first when two shared a name, and found no vault at all for
    /// one connected at a subfolder of an Obsidian vault.
    func obsidianURL(forFile fileURL: URL? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        if let fileURL {
            components.queryItems = [URLQueryItem(name: "path", value: fileURL.standardizedFileURL.path)]
        } else {
            components.queryItems = [URLQueryItem(name: "vault", value: obsidianVaultName)]
        }
        return components.url
    }

    /// True when `fileURL` lives inside this vault.
    func contains(_ fileURL: URL) -> Bool {
        fileURL.standardizedFileURL.path.hasPrefix(rootPath.standardizedFileURL.path + "/")
    }

    /// True when this vault is rooted at `url`, however the path is spelled
    /// (symlinks, `..`, case), so one folder isn't connected twice.
    func hasRoot(_ url: URL) -> Bool {
        AppState.isSameFile(rootPath, url)
    }

    /// True when the vault's folder is there. A send never creates it: a
    /// missing root means the vault was moved or renamed, or its drive is
    /// unmounted, and recreating it hid notes from the real vault.
    var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: rootPath.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

struct VaultTemplate: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var content: String
    var frontmatterTemplate: Frontmatter?
    var filenamePattern: String
    
    init(
        id: UUID = UUID(),
        name: String,
        content: String = "",
        frontmatterTemplate: Frontmatter? = nil,
        filenamePattern: String = "{{title}}"
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.frontmatterTemplate = frontmatterTemplate
        self.filenamePattern = filenamePattern
    }

    // Resilient decoding (like AppSettings): missing keys use the defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        frontmatterTemplate = try c.decodeIfPresent(Frontmatter.self, forKey: .frontmatterTemplate)
        filenamePattern = try c.decodeIfPresent(String.self, forKey: .filenamePattern) ?? "{{title}}"
    }
    
    func generateFilename(title: String, date: Date = Date()) -> String {
        let pattern = filenamePattern.isEmpty ? "{{title}}" : filenamePattern
        return Self.substitute(pattern, title: title, date: date)
    }

    /// Renders the template body for a document. `{{content}}` marks where the
    /// document body goes; a template without it gets the body appended so user
    /// content is never silently dropped.
    func renderContent(for document: MarkdownDocument, date: Date = Date()) -> String {
        guard !content.isEmpty else { return document.content }
        var rendered = Self.substitute(content, title: document.displayTitle, date: date)
        if rendered.contains("{{content}}") {
            rendered = rendered.replacingOccurrences(of: "{{content}}", with: document.content)
        } else {
            rendered += "\n\n" + document.content
        }
        return rendered
    }

    /// The template rendered for a document, with the frontmatter block it
    /// opens with (if any) apart from the body. A send merges that block into
    /// the note's properties: left at the top of the body, it was a second
    /// block, which Obsidian shows as a rule and a heading.
    func renderParts(for document: MarkdownDocument, date: Date = Date()) -> (frontmatter: FrontmatterSource?, body: String) {
        guard let block = FileService.frontmatterBlock(in: content) else {
            return (nil, renderContent(for: document, date: date))
        }
        let yaml = Self.substituteYAML(String(content[block.yaml]), title: document.displayTitle, date: date)
        let frontmatter = FrontmatterSource(
            opening: String(content[..<block.yaml.lowerBound]),
            yaml: yaml,
            closing: String(content[block.yaml.upperBound..<block.bodyStart]),
            parsed: FileService.properties(fromYAML: yaml)
        )
        var body = self
        body.content = String(content[block.bodyStart...])
        return (frontmatter, body.renderContent(for: document, date: date))
    }

    /// Fills in a template's frontmatter YAML. `{{title}}` is written in the
    /// form of the value it stands in: escaped inside quotes, and quoted as a
    /// whole plain value YAML would misread ("Re: Q3", "#1", "2024"). Pasted
    /// in as is, such a title made the block invalid and its properties were
    /// lost. Inside a longer plain value it is written as is.
    private static func substituteYAML(_ yaml: String, title: String, date: Date) -> String {
        // The other placeholders are digits and separators, safe anywhere.
        let parts = substitute(yaml, title: "{{title}}", date: date).components(separatedBy: "{{title}}")
        guard parts.count > 1 else { return parts[0] }
        // Unique plain words where the titles go, so parsing tells which
        // kind of value each one is in.
        let markers = (1..<parts.count).map { "cmdmdTitle\($0)x" }
        let marked = zip(markers, parts.dropFirst()).reduce(parts[0]) { $0 + $1.0 + $1.1 }
        var forms: [String: String] = [:]
        if marked.utf8.count <= FileService.maxFrontmatterBytes, !FileService.mayExpandAliases(marked),
           let root = try? Yams.compose(yaml: marked) {
            collectTitleForms(in: root, inFlow: false, markers: markers, title: title, into: &forms)
        }
        return zip(markers, parts.dropFirst()).reduce(parts[0]) { $0 + (forms[$1.0] ?? title) + $1.1 }
    }

    private static func collectTitleForms(in node: Node, inFlow: Bool, markers: [String], title: String, into forms: inout [String: String]) {
        switch node {
        case .scalar(let scalar):
            for marker in markers where scalar.string.contains(marker) {
                switch scalar.style {
                case .doubleQuoted:
                    forms[marker] = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                case .singleQuoted:
                    forms[marker] = title.replacingOccurrences(of: "'", with: "''")
                case .plain where scalar.string == marker:
                    forms[marker] = yamlScalar(title, inFlow: inFlow)
                default:
                    break
                }
            }
        case .mapping(let mapping):
            for (key, value) in mapping {
                collectTitleForms(in: key, inFlow: inFlow || mapping.style == .flow, markers: markers, title: title, into: &forms)
                collectTitleForms(in: value, inFlow: inFlow || mapping.style == .flow, markers: markers, title: title, into: &forms)
            }
        case .sequence(let sequence):
            for item in sequence {
                collectTitleForms(in: item, inFlow: inFlow || sequence.style == .flow, markers: markers, title: title, into: &forms)
            }
        default:
            break
        }
    }

    /// `text` as a whole YAML value: plain where YAML reads it back as that
    /// text, otherwise quoted as Yams writes it.
    private static func yamlScalar(_ text: String, inFlow: Bool) -> String {
        if let dumped = try? Yams.dump(object: ["k": text], width: -1, allowUnicode: true),
           dumped.hasPrefix("k: "), dumped.hasSuffix("\n") {
            let value = String(dumped.dropFirst(3).dropLast())
            // A comma or bracket ends a plain value inside [ ] or { }.
            if !value.contains("\n"), value != text || !inFlow || !text.contains(where: { ",[]{}".contains($0) }) {
                return value
            }
        }
        return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func substitute(_ pattern: String, title: String, date: Date) -> String {
        let dateFormatter = DateFormatter.fixedFormat("yyyy-MM-dd")
        let timeFormatter = DateFormatter.fixedFormat("HH:mm")
        let timestampFormatter = DateFormatter.fixedFormat("HHmmss")

        return pattern
            .replacingOccurrences(of: "{{title}}", with: title)
            .replacingOccurrences(of: "{{date}}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: date))
            .replacingOccurrences(of: "{{timestamp}}", with: timestampFormatter.string(from: date))
    }
}

extension DateFormatter {
    /// A formatter for dates written into filenames and notes: Gregorian
    /// calendar and ASCII digits whatever the user's region (a Japanese-calendar
    /// Mac wrote "0008-10-11", a Thai one "2569-10-11"), in the local time zone.
    static func fixedFormat(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }
}

enum SendAction: String, CaseIterable, Codable {
    case copy = "Copy"
    case move = "Move"
}

enum FileConflictResolution: String, CaseIterable, Codable {
    case rename = "Rename with suffix"
    case timestamp = "Add timestamp"
    case overwrite = "Overwrite"
    case skip = "Skip"
}

struct SendOptions: Equatable {
    var action: SendAction = .copy
    var targetVault: Vault?
    var targetFolder: String = "Inbox"
    var conflictResolution: FileConflictResolution = .rename
    var injectFrontmatter: Bool = true
    var applyTemplate: Bool = false
    var templateId: UUID?
    var addSourceLink: Bool = false
    var openAfterSend: Bool = false
    /// Batch sends only: `AppState.sendPathKey`s of files the batch wrote or
    /// still has to send. A target clashing with one gets a new name even
    /// under Overwrite or Skip, so batch members never replace each other.
    var reservedPaths: Set<String> = []
}

/// What a single send did. Quiet callers (auto-route, batch, Quick Capture)
/// report from this instead of treating every send that didn't throw as written.
enum SendOutcome: Equatable {
    case sent(URL)
    /// The target already existed and the conflict resolution was Skip.
    case skipped(URL)
    /// The note already lives at the target, so nothing was written or removed.
    case alreadyInPlace(URL)

    /// Toast for a send that wrote nothing; nil when the note was sent.
    var unsentMessage: String? {
        switch self {
        case .sent:
            return nil
        case .skipped(let url):
            return "Skipped: \(url.lastPathComponent) already exists"
        case .alreadyInPlace(let url):
            return "\(url.lastPathComponent) is already in \(url.deletingLastPathComponent().lastPathComponent)"
        }
    }
}

struct RoutingRule: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var conditions: [RoutingCondition]
    var targetVaultId: UUID
    var targetFolder: String
    var action: SendAction
    var injectFrontmatter: Bool
    var priority: Int
    
    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        conditions: [RoutingCondition] = [],
        targetVaultId: UUID,
        targetFolder: String = "Inbox",
        action: SendAction = .move,
        injectFrontmatter: Bool = true,
        priority: Int = 0
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.targetVaultId = targetVaultId
        self.targetFolder = targetFolder
        self.action = action
        self.injectFrontmatter = injectFrontmatter
        self.priority = priority
    }

    // Resilient decoding for the descriptive keys (like AppSettings). What the
    // rule matches and where (and how) it sends stays required: a rule that
    // can't be read faithfully is skipped — its file is backed up — rather
    // than run with guessed conditions, target or a destructive default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        conditions = try c.decode([RoutingCondition].self, forKey: .conditions)
        targetVaultId = try c.decode(UUID.self, forKey: .targetVaultId)
        targetFolder = try c.decode(String.self, forKey: .targetFolder)
        action = try c.decode(SendAction.self, forKey: .action)
        injectFrontmatter = try c.decodeIfPresent(Bool.self, forKey: .injectFrontmatter) ?? true
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }
}

struct RoutingCondition: Identifiable, Equatable, Codable {
    let id: UUID
    var type: ConditionType
    var value: String
    var matchType: MatchType
    
    init(
        id: UUID = UUID(),
        type: ConditionType,
        value: String,
        matchType: MatchType = .contains
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.matchType = matchType
    }

    // Only the identifier is optional: an unknown type or match type (or a
    // missing value, which would match everything) fails the condition and
    // with it the rule, instead of silently widening what the rule routes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(ConditionType.self, forKey: .type)
        value = try c.decode(String.self, forKey: .value)
        matchType = try c.decode(MatchType.self, forKey: .matchType)
    }
    
    enum ConditionType: String, CaseIterable, Codable {
        case tag = "Tag"
        case frontmatterKey = "Frontmatter Key"
        case filenamePrefix = "Filename Prefix"
        case filenameSuffix = "Filename Suffix"
        case sourceDevice = "Source Device"
        case content = "Content"
    }
    
    enum MatchType: String, CaseIterable, Codable {
        case equals = "Equals"
        case contains = "Contains"
        case startsWith = "Starts With"
        case endsWith = "Ends With"
        case regex = "Regex"
    }
    
    func matches(document: MarkdownDocument) -> Bool {
        let targetValue: String
        switch type {
        case .tag:
            // Inline #tags count like frontmatter tags (as in Obsidian), and the
            // rule value may be written with or without its leading '#'.
            let needle = value.hasPrefix("#") ? String(value.dropFirst()) : value
            return document.allTags.contains { matchValue($0, against: matchType == .regex ? nil : needle) }
        case .frontmatterKey:
            // "key: value" — spaces around either part are fine ("status: done"
            // never matched), and the keys FileService parses into fields
            // (title, date, tags, aliases, cssclass) count too.
            let parts = value.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let frontmatter = document.frontmatter,
                  let actual = Self.frontmatterValue(parts[0].trimmingCharacters(in: .whitespaces), in: frontmatter) else {
                return false
            }
            return matchValue(actual, against: parts[1].trimmingCharacters(in: .whitespaces))
        case .filenamePrefix, .filenameSuffix:
            targetValue = document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayTitle
            // Contains (which every older rule has) keeps the condition's own
            // test, now case-insensitive; any other Match applies as picked
            // instead of being ignored.
            guard matchType == .contains else { return matchValue(targetValue) }
            let name = targetValue.lowercased(), needle = value.lowercased()
            return type == .filenamePrefix ? name.hasPrefix(needle) : name.hasSuffix(needle)
        case .sourceDevice:
            return matchValue(document.sourceDevice ?? "")
        case .content:
            return matchValue(document.content)
        }
    }
    
    private func matchValue(_ target: String, against expected: String? = nil) -> Bool {
        let compareValue = expected ?? value
        switch matchType {
        case .equals:
            return target.lowercased() == compareValue.lowercased()
        case .contains:
            return target.lowercased().contains(compareValue.lowercased())
        case .startsWith:
            return target.lowercased().hasPrefix(compareValue.lowercased())
        case .endsWith:
            return target.lowercased().hasSuffix(compareValue.lowercased())
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: compareValue, options: .caseInsensitive) else {
                return false
            }
            let range = NSRange(target.startIndex..., in: target)
            // Rules run on the main thread, and a backtracking-prone pattern such
            // as `(\w+\s?)+:` can take minutes on an ordinary note, so stop after
            // a fixed budget (a plain scan of a 5 MB note takes ~0.2 s).
            let deadline = Date().addingTimeInterval(Self.regexTimeBudget)
            var matched = false, timedOut = false
            regex.enumerateMatches(in: target, options: .reportProgress, range: range) { result, _, stop in
                if result != nil {
                    matched = true
                    stop.pointee = true
                } else if Date() > deadline {
                    timedOut = true
                    stop.pointee = true
                }
            }
            if timedOut {
                Log.error("routing regex gave up after \(Self.regexTimeBudget)s:", .send, detail: compareValue)
            }
            return matched
        }
    }

    /// Longest a single regex condition may run before it counts as no match.
    static let regexTimeBudget: TimeInterval = 0.5

    /// A frontmatter value as text for a Frontmatter Key condition, the key
    /// matched case-insensitively. Nil when the note doesn't set it.
    private static func frontmatterValue(_ key: String, in frontmatter: Frontmatter) -> String? {
        let known: String?
        switch key.lowercased() {
        case "title": known = frontmatter.title
        case "cssclass": known = frontmatter.cssclass
        case "tags": known = frontmatter.tags.isEmpty ? nil : frontmatter.tags.joined(separator: ", ")
        case "aliases": known = frontmatter.aliases.isEmpty ? nil : frontmatter.aliases.joined(separator: ", ")
        case "date":
            // As the note writes it (see Frontmatter.toYAML).
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            known = frontmatter.date.map { formatter.string(from: $0) }
        default: known = nil
        }
        if let known { return known }
        if let exact = frontmatter.custom[key] { return exact.displayString }
        return frontmatter.custom.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value.displayString
    }
}

extension RoutingCondition {
    /// Why the rule editor shouldn't save this condition — it could never
    /// match as written — or nil when it's usable.
    var validationError: String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter a value"
        }
        var pattern = value
        if type == .frontmatterKey {
            let parts = value.split(separator: ":", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                return "Use key: value"
            }
            pattern = parts[1]
        }
        if matchType == .regex, (try? NSRegularExpression(pattern: pattern)) == nil {
            return "Invalid regular expression"
        }
        return nil
    }
}

extension RoutingCondition.ConditionType {
    /// The Match a condition of this type starts with in the rule editor.
    /// Tags and keys compare whole values (Contains let "art" route #smart).
    var defaultMatchType: RoutingCondition.MatchType {
        switch self {
        case .tag, .frontmatterKey, .sourceDevice: return .equals
        case .filenamePrefix: return .startsWith
        case .filenameSuffix: return .endsWith
        case .content: return .contains
        }
    }
}
