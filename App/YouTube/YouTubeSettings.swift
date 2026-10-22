import Foundation
import Observation

/// API keys and models for YouTube summaries: Whisper on Groq transcribes the audio and a
/// Gemini model, through Gemini's OpenAI-compatible API, writes the summary.
@MainActor
@Observable
final class YouTubeSettings {
    nonisolated static let transcriptionModels = ["whisper-large-v3-turbo", "whisper-large-v3"]
    nonisolated static let defaultTranscriptionModel = "whisper-large-v3-turbo"
    nonisolated static let defaultSummaryModel = "gemini-3.8-flash"

    enum SummaryLanguage: String, CaseIterable, Identifiable, Sendable {
        case video, spanish, english

        var id: String { rawValue }

        var title: String {
            switch self {
            case .video: return "El del vídeo"
            case .spanish: return "Español"
            case .english: return "Inglés"
            }
        }
    }

    /// Values read when an import starts.
    struct Configuration: Sendable {
        var groqAPIKey = ""
        var geminiAPIKey = ""
        var transcriptionModel = YouTubeSettings.defaultTranscriptionModel
        var summaryModel = YouTubeSettings.defaultSummaryModel
        var summaryLanguage = SummaryLanguage.video
    }

    private enum Keys {
        static let groqAPIKey = "groq.apiKey"
        static let geminiAPIKey = "gemini.apiKey"
        static let transcriptionModel = "youtube.transcriptionModel"
        static let summaryModel = "youtube.summaryModel"
        static let summaryLanguage = "youtube.summaryLanguage"
    }

    var groqAPIKey: String {
        didSet { Keychain.set(groqAPIKey, for: Keys.groqAPIKey) }
    }
    var geminiAPIKey: String {
        didSet { Keychain.set(geminiAPIKey, for: Keys.geminiAPIKey) }
    }
    var transcriptionModel: String {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: Keys.transcriptionModel) }
    }
    var summaryModel: String {
        didSet { UserDefaults.standard.set(summaryModel, forKey: Keys.summaryModel) }
    }
    var summaryLanguage: SummaryLanguage {
        didSet { UserDefaults.standard.set(summaryLanguage.rawValue, forKey: Keys.summaryLanguage) }
    }

    init() {
        let defaults = UserDefaults.standard
        groqAPIKey = Keychain.string(for: Keys.groqAPIKey) ?? ""
        geminiAPIKey = Keychain.string(for: Keys.geminiAPIKey) ?? ""
        transcriptionModel = defaults.string(forKey: Keys.transcriptionModel) ?? Self.defaultTranscriptionModel
        summaryModel = defaults.string(forKey: Keys.summaryModel) ?? Self.defaultSummaryModel
        summaryLanguage = SummaryLanguage(rawValue: defaults.string(forKey: Keys.summaryLanguage) ?? "") ?? .video
    }

    var hasAPIKeys: Bool {
        !configuration.groqAPIKey.isEmpty && !configuration.geminiAPIKey.isEmpty
    }

    var configuration: Configuration {
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let transcription = trimmed(transcriptionModel)
        let summary = trimmed(summaryModel)
        return Configuration(
            groqAPIKey: trimmed(groqAPIKey),
            geminiAPIKey: trimmed(geminiAPIKey),
            transcriptionModel: transcription.isEmpty ? Self.defaultTranscriptionModel : transcription,
            summaryModel: summary.isEmpty ? Self.defaultSummaryModel : summary,
            summaryLanguage: summaryLanguage
        )
    }
}
