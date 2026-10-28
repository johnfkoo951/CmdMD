import Foundation

/// Image files in the open folder and vaults, by name, so `![[pic.png]]`
/// finds its picture the way Obsidian does. Obsidian writes the shortest link
/// that is unique in the vault, so a note in `Projects/` embeds
/// `assets/pic.png` as just `![[pic.png]]` — resolved against the note's own
/// folder, that showed a broken image.
///
/// Built from file names only, in the same walk as the note index
/// (`NoteIndexService.buildIndexes`). Equality is by build, not by content:
/// it is part of `MarkdownRenderOptions`, compared on every preview update,
/// and AppState keeps the old build when a rebuild finds the same files.
struct AttachmentIndex: Equatable {
    static let empty = AttachmentIndex(files: [])

    /// Lowercased file name → every file with that name.
    let filesByName: [String: [URL]]
    private let build = UUID()

    init(files: [URL]) {
        filesByName = Dictionary(grouping: files.map(\.standardizedFileURL)) {
            $0.lastPathComponent.lowercased()
        }
    }

    static func == (lhs: AttachmentIndex, rhs: AttachmentIndex) -> Bool {
        lhs.build == rhs.build
    }

    func hasSameFiles(as other: AttachmentIndex) -> Bool {
        filesByName == other.filesByName
    }

    /// The file an embed target names: `pic.png` anywhere, or `assets/pic.png`
    /// in a folder ending in `assets`. Names compare case-insensitively, as on
    /// the default macOS volume and in Obsidian. Nil when nothing matches.
    func resolve(_ target: String, from noteFolder: URL?) -> URL? {
        let components = target.split(separator: "/").map(String.init).filter { $0 != "." }
        guard let name = components.last,
              let candidates = filesByName[name.lowercased()] else { return nil }
        let matching = candidates.filter { url in
            let path = url.pathComponents
            guard path.count >= components.count else { return false }
            return zip(path.suffix(components.count), components).allSatisfy {
                $0.localizedCaseInsensitiveCompare($1) == .orderedSame
            }
        }
        return Self.preferred(matching, for: noteFolder?.standardizedFileURL)
    }

    /// Picks one file when several share the embed's name (two `image.png`s
    /// in different project folders is common: pasted screenshots get default
    /// names). `candidates` is never empty unless nothing matched.
    static func preferred(_ candidates: [URL], for noteFolder: URL?) -> URL? {
        guard candidates.count > 1 else { return candidates.first }
        // TODO: choose among same-named files.
        return candidates.first
    }
}
