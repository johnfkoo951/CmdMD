import Foundation
import UniformTypeIdentifiers
import WebKit

/// Local images for the preview and PDF views. A page loaded with
/// `loadHTMLString(_:baseURL:)` gets no file:// read access, so `![](x.png)`,
/// `![[x.png]]` and raw `<img src="docs/x.png">` all rendered broken. The
/// renderer instead points local image sources at `cmdmd-asset://local/<path>`
/// and `LocalAssetSchemeHandler` serves them — image files only, and only from
/// inside the note's folder, the open folder or a vault root. The page itself
/// stays file://, so the asset origin is cross-origin to it: without CORS
/// headers a note can display these images but never read their bytes.
enum LocalAssetURL {
    static let scheme = "cmdmd-asset"
    static let host = "local"

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "heif", "avif", "ico"
    ]

    private static let imageTagPattern = try! NSRegularExpression(
        pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]
    )
    private static let sourcePattern = try! NSRegularExpression(
        pattern: #"\ssrc="([^"]*)""#, options: [.caseInsensitive]
    )

    /// Rewrites the `src` of every local `<img>` in rendered body HTML. Runs
    /// on the final body, so Markdown images, wiki embeds, callout content and
    /// raw-HTML images are all covered; every tag there is renderer-emitted or
    /// re-serialized by `RawHTMLSanitizer` (double-quoted, no bare `>`), which
    /// keeps the pattern reliable.
    static func rewriteImageSources(in body: String, baseURL: URL?, roots: [URL]) -> String {
        let source = body as NSString
        let tags = imageTagPattern.matches(in: body, range: NSRange(location: 0, length: source.length))
        guard !tags.isEmpty else { return body }

        var result = ""
        result.reserveCapacity(body.utf8.count)
        var cursor = 0
        for tag in tags {
            result += source.substring(with: NSRange(location: cursor, length: tag.range.location - cursor))
            var tagHTML = source.substring(with: tag.range)
            let tagSource = tagHTML as NSString
            if let src = sourcePattern.firstMatch(in: tagHTML, range: NSRange(location: 0, length: tagSource.length)) {
                let value = RawHTMLSanitizer.decodeCharacterReferences(tagSource.substring(with: src.range(at: 1)))
                if let asset = assetURL(forImageSource: value, baseURL: baseURL, roots: roots) {
                    tagHTML = tagSource.replacingCharacters(in: src.range(at: 1), with: htmlEscape(asset))
                }
            }
            result += tagHTML
            cursor = NSMaxRange(tag.range)
        }
        result += source.substring(from: cursor)
        return result
    }

    /// The asset URL for an image source that names a local image file inside
    /// the note's folder (`baseURL`) or one of `roots`; nil for remote, data:,
    /// protocol-relative and non-image sources, and for anything that resolves
    /// outside every root (`../` cannot climb out — paths are standardized
    /// before the check).
    static func assetURL(forImageSource source: String, baseURL: URL?, roots: [URL]) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { return nil }

        let fileURL: URL
        if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            fileURL = url
        } else if trimmed.hasPrefix("/") {
            guard let url = URL(string: trimmed, relativeTo: URL(fileURLWithPath: "/")) else { return nil }
            fileURL = url
        } else {
            guard let baseURL, let url = URL(string: trimmed, relativeTo: baseURL) else { return nil }
            fileURL = url
        }

        // Standardize the DECODED path, so `%2e%2e` segments climb like `..`.
        let path = standardizedPath(fileURL.absoluteURL.path)
        guard imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        let allowedRoots = [baseURL].compactMap { $0 } + roots
        guard allowedRoots.contains(where: { isPath(path, inside: standardizedPath($0.path)) }),
              let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return "\(scheme)://\(host)\(encodedPath)"
    }

    /// Resolves `.` and `..` lexically. Unlike URL(fileURLWithPath:) it keeps
    /// the source's Unicode normalization (that one decomposes 한 to NFD) and
    /// never touches the disk.
    private static func standardizedPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// The file an asset request may read, or nil. Checked again here — the
    /// page could request any asset URL — after resolving symlinks on both
    /// sides, so a link inside a root can't reach a file outside it.
    static func fileURL(for url: URL, allowedRoots: [URL]) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host == host, url.path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: url.path).standardizedFileURL
        guard imageExtensions.contains(file.pathExtension.lowercased()) else { return nil }
        let resolved = file.resolvingSymlinksInPath()
        let allowed = allowedRoots.contains { root in
            root.isFileURL && isPath(resolved.path, inside: root.standardizedFileURL.resolvingSymlinksInPath().path)
        }
        return allowed ? resolved : nil
    }

    static func mimeType(for file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        guard root != "/" else { return false }
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Serves `cmdmd-asset://local/<path>` requests from disk (see `LocalAssetURL`).
/// One instance per web view configuration; `allowedRoots` is asked on each
/// request so it follows the page currently shown.
final class LocalAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    var allowedRoots: () -> [URL]
    /// Tasks still owed a response. WebKit raises if a task is answered after
    /// `stop`, and reads finish asynchronously.
    private var activeTasks: Set<ObjectIdentifier> = []

    init(allowedRoots: @escaping () -> [URL] = { [] }) {
        self.allowedRoots = allowedRoots
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let file = LocalAssetURL.fileURL(for: url, allowedRoots: allowedRoots()) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
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
                    "Content-Type": LocalAssetURL.mimeType(for: file),
                    "Content-Length": String(data.count),
                    "X-Content-Type-Options": "nosniff",
                    // Inert even if something manages to open one as a document.
                    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'"
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
