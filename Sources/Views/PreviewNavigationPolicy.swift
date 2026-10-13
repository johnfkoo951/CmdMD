import Foundation
import WebKit

/// What a navigation inside the rendered page may do. Pure, so the rules are
/// testable; the preview and the PDF exporter both consult it.
///
/// Only a user's link click (`.linkActivated`) in the main frame — or one
/// asking for a new window — leaves the page: http/https/mailto/obsidian open
/// externally, cmdmd:// routes inside the app, linked notes open in a tab and
/// other local files are revealed in Finder, never launched (a `.command` or
/// `.app` link would otherwise run). Everything else a note can trigger
/// without a click — meta refresh, scripted location changes, form posts,
/// iframe loads — is cancelled, except the page's own load and in-page
/// `#anchor` jumps.
enum PreviewNavigationPolicy {
    enum Decision: Equatable {
        case allow
        case cancel
        case openExternal(URL)
        case openInternal(URL)
        case openNote(URL)
        case revealInFinder(URL)
    }

    static let externalSchemes: Set<String> = ["http", "https", "mailto", "obsidian"]
    static let noteExtensions: Set<String> = ["md", "markdown", "txt"]

    /// The URL WebKit reports for a page loaded with `loadHTMLString(_:baseURL:)`.
    static func pageURL(forBaseURL baseURL: URL?) -> URL {
        baseURL ?? URL(string: "about:blank")!
    }

    /// - Parameters:
    ///   - isMainFrame: `targetFrame?.isMainFrame ?? true` — a nil target
    ///     frame is a new-window request, judged like the main frame.
    ///   - pageURL: the page currently loaded (see `pageURL(forBaseURL:)`).
    static func decide(url: URL?, navigationType: WKNavigationType, isMainFrame: Bool, pageURL: URL) -> Decision {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""

        // The page CSP blocks frames; only WebKit's own initial about:blank
        // documents get through here.
        guard isMainFrame else { return scheme == "about" ? .allow : .cancel }

        if isSameDocument(url, pageURL), navigationType != .linkActivated || hasFragment(url) {
            return .allow
        }
        guard navigationType == .linkActivated else { return .cancel }

        switch scheme {
        case "cmdmd":
            return .openInternal(url)
        case _ where externalSchemes.contains(scheme):
            return .openExternal(url)
        case "file":
            let target = withoutFragment(url)
            return noteExtensions.contains(target.pathExtension.lowercased())
                ? .openNote(target)
                : .revealInFinder(target)
        default:
            return .cancel
        }
    }

    /// Same document, ignoring any fragment.
    static func isSameDocument(_ a: URL, _ b: URL) -> Bool {
        if a.isFileURL, b.isFileURL {
            return (a.host ?? "") == (b.host ?? "")
                && a.standardizedFileURL.path == b.standardizedFileURL.path
                && a.hasDirectoryPath == b.hasDirectoryPath
        }
        return withoutFragment(a).absoluteString == withoutFragment(b).absoluteString
    }

    /// String-based on purpose: for the NSURL WebKit hands over, `fragment`
    /// is nil on non-hierarchical URLs such as a draft's `about:blank#x`.
    static func hasFragment(_ url: URL) -> Bool {
        anchorString(url).contains("#")
    }

    static func withoutFragment(_ url: URL) -> URL {
        let string = anchorString(url)
        guard let hash = string.firstIndex(of: "#") else { return url }
        return URL(string: String(string[..<hash])) ?? url
    }

    /// `absoluteString`, except that an `about:` URL's `%23` reads as the
    /// fragment delimiter: macOS 15's Foundation spells a draft's
    /// `about:blank#x` as `about:blank%23x`, even when built by CFURL from
    /// bytes the way WebKit builds the URLs it hands over.
    private static func anchorString(_ url: URL) -> String {
        let string = url.absoluteString
        guard url.scheme?.lowercased() == "about" else { return string }
        return string.replacingOccurrences(of: "%23", with: "#")
    }
}
