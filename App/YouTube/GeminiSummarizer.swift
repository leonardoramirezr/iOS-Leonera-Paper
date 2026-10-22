import Foundation

/// Summary of a transcript in the "Main takeaways" style.
struct VideoSummary: Sendable {
    /// Markdown: overview paragraph, then `## Main takeaways` with a numbered list.
    var markdown: String
    /// Overview in plain text, for the library list.
    var overview: String?
}

/// Writes the summary with a Gemini model through Gemini's OpenAI-compatible API
/// (`/v1beta/openai/chat/completions`).
enum GeminiSummarizer {
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    static let heading = "## Main takeaways"

    private struct Message: Encodable {
        var role: String
        var content: String
    }

    private struct ChatRequest: Encodable {
        var model: String
        var messages: [Message]
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }

            var message: Message?
            var finish_reason: String?
        }

        var choices: [Choice]
    }

    static func summarize(_ transcript: String, title: String, channel: String?,
                          language: YouTubeSettings.SummaryLanguage, apiKey: String, model: String) async throws -> VideoSummary {
        var details = "Title: \(title)\n"
        if let channel, !channel.isEmpty { details += "Channel: \(channel)\n" }
        let chat = ChatRequest(model: model, messages: [
            Message(role: "system", content: instructions(language: language)),
            Message(role: "user", content: "\(details)\nTranscript:\n\(transcript)"),
        ])

        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data = try await AIService.send(request, body: try JSONEncoder().encode(chat), service: "Gemini")
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = response.choices.first?.message?.content ?? ""
        let markdown = clean(content)
        guard !markdown.isEmpty else {
            let reason = response.choices.first?.finish_reason.map { " (\($0))" } ?? ""
            throw AIServiceError(service: "Gemini", status: 200, message: "devolvió un resumen vacío\(reason).")
        }
        return VideoSummary(markdown: markdown, overview: overview(in: markdown))
    }

    private static func instructions(language: YouTubeSettings.SummaryLanguage) -> String {
        let target: String
        switch language {
        case .video: target = "the same language as the transcript"
        case .spanish: target = "Spanish"
        case .english: target = "English"
        }
        return """
        You summarize YouTube videos from their automatic transcript. Write a "Main takeaways" \
        summary in Markdown with exactly this structure:

        <One or two sentences with the central idea of the video.>

        \(heading)

        1. **<The takeaway in a few words>.** <One to three sentences that explain it with the \
        concrete facts, figures, examples or arguments given in the video.>
        2. …

        Rules:
        - Between 5 and 10 takeaways, the most important first. Fewer if the video is short.
        - Use only what is said in the video; do not add outside facts or opinions.
        - The transcript may misspell names and terms; write them correctly when the context makes them clear.
        - No title, no introduction such as "Here is the summary" and no closing remarks.
        - Only bold, italics and the numbered list: no other headings, tables, links or code blocks.
        - Keep the heading "\(heading)" in English.
        - Write the summary in \(target).
        """
    }

    /// Removes what the reader should not get: code fences around the answer, a title of its
    /// own and `==`, which the library uses for highlights.
    private static func clean(_ content: String) -> String {
        var lines = content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true, lines.last?.hasPrefix("```") == true, lines.count >= 2 {
            lines = Array(lines.dropFirst().dropLast())
        }
        while let first = lines.first, first.hasPrefix("# ") || first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        var markdown = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "==", with: "=\\=")
        if !markdown.isEmpty && !markdown.contains(heading) {
            markdown = "\(heading)\n\n\(markdown)"
        }
        return markdown
    }

    /// The paragraph before the takeaways or, if there is none, the first takeaway.
    private static func overview(in markdown: String) -> String? {
        let parts = markdown.components(separatedBy: heading)
        let intro = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate: String?
        if intro.isEmpty {
            let takeaways = parts.dropFirst().joined(separator: heading).components(separatedBy: "\n")
            candidate = takeaways.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        } else {
            candidate = intro.components(separatedBy: "\n\n").first
        }
        guard var text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let range = text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        for marker in ["**", "__", "*", "\\"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}
