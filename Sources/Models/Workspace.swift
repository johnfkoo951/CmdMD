import Foundation
import SwiftUI

// MARK: - View Mode

enum ViewMode: String, CaseIterable, Codable {
    case source = "Source"
    case split = "Split"
    case preview = "Preview"
}

// MARK: - Launch Defaults

/// Review-first launch posture: open straight into preview with chrome hidden.
struct AppLaunchDefaults: Equatable {
    var viewMode: ViewMode = .preview
    var sidebarVisible: Bool = false
}

// MARK: - Sidebar

enum SidebarTab: String, CaseIterable, Codable {
    case files = "Files"
    case favorites = "Favorites"
    case drafts = "Drafts"
    case recent = "Recent"

    var icon: String {
        switch self {
        case .files: return "folder"
        case .favorites: return "star"
        case .drafts: return "doc.text"
        case .recent: return "clock"
        }
    }
}

// MARK: - Tabs

struct EditorTab: Identifiable, Equatable, Codable {
    let id: UUID
    var documentId: UUID
    var fileURL: URL?
    var title: String
    var isPinned: Bool
    var isDirty: Bool
    var scrollPosition: CGFloat
    var cursorPosition: Int

    init(
        id: UUID = UUID(),
        documentId: UUID = UUID(),
        fileURL: URL? = nil,
        title: String = "Untitled",
        isPinned: Bool = false,
        isDirty: Bool = false,
        scrollPosition: CGFloat = 0,
        cursorPosition: Int = 0
    ) {
        self.id = id
        self.documentId = documentId
        self.fileURL = fileURL
        self.title = title
        self.isPinned = isPinned
        self.isDirty = isDirty
        self.scrollPosition = scrollPosition
        self.cursorPosition = cursorPosition
    }

    var displayTitle: String {
        if let url = fileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return title.isEmpty ? "Untitled" : title
    }
}

// MARK: - Favorites

struct FavoriteItem: Identifiable, Equatable, Codable {
    let id: UUID
    var url: URL
    var addedAt: Date
    var alias: String?

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date(), alias: String? = nil) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
        self.alias = alias
    }

    // Resilient decoding (like AppSettings): a key missing from an older or
    // newer favorites.json falls back to its default instead of failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decode(URL.self, forKey: .url)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
    }

    var displayName: String {
        // Folders and extension-less names show whole: deletingPathExtension()
        // turned the folder "70. Outputs" into "70".
        alias ?? (url.hasDirectoryPath || url.pathExtension.isEmpty
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent)
    }
}

// MARK: - File Tree

struct FileTreeItem: Identifiable, Hashable {
    /// Identity IS the path — a fresh UUID per tree rebuild made SwiftUI treat
    /// every refresh as all-new rows (row churn, lost disclosure animations).
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    var isExpanded: Bool
    var children: [FileTreeItem]

    init(url: URL, isDirectory: Bool = false, isExpanded: Bool = false, children: [FileTreeItem] = []) {
        self.url = url
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.children = children
    }

    var name: String {
        url.lastPathComponent
    }

    var icon: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "doc.text"
        case "txt": return "doc.plaintext"
        case "json": return "curlybraces"
        case "yml", "yaml": return "list.bullet.rectangle"
        default: return "doc"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileTreeItem, rhs: FileTreeItem) -> Bool {
        lhs.url == rhs.url && lhs.isExpanded == rhs.isExpanded && lhs.children == rhs.children
    }
}

// MARK: - Search

struct SearchResult: Identifiable {
    let id: UUID
    let fileURL: URL
    /// The matched line as the editor numbers it: lines of the body, below
    /// the frontmatter block. Nil for a match inside that block (a property),
    /// which the editor doesn't show.
    let lineNumber: Int?
    let lineContent: String
    let matchRange: Range<String.Index>

    init(fileURL: URL, lineNumber: Int?, lineContent: String, matchRange: Range<String.Index>) {
        self.id = UUID()
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.lineContent = lineContent
        self.matchRange = matchRange
    }

    var fileName: String {
        fileURL.lastPathComponent
    }
}

// MARK: - Table of Contents

struct TOCHeading: Identifiable, Equatable {
    /// Position in the document's heading list. Stable across re-parses, so
    /// the inspector's rows update in place (a fresh UUID per parse rebuilt
    /// every row on each typing pause), and unique even where slugs collide
    /// ("Intro", "Intro", "Intro 1" give "intro-1" twice).
    let id: Int
    let level: Int
    let text: String
    let lineNumber: Int
    /// Deduplicated anchor id matching the preview renderer's heading ids.
    let slug: String

    init(index: Int, level: Int, text: String, lineNumber: Int, slug: String = "") {
        self.id = index
        self.level = level
        self.text = text
        self.lineNumber = lineNumber
        self.slug = slug.isEmpty ? markdownHeadingSlug(text) : slug
    }
}

// MARK: - Session Restore

/// What gets persisted across launches when "Restore last session" is on.
struct SessionState: Codable, Equatable {
    var openFiles: [URL] = []
    var activeFileIndex: Int?
    var viewMode: ViewMode = .preview
    var currentFolder: URL?
    var sidebarVisible: Bool = false
    var inspectorVisible: Bool = false
}

// MARK: - Persistence

/// Decodes a JSON array entry by entry, skipping entries that fail, so one
/// malformed (or newer-format) entry can't take the rest of the list with it.
struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element] = []
    /// Entries that couldn't be decoded and were left out.
    var skippedCount = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                skippedCount += 1
                // A failed decode doesn't advance the container; step over the
                // bad entry explicitly.
                _ = try container.decode(SkippedEntry.self)
            }
        }
    }

    private struct SkippedEntry: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
