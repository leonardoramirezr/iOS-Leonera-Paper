import Foundation

/// Metadata of a YouTube video. Kept between retries of an import.
struct YouTubeVideoInfo: Codable, Sendable {
    var id: String
    var title: String
    var channel: String?
    /// Length in seconds.
    var duration: Int?
    var thumbnailURL: URL?
}

/// A direct media URL of a video, as returned by one InnerTube client.
struct YouTubeStream: Sendable {
    var url: URL
    var itag: Int
    var mimeType: String
    var bitrate: Int
    var contentLength: Int64?
    /// Downloads must use the user agent of the client that asked for the URL.
    var userAgent: String

    var isAudioOnly: Bool { mimeType.hasPrefix("audio/") }
    var fileExtension: String { isAudioOnly ? "m4a" : "mp4" }
}

enum YouTubeError: LocalizedError {
    case unavailable(String)
    case liveStream
    case noStreams
    case blocked
    case httpStatus(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "YouTube no deja reproducir este vídeo: \(reason)"
        case .liveStream: return "Las emisiones en directo no se pueden resumir; vuelve a intentarlo cuando terminen."
        case .noStreams: return "YouTube no ofrece ningún audio descargable para este vídeo."
        case .blocked: return "YouTube rechazó la descarga del audio. Vuelve a intentarlo más tarde."
        case .httpStatus(let code): return "YouTube respondió con el error HTTP \(code)."
        case .badResponse: return "YouTube devolvió una respuesta inesperada."
        }
    }
}

/// Gets the audio of a YouTube video through the InnerTube player API, as yt-dlp does with
/// the clients that need no JavaScript: their stream URLs come ready to download, with no
/// signature to decipher and no PO token.
@MainActor
enum YouTubeClient {
    struct Client: Sendable {
        var name: String
        var nameID: Int
        var version: String
        var userAgent: String
        var device: [String: String]
        var androidSdkVersion: Int?
    }

    /// Values from yt-dlp (`yt_dlp/extractor/youtube/_base.py`, October 2026). When YouTube
    /// stops serving one of these clients, copy the current values from there.
    static let clients: [Client] = [
        // yt-dlp's default client without JavaScript. Not available for "made for kids" videos.
        Client(name: "VISIONOS", nameID: 101, version: "1.02",
               userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
               device: ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
                        "osName": "visionOS", "osVersion": "26.5.23O471"]),
        // Fallback: since August 2026 YouTube refuses most of its downloads without a PO token.
        Client(name: "ANDROID_VR", nameID: 28, version: "1.65.10",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
               device: ["deviceMake": "Oculus", "deviceModel": "Quest 3",
                        "osName": "Android", "osVersion": "12L"],
               androidSdkVersion: 32),
    ]

    /// Downloads come in ranges: YouTube throttles requests for the whole file.
    private static let rangeSize: Int64 = 5 << 20

    /// Visitor ID that YouTube hands out; reused for the next videos.
    private static var visitorData: String?

    /// Downloads the audio of `videoID` into `folder`. Audio-only AAC streams come first and the
    /// video with sound (whose audio track is used) only if YouTube refuses all of them. Each
    /// client is tried in turn.
    static func downloadMedia(videoID: String, into folder: URL,
                              status: @escaping @MainActor (String) -> Void) async throws -> (info: YouTubeVideoInfo, file: URL) {
        var firstError: Error?
        for client in clients {
            do {
                status("Buscando el audio del vídeo…")
                let (info, streams) = try await player(videoID: videoID, client: client)
                guard !streams.isEmpty else { throw YouTubeError.noStreams }
                for stream in streams {
                    let destination = folder.appendingPathComponent("media.\(stream.fileExtension)")
                    let label = stream.isAudioOnly ? "Descargando el audio" : "Descargando el vídeo"
                    do {
                        try await download(stream, to: destination) { fraction in
                            status("\(label)… \(Int(fraction * 100)) %")
                        }
                        return (info, destination)
                    } catch YouTubeError.blocked, YouTubeError.httpStatus {
                        continue
                    }
                }
                throw YouTubeError.blocked
            } catch let error as YouTubeError {
                if case .liveStream = error { throw error }
                firstError = firstError ?? error
            }
        }
        throw firstError ?? YouTubeError.noStreams
    }

    // MARK: - Player API

    private static func player(videoID: String, client: Client) async throws -> (YouTubeVideoInfo, [YouTubeStream]) {
        var json = try await requestPlayer(videoID: videoID, client: client, visitorData: visitorData)
        if status(of: json) != "OK", let fresh = extractVisitorData(from: json), fresh != visitorData {
            // Without a visitor ID YouTube often answers "Sign in to confirm you're not a bot".
            // That refusal carries a fresh ID to retry with.
            visitorData = fresh
            json = try await requestPlayer(videoID: videoID, client: client, visitorData: fresh)
        }

        let playability = json["playabilityStatus"] as? [String: Any]
        guard status(of: json) == "OK" else {
            let reason = playability?["reason"] as? String
                ?? (playability?["messages"] as? [String])?.first
                ?? status(of: json)
                ?? "motivo desconocido"
            throw YouTubeError.unavailable(reason)
        }
        let details = json["videoDetails"] as? [String: Any] ?? [:]
        if details["isLive"] as? Bool == true || details["isUpcoming"] as? Bool == true {
            throw YouTubeError.liveStream
        }
        let thumbnails = (details["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let info = YouTubeVideoInfo(
            id: videoID,
            title: (details["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Vídeo de YouTube",
            channel: details["author"] as? String,
            duration: (details["lengthSeconds"] as? String).flatMap { Int($0) },
            thumbnailURL: (thumbnails.last?["url"] as? String).flatMap(URL.init(string:))
        )

        let streaming = json["streamingData"] as? [String: Any] ?? [:]
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        let muxed = streaming["formats"] as? [[String: Any]] ?? []
        func stream(_ format: [String: Any]) -> YouTubeStream? {
            guard let string = format["url"] as? String, let url = URL(string: string),
                  let mimeType = format["mimeType"] as? String,
                  let itag = format["itag"] as? Int else { return nil }
            return YouTubeStream(url: url, itag: itag, mimeType: mimeType,
                                 bitrate: format["bitrate"] as? Int ?? 0,
                                 contentLength: (format["contentLength"] as? String).flatMap { Int64($0) },
                                 userAgent: client.userAgent)
        }
        // AAC audio, which AVFoundation decodes (WebM/Opus is not used), without dynamic range
        // compression and, if the video has several audio tracks, the original one.
        let audio = adaptive
            .filter { format in
                let track = format["audioTrack"] as? [String: Any]
                return (format["mimeType"] as? String)?.hasPrefix("audio/mp4") == true
                    && format["isDrc"] as? Bool != true
                    && (track == nil || track?["audioIsDefault"] as? Bool == true)
            }
            .compactMap(stream)
            .sorted { $0.bitrate < $1.bitrate }
        let video = muxed
            .filter { ($0["mimeType"] as? String)?.hasPrefix("video/mp4") == true }
            .compactMap(stream)
            .sorted { $0.bitrate < $1.bitrate }
        return (info, audio + video)
    }

    private static func requestPlayer(videoID: String, client: Client, visitorData: String?) async throws -> [String: Any] {
        var context: [String: Any] = client.device
        context["clientName"] = client.name
        context["clientVersion"] = client.version
        context["userAgent"] = client.userAgent
        context["hl"] = "en"
        context["timeZone"] = "UTC"
        context["utcOffsetMinutes"] = 0
        if let sdk = client.androidSdkVersion { context["androidSdkVersion"] = sdk }
        if let visitorData { context["visitorData"] = visitorData }
        let body: [String: Any] = [
            "context": ["client": context],
            "videoId": videoID,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!,
                                 timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(client.nameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw YouTubeError.httpStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeError.badResponse
        }
        return json
    }

    private static func status(of json: [String: Any]) -> String? {
        (json["playabilityStatus"] as? [String: Any])?["status"] as? String
    }

    private static func extractVisitorData(from json: [String: Any]) -> String? {
        guard let value = (json["responseContext"] as? [String: Any])?["visitorData"] as? String else { return nil }
        let decoded = value.removingPercentEncoding ?? value
        return decoded.isEmpty ? nil : decoded
    }

    // MARK: - Download

    private static func download(_ stream: YouTubeStream, to destination: URL,
                                 progress: (Double) -> Void) async throws {
        let partial = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            var offset: Int64 = 0
            var total = stream.contentLength
            progress(0)
            while total.map({ offset < $0 }) ?? true {
                try Task.checkCancellation()
                var end = offset + rangeSize - 1
                if let total { end = min(end, total - 1) }
                var request = URLRequest(url: stream.url, timeoutInterval: 60)
                request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw YouTubeError.badResponse }
                switch http.statusCode {
                case 206:
                    guard !data.isEmpty else { throw YouTubeError.badResponse }
                    try handle.write(contentsOf: data)
                    offset += Int64(data.count)
                    if total == nil {
                        // «bytes 0-5242879/12345678»; without it, a short range is the last one.
                        total = (http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last)
                            .flatMap { Int64($0) }
                            ?? (Int64(data.count) < rangeSize ? offset : nil)
                    }
                case 200:
                    // The server ignored the range and sent the whole file.
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: data)
                    offset = Int64(data.count)
                    total = offset
                case 403, 410:
                    throw YouTubeError.blocked
                default:
                    throw YouTubeError.httpStatus(http.statusCode)
                }
                if let total, total > 0 { progress(Double(offset) / Double(total)) }
            }
            guard offset > 0 else { throw YouTubeError.badResponse }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
