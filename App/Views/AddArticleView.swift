import SwiftUI
import UniformTypeIdentifiers

/// Añadir un artículo pegando su URL o eligiendo un PDF.
struct AddArticleView: View {
    @Environment(Library.self) private var library
    @Environment(YouTubeSettings.self) private var youtube
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showsPDFPicker = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $text, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(save)
                    PasteButton(payloadType: URL.self) { urls in
                        if let url = urls.first {
                            text = url.absoluteString
                        }
                    }
                    if let url, YouTubeLink.isVideo(url) {
                        if youtube.canSummarizeVideos {
                            Label("Vídeo de YouTube: se transcribirá con Whisper y se resumirá con \(youtube.summaryProvider.name).",
                                  systemImage: "play.rectangle")
                                .font(.footnote)
                        } else {
                            Label("Para resumir vídeos de YouTube, añade las claves de Groq y de \(youtube.summaryProvider.name) en Ajustes › Resúmenes de YouTube.",
                                  systemImage: "key")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("La página se convierte a Markdown con sus imágenes y se guarda en Archivos › En mi iPhone › Leonera Paper. Un enlace de YouTube se guarda como resumen del vídeo. También puedes compartirlos desde Safari o la app de YouTube.")
                }
                Section {
                    Button {
                        focused = false
                        showsPDFPicker = true
                    } label: {
                        Label("Elegir PDF…", systemImage: "doc.richtext")
                    }
                } footer: {
                    Text("El PDF se convierte a Markdown y se guarda junto al original. También puedes abrir un PDF desde Archivos o Mail con «Leonera Paper», o pegar el enlace a un PDF.")
                }
            }
            .fileImporter(isPresented: $showsPDFPicker, allowedContentTypes: [.pdf],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                for url in urls {
                    library.importPDF(at: url)
                }
                dismiss()
            }
            .navigationTitle("Añadir artículo")
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
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var url: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, host.contains(".") else { return nil }
        return url
    }

    private func save() {
        guard let url else { return }
        library.importArticle(from: url)
        dismiss()
    }
}
