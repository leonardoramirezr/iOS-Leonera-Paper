import SwiftUI

/// Añadir o editar un blog. Al escribir la URL se obtienen automáticamente
/// el título y el icono, que se pueden modificar antes de guardar.
struct BlogEditorView: View {
    @Environment(BlogStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let original: Blog?
    @State private var urlText: String
    @State private var title: String
    @State private var iconText: String
    @State private var isFetching = false
    @State private var fetchError: String?
    /// El usuario tocó el título o el icono: no se sobrescriben al volver a obtener.
    @State private var titleEdited: Bool
    @State private var iconEdited: Bool
    @FocusState private var urlFocused: Bool

    init(blog: Blog?) {
        original = blog
        _urlText = State(initialValue: blog?.url.absoluteString ?? "")
        _title = State(initialValue: blog?.title ?? "")
        _iconText = State(initialValue: blog?.iconURL?.absoluteString ?? "")
        _titleEdited = State(initialValue: blog != nil)
        _iconEdited = State(initialValue: blog != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($urlFocused)
                        .onSubmit { Task { await fetch(force: true) } }
                    PasteButton(payloadType: URL.self) { urls in
                        if let url = urls.first { urlText = url.absoluteString }
                    }
                } header: {
                    Text("Dirección")
                } footer: {
                    Text("La portada o el archivo de un blog, newsletter, Medium, Substack…")
                }

                Section {
                    HStack(spacing: 12) {
                        BlogIcon(url: iconURL, size: 44)
                        TextField("Título", text: Binding(get: { title }, set: { title = $0; titleEdited = true }))
                            .font(.headline)
                        if isFetching { ProgressView() }
                    }
                    TextField("URL del icono", text: Binding(get: { iconText }, set: { iconText = $0; iconEdited = true }))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote)
                    Button {
                        titleEdited = false
                        iconEdited = false
                        Task { await fetch(force: true) }
                    } label: {
                        Label("Obtener de nuevo", systemImage: "arrow.clockwise")
                    }
                    .disabled(url == nil || isFetching)
                } header: {
                    Text("Vista previa")
                } footer: {
                    if let fetchError {
                        Text(fetchError).foregroundStyle(.orange)
                    } else {
                        Text("El título y el icono se obtienen automáticamente; puedes cambiarlos antes de guardar.")
                    }
                }
            }
            .navigationTitle(original == nil ? "Añadir blog" : "Editar blog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar", action: save)
                        .disabled(url == nil)
                }
            }
            .task(id: urlText) {
                guard original == nil || url != original?.url else { return }
                // Espera a que el usuario deje de escribir.
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                await fetch(force: false)
            }
            .onAppear { if original == nil { urlFocused = true } }
        }
        .presentationDetents([.medium, .large])
    }

    private var url: URL? { Self.webURL(from: urlText) }

    private var iconURL: URL? {
        let trimmed = iconText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(string: trimmed)
    }

    private func fetch(force: Bool) async {
        guard let url else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let metadata = try await BlogMetadataFetcher.fetch(url)
            guard Self.webURL(from: urlText) == url else { return }
            fetchError = nil
            if !titleEdited || title.isEmpty, let fetched = metadata.title {
                title = fetched
            }
            if !iconEdited || iconText.isEmpty, let icon = metadata.iconURL {
                iconText = icon.absoluteString
            }
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            if force || title.isEmpty {
                fetchError = "No se pudo obtener la página: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        guard let url else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var blog = original ?? Blog(id: UUID(), title: "", url: url, iconURL: nil, addedAt: .now)
        if original == nil, let existing = store.contains(url) {
            blog = existing
        }
        blog.url = url
        blog.title = trimmed.isEmpty ? (url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString) : trimmed
        blog.iconURL = iconURL
        store.save(blog)
        dismiss()
    }

    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, host.contains(".") else { return nil }
        return url
    }
}
