import Foundation

struct Article: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var sourceURL: URL
    var siteName: String?
    var author: String?
    var excerpt: String?
    var published: String?
    /// Carpeta del artículo dentro de Documentos.
    var folderName: String
    /// Nombre del archivo Markdown dentro de la carpeta.
    var fileName: String
    var savedAt: Date
    /// Ruta relativa (dentro de la carpeta) de la imagen principal, si la hay.
    var leadImage: String?
    var readingProgress: Double?
    var drive: DriveInfo?

    var displaySite: String {
        if let siteName, !siteName.isEmpty { return siteName }
        return sourceURL.host?.replacingOccurrences(of: "www.", with: "") ?? sourceURL.absoluteString
    }
}

struct DriveInfo: Codable, Hashable {
    var folderID: String
    var markdownFileID: String
    var uploadedAt: Date
}

/// Ubicación de los archivos: cada artículo es una carpeta en Documentos
/// (visible en la app Archivos) con el `.md` y una subcarpeta `images/`.
struct ArticleStorage {
    let documents: URL
    let indexURL: URL

    init(fileManager: FileManager = .default) {
        documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        indexURL = support.appendingPathComponent("library.json")
    }

    func folderURL(for article: Article) -> URL {
        documents.appendingPathComponent(article.folderName, isDirectory: true)
    }

    func markdownURL(for article: Article) -> URL {
        folderURL(for: article).appendingPathComponent(article.fileName)
    }

    func imagesURL(inFolder folder: URL) -> URL {
        folder.appendingPathComponent("images", isDirectory: true)
    }

    func loadIndex() -> [Article] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let articles = (try? decoder.decode([Article].self, from: data)) ?? []
        // Si el usuario borró la carpeta desde Archivos, el artículo desaparece.
        return articles.filter { FileManager.default.fileExists(atPath: markdownURL(for: $0).path) }
    }

    func saveIndex(_ articles: [Article]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(articles) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Crea una carpeta nueva con un nombre legible y único a partir del título.
    func makeFolder(for title: String) throws -> (name: String, url: URL) {
        let base = Self.slug(title)
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: documents.appendingPathComponent(name).path) {
            name = "\(base)-\(counter)"
            counter += 1
        }
        let url = documents.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (name, url)
    }

    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
            if result.count >= 64 { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "articulo" : result
    }
}
