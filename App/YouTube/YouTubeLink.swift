import Foundation

/// Recognizes links to YouTube videos and turns them into one canonical URL, so the same
/// video shared as `youtu.be/…`, `/shorts/…` or `watch?v=…&si=…` is detected as a duplicate.
enum YouTubeLink {
    /// The 11-character video ID in `url`, or nil when it is not a link to a YouTube video.
    static func videoID(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = url.pathComponents.filter { $0 != "/" }

        var candidate: String?
        if host == "youtu.be" {
            candidate = parts.first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" {
            if parts == ["watch"] {
                candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["shorts", "live", "embed", "v", "e"].contains(parts[0]) {
                candidate = parts[1]
            }
        }
        guard let id = candidate, isValidID(id) else { return nil }
        return id
    }

    static func isVideo(_ url: URL) -> Bool {
        videoID(from: url) != nil
    }

    /// `https://www.youtube.com/watch?v=<id>` for any YouTube video link, nil for other links.
    static func canonicalURL(for url: URL) -> URL? {
        videoID(from: url).map(watchURL(for:))
    }

    static func watchURL(for id: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    /// «1:02:03» or «2:03».
    static func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    private static func isValidID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }
}
