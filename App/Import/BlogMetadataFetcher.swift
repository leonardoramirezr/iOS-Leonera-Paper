import Foundation

/// Obtiene el título y el icono de la portada de un blog a partir de su HTML.
enum BlogMetadataFetcher {
    struct Metadata: Equatable {
        var title: String?
        var iconURL: URL?
        /// URL final tras redirecciones.
        var finalURL: URL
    }

    static func fetch(_ url: URL) async throws -> Metadata {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let finalURL = response.url ?? url
        let html = String(decoding: data.prefix(512 * 1024), as: UTF8.self)
        return parse(html: html, baseURL: finalURL)
    }

    static func parse(html: String, baseURL: URL) -> Metadata {
        let head = html.range(of: "</head>", options: .caseInsensitive).map { String(html[..<$0.upperBound]) } ?? html
        let metas = tags(named: "meta", in: head)
        let links = tags(named: "link", in: head)

        func meta(_ key: String) -> String? {
            metas.first { ($0["property"] ?? $0["name"])?.lowercased() == key }?["content"]
                .map(clean).flatMap { $0.isEmpty ? nil : $0 }
        }

        let titleTag = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: head).map(clean)
        let title = meta("og:site_name") ?? meta("application-name") ?? titleTag.flatMap { $0.isEmpty ? nil : $0 }
            ?? meta("og:title")

        // Preferimos iconos grandes: apple-touch-icon, luego icon con el mayor tamaño.
        var best: (score: Int, url: URL)?
        for link in links {
            guard let rel = link["rel"]?.lowercased(), let href = link["href"],
                  let resolved = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL else { continue }
            let size = link["sizes"].flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 0
            let score: Int
            if rel.contains("apple-touch-icon") {
                score = 10_000 + max(size, 180)
            } else if rel.split(separator: " ").contains("icon") {
                score = resolved.pathExtension.lowercased() == "svg" ? 1 : 100 + size
            } else {
                continue
            }
            if best == nil || score > best!.score { best = (score, resolved) }
        }
        let fallback = URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL
        return Metadata(title: title.map(decodeEntities), iconURL: best?.url ?? fallback, finalURL: baseURL)
    }

    // MARK: - Utilidades HTML

    private static func tags(named name: String, in html: String) -> [[String: String]] {
        guard let regex = try? NSRegularExpression(pattern: "<\(name)\\b([^>]*)>", options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            attributes(ns.substring(with: $0.range(at: 1)))
        }
    }

    private static func attributes(_ text: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [:] }
        let ns = text as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            for group in 2...4 where match.range(at: group).location != NSNotFound {
                result[key] = ns.substring(with: match.range(at: group))
                break
            }
        }
        return result
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func clean(_ text: String) -> String {
        decodeEntities(text).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let hex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        return result
    }
}
