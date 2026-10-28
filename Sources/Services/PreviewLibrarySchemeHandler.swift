import CryptoKit
import Foundation
import WebKit

/// Where a rendered page loads its scripts, styles and fonts from
/// (`MarkdownRenderOptions.libraries`).
enum PreviewLibraryOrigin: Equatable {
    /// The app's own copies at `cmdmd-lib://` — only the app's web views
    /// (preview, PDF export) can load them, and they need no network.
    case bundled
    /// Pinned jsDelivr files, for HTML that leaves the app (export, clipboard).
    case cdn
}

/// A script or stylesheet a page links, with its Subresource Integrity value
/// (nil only for a CDN theme without a pinned hash).
struct LibraryResource: Equatable {
    let url: String
    let integrity: String?
}

/// The preview's libraries ship inside the app, so a page works offline and
/// asks the network for nothing. Pages link them as `cmdmd-lib://lib/<path>`,
/// served read-only from two roots: PreviewLibs (KaTeX, Pele: the repo's
/// Resources/PreviewLibs, which package_app.sh copies into the app) and,
/// under `highlightr/`, Highlightr's resource bundle — the editor's own
/// highlight.js and themes, reused rather than shipped twice.
enum PreviewLibrary {
    static let scheme = "cmdmd-lib"
    static let host = "lib"
    /// What style-src and font-src name: stylesheets and fonts may come from
    /// any bundled file (KaTeX's CSS picks its fonts itself).
    static let origin = "\(scheme)://\(host)"
    static let highlightrPrefix = "highlightr"
    /// PreviewLibs' copies of highlight.js themes that Highlightr's bundle
    /// holds only as their base16 namesakes (see LICENSES.md).
    static let highlightThemesFolder = "highlight-themes"
    static let originalHighlightThemes: Set<String> = ["nord", "monokai"]

    /// Only these are served; anything else under a root stays unreachable.
    static let mimeTypes: [String: String] = [
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "woff2": "font/woff2"
    ]

    /// The folders requests may read from; nil when one isn't installed.
    struct Roots {
        var libraries: URL?
        var highlightr: URL?
    }

    /// The roots for an app (or bare executable) at these main-bundle URLs.
    /// Highlightr's files sit in its bundle's resource folder: Contents/Resources
    /// when the Xcode build system made it (the packaged app), the bundle
    /// itself when SwiftPM's native one did.
    static func roots(resourceURL: URL?, bundleURL: URL) -> Roots {
        Roots(
            libraries: firstDirectory(among: librariesCandidates(resourceURL: resourceURL)),
            highlightr: SyntaxHighlighter.resolvedHighlightrBundle(
                among: highlightrCandidates(resourceURL: resourceURL, bundleURL: bundleURL)
            ).flatMap { Bundle(url: $0)?.resourceURL }
        )
    }

    // A release build looks only inside the app. A checkout path compiled
    // into it would publish the builder's home folder, and a fallback to it
    // would run whatever scripts sit there: their hashes come from the same
    // bytes, so SRI passes anything.
    #if DEBUG
    /// The checkout this binary was built from, where `swift run`,
    /// `swift test` and dev bundles find what package_app.sh would copy.
    private static let checkout = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Services
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()
    #endif

    /// The packaged app's Contents/Resources/PreviewLibs, then (debug builds)
    /// the checkout's.
    static func librariesCandidates(resourceURL: URL?) -> [URL] {
        var candidates = [resourceURL?.appendingPathComponent("PreviewLibs", isDirectory: true)].compactMap { $0 }
        #if DEBUG
        candidates.append(checkout.appendingPathComponent("Resources/PreviewLibs", isDirectory: true))
        #endif
        return candidates
    }

    /// Where the editor's Highlightr looks (see SyntaxHighlighter), then (debug
    /// builds) the checkout's build folders: a test runner's main bundle is
    /// xctest, and a dev .app wrapping .build/debug/CmdMD carries no copy.
    static func highlightrCandidates(resourceURL: URL?, bundleURL: URL) -> [URL] {
        var candidates = SyntaxHighlighter.highlightrBundleCandidates(resourceURL: resourceURL, bundleURL: bundleURL)
        #if DEBUG
        candidates += ["debug", "release"].map {
            checkout.appendingPathComponent(".build/\($0)/Highlightr_Highlightr.bundle", isDirectory: true)
        }
        #endif
        return candidates
    }

    private static func firstDirectory(among candidates: [URL]) -> URL? {
        let found = candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if found == nil {
            Log.error("Preview libraries not found (re-package with scripts/package_app.sh)",
                      detail: candidates.map(\.path).joined(separator: ", "))
        }
        return found
    }

    // MARK: Paths

    /// Letters, digits and `._-`, not starting with a dot — everything the
    /// renderer links. Rules out `.` and `..`, hidden files, `%` escapes
    /// (`%2e%2e`, `%2f`), `\` and empty segments (`//`, an absolute path).
    private static func isSafeComponent(_ component: Substring) -> Bool {
        guard let first = component.first, first != "." else { return false }
        return component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The file a library path (`katex/katex.min.js`, `highlightr/nord.min.css`)
    /// names, or nil. Symlinks are resolved on both sides before the
    /// containment check, so a link inside a root can't reach a file outside it.
    static func fileURL(forPath path: String, roots: Roots) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy(isSafeComponent),
              let name = components.last,
              mimeTypes[(String(name) as NSString).pathExtension] != nil else { return nil }

        let inHighlightr = components.first == Substring(highlightrPrefix)
        guard let root = inHighlightr ? roots.highlightr : roots.libraries else { return nil }
        let relative = inHighlightr ? components.dropFirst() : components[...]
        guard !relative.isEmpty else { return nil }

        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let file = relative
            .reduce(root) { $0.appendingPathComponent(String($1)) }
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard rootPath != "/", file.path.hasPrefix(rootPath + "/"),
              FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return file
    }

    /// The file a request may read, or nil. The page could ask for any URL,
    /// so this takes nothing but `cmdmd-lib://lib/<path>`: no credentials,
    /// port, query or fragment, and the path as sent, never percent-decoded.
    static func fileURL(for url: URL, roots: Roots) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host == host,
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              path.hasPrefix("/") else { return nil }
        return fileURL(forPath: String(path.dropFirst()), roots: roots)
    }

    static func mimeType(for file: URL) -> String {
        mimeTypes[file.pathExtension] ?? "application/octet-stream"
    }

    // MARK: Page links

    private static let lock = NSLock()
    // Guarded by `lock`.
    private static var current = roots(resourceURL: Bundle.main.resourceURL, bundleURL: Bundle.main.bundleURL)
    /// Per path, hashed on first use: the bytes can't change while the app
    /// runs, and a render must not re-read a megabyte of highlight.js.
    private static var resources: [String: LibraryResource?] = [:]

    /// The roots the app serves and links. Only tests set it, to render
    /// against the checkout in a release build, which never falls back to it.
    /// (Not an environment variable: whoever sets one would pick the scripts.)
    static var installed: Roots {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            current = newValue
            resources = [:]
        }
    }

    /// An installed file's URL and Subresource Integrity value, or nil when
    /// it isn't installed. The hash comes from the bytes the handler serves,
    /// so a re-synced library needs no hard-coded value updated.
    static func resource(_ path: String) -> LibraryResource? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = resources[path] { return cached }
        let resource = fileURL(forPath: path, roots: current)
            .flatMap { try? Data(contentsOf: $0) }
            .map { LibraryResource(url: "\(origin)/\(path)", integrity: integrity(of: $0)) }
        resources[path] = resource
        return resource
    }

    static func integrity(of data: Data) -> String {
        "sha384-" + Data(SHA384.hash(data: data)).base64EncodedString()
    }

    /// An installed script or stylesheet's text, for pages that inline it.
    static func contents(_ path: String) -> String? {
        fileURL(forPath: path, roots: installed)
            .flatMap { try? Data(contentsOf: $0) }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Diagrams

    /// The folder cmds-pele's `bin/pele-sync.py` keeps current: Pele, the CMDS
    /// bootstrap and theme, and the stamp naming their versions.
    static let peleFolder = "cmds-pele"

    /// The Pele release the installed copy is, from the stamp the sync writes
    /// beside it (never hard-coded, so a re-sync needs no code change). Nil
    /// when it isn't installed or doesn't name a plain npm version. Read per
    /// call: only CDN pages with a diagram ask, and they read Pele's files too.
    static var peleVersion: String? { peleVersion(in: installed) }

    static func peleVersion(in roots: Roots) -> String? {
        struct Stamp: Decodable { let pele: String }
        guard let stamp = roots.libraries?.appendingPathComponent("\(peleFolder)/cmds-pele.version.json"),
              let data = try? Data(contentsOf: stamp),
              let version = try? JSONDecoder().decode(Stamp.self, from: data).pele,
              version.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
        else { return nil }
        return version
    }
}

/// Serves `cmdmd-lib://lib/<path>` requests (see `PreviewLibrary`).
final class PreviewLibrarySchemeHandler: NSObject, WKURLSchemeHandler {
    private let roots: PreviewLibrary.Roots
    /// Tasks still owed a response. WebKit raises if a task is answered after
    /// `stop`, and reads finish asynchronously.
    private var activeTasks: Set<ObjectIdentifier> = []

    init(roots: PreviewLibrary.Roots = PreviewLibrary.installed) {
        self.roots = roots
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let file = PreviewLibrary.fileURL(for: url, roots: roots) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasks.insert(id)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: file)
            DispatchQueue.main.async {
                guard let self, self.activeTasks.remove(id) != nil else { return }
                guard let data else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let headers = [
                    "Content-Type": PreviewLibrary.mimeType(for: file),
                    "Content-Length": String(data.count),
                    "X-Content-Type-Options": "nosniff",
                    // SRI and @font-face fetch in CORS mode, from a file:// page
                    // (origin "null"). The files are public libraries.
                    "Access-Control-Allow-Origin": "*",
                    // Fixed for the app's lifetime: an update ships a new app.
                    "Cache-Control": "max-age=31536000, immutable"
                ]
                if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                } else {
                    urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }
}
