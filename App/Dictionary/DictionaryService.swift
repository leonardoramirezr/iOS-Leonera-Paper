import Foundation
import Observation
import UIKit

/// Configuración y caché de las consultas al diccionario.
@MainActor
@Observable
final class DictionaryService {
    static let defaultBaseURL = "https://od-api.oxforddictionaries.com/api/v2"

    private enum Keys {
        static let source = "dictionary.source"
        static let appID = "oxford.appID"
        static let baseURL = "oxford.baseURL"
        static let appKey = "oxford.appKey"
    }

    var preferredSource: DictionarySource {
        didSet { UserDefaults.standard.set(preferredSource.rawValue, forKey: Keys.source) }
    }
    var appID: String {
        didSet { UserDefaults.standard.set(appID, forKey: Keys.appID); cache.removeAll() }
    }
    var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL); cache.removeAll() }
    }
    var appKey: String {
        didSet { Keychain.set(appKey, for: Keys.appKey); cache.removeAll() }
    }

    @ObservationIgnored private var cache: [String: DictionaryEntry?] = [:]

    init() {
        let defaults = UserDefaults.standard
        preferredSource = DictionarySource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .automatic
        appID = defaults.string(forKey: Keys.appID) ?? ""
        baseURL = defaults.string(forKey: Keys.baseURL) ?? Self.defaultBaseURL
        appKey = Keychain.string(for: Keys.appKey) ?? ""
    }

    var hasOxfordCredentials: Bool {
        !appID.trimmingCharacters(in: .whitespaces).isEmpty && !appKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Sin credenciales de Oxford, «Automático» usa los diccionarios Oxford instalados en iOS.
    func effectiveSource(for source: DictionarySource) -> DictionarySource {
        if source == .automatic && !hasOxfordCredentials { return .system }
        return source
    }

    private var client: OxfordDictionaryClient? {
        guard hasOxfordCredentials,
              let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultBaseURL : baseURL)
        else { return nil }
        return OxfordDictionaryClient(baseURL: url,
                                      appID: appID.trimmingCharacters(in: .whitespaces),
                                      appKey: appKey.trimmingCharacters(in: .whitespaces))
    }

    /// Consulta la API de Oxford. Para `.automatic`: English–Spanish y, si no está, Oxford Dictionary of English.
    func lookup(_ term: String, source: DictionarySource) async throws -> DictionaryEntry? {
        guard let client else { return nil }
        let key = "\(source.rawValue)|\(term.lowercased())"
        if let cached = cache[key] { return cached }

        let entry: DictionaryEntry?
        switch source {
        case .englishSpanish:
            entry = try await client.englishSpanish(term)
        case .english:
            entry = try await client.english(term)
        case .automatic:
            if let translation = try await client.englishSpanish(term) {
                entry = translation
            } else {
                entry = try await client.english(term)
            }
        case .system:
            entry = nil
        }
        cache[key] = .some(entry)
        return entry
    }

    func systemHasDefinition(_ term: String) -> Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: term)
    }

    /// Normaliza la selección para buscarla: sin puntuación alrededor y como mucho 4 palabras.
    static func lookupTerm(from selection: String) -> String? {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return nil }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= 4, trimmed.contains(where: \.isLetter) else { return nil }
        return words.joined(separator: " ")
    }
}
