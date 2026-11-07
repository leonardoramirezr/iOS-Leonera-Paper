import Foundation

/// How long the summary of a YouTube video is. It is chosen for each link, when it is pasted in
/// «Añadir artículo» or shared with the share extension; medium by default.
enum SummaryLength: String, CaseIterable, Identifiable, Codable, Sendable {
    case short, medium, long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "Corto"
        case .medium: return "Mediano"
        case .long: return "Largo"
        }
    }

    /// What the size means, shown under its title in the share extension.
    var detail: String {
        switch self {
        case .short: return "3–5 ideas de una frase"
        case .medium: return "5–10 ideas de una a tres frases"
        case .long: return "10–15 ideas con más detalle"
        }
    }
}
