import Foundation

/// Convierte una URL en un artículo Markdown guardado en local con sus imágenes.
@MainActor
enum ArticleImporter {
    static func importArticle(from url: URL, storage: ArticleStorage,
                              progress: @escaping @MainActor (String) -> Void) async throws -> Article {
        if url.pathExtension.lowercased() == "pdf" {
            return try await PDFImporter.importRemotePDF(from: url, storage: storage, progress: progress)
        }
        progress("Cargando la página…")
        let extracted: ExtractedArticle
        do {
            extracted = try await ArticleExtractor.extract(from: url)
        } catch ExtractionError.pdfDocument(let pdfURL) {
            // La página resultó ser un PDF (p. ej., un enlace de descarga sin «.pdf»).
            return try await PDFImporter.importRemotePDF(from: pdfURL ?? url, storage: storage, progress: progress)
        }
        let finalURL = extracted.url.flatMap(URL.init(string:)) ?? url
        let title = extracted.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (finalURL.host ?? "Artículo")
            : extracted.title.trimmingCharacters(in: .whitespacesAndNewlines)

        let folder = try storage.makeFolder(for: title)
        do {
            if !extracted.images.isEmpty {
                progress("Descargando \(extracted.images.count) imágenes…")
            }
            let imagesFolder = storage.imagesURL(inFolder: folder.url)
            let outcomes = await ImageDownloader.downloadAll(extracted.images, to: imagesFolder, referer: finalURL)
            let body = replaceImageTokens(in: extracted.markdown, outcomes: outcomes)

            var leadImage: String?
            for outcome in outcomes {
                if case .saved(let path) = outcome {
                    leadImage = path
                    break
                }
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path))?.isEmpty ?? false {
                try? FileManager.default.removeItem(at: imagesFolder)
            }

            progress("Guardando Markdown…")
            let savedAt = Date()
            let markdown = compose(title: title, url: finalURL, extracted: extracted, body: body, savedAt: savedAt)
            let fileName = "\(folder.name).md"
            try markdown.write(to: folder.url.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

            return Article(
                id: UUID(),
                title: title,
                sourceURL: finalURL,
                siteName: extracted.siteName,
                author: extracted.byline,
                excerpt: extracted.excerpt,
                published: extracted.published,
                folderName: folder.name,
                fileName: fileName,
                savedAt: savedAt,
                leadImage: leadImage,
                readingProgress: nil,
                drive: nil
            )
        } catch {
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
    }

    // MARK: - Markdown

    static func replaceImageTokens(in markdown: String, outcomes: [ImageDownloader.Outcome]) -> String {
        var result = markdown
        for (index, outcome) in outcomes.enumerated().reversed() {
            let token = "leonera-image:\(index)"
            switch outcome {
            case .saved(let path):
                result = result.replacingOccurrences(of: "](\(token))", with: "](\(path))")
            case .remote(let url):
                result = result.replacingOccurrences(of: "](\(token))", with: "](\(escapeURL(url)))")
            case .drop:
                let pattern = #"!\[(?:\\.|[^\]\\])*\]\("# + NSRegularExpression.escapedPattern(for: token) + #"\)"#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(result.startIndex..., in: result)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
                }
            }
        }
        // Quita líneas vacías sobrantes que dejan las imágenes eliminadas.
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func compose(title: String, url: URL, extracted: ExtractedArticle, body: String, savedAt: Date) -> String {
        let iso = ISO8601DateFormatter()
        var front = ["---", "title: \(yaml(title))", "source: \(url.absoluteString)"]
        if let site = extracted.siteName, !site.isEmpty { front.append("site: \(yaml(site))") }
        if let author = extracted.byline, !author.isEmpty { front.append("author: \(yaml(author))") }
        if let published = extracted.published, !published.isEmpty { front.append("published: \(yaml(published))") }
        if let lang = extracted.lang, !lang.isEmpty { front.append("lang: \(lang)") }
        front.append("saved: \(iso.string(from: savedAt))")
        front.append("---")

        var meta: [String] = []
        if let author = extracted.byline, !author.isEmpty { meta.append(escape(author)) }
        let site = extracted.siteName?.isEmpty == false ? extracted.siteName! : (url.host ?? url.absoluteString)
        meta.append("[\(escape(site))](\(escapeURL(url.absoluteString)))")
        if let date = displayDate(extracted.published) { meta.append(date) }

        return front.joined(separator: "\n")
            + "\n\n# \(escape(title))\n\n"
            + "*\(meta.joined(separator: " · "))*\n\n"
            + body
            + "\n"
    }

    /// Escapa texto plano para que no se interprete como Markdown.
    nonisolated static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result.replacingOccurrences(of: "==", with: "=\\=")
    }

    nonisolated static func escapeURL(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    nonisolated static func yaml(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    nonisolated static func displayDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let parsers: [ISO8601DateFormatter] = {
            let full = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateOnly = ISO8601DateFormatter()
            dateOnly.formatOptions = [.withFullDate]
            return [full, fractional, dateOnly]
        }()
        for parser in parsers {
            if let date = parser.date(from: value) {
                return date.formatted(date: .abbreviated, time: .omitted)
            }
        }
        return nil
    }
}
