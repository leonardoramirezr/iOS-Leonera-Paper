import Foundation
import UIKit

enum YouTubeImportError: LocalizedError {
    case missingGroqKey
    case missingGeminiKey
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingGroqKey: return "Falta la clave de la API de Groq (Ajustes › Resúmenes de YouTube)."
        case .missingGeminiKey: return "Falta la clave de la API de Gemini (Ajustes › Resúmenes de YouTube)."
        case .emptyTranscript: return "Whisper no encontró voz en el audio del vídeo."
        }
    }
}

/// Saves a YouTube video as an article: downloads its audio, transcribes it with Whisper
/// (Groq), summarizes it with Gemini and writes a Markdown file with the summary followed by
/// the transcript.
@MainActor
enum YouTubeImporter {
    static func importVideo(id videoID: String, settings: YouTubeSettings.Configuration, storage: ArticleStorage,
                            progress: @escaping @MainActor (String) -> Void) async throws -> Article {
        guard !settings.groqAPIKey.isEmpty else { throw YouTubeImportError.missingGroqKey }
        guard !settings.geminiAPIKey.isEmpty else { throw YouTubeImportError.missingGeminiKey }

        let activity = BackgroundActivity(name: "Resumir vídeo de YouTube")
        defer { activity.end() }

        // The video data, the downloaded audio and the transcript stay in a work folder until
        // the article is saved, so a retry resumes where the previous attempt failed.
        let work = workFolder(for: videoID)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let infoURL = work.appendingPathComponent("video.json")
        let transcriptURL = work.appendingPathComponent("transcript.json")
        var info = load(YouTubeVideoInfo.self, from: infoURL)
        var transcript = load(Transcript.self, from: transcriptURL)

        if transcript == nil || info == nil {
            var media = info == nil ? nil : downloadedMedia(in: work)
            if media == nil {
                let downloaded = try await YouTubeClient.downloadMedia(videoID: videoID, into: work, status: progress)
                info = downloaded.info
                save(downloaded.info, to: infoURL)
                media = downloaded.file
            }
            if let media {
                let fresh = try await transcribe(media, duration: info?.duration, settings: settings,
                                                 work: work, progress: progress)
                save(fresh, to: transcriptURL)
                transcript = fresh
                try? FileManager.default.removeItem(at: media)
            }
        }
        guard let info, let transcript else { throw YouTubeError.noStreams }

        progress("Resumiendo con Gemini…")
        let summary = try await GeminiSummarizer.summarize(transcript.text, title: info.title, channel: info.channel,
                                                           language: settings.summaryLanguage,
                                                           apiKey: settings.geminiAPIKey, model: settings.summaryModel)

        progress("Guardando Markdown…")
        let folder = try storage.makeFolder(for: info.title)
        do {
            let leadImage = await saveThumbnail(of: info, in: storage.imagesURL(inFolder: folder.url))
            let savedAt = Date()
            let markdown = compose(info: info, summary: summary, transcript: transcript, leadImage: leadImage,
                                   settings: settings, savedAt: savedAt)
            let fileName = "\(folder.name).md"
            try markdown.write(to: folder.url.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: work)

            return Article(
                id: UUID(),
                title: info.title,
                sourceURL: YouTubeLink.watchURL(for: videoID),
                siteName: "YouTube",
                author: info.channel,
                excerpt: summary.overview,
                published: nil,
                folderName: folder.name,
                fileName: fileName,
                savedAt: savedAt,
                leadImage: leadImage,
                readingProgress: nil,
                drive: nil,
                videoID: videoID,
                videoDuration: info.duration
            )
        } catch {
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
    }

    /// Deletes the work files of a video whose import was dismissed.
    static func discardWorkFiles(for url: URL) {
        guard let id = YouTubeLink.videoID(from: url) else { return }
        try? FileManager.default.removeItem(at: workFolder(for: id))
    }

    // MARK: - Steps

    private static func transcribe(_ media: URL, duration: Int?, settings: YouTubeSettings.Configuration,
                                   work: URL, progress: @escaping @MainActor (String) -> Void) async throws -> Transcript {
        progress("Preparando el audio…")
        let partsFolder = work.appendingPathComponent("parts", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: partsFolder) }
        let chunks: [AudioChunker.Chunk]
        do {
            let total = duration.map(Double.init)
            chunks = try await Task.detached(priority: .userInitiated) {
                try await AudioChunker.split(media, into: partsFolder, duration: total) { fraction in
                    Task { @MainActor in progress("Preparando el audio… \(Int(fraction * 100)) %") }
                }
            }.value
        } catch {
            // AVFoundation could not read it: Groq gets the downloaded audio if it fits.
            guard AudioChunker.canUploadDirectly(media) else { throw error }
            chunks = [AudioChunker.Chunk(url: media, offset: 0)]
        }

        var texts: [String] = []
        var segments: [Transcript.Segment] = []
        var language: String?
        for (index, chunk) in chunks.enumerated() {
            progress(chunks.count == 1
                     ? "Transcribiendo con Whisper…"
                     : "Transcribiendo con Whisper (parte \(index + 1) de \(chunks.count))…")
            let part = try await GroqTranscriber.transcribe(chunk.url, offset: chunk.offset,
                                                            apiKey: settings.groqAPIKey, model: settings.transcriptionModel)
            if !part.text.isEmpty { texts.append(part.text) }
            segments += part.segments
            language = language ?? part.language
        }
        guard !texts.isEmpty else { throw YouTubeImportError.emptyTranscript }
        return Transcript(text: texts.joined(separator: " "), language: language, segments: segments)
    }

    /// Saves the largest thumbnail available as `images/thumbnail.jpg`.
    private static func saveThumbnail(of info: YouTubeVideoInfo, in folder: URL) async -> String? {
        var candidates = ["maxresdefault", "hq720", "hqdefault"].compactMap {
            URL(string: "https://i.ytimg.com/vi/\(info.id)/\($0).jpg")
        }
        if let url = info.thumbnailURL { candidates.append(url) }
        for url in candidates {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(ImageDownloader.userAgent, forHTTPHeaderField: "User-Agent")
            guard let result = try? await URLSession.shared.data(for: request),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: result.0), image.size.width >= 200 else { continue }
            let data = result.0
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try (image.jpegData(compressionQuality: 0.85) ?? data).write(to: folder.appendingPathComponent("thumbnail.jpg"))
                return "images/thumbnail.jpg"
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: - Markdown

    static func compose(info: YouTubeVideoInfo, summary: VideoSummary, transcript: Transcript, leadImage: String?,
                        settings: YouTubeSettings.Configuration, savedAt: Date) -> String {
        let yaml = ArticleImporter.yaml
        let escape = ArticleImporter.escape
        let url = YouTubeLink.watchURL(for: info.id).absoluteString
        var front = ["---", "title: \(yaml(info.title))", "source: \(url)", "site: \"YouTube\""]
        if let channel = info.channel, !channel.isEmpty { front.append("author: \(yaml(channel))") }
        front.append("video: \(yaml(info.id))")
        if let duration = info.duration { front.append("duration: \(duration)") }
        front.append("transcription: \(yaml(settings.transcriptionModel))")
        front.append("summary: \(yaml(settings.summaryModel))")
        front.append("saved: \(ISO8601DateFormatter().string(from: savedAt))")
        front.append("---")

        var meta: [String] = []
        if let channel = info.channel, !channel.isEmpty { meta.append(escape(channel)) }
        meta.append("[YouTube](\(url))")
        if let duration = info.duration { meta.append(YouTubeLink.formatDuration(duration)) }

        var parts = [front.joined(separator: "\n"), "# \(escape(info.title))", "*\(meta.joined(separator: " · "))*"]
        if let leadImage { parts.append("![\(escape(info.title))](\(leadImage))") }
        parts.append(summary.markdown)
        parts.append("## Transcripción")
        parts.append(contentsOf: transcriptParagraphs(transcript, videoID: info.id))
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Groups the segments into paragraphs of about a minute, each starting with a link to that
    /// moment of the video. Without segments the whole text is one paragraph.
    private static func transcriptParagraphs(_ transcript: Transcript, videoID: String) -> [String] {
        guard !transcript.segments.isEmpty else { return [ArticleImporter.escape(transcript.text)] }
        var paragraphs: [String] = []
        var current: [String] = []
        var start = transcript.segments[0].start
        func flush() {
            guard !current.isEmpty else { return }
            let seconds = Int(start)
            let link = "[\(YouTubeLink.formatDuration(seconds))](\(YouTubeLink.watchURL(for: videoID, at: seconds)))"
            paragraphs.append("\(link) \(ArticleImporter.escape(current.joined(separator: " ")))")
            current = []
        }
        for segment in transcript.segments {
            if current.isEmpty { start = segment.start }
            current.append(segment.text)
            let elapsed = segment.end - start
            let endsSentence = segment.text.last.map { ".?!…".contains($0) } ?? false
            if (elapsed >= 60 && endsSentence) || elapsed >= 120 { flush() }
        }
        flush()
        return paragraphs
    }

    // MARK: - Work files

    private static func workFolder(for videoID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YouTube", isDirectory: true)
            .appendingPathComponent(videoID, isDirectory: true)
    }

    private static func downloadedMedia(in folder: URL) -> URL? {
        ["m4a", "mp4"]
            .map { folder.appendingPathComponent("media.\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Asks iOS for a little more time to finish the import if the app goes to the background.
@MainActor
private final class BackgroundActivity {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        // iOS calls the expiration handler on the main thread.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
