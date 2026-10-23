import SwiftUI

/// Archived articles. They leave the main list but stay on disk until deleted here.
struct ArchiveView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.archivedArticles) { article in
                    NavigationLink(value: article.id) {
                        ArticleRow(article: article, imageFolder: library.folderURL(for: article))
                    }
                    .contextMenu {
                        Button {
                            library.setArchived(article, false)
                        } label: {
                            Label("Desarchivar", systemImage: "tray.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            library.delete(article)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            library.delete(article)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            library.setArchived(article, false)
                        } label: {
                            Label("Desarchivar", systemImage: "tray.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Archivo")
            .navigationDestination(for: UUID.self) { id in
                if let article = library.article(id: id) {
                    ReaderView(article: article, library: library)
                } else {
                    ContentUnavailableView("Artículo no encontrado", systemImage: "doc.questionmark")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") { dismiss() }
                }
            }
            .overlay {
                if library.archivedArticles.isEmpty {
                    ContentUnavailableView("Sin artículos archivados", systemImage: "archivebox",
                                           description: Text("Desliza un artículo de derecha a izquierda para archivarlo. Sigue guardado y puedes recuperarlo desde aquí."))
                }
            }
        }
    }
}
