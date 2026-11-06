import Foundation
import Observation

/// Settings for YouTube summaries: Whisper on Groq transcribes the audio, and the chosen LLM
/// provider writes the summary through its OpenAI-compatible API.
@MainActor
@Observable
final class YouTubeSettings {
    nonisolated static let transcriptionModels = ["whisper-large-v3-turbo", "whisper-large-v3"]
    nonisolated static let defaultTranscriptionModel = "whisper-large-v3-turbo"

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
        var transcriptionModel = YouTubeSettings.defaultTranscriptionModel
        /// Nil while the summary provider is incomplete: no base URL, account ID or model.
        var summary: LLMConnection?
        var summaryLanguage = SummaryLanguage.video
    }

    private enum Keys {
        static let transcriptionModel = "youtube.transcriptionModel"
        static let summaryProvider = "youtube.summaryProvider"
        static let summaryModel = "youtube.summaryModel"
        static let summaryLanguage = "youtube.summaryLanguage"
        static let cloudflareAccountID = "youtube.cloudflareAccountID"
        static let customBaseURL = "youtube.customBaseURL"
    }

    /// API key of each provider, kept in the Keychain. Whisper uses the Groq key.
    private(set) var apiKeys: [LLMProvider: String]

    var transcriptionModel: String {
        didSet { UserDefaults.standard.set(transcriptionModel, forKey: Keys.transcriptionModel) }
    }
    var summaryProvider: LLMProvider {
        didSet {
            guard summaryProvider != oldValue else { return }
            UserDefaults.standard.set(summaryProvider.rawValue, forKey: Keys.summaryProvider)
            // Model names belong to one provider, so switching restores that provider's default.
            summaryModel = summaryProvider.defaultModel
        }
    }
    var summaryModel: String {
        didSet { UserDefaults.standard.set(summaryModel, forKey: Keys.summaryModel) }
    }
    var summaryLanguage: SummaryLanguage {
        didSet { UserDefaults.standard.set(summaryLanguage.rawValue, forKey: Keys.summaryLanguage) }
    }
    var cloudflareAccountID: String {
        didSet { UserDefaults.standard.set(cloudflareAccountID, forKey: Keys.cloudflareAccountID) }
    }
    var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: Keys.customBaseURL) }
    }

    init() {
        let defaults = UserDefaults.standard
        apiKeys = Dictionary(uniqueKeysWithValues: LLMProvider.allCases.map { provider in
            (provider, Keychain.string(for: YouTubeSettings.keychainKey(for: provider)) ?? "")
        })
        transcriptionModel = defaults.string(forKey: Keys.transcriptionModel) ?? Self.defaultTranscriptionModel
        let provider = LLMProvider(rawValue: defaults.string(forKey: Keys.summaryProvider) ?? "") ?? .gemini
        summaryProvider = provider
        summaryModel = defaults.string(forKey: Keys.summaryModel) ?? provider.defaultModel
        summaryLanguage = SummaryLanguage(rawValue: defaults.string(forKey: Keys.summaryLanguage) ?? "") ?? .video
        cloudflareAccountID = defaults.string(forKey: Keys.cloudflareAccountID) ?? ""
        customBaseURL = defaults.string(forKey: Keys.customBaseURL) ?? ""
    }

    func apiKey(for provider: LLMProvider) -> String {
        apiKeys[provider] ?? ""
    }

    func setAPIKey(_ key: String, for provider: LLMProvider) {
        apiKeys[provider] = key
        Keychain.set(key, for: YouTubeSettings.keychainKey(for: provider))
    }

    /// Whether the Groq key is set and the summary provider has a key, base URL and model.
    var canSummarizeVideos: Bool {
        !apiKey(for: .groq).isEmpty && isSummaryReady
    }

    /// Whether the summary provider has a complete connection and a key to test it with.
    var isSummaryReady: Bool {
        summaryConnection.map { !$0.apiKey.isEmpty } ?? false
    }

    /// The summary provider with its key and model. Nil while its base URL or model is missing.
    var summaryConnection: LLMConnection? {
        let typed = trimmed(summaryModel)
        let model = typed.isEmpty ? summaryProvider.defaultModel : typed
        guard !model.isEmpty,
              let base = summaryProvider.baseURL(cloudflareAccountID: trimmed(cloudflareAccountID),
                                                 customBaseURL: trimmed(customBaseURL))?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let endpoint = URL(string: base + "/chat/completions") else { return nil }
        return LLMConnection(provider: summaryProvider, endpoint: endpoint,
                             apiKey: trimmed(apiKey(for: summaryProvider)), model: model)
    }

    /// Where the summary provider lists its models, with the key that reads them. Nil while the key
    /// or the provider's URL is missing.
    var summaryModelList: ModelListRequest? {
        let provider = summaryProvider
        let key = trimmed(apiKey(for: provider))
        guard !key.isEmpty,
              let url = provider.modelsURL(cloudflareAccountID: trimmed(cloudflareAccountID),
                                           customBaseURL: trimmed(customBaseURL)) else { return nil }
        return ModelListRequest(provider: provider, url: url, apiKey: key)
    }

    /// Chat models the summary provider offers to its key. Empty when it has no list or does not answer.
    func discoverSummaryModels() async -> [String] {
        guard let request = summaryModelList else { return [] }
        return (try? await ModelDiscovery.chatModels(request)) ?? []
    }

    /// Whisper models the Groq account offers. Empty when the key is missing or does not answer.
    func discoverTranscriptionModels() async -> [String] {
        let key = trimmed(apiKey(for: .groq))
        guard !key.isEmpty else { return [] }
        return (try? await GroqTranscriber.whisperModels(apiKey: key)) ?? []
    }

    var configuration: Configuration {
        let transcription = trimmed(transcriptionModel)
        return Configuration(
            groqAPIKey: trimmed(apiKey(for: .groq)),
            transcriptionModel: transcription.isEmpty ? Self.defaultTranscriptionModel : transcription,
            summary: summaryConnection,
            summaryLanguage: summaryLanguage
        )
    }

    /// Checks the Groq key and the Whisper model (see `GroqTranscriber.checkKey`).
    func checkTranscriptionKey() async throws {
        try await GroqTranscriber.checkKey(trimmed(apiKey(for: .groq)), model: trimmed(transcriptionModel))
    }

    /// Checks the summary provider with a one-word request (see `LLMSummarizer.checkConnection`).
    func checkSummaryConnection() async throws {
        guard let connection = summaryConnection else { throw YouTubeImportError.incompleteSummarySettings }
        guard !connection.apiKey.isEmpty else { throw YouTubeImportError.missingSummaryKey(connection.provider.name) }
        try await LLMSummarizer.checkConnection(connection)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keychainKey(for provider: LLMProvider) -> String {
        "\(provider.rawValue).apiKey"
    }
}
