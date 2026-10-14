import Foundation
import Observation

/// Marcador a la portada o archivo de un blog, newsletter, Medium, etc.
/// Sirve para descubrir artículos nuevos.
struct Blog: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: URL
    var iconURL: URL?
    var addedAt: Date

    var displayHost: String {
        url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }
}

/// Lista de blogs guardados, persistida en Application Support/blogs.json.
@MainActor
@Observable
final class BlogStore {
    private(set) var blogs: [Blog] = []
    @ObservationIgnored private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("blogs.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            blogs = (try? decoder.decode([Blog].self, from: data)) ?? []
        }
    }

    func contains(_ url: URL) -> Blog? {
        blogs.first { Self.normalized($0.url) == Self.normalized(url) }
    }

    /// Añade un blog nuevo o reemplaza el que tenga el mismo id.
    func save(_ blog: Blog) {
        if let index = blogs.firstIndex(where: { $0.id == blog.id }) {
            blogs[index] = blog
        } else {
            blogs.insert(blog, at: 0)
        }
        persist()
    }

    func delete(_ blog: Blog) {
        blogs.removeAll { $0.id == blog.id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        blogs.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(blogs) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func normalized(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        text = text.replacingOccurrences(of: "://www.", with: "://")
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
