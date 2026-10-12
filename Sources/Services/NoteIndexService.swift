import Foundation

/// Builds the wiki-link completion index by scanning note roots for Markdown
/// files. Only file names are read — never contents — so even large vaults
/// index quickly. Runs off the main thread (see AppState.rebuildNoteIndex).
enum NoteIndexService {
    static let supportedExtensions: Set<String> = ["md", "markdown", "txt"]

    /// `limit` is a safety ceiling for pathological folders (e.g. a dev tree
    /// full of node_modules), not a working-set size: it caps each root on its
    /// own, so one huge root can't starve the vaults after it, and the result
    /// is truncated only after sorting, keeping the most recent notes.
    /// Folders of tool output, never notes. A dev tree's node_modules made one
    /// walk take 20 s+ for notes it then dropped. Hidden ones (.git, .build,
    /// .obsidian) are already skipped by the enumerator.
    static let skippedFolderNames: Set<String> = ["node_modules", "DerivedData", "Pods", "__pycache__", "venv"]

    static func buildIndex(roots: [URL], limit: Int = 100_000) -> [VaultNote] {
        var notes: [VaultNote] = []
        var seenPaths: Set<String> = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var rootCount = 0
            for case let fileURL as URL in enumerator {
                // A newer rebuild supersedes this one (AppState.rebuildNoteIndex).
                if Task.isCancelled { return [] }
                if skippedFolderNames.contains(fileURL.lastPathComponent),
                   (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                let standardized = fileURL.standardizedFileURL
                guard seenPaths.insert(standardized.path).inserted else { continue }

                // The enumerated URL carries the prefetched date; the
                // standardized copy would stat the file again.
                let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast

                notes.append(VaultNote(
                    path: relativePath(of: standardized, in: root),
                    title: standardized.deletingPathExtension().lastPathComponent,
                    modifiedAt: modified,
                    url: standardized
                ))

                rootCount += 1
                if rootCount >= limit { break }
            }
        }

        return Array(sorted(notes).prefix(limit))
    }

    /// Recently-modified notes first so completions surface what the user is
    /// actually working with.
    private static func sorted(_ notes: [VaultNote]) -> [VaultNote] {
        notes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func relativePath(of fileURL: URL, in root: URL) -> String {
        let rootPrefix = root.standardizedFileURL.path + "/"
        guard fileURL.path.hasPrefix(rootPrefix) else { return fileURL.lastPathComponent }
        return String(fileURL.path.dropFirst(rootPrefix.count))
    }
}
