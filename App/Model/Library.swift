import Foundation
import Observation

/// Biblioteca de artículos guardados e importaciones en curso.
@MainActor
@Observable
final class Library {
    struct ImportJob: Identifiable, Equatable {
        let id = UUID()
        /// Página web o copia local de un PDF.
        let url: URL
        var status: String
        var error: String?
        /// Size of the summary when the link is a YouTube video.
        var summaryLength = YouTubeSettings.SummaryLength.medium

        var displayName: String {
            if YouTubeLink.isVideo(url) { return "Vídeo de YouTube" }
            return url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString)
        }
    }

    private(set) var articles: [Article] = []
    private(set) var jobs: [ImportJob] = []
    /// Mensaje breve para mostrar en la parte inferior de la biblioteca.
    var notice: String?

    let storage = ArticleStorage()
    @ObservationIgnored weak var drive: DriveSync?
    @ObservationIgnored weak var youtube: YouTubeSettings?
    @ObservationIgnored private var pendingDriveUpdates: [UUID: Task<Void, Never>] = [:]

    init() {
        articles = storage.loadIndex().sorted { $0.savedAt > $1.savedAt }
    }

    func article(id: UUID) -> Article? {
        articles.first { $0.id == id }
    }

    func markdownURL(for article: Article) -> URL {
        storage.markdownURL(for: article)
    }

    func folderURL(for article: Article) -> URL {
        storage.folderURL(for: article)
    }

    func pdfURL(for article: Article) -> URL? {
        storage.pdfURL(for: article)
    }

    // MARK: - Entrada de enlaces

    func handleIncoming(_ url: URL) {
        if url.isFileURL {
            // PDF abierto desde Archivos, Mail, etc. («Abrir en Leonera Paper»).
            importPDF(at: url)
        } else if let target = AppLinks.articleURL(from: url) {
            importArticle(from: target)
        }
        drainSharedQueue()
    }

    /// Importa un PDF local: primero se copia a una carpeta temporal propia.
    func importPDF(at url: URL) {
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try ArticleStorage.stagePDF(from: url)
                }.value
                importArticle(from: staged)
            } catch {
                notice = "No se pudo abrir «\(url.lastPathComponent)»: \(error.localizedDescription)"
            }
        }
    }

    func drainSharedQueue() {
        for item in SharedQueue.drain() {
            importArticle(from: item.url)
        }
    }

    // MARK: - Importación

    func importArticle(from url: URL, summaryLength: YouTubeSettings.SummaryLength = .medium) {
        let url = YouTubeLink.canonicalURL(for: url) ?? url
        guard !jobs.contains(where: { $0.url == url && $0.error == nil }) else { return }
        if !url.isFileURL, let existing = articles.first(where: { $0.sourceURL == url }) {
            notice = "«\(existing.title)» ya está en tu biblioteca."
            return
        }
        jobs.removeAll { $0.url == url }
        let job = ImportJob(url: url, status: "Preparando…", summaryLength: summaryLength)
        jobs.append(job)
        Task { await runImport(jobID: job.id, url: url, summaryLength: summaryLength) }
    }

    func retry(_ job: ImportJob) {
        jobs.removeAll { $0.id == job.id }
        importArticle(from: job.url, summaryLength: job.summaryLength)
    }

    func dismiss(_ job: ImportJob) {
        jobs.removeAll { $0.id == job.id }
        removeStagedPDF(job.url)
        YouTubeImporter.discardWorkFiles(for: job.url)
    }

    private func runImport(jobID: UUID, url: URL, summaryLength: YouTubeSettings.SummaryLength) async {
        let update: @MainActor (String) -> Void = { [weak self] status in
            guard let self, let index = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
            self.jobs[index].status = status
        }
        do {
            let article: Article
            if url.isFileURL {
                article = try await PDFImporter.importPDF(at: url, sourceURL: nil, suggestedName: url.lastPathComponent,
                                                          storage: storage, progress: update)
            } else if let videoID = YouTubeLink.videoID(from: url) {
                article = try await YouTubeImporter.importVideo(id: videoID,
                                                                settings: youtube?.configuration ?? YouTubeSettings.Configuration(),
                                                                summaryLength: summaryLength,
                                                                storage: storage, progress: update)
            } else {
                article = try await ArticleImporter.importArticle(from: url, storage: storage, progress: update)
            }
            jobs.removeAll { $0.id == jobID }
            removeStagedPDF(url)
            articles.insert(article, at: 0)
            persist()
            notice = "Guardado: \(article.title)"
            if drive?.autoUpload == true {
                uploadToDrive(article)
            }
        } catch {
            if let index = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[index].error = error.localizedDescription
            }
        }
    }

    /// Borra la copia temporal de un PDF (se conserva mientras se pueda reintentar).
    private func removeStagedPDF(_ url: URL) {
        guard url.isFileURL else { return }
        let staging = ArticleStorage.pdfStagingDirectory.standardizedFileURL.path
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard folder.path.hasPrefix(staging + "/") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Cambios

    func delete(_ article: Article) {
        try? FileManager.default.removeItem(at: storage.folderURL(for: article))
        articles.removeAll { $0.id == article.id }
        persist()
    }

    /// Cambia el título que se ve en la biblioteca y el del Markdown guardado. La carpeta
    /// y el archivo conservan su nombre, así que las rutas de las imágenes no cambian.
    func rename(_ id: UUID, to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = articles.firstIndex(where: { $0.id == id }),
              articles[index].title != title else { return }
        let url = storage.markdownURL(for: articles[index])
        do {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            try ArticleImporter.retitle(markdown, to: title).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            notice = "No se pudo cambiar el título: \(error.localizedDescription)"
            return
        }
        articles[index].title = title
        persist()
        markdownDidChange(id)
    }

    func updateProgress(_ id: UUID, progress: Double) {
        guard let index = articles.firstIndex(where: { $0.id == id }) else { return }
        articles[index].readingProgress = min(max(progress, 0), 1)
        persist()
    }

    /// Se llama cuando el Markdown cambia (resaltados) para sincronizarlo con Drive.
    func markdownDidChange(_ id: UUID) {
        guard let drive, drive.isConnected, let article = article(id: id) else { return }
        guard article.drive != nil || drive.autoUpload else { return }
        pendingDriveUpdates[id]?.cancel()
        pendingDriveUpdates[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self, let current = self.article(id: id) else { return }
            self.uploadToDrive(current)
        }
    }

    func uploadToDrive(_ article: Article) {
        guard let drive else { return }
        Task {
            do {
                let info = try await drive.upload(article: article, storage: storage)
                if let index = articles.firstIndex(where: { $0.id == article.id }) {
                    articles[index].drive = info
                    persist()
                }
            } catch {
                notice = "Google Drive: \(error.localizedDescription)"
            }
        }
    }

    func uploadAllToDrive() {
        for article in articles where article.drive == nil {
            uploadToDrive(article)
        }
    }

    private func persist() {
        storage.saveIndex(articles)
    }
}
