import QuickLook
import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(DriveSync.self) private var drive
    @Environment(\.openURL) private var openURL

    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var showsAdd = false
    @State private var showsSettings = false
    @State private var previewURL: URL?
    @State private var renaming: Article?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !library.jobs.isEmpty {
                    Section("Importando") {
                        ForEach(library.jobs) { job in
                            ImportJobRow(job: job)
                        }
                    }
                }
                Section {
                    ForEach(filteredArticles) { article in
                        NavigationLink(value: article.id) {
                            ArticleRow(article: article, imageFolder: library.folderURL(for: article))
                        }
                        .contextMenu { menu(for: article) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                library.delete(article)
                            } label: {
                                Label("Eliminar", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Leonera Paper")
            .searchable(text: $search, prompt: "Buscar artículos")
            .navigationDestination(for: UUID.self) { id in
                if let article = library.article(id: id) {
                    ReaderView(article: article, library: library)
                } else {
                    ContentUnavailableView("Artículo no encontrado", systemImage: "doc.questionmark")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Ajustes")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Añadir URL o PDF")
                }
            }
            .overlay {
                if library.articles.isEmpty && library.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("Sin artículos", systemImage: "doc.richtext")
                    } description: {
                        Text("Comparte una página desde Safari con «Leonera Paper» o pulsa + para pegar una URL o elegir un PDF.")
                    } actions: {
                        Button("Añadir URL o PDF") { showsAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if !search.isEmpty && filteredArticles.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = library.notice {
                    NoticeBanner(text: notice) { library.notice = nil }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: library.notice)
            .sheet(isPresented: $showsAdd) {
                AddArticleView()
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
            .sheet(item: $renaming) { article in
                RenameArticleView(article: article)
            }
            .quickLookPreview($previewURL)
        }
    }

    private var filteredArticles: [Article] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.articles }
        return library.articles.filter { article in
            article.title.localizedCaseInsensitiveContains(query)
                || article.displaySite.localizedCaseInsensitiveContains(query)
                || (article.excerpt?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    @ViewBuilder
    private func menu(for article: Article) -> some View {
        Button {
            renaming = article
        } label: {
            Label("Cambiar título", systemImage: "pencil")
        }
        ShareLink(item: library.markdownURL(for: article)) {
            Label("Compartir Markdown", systemImage: "square.and.arrow.up")
        }
        if let source = article.sourceURL {
            Button {
                openURL(source)
            } label: {
                Label("Abrir original", systemImage: "safari")
            }
        }
        if let pdf = library.pdfURL(for: article) {
            Button {
                previewURL = pdf
            } label: {
                Label("Ver PDF original", systemImage: "doc.richtext")
            }
        }
        if drive.isConnected {
            Button {
                library.uploadToDrive(article)
            } label: {
                Label(article.drive == nil ? "Subir a Google Drive" : "Actualizar en Google Drive",
                      systemImage: "icloud.and.arrow.up")
            }
        }
        Button(role: .destructive) {
            library.delete(article)
        } label: {
            Label("Eliminar", systemImage: "trash")
        }
    }
}

private struct ArticleRow: View {
    let article: Article
    let imageFolder: URL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                    .lineLimit(3)
                if let excerpt = article.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(article.displaySite)
                    Text("·")
                    Text(article.savedAt, format: .dateTime.day().month(.abbreviated))
                    if let progress = article.readingProgress, progress > 0.02 {
                        Text("·")
                        Text(progress > 0.97 ? "Leído" : "\(Int(progress * 100)) %")
                    }
                    if article.drive != nil {
                        Image(systemName: "checkmark.icloud")
                            .accessibilityLabel("En Google Drive")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let lead = article.leadImage {
                Thumbnail(url: imageFolder.appendingPathComponent(lead))
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.12)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 216, height: 216))
            }.value
        }
    }
}

private struct ImportJobRow: View {
    @Environment(Library.self) private var library
    let job: Library.ImportJob

    var body: some View {
        HStack(spacing: 12) {
            if job.error == nil {
                ProgressView()
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(job.error ?? job.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            if job.error != nil {
                Button("Reintentar") { library.retry(job) }
                    .buttonStyle(.borderless)
                Button {
                    library.dismiss(job)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Descartar")
            }
        }
    }
}

private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
            }
            .accessibilityLabel("Cerrar aviso")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: text) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { dismiss() }
        }
    }
}
