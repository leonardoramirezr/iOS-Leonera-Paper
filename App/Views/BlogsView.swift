import SwiftUI

/// Blogs, newsletters y otras portadas guardadas para descubrir artículos nuevos.
struct BlogsView: View {
    @Environment(BlogStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var search = ""
    @State private var showsAdd = false
    @State private var editing: Blog?

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredBlogs) { blog in
                    Button {
                        openURL(blog.url)
                    } label: {
                        BlogRow(blog: blog)
                    }
                    .foregroundStyle(.primary)
                    .contextMenu {
                        Button {
                            editing = blog
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        ShareLink(item: blog.url) {
                            Label("Compartir", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            store.delete(blog)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete(blog)
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                        Button {
                            editing = blog
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onMove(perform: search.isEmpty ? move : nil)
            }
            .listStyle(.plain)
            .navigationTitle("Blogs")
            .searchable(text: $search, prompt: "Buscar blogs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.blogs.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Añadir blog")
                }
            }
            .overlay {
                if store.blogs.isEmpty {
                    ContentUnavailableView {
                        Label("Sin blogs", systemImage: "books.vertical")
                    } description: {
                        Text("Guarda la portada o el archivo de un blog, newsletter o perfil de Medium para descubrir artículos nuevos.")
                    } actions: {
                        Button("Añadir blog") { showsAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if !search.isEmpty && filteredBlogs.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .sheet(isPresented: $showsAdd) {
                BlogEditorView(blog: nil)
            }
            .sheet(item: $editing) { blog in
                BlogEditorView(blog: blog)
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        store.move(from: source, to: destination)
    }

    private var filteredBlogs: [Blog] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.blogs }
        return store.blogs.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct BlogRow: View {
    let blog: Blog

    var body: some View {
        HStack(spacing: 12) {
            BlogIcon(url: blog.iconURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(blog.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(blog.displayHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Icono del blog con un marcador de posición mientras carga o si falla.
struct BlogIcon: View {
    let url: URL?
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}
