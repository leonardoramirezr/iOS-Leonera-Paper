import Foundation
import Observation

/// Biblioteca de artículos guardados e importaciones en curso.
@MainActor
@Observable
final class Library {
    struct ImportJob: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var status: String
        var error: String?
    }

    private(set) var articles: [Article] = []
    private(set) var jobs: [ImportJob] = []
    /// Mensaje breve para mostrar en la parte inferior de la biblioteca.
    var notice: String?

    let storage = ArticleStorage()
    @ObservationIgnored weak var drive: DriveSync?
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

    // MARK: - Entrada de enlaces

    func handleIncoming(_ url: URL) {
        if let target = AppLinks.articleURL(from: url) {
            importArticle(from: target)
        }
        drainSharedQueue()
    }

    func drainSharedQueue() {
        for item in SharedQueue.drain() {
            importArticle(from: item.url)
        }
    }

    // MARK: - Importación

    func importArticle(from url: URL) {
        guard !jobs.contains(where: { $0.url == url && $0.error == nil }) else { return }
        if let existing = articles.first(where: { $0.sourceURL == url }) {
            notice = "«\(existing.title)» ya está en tu biblioteca."
            return
        }
        jobs.removeAll { $0.url == url }
        let job = ImportJob(url: url, status: "Preparando…")
        jobs.append(job)
        Task { await runImport(jobID: job.id, url: url) }
    }

    func retry(_ job: ImportJob) {
        jobs.removeAll { $0.id == job.id }
        importArticle(from: job.url)
    }

    func dismiss(_ job: ImportJob) {
        jobs.removeAll { $0.id == job.id }
    }

    private func runImport(jobID: UUID, url: URL) async {
        do {
            let article = try await ArticleImporter.importArticle(from: url, storage: storage) { [weak self] status in
                guard let self, let index = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                self.jobs[index].status = status
            }
            jobs.removeAll { $0.id == jobID }
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

    // MARK: - Cambios

    func delete(_ article: Article) {
        try? FileManager.default.removeItem(at: storage.folderURL(for: article))
        articles.removeAll { $0.id == article.id }
        persist()
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
