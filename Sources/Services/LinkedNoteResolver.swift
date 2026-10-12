import Foundation

struct LinkedNoteResolver {
    private static let supportedExtensions: Set<String> = ["md", "markdown", "txt"]

    private let roots: [URL]
    private let fileManager: FileManager

    init(roots: [URL], fileManager: FileManager = .default) {
        self.roots = Self.uniqueStandardizedRoots(roots)
        self.fileManager = fileManager
    }

    func resolve(_ rawTarget: String) -> URL? {
        guard let target = Self.normalizedTarget(rawTarget) else { return nil }
        return resolve(normalizedTarget: target)
    }

    func resolve(normalizedTarget target: String) -> URL? {
        if let directURL = resolveDirectCandidate(named: target) {
            return directURL
        }

        return findLinkedNote(named: target)
    }

    func resolveDirectCandidate(named target: String) -> URL? {
        // Files only: a folder named like the note (`Archive.2023/`) is no note.
        directCandidateURLs(for: target).first { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    static func normalizedTarget(_ rawTarget: String) -> String? {
        splitTarget(rawTarget).note
    }

    /// Splits a wiki-link target into its note and heading: `Note#Heading` →
    /// ("Note", "Heading"), `#Heading` → (nil, "Heading"), a heading in the
    /// current note. As in Obsidian the last `#` segment names the heading,
    /// and a `#^block` id is no heading.
    /// (`split(separator:)` dropped the empty note of `#Heading` and looked
    /// for a note called "Heading".)
    /// The target arrives decoded (URLComponents decodes the `note=` query
    /// value) and isn't decoded again: a second pass turned `100% Done` into
    /// nil, so its link did nothing, and `a%20b` into `a b`.
    static func splitTarget(_ rawTarget: String) -> (note: String?, heading: String?) {
        var notePart = rawTarget[...]
        var heading: String?
        if let hash = rawTarget.firstIndex(of: "#") {
            notePart = rawTarget[..<hash]
            let fragment = rawTarget[rawTarget.index(after: hash)...]
            let last = fragment.split(separator: "#").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !last.isEmpty, !last.hasPrefix("^") { heading = last }
        }
        if let caret = notePart.firstIndex(of: "^") {
            notePart = notePart[..<caret]
        }
        let note = notePart.trimmingCharacters(in: .whitespacesAndNewlines)

        return (note.isEmpty ? nil : note, heading)
    }

    private func directCandidateURLs(for target: String) -> [URL] {
        // `isDirectory: false`, or a target naming an existing folder gets a
        // trailing slash that its `.md` variant keeps (`Archive.2023.md/`).
        if target.hasPrefix("/") {
            return fileNameVariants(for: URL(fileURLWithPath: target, isDirectory: false)).map(\.standardizedFileURL)
        }

        return roots.flatMap { root in
            fileNameVariants(for: root.appendingPathComponent(target, isDirectory: false))
                .map(\.standardizedFileURL)
        }
    }

    /// A target is a note name unless it ends in a note extension: Foundation
    /// reads any last `.token` as one, so `2024.05.01`, `Node.js` or `v1.2`
    /// got no `.md` and never resolved. Other extensions (`a.pdf`) still try
    /// the literal file, after the notes.
    private func fileNameVariants(for url: URL) -> [URL] {
        guard !Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { return [url] }
        let notes = [
            url.appendingPathExtension("md"),
            url.appendingPathExtension("markdown"),
            url.appendingPathExtension("txt")
        ]
        return url.pathExtension.isEmpty ? notes : notes + [url]
    }

    /// Walks the roots in priority order for the first note whose name matches.
    /// A folder-qualified target (`ProjectB/README`) must also match the note's
    /// trailing folders, as in Obsidian: by name alone it opened whichever
    /// README the walk met first.
    private func findLinkedNote(named target: String) -> URL? {
        // Only a note extension is dropped: `2024.05.01` is a name, not
        // `2024.05` with an `01` extension.
        let targetComponents = Self.removingNoteExtension(target)
            .split(separator: "/").map(String.init)
        guard let targetBasename = targetComponents.last else { return nil }
        // Roots already searched without a match. The document folder usually
        // sits inside the open folder, itself often a vault root, so walking
        // each root in full read the same files up to three times.
        var walked: Set<String> = []

        for root in roots {
            if walked.contains(where: { root.path.hasPrefix($0 + "/") }) { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                    if walked.contains(fileURL.path) { enumerator.skipDescendants() }
                    continue
                }

                let basename = fileURL.deletingPathExtension().lastPathComponent
                if basename.localizedCaseInsensitiveCompare(targetBasename) == .orderedSame,
                   Self.path(of: fileURL, endsWith: targetComponents) {
                    return fileURL.standardizedFileURL
                }
            }
            walked.insert(root.path)
        }

        return nil
    }

    /// `path` minus a trailing `.md`/`.markdown`/`.txt`, in any case.
    private static func removingNoteExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        guard supportedExtensions.contains(ext.lowercased()) else { return path }
        return String(path.dropLast(ext.count + 1))
    }

    /// Whether the note's path, minus its extension, ends in `components`,
    /// compared per component and case-insensitively. Absolute components, so
    /// a vault-relative link matches when only a subfolder is a root.
    private static func path(of fileURL: URL, endsWith components: [String]) -> Bool {
        let fileComponents = fileURL.deletingPathExtension().pathComponents
        guard fileComponents.count >= components.count else { return false }
        return zip(fileComponents.suffix(components.count), components).allSatisfy {
            $0.localizedCaseInsensitiveCompare($1) == .orderedSame
        }
    }

    private static func uniqueStandardizedRoots(_ roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }
}
