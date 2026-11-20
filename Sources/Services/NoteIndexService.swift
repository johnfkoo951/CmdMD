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
        buildIndexes(roots: roots, limit: limit).notes
    }

    /// The notes plus the images beside them (see `AttachmentIndex`), from
    /// one walk: a second walk would double the time on a large vault.
    static func buildIndexes(roots: [URL], limit: Int = 100_000) -> (notes: [VaultNote], attachments: AttachmentIndex) {
        var notes: [VaultNote] = []
        var images: [URL] = []
        var seenPaths: Set<String> = []

        // Runs at launch and on every switch back to CmdMD, so the per-file
        // work is kept to what the index needs (it was ~1.1 s for 20k notes).
        // A file can only be met twice when one root holds another, and only
        // then are paths hashed (Korean names hash slowly: they're normalized
        // first).
        let resolvedRoots = roots.map { $0.resolvingSymlinksInPath().path }
        let rootsOverlap = resolvedRoots.indices.contains { i in
            resolvedRoots.indices.contains { j in
                i != j && (resolvedRoots[i] == resolvedRoots[j]
                           || resolvedRoots[j].utf8.starts(with: (resolvedRoots[i] + "/").utf8))
            }
        }
        /// The file's standardized URL, as the index has always held it (tabs
        /// and recents compare URLs byte for byte), without its stat. A walked
        /// path has no `.`, `..` or `//`, so standardizing only drops a leading
        /// /private (the walk reports roots under /tmp and /var that way) and
        /// respells a non-ASCII name decomposed; the walk hands back the name
        /// as stored, often composed. CoreFoundation builds that spelling from
        /// the file system representation, escaping as the walk does (`;` as
        /// %3B, which `URL(fileURLWithPath:)` leaves bare): equal to the
        /// standardized URL for all 32,720 files of the vaults and Downloads.
        /// The representation goes into one reused buffer (the NSString
        /// property hands back an autoreleased one per call).
        var representation = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        func standardized(_ fileURL: URL) -> URL {
            let path = fileURL.path
            if path.utf8.starts(with: "/private/".utf8) { return fileURL.standardizedFileURL }
            guard path.utf8.contains(where: { $0 >= 0x80 }) else { return fileURL }
            return representation.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress,
                      (path as NSString).getFileSystemRepresentation(base, maxLength: buffer.count) else {
                    return fileURL.standardizedFileURL
                }
                let length = strlen(base)
                return base.withMemoryRebound(to: UInt8.self, capacity: length) {
                    CFURLCreateFromFileSystemRepresentation(nil, $0, length, false) as URL
                }
            }
        }

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            let rootPrefix = root.standardizedFileURL.path + "/"
            let rootPrefixBytes = Array(rootPrefix.utf8)

            var rootCount = 0
            var rootImageCount = 0
            for case let fileURL as URL in enumerator {
                // A newer rebuild supersedes this one (AppState.rebuildNoteIndex).
                if Task.isCancelled { return ([], .empty) }
                let name = fileURL.lastPathComponent
                if skippedFolderNames.contains(name),
                   (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = fileURL.pathExtension.lowercased()
                if LocalAssetURL.imageExtensions.contains(ext) {
                    if rootImageCount < limit, !rootsOverlap || seenPaths.insert(standardized(fileURL).path).inserted {
                        images.append(fileURL)
                        rootImageCount += 1
                    }
                    continue
                }
                guard supportedExtensions.contains(ext) else { continue }
                let url = standardized(fileURL)
                let path = url.path
                if rootsOverlap { guard seenPaths.insert(path).inserted else { continue } }

                // The enumerated URL carries the prefetched date; a
                // standardized copy would stat the file again.
                let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast

                let fileName = url == fileURL ? name : url.lastPathComponent
                notes.append(VaultNote(
                    path: relativePath(path, under: rootPrefix, bytes: rootPrefixBytes, fileName: fileName),
                    // The name less its note extension (ASCII, so one byte a letter).
                    title: String(decoding: fileName.utf8.dropLast(ext.utf8.count + 1), as: UTF8.self),
                    modifiedAt: modified,
                    url: url
                ))

                rootCount += 1
                if rootCount >= limit { break }
            }
        }

        return (Array(sorted(notes).prefix(limit)), AttachmentIndex(files: images))
    }

    /// Recently-modified notes first so completions surface what the user is
    /// actually working with.
    private static func sorted(_ notes: [VaultNote]) -> [VaultNote] {
        notes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// `path` below the root (`rootPrefix`: the root's standardized path and
    /// a slash). Bytes first: `String.hasPrefix` compares canonically, slowly
    /// for Korean names, and both sides are usually spelled alike. A root
    /// spelled composed against a decomposed file path still matches through
    /// the canonical compare.
    private static func relativePath(_ path: String, under rootPrefix: String, bytes: [UInt8], fileName: String) -> String {
        if path.utf8.starts(with: bytes) {
            return String(decoding: path.utf8.dropFirst(bytes.count), as: UTF8.self)
        }
        guard path.hasPrefix(rootPrefix) else { return fileName }
        return String(path.dropFirst(rootPrefix.count))
    }
}
