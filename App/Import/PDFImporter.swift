import Foundation

/// Convierte un PDF (local o descargado de la web) en un artículo Markdown con sus
/// imágenes. El PDF original se guarda junto al Markdown.
@MainActor
enum PDFImporter {
    /// - Parameters:
    ///   - fileURL: copia local del PDF.
    ///   - sourceURL: dirección web de la que se descargó, si la hay.
    ///   - suggestedName: nombre del archivo, para usarlo como título si el PDF no tiene uno.
    static func importPDF(at fileURL: URL, sourceURL: URL?, suggestedName: String?, storage: ArticleStorage,
                          progress: @escaping @MainActor (String) -> Void) async throws -> Article {
        progress("Leyendo el PDF…")
        // El título (y por tanto la carpeta) se conoce al terminar: las imágenes van antes a una carpeta temporal.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedImages = staging.appendingPathComponent("images", isDirectory: true)

        let converted = try await Task.detached(priority: .userInitiated) {
            try PDFConverter.convert(fileURL: fileURL, imagesFolder: stagedImages) { page, total in
                Task { @MainActor in progress("Convirtiendo página \(page) de \(total)…") }
            }
        }.value

        let title = converted.title
            ?? suggestedName.map(readableName).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Documento PDF"
        let folder = try storage.makeFolder(for: title)
        do {
            if FileManager.default.fileExists(atPath: stagedImages.path) {
                try FileManager.default.moveItem(at: stagedImages, to: storage.imagesURL(inFolder: folder.url))
            }
            let pdfName = "\(folder.name).pdf"
            try FileManager.default.copyItem(at: fileURL, to: folder.url.appendingPathComponent(pdfName))

            progress("Guardando Markdown…")
            let savedAt = Date()
            let published = converted.created.map { date -> String in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                return formatter.string(from: date)
            }
            let siteName = sourceURL?.host?.replacingOccurrences(of: "www.", with: "")
            let markdown = compose(title: title, sourceURL: sourceURL, siteName: siteName, pdfName: pdfName,
                                   converted: converted, published: published, savedAt: savedAt)
            let fileName = "\(folder.name).md"
            try markdown.write(to: folder.url.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

            return Article(
                id: UUID(),
                title: title,
                sourceURL: sourceURL,
                siteName: siteName,
                author: converted.author,
                excerpt: converted.excerpt,
                published: published,
                folderName: folder.name,
                fileName: fileName,
                savedAt: savedAt,
                leadImage: converted.cover,
                readingProgress: nil,
                drive: nil,
                pdfFileName: pdfName
            )
        } catch {
            try? FileManager.default.removeItem(at: folder.url)
            throw error
        }
    }

    /// Descarga el PDF de `url` y lo importa.
    static func importRemotePDF(from url: URL, storage: ArticleStorage,
                                progress: @escaping @MainActor (String) -> Void) async throws -> Article {
        progress("Descargando el PDF…")
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(ImageDownloader.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/pdf,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appendingPathComponent("document.pdf")
        try FileManager.default.moveItem(at: downloaded, to: local)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExtractionError.loadFailed("HTTP \(http.statusCode)")
        }
        guard isPDF(local) else { throw PDFConversionError.unreadable }

        let finalURL = response.url ?? url
        let name = response.suggestedFilename.flatMap { $0.lowercased() == "unknown" ? nil : $0 }
            ?? finalURL.lastPathComponent.removingPercentEncoding
        return try await importPDF(at: local, sourceURL: finalURL, suggestedName: name, storage: storage, progress: progress)
    }

    /// Comprueba la firma `%PDF-` (en los primeros bytes, como hacen los lectores).
    nonisolated static func isPDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    /// «informe_anual-2024.pdf» → «informe anual-2024».
    private static func readableName(_ fileName: String) -> String {
        var name = fileName
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        return name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func compose(title: String, sourceURL: URL?, siteName: String?, pdfName: String,
                        converted: ConvertedPDF, published: String?, savedAt: Date) -> String {
        let yaml = ArticleImporter.yaml
        var front = ["---", "title: \(yaml(title))"]
        if let sourceURL { front.append("source: \(sourceURL.absoluteString)") }
        if let siteName, !siteName.isEmpty { front.append("site: \(yaml(siteName))") }
        if let author = converted.author { front.append("author: \(yaml(author))") }
        if let published { front.append("published: \(yaml(published))") }
        front.append("pdf: \(yaml(pdfName))")
        front.append("pages: \(converted.pageCount)")
        front.append("saved: \(ISO8601DateFormatter().string(from: savedAt))")
        front.append("---")

        var meta: [String] = []
        if let author = converted.author { meta.append(ArticleImporter.escape(author)) }
        if let sourceURL {
            let site = siteName?.isEmpty == false ? siteName! : (sourceURL.host ?? sourceURL.absoluteString)
            meta.append("[\(ArticleImporter.escape(site))](\(ArticleImporter.escapeURL(sourceURL.absoluteString)))")
        }
        meta.append(converted.pageCount == 1 ? "PDF · 1 página" : "PDF · \(converted.pageCount) páginas")
        if let date = ArticleImporter.displayDate(published) { meta.append(date) }

        return front.joined(separator: "\n")
            + "\n\n# \(ArticleImporter.escape(title))\n\n"
            + "*\(meta.joined(separator: " · "))*\n\n"
            + converted.markdown
            + "\n"
    }
}
