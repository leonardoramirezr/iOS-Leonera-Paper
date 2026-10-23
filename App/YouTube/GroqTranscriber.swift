import Foundation

/// Transcript of a video, with the time of each segment. Kept between retries of an import.
struct Transcript: Codable, Sendable {
    struct Segment: Codable, Sendable {
        /// Seconds from the start of the video.
        var start: Double
        var end: Double
        var text: String
    }

    var text: String
    var language: String?
    var segments: [Segment]
}

/// Speech to text with Whisper on Groq (`/openai/v1/audio/transcriptions`).
enum GroqTranscriber {
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    private struct Response: Decodable {
        struct Segment: Decodable {
            var start: Double
            var end: Double
            var text: String
        }

        var text: String
        var language: String?
        var segments: [Segment]?
    }

    /// Transcribes one audio file. Segment times are shifted by `offset` (where the file starts
    /// within the video).
    static func transcribe(_ file: URL, offset: Double, apiKey: String, model: String) async throws -> Transcript {
        let boundary = "leonera-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(text: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model)
        field("response_format", "verbose_json")
        field("temperature", "0")
        body.append(text: "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n")
        body.append(text: "Content-Type: \(file.pathExtension == "m4a" ? "audio/mp4" : "video/mp4")\r\n\r\n")
        body.append(try Data(contentsOf: file))
        body.append(text: "\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try await AIService.send(request, body: body, service: "Groq")
        let response = try JSONDecoder().decode(Response.self, from: data)
        let segments = (response.segments ?? []).map {
            Transcript.Segment(start: $0.start + offset, end: $0.end + offset,
                               text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Transcript(text: response.text.trimmingCharacters(in: .whitespacesAndNewlines),
                          language: response.language, segments: segments.filter { !$0.text.isEmpty })
    }
}

private extension Data {
    mutating func append(text: String) {
        append(Data(text.utf8))
    }
}
