import Foundation
import Security

/// Enlaces que la extensión de compartir deja pendientes para la app.
///
/// Sin App Groups no hay contenedor compartido, así que la cola vive en un grupo
/// de llavero (`keychain-access-groups`), que comparten la app y la extensión
/// por pertenecer al mismo equipo. Además, la extensión intenta abrir la app con
/// `leonerapaper://import?url=…`; la cola cubre el caso en que no lo consiga.
enum SharedQueue {
    struct Item: Codable, Equatable {
        var url: URL
        var title: String?
        var date: Date
        /// Size of the summary chosen in the share extension when the link is a YouTube video.
        /// Nil for other links and for items queued by older versions.
        var summaryLength: SummaryLength?
    }

    private static let service = "leonerapaper.pending-articles"

    /// Grupo de llavero compartido (`<TEAM>.<bundle>.shared`), definido en el Info.plist.
    static var accessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LPSharedKeychainGroup") as? String,
              let team = group.split(separator: ".").first else { return nil }
        // En una compilación sin firmar no hay prefijo de equipo y el grupo no es válido.
        let isTeamID = team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        return isTeamID ? group : nil
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    @discardableResult
    static func enqueue(url: URL, title: String?, summaryLength: SummaryLength? = nil) -> Bool {
        let item = Item(url: url, title: title, date: Date(), summaryLength: summaryLength)
        guard let data = try? JSONEncoder().encode(item) else { return false }
        var query = baseQuery()
        query[kSecAttrAccount as String] = UUID().uuidString
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Devuelve y elimina todos los enlaces pendientes, del más antiguo al más reciente.
    static func drain() -> [Item] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [[String: Any]] else { return [] }

        var items: [Item] = []
        for attribute in attributes {
            guard let account = attribute[kSecAttrAccount as String] as? String else { continue }
            var itemQuery = baseQuery()
            itemQuery[kSecAttrAccount as String] = account
            itemQuery[kSecReturnData as String] = true
            itemQuery[kSecMatchLimit as String] = kSecMatchLimitOne

            var data: CFTypeRef?
            if SecItemCopyMatching(itemQuery as CFDictionary, &data) == errSecSuccess,
               let data = data as? Data,
               let item = try? JSONDecoder().decode(Item.self, from: data) {
                items.append(item)
            }
            itemQuery.removeValue(forKey: kSecReturnData as String)
            itemQuery.removeValue(forKey: kSecMatchLimit as String)
            SecItemDelete(itemQuery as CFDictionary)
        }
        return items.sorted { $0.date < $1.date }
    }
}

enum AppLinks {
    static var scheme: String {
        (Bundle.main.object(forInfoDictionaryKey: "LPURLScheme") as? String) ?? "leonerapaper"
    }

    /// `leonerapaper://import?url=…`, with `&summary=<size>` when a summary size was chosen.
    static func importURL(for url: URL, summaryLength: SummaryLength? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let summaryLength {
            components.queryItems?.append(URLQueryItem(name: "summary", value: summaryLength.rawValue))
        }
        return components.url
    }

    /// Extrae la URL a importar de `leonerapaper://import?url=…`.
    static func articleURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let value = components?.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: value), let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return target
    }

    /// The summary size in `leonerapaper://import?url=…&summary=<size>`, nil when it is missing.
    static func summaryLength(from url: URL) -> SummaryLength? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "summary" })?.value.flatMap(SummaryLength.init(rawValue:))
    }
}
