import SwiftUI

/// Cambia el título de un artículo. El Markdown guardado y, si está en Google Drive,
/// la copia subida se actualizan al guardar.
struct RenameArticleView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    private let article: Article
    @State private var title: String
    @FocusState private var focused: Bool

    init(article: Article) {
        self.article = article
        _title = State(initialValue: article.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Título", text: $title)
                        .focused($focused)
                        .onSubmit(save)
                } footer: {
                    Text("Cambia el título en la biblioteca y en el encabezado del Markdown. El nombre de la carpeta y del archivo no cambia.")
                }
            }
            .navigationTitle("Cambiar título")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        library.rename(article.id, to: title)
        dismiss()
    }
}
