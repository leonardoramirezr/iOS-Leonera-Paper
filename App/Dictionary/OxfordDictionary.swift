import Foundation

/// Diccionarios que puede consultar el panel de definiciones.
enum DictionarySource: String, CaseIterable, Identifiable {
    /// Oxford English–Spanish y, si la palabra no está, Oxford Dictionary of English.
    case automatic
    case englishSpanish
    case english
    /// Diccionarios instalados en iOS (incluyen el Oxford Spanish Dictionary y el ODE).
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automático"
        case .englishSpanish: return "Oxford English–Spanish"
        case .english: return "Oxford Dictionary of English"
        case .system: return "Diccionarios de iOS"
        }
    }

    var shortTitle: String {
        switch self {
        case .automatic: return "Auto"
        case .englishSpanish: return "EN–ES"
        case .english: return "ODE"
        case .system: return "iOS"
        }
    }
}

struct DictionaryEntry: Equatable {
    struct Sense: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var detail: String?
        var labels: [String]
        var examples: [String]
        var subsenses: [Sense]
    }

    struct Section: Equatable, Identifiable {
        let id = UUID()
        var category: String
        var pronunciation: String?
        var senses: [Sense]
    }

    var source: DictionarySource
    var headword: String
    var sections: [Section]
}

/// Cliente de la Oxford Dictionaries API v2 (necesita App ID y App Key propios).
struct OxfordDictionaryClient {
    var baseURL: URL
    var appID: String
    var appKey: String

    enum Failure: LocalizedError {
        case unauthorized
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "La API de Oxford rechazó las credenciales (App ID / App Key)."
            case .http(let code): return "La API de Oxford respondió con el código \(code)."
            }
        }
    }

    /// Traducción inglés → español (Oxford English–Spanish). nil si la palabra no existe.
    func englishSpanish(_ word: String) async throws -> DictionaryEntry? {
        try await withLemmaFallback(word) { candidate in
            guard let data = try await get("translations/en/es/\(Self.wordID(candidate))", query: ["strictMatch": "false"]) else {
                return nil
            }
            return Self.parse(data, source: .englishSpanish, translations: true)
        }
    }

    /// Definición en inglés (Oxford Dictionary of English, `en-gb`). nil si la palabra no existe.
    func english(_ word: String) async throws -> DictionaryEntry? {
        try await withLemmaFallback(word) { candidate in
            guard let data = try await get("entries/en-gb/\(Self.wordID(candidate))", query: ["strictMatch": "false"]) else {
                return nil
            }
            return Self.parse(data, source: .english, translations: false)
        }
    }

    // MARK: - Red

    private func withLemmaFallback(_ word: String,
                                   lookup: (String) async throws -> DictionaryEntry?) async throws -> DictionaryEntry? {
        if let entry = try await lookup(word) { return entry }
        // «running» → «run», «mice» → «mouse».
        for lemma in try await lemmas(word) where lemma.lowercased() != word.lowercased() {
            if let entry = try await lookup(lemma) { return entry }
        }
        if word != word.lowercased(), let entry = try await lookup(word.lowercased()) { return entry }
        return nil
    }

    private func lemmas(_ word: String) async throws -> [String] {
        guard let data = try await get("lemmas/en/\(Self.wordID(word))", query: [:]) else { return [] }
        let response = try JSONDecoder().decode(LemmasResponse.self, from: data)
        var result: [String] = []
        for lexical in response.results?.flatMap({ $0.lexicalEntries ?? [] }) ?? [] {
            for inflection in lexical.inflectionOf ?? [] where !result.contains(inflection.text) {
                result.append(inflection.text)
            }
        }
        return result
    }

    /// Devuelve nil en 404 (la palabra no está en ese diccionario).
    private func get(_ path: String, query: [String: String]) async throws -> Data? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: "\(base)/\(path)") else { throw Failure.http(0) }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw Failure.http(0) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(appID, forHTTPHeaderField: "app_id")
        request.setValue(appKey, forHTTPHeaderField: "app_key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 404: return nil
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.http(status)
        }
    }

    private static func wordID(_ word: String) -> String {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "’", with: "'")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-'._~")
        return normalized.addingPercentEncoding(withAllowedCharacters: allowed) ?? normalized
    }

    // MARK: - Interpretación

    private struct LemmasResponse: Decodable {
        struct Result: Decodable { var lexicalEntries: [LexicalEntry]? }
        struct LexicalEntry: Decodable { var inflectionOf: [Inflection]? }
        struct Inflection: Decodable { var text: String }
        var results: [Result]?
    }

    private struct EntriesResponse: Decodable {
        var results: [HeadwordEntry]?
    }

    private struct HeadwordEntry: Decodable {
        var word: String?
        var lexicalEntries: [LexicalEntry]?
    }

    private struct LexicalEntry: Decodable {
        var lexicalCategory: Labelled?
        var entries: [Entry]?
        var pronunciations: [Pronunciation]?
    }

    private struct Entry: Decodable {
        var senses: [Sense]?
        var pronunciations: [Pronunciation]?
    }

    private struct Pronunciation: Decodable {
        var phoneticSpelling: String?
        var phoneticNotation: String?
    }

    private struct Labelled: Decodable {
        var id: String?
        var text: String?
    }

    private struct TextItem: Decodable {
        var text: String?
        var translations: [TextItem]?
    }

    private struct Sense: Decodable {
        var definitions: [String]?
        var shortDefinitions: [String]?
        var translations: [TextItem]?
        var examples: [TextItem]?
        var notes: [TextItem]?
        var registers: [Labelled]?
        var domains: [Labelled]?
        var regions: [Labelled]?
        var subsenses: [Sense]?
    }

    private static func parse(_ data: Data, source: DictionarySource, translations: Bool) -> DictionaryEntry? {
        guard let response = try? JSONDecoder().decode(EntriesResponse.self, from: data),
              let results = response.results, !results.isEmpty else { return nil }

        var sections: [DictionaryEntry.Section] = []
        for result in results {
            for lexical in result.lexicalEntries ?? [] {
                let pronunciation = (lexical.pronunciations ?? lexical.entries?.first?.pronunciations ?? [])
                    .first { $0.phoneticNotation == "IPA" }?.phoneticSpelling
                let senses = (lexical.entries ?? []).flatMap { $0.senses ?? [] }
                    .compactMap { convert($0, translations: translations) }
                guard !senses.isEmpty else { continue }
                sections.append(DictionaryEntry.Section(
                    category: lexical.lexicalCategory?.text ?? lexical.lexicalCategory?.id ?? "",
                    pronunciation: pronunciation.map { "/\($0)/" },
                    senses: senses
                ))
            }
        }
        guard !sections.isEmpty else { return nil }
        return DictionaryEntry(source: source, headword: results.first?.word ?? "", sections: sections)
    }

    private static func convert(_ sense: Sense, translations: Bool) -> DictionaryEntry.Sense? {
        let labels = (sense.registers ?? []) + (sense.domains ?? []) + (sense.regions ?? [])
        let examples = (sense.examples ?? []).compactMap { example -> String? in
            guard let text = example.text else { return nil }
            let translated = (example.translations ?? []).compactMap(\.text).joined(separator: "; ")
            return translated.isEmpty ? text : "\(text) → \(translated)"
        }
        let subsenses = (sense.subsenses ?? []).compactMap { convert($0, translations: translations) }

        let text: String
        var detail: String?
        if translations {
            text = (sense.translations ?? []).compactMap(\.text).joined(separator: ", ")
            detail = (sense.notes ?? []).compactMap(\.text).first ?? sense.definitions?.first
        } else {
            text = (sense.definitions ?? sense.shortDefinitions ?? []).joined(separator: " ")
            detail = (sense.notes ?? []).compactMap(\.text).first
        }
        guard !text.isEmpty || !subsenses.isEmpty else { return nil }
        return DictionaryEntry.Sense(
            text: text,
            detail: detail,
            labels: labels.compactMap { $0.text ?? $0.id },
            examples: Array(examples.prefix(3)),
            subsenses: subsenses
        )
    }
}
