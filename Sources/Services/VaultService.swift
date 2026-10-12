import Foundation
import AppKit

actor VaultService {
    private let dataDirectory: URL
    private var bookmarks: [UUID: Data] = [:]
    private var accessedURLs: [UUID: URL] = [:]
    
    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        
        let bookmarksURL = dataDirectory.appendingPathComponent("vault-bookmarks.json")
        if let data = try? Data(contentsOf: bookmarksURL),
           let dict = try? JSONDecoder().decode([String: Data].self, from: data) {
            for (key, value) in dict {
                if let uuid = UUID(uuidString: key) {
                    bookmarks[uuid] = value
                }
            }
        }
    }
    
    func registerVault(name: String, at url: URL, inboxPath: String = "") async throws -> Vault {
        guard url.startAccessingSecurityScopedResource() else {
            throw VaultError.accessDenied
        }
        
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        let vault = Vault(
            name: name,
            rootPath: url,
            inboxPath: inboxPath,
            bookmarkData: bookmarkData
        )
        
        bookmarks[vault.id] = bookmarkData
        accessedURLs[vault.id] = url
        saveBookmarks()
        
        return vault
    }
    
    func restoreVaultAccess(for vault: Vault) throws -> URL {
        guard let bookmarkData = vault.bookmarkData ?? bookmarks[vault.id] else {
            throw VaultError.bookmarkNotFound
        }
        
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        
        guard url.startAccessingSecurityScopedResource() else {
            throw VaultError.accessDenied
        }
        
        if isStale {
            let newBookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarks[vault.id] = newBookmarkData
            saveBookmarks()
        }
        
        accessedURLs[vault.id] = url
        return url
    }
    
    /// Where the vault's folder is now. Bookmarks follow renames and moves
    /// (Obsidian's Rename vault, Finder, iCloud Drive), which the stored
    /// rootPath doesn't. Comes with a re-minted bookmark when the stored one
    /// is stale. Nil without a bookmark or when it doesn't resolve; never
    /// mounts a volume or shows UI.
    func resolveLocation(of vault: Vault) -> (url: URL, refreshedBookmark: Data?)? {
        guard let bookmarkData = vault.bookmarkData ?? bookmarks[vault.id] else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard isStale else { return (url, nil) }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let refreshed = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return (url, refreshed)
    }

    func releaseVaultAccess(for vault: Vault) {
        if let url = accessedURLs[vault.id] {
            url.stopAccessingSecurityScopedResource()
            accessedURLs.removeValue(forKey: vault.id)
        }
    }
    
    func listFolders(in vault: Vault) async throws -> [String] {
        let url = try restoreVaultAccess(for: vault)
        defer { releaseVaultAccess(for: vault) }
        
        var folders: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                if !relativePath.hasPrefix(".obsidian") {
                    folders.append(relativePath)
                }
            }
        }
        
        return folders.sorted(by: Self.folderPathPrecedes)
    }
    
    /// Folder-tree order for the nested pickers, which indent by depth and
    /// show only the last component: paths compare component by component in
    /// Finder order (case-insensitive, numeric-aware), so each folder's
    /// subfolders follow it directly. Plain `<` put "Daily Notes" between
    /// "Daily" and "Daily/2026", whose "2026" then read as a Daily Notes child.
    static func folderPathPrecedes(_ a: String, _ b: String) -> Bool {
        let lhs = a.split(separator: "/"), rhs = b.split(separator: "/")
        for (l, r) in zip(lhs, rhs) where l != r {
            let order = l.localizedStandardCompare(r)
            return order == .orderedSame ? l < r : order == .orderedAscending
        }
        return lhs.count < rhs.count
    }


    
    /// Counts Markdown notes in a vault (best-effort, skips hidden + `.obsidian`).
    /// Used by the manager UI to show "N notes" without blocking the main thread.
    func noteCount(in vault: Vault) async -> Int {
        let url = (try? restoreVaultAccess(for: vault)) ?? vault.rootPath
        defer { releaseVaultAccess(for: vault) }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        // `allObjects` up front: iterating an enumerator directly calls
        // makeIterator, which is unavailable from async contexts in Swift 6.
        let urls = enumerator.allObjects.compactMap { $0 as? URL }
        return urls.reduce(into: 0) { count, fileURL in
            let ext = fileURL.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" { count += 1 }
        }
    }

    private func saveBookmarks() {
        let bookmarksURL = dataDirectory.appendingPathComponent("vault-bookmarks.json")
        var dict: [String: Data] = [:]
        for (key, value) in bookmarks {
            dict[key.uuidString] = value
        }
        
        if let data = try? JSONEncoder().encode(dict) {
            // Atomic, like the other data files: an interrupted write must not
            // leave a truncated file that drops every bookmark on next read.
            try? data.write(to: bookmarksURL, options: .atomic)
        }
    }
}

// MARK: - Obsidian discovery

/// A vault Obsidian itself knows about, parsed from its `obsidian.json` registry.
struct DetectedObsidianVault: Identifiable, Hashable {
    var id: String { path.path }
    let path: URL
    let isOpen: Bool

    var name: String { path.lastPathComponent }
    /// True when the folder still exists on disk.
    var exists: Bool { FileManager.default.fileExists(atPath: path.path) }
}

/// Reads the user's installed Obsidian vaults so CmdMD can offer one-click
/// connection instead of forcing a manual folder hunt.
enum ObsidianLocator {
    /// `~/Library/Application Support/obsidian/obsidian.json`
    private static var registryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("obsidian/obsidian.json")
    }

    /// True when the folder carries Obsidian's `.obsidian` config directory.
    static func isObsidianVault(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let configPath = url.appendingPathComponent(".obsidian").path
        return FileManager.default.fileExists(atPath: configPath, isDirectory: &isDir) && isDir.boolValue
    }

    /// Detected vaults from Obsidian's registry, most-recently-opened first.
    /// Returns an empty list when Obsidian isn't installed or the file is absent.
    static func detectedVaults() -> [DetectedObsidianVault] {
        guard let registryURL,
              let data = try? Data(contentsOf: registryURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]] else {
            return []
        }

        return vaults.values
            .compactMap { entry -> (DetectedObsidianVault, Double)? in
                guard let path = entry["path"] as? String else { return nil }
                let ts = (entry["ts"] as? Double) ?? 0
                let isOpen = (entry["open"] as? Bool) ?? false
                let vault = DetectedObsidianVault(path: URL(fileURLWithPath: path), isOpen: isOpen)
                return (vault, ts)
            }
            .filter { $0.0.exists }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}

/// In-memory index entry (never persisted).
struct VaultNote: Identifiable {
    var id: String { path }
    let path: String
    let title: String
    let modifiedAt: Date
    /// Absolute location, used by Omnisearch to open the file directly.
    let url: URL
    /// `searchKey(for:)` of title and path, built once with the index (off the
    /// main thread) so per-keystroke completion matching is a plain byte search.
    let titleKey: [UInt8]
    let pathKey: [UInt8]

    init(path: String, title: String, modifiedAt: Date, url: URL? = nil) {
        self.path = path
        self.title = title
        self.modifiedAt = modifiedAt
        self.url = url ?? URL(fileURLWithPath: path, isDirectory: false)
        self.titleKey = Self.searchKey(for: title)
        self.pathKey = Self.searchKey(for: path)
    }

    /// Case-insensitive match key: precomposed (NFC — the file system often
    /// hands back decomposed names, e.g. Korean), lowercased, as UTF-8 bytes.
    static func searchKey(for string: String) -> [UInt8] {
        Array(string.precomposedStringWithCanonicalMapping.lowercased().utf8)
    }
}

enum VaultError: LocalizedError {
    case accessDenied
    case bookmarkNotFound
    case folderNotFound
    case indexingFailed
    
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Cannot access vault folder. Please grant permission."
        case .bookmarkNotFound:
            return "Vault bookmark not found. Please re-register the vault."
        case .folderNotFound:
            return "Vault folder not found."
        case .indexingFailed:
            return "Failed to index vault contents."
        }
    }
}
