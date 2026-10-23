import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(DriveSync.self) private var drive
    @Environment(DictionaryService.self) private var dictionary
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(YouTubeSettings.self) private var youtube
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var transcriptionCheck = KeyCheck.idle
    @State private var summaryCheck = KeyCheck.idle

    var body: some View {
        @Bindable var drive = drive
        @Bindable var dictionary = dictionary
        @Bindable var preferences = preferences
        @Bindable var youtube = youtube

        NavigationStack {
            Form {
                Section("Lectura") {
                    Picker("Estilo", selection: $preferences.themeID) {
                        ForEach(ReaderTheme.all, id: \.id) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    Picker("Tipografía", selection: $preferences.font) {
                        ForEach(ReaderFont.allCases) { font in
                            Text(font.name).tag(font)
                        }
                    }
                    Stepper("Tamaño: \(Int(preferences.fontSize)) pt", value: $preferences.fontSize, in: 14...32, step: 1)
                }

                Section {
                    Picker("Diccionario", selection: $dictionary.preferredSource) {
                        ForEach(DictionarySource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    TextField("App ID", text: $dictionary.appID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("App Key", text: $dictionary.appKey)
                    TextField("URL base de la API", text: $dictionary.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Diccionario")
                } footer: {
                    Text("«Automático» busca en Oxford English–Spanish y, si la palabra no está, en Oxford Dictionary of English. Con App ID y App Key de la Oxford Dictionaries API (developer.oxforddictionaries.com) la definición se muestra directamente; sin ellas se usan los diccionarios Oxford de iOS (Ajustes › General › Diccionario: «Español – Inglés» y «Inglés (Reino Unido)»).")
                }

                Section {
                    SecureField("Clave de la API de Groq", text: keyBinding(.groq))
                    Picker("Modelo de Whisper", selection: $youtube.transcriptionModel) {
                        ForEach(YouTubeSettings.transcriptionModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    checkButton("Probar clave de voz a texto", check: $transcriptionCheck,
                                disabled: youtube.apiKey(for: .groq).isEmpty) {
                        try await youtube.checkTranscriptionKey()
                    }
                } header: {
                    Text("Resúmenes de YouTube")
                } footer: {
                    Text("Whisper transcribe el audio de los vídeos con la API de Groq. Crea la clave en console.groq.com/keys; se guarda en el llavero del iPhone.")
                }

                Section {
                    Picker("Proveedor", selection: $youtube.summaryProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.name).tag(provider)
                        }
                    }
                    SecureField("Clave de la API de \(youtube.summaryProvider.name)",
                                text: keyBinding(youtube.summaryProvider))
                    if youtube.summaryProvider == .cloudflare {
                        TextField("ID de la cuenta de Cloudflare", text: $youtube.cloudflareAccountID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if youtube.summaryProvider == .custom {
                        TextField("URL base de la API", text: $youtube.customBaseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Modelo") {
                        TextField("Modelo", text: $youtube.summaryModel, prompt: Text(modelPrompt))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Picker("Idioma del resumen", selection: $youtube.summaryLanguage) {
                        ForEach(YouTubeSettings.SummaryLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    checkButton("Probar clave de LLM (\(youtube.summaryProvider.name))", check: $summaryCheck,
                                disabled: !youtube.isSummaryReady) {
                        try await youtube.checkSummaryConnection()
                    }
                } header: {
                    Text("Modelo de lenguaje")
                } footer: {
                    Text(summaryFooter)
                }

                Section {
                    if drive.bundledClientID == nil {
                        TextField("Client ID de iOS", text: $drive.customClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if drive.isConnected {
                        LabeledContent("Cuenta", value: drive.accountEmail ?? "Conectada")
                        Toggle("Subir artículos nuevos", isOn: $drive.autoUpload)
                        Button("Subir los artículos pendientes") { library.uploadAllToDrive() }
                            .disabled(drive.isUploading)
                        Button("Desconectar", role: .destructive) { drive.disconnect() }
                    } else {
                        Button {
                            connecting = true
                            Task {
                                await drive.connect()
                                connecting = false
                            }
                        } label: {
                            HStack {
                                Text("Conectar con Google Drive")
                                if connecting {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(drive.clientID.isEmpty || connecting)
                    }
                    if drive.isUploading {
                        HStack {
                            ProgressView()
                            Text("Subiendo…").foregroundStyle(.secondary)
                        }
                    }
                    if let error = drive.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Google Drive (opcional)")
                } footer: {
                    Text("Los artículos se copian en la carpeta «Leonera Paper» de tu Drive. Se necesita un ID de cliente OAuth de tipo iOS con el bundle ID de la app; la app solo puede ver los archivos que ella misma crea.")
                }

                Section {
                    LabeledContent("Artículos", value: "\(library.articles.count)")
                    LabeledContent("Ubicación", value: "Archivos › En mi iPhone › Leonera Paper")
                } header: {
                    Text("Almacenamiento")
                } footer: {
                    Text("Cada artículo es una carpeta con su archivo .md y las imágenes. Los resaltados se guardan en el Markdown como ==texto==.")
                }

                Section("Acerca de") {
                    LabeledContent("Build", value: Self.buildName)
                }
            }
            .onChange(of: youtube.apiKey(for: .groq)) { _, _ in transcriptionCheck = .idle }
            .onChange(of: youtube.transcriptionModel) { _, _ in transcriptionCheck = .idle }
            .onChange(of: youtube.summaryConnection) { _, _ in summaryCheck = .idle }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }

    private static var buildName: String {
        Bundle.main.infoDictionary?["LPBuildTag"] as? String ?? "?"
    }

    private var summaryFooter: String {
        var text = "Al guardar un enlace de YouTube, el modelo escribe un resumen «Main takeaways» que aparece en la lista de artículos, con la transcripción debajo. Todos los proveedores usan su API compatible con OpenAI."
        if youtube.summaryProvider == .cloudflare {
            text += " En Cloudflare necesitas el ID de tu cuenta y un token de API con permiso de Workers AI."
        }
        if youtube.summaryProvider == .custom {
            text += " Indica la URL base de la API (por ejemplo, https://api.ejemplo.com/v1) y el nombre del modelo."
        }
        if let page = youtube.summaryProvider.keyPage {
            text += " Crea la clave en \(page)."
        }
        return text + " Las claves se guardan en el llavero del iPhone."
    }

    /// The provider's default model, or a hint when the user has to type the model.
    private var modelPrompt: String {
        let model = youtube.summaryProvider.defaultModel
        return model.isEmpty ? "Nombre del modelo" : model
    }

    /// Binding to the key of one provider, which is stored in the Keychain.
    private func keyBinding(_ provider: LLMProvider) -> Binding<String> {
        Binding(
            get: { youtube.apiKey(for: provider) },
            set: { youtube.setAPIKey($0, for: provider) }
        )
    }

    /// «Probar clave» button. Its outcome stays under it until the key, model or endpoint changes.
    private func checkButton(_ title: String, check: Binding<KeyCheck>, disabled: Bool,
                             _ work: @escaping () async throws -> Void) -> some View {
        Group {
            Button {
                check.wrappedValue = .running
                Task {
                    do {
                        try await work()
                        check.wrappedValue = .passed
                    } catch {
                        check.wrappedValue = .failed(error.localizedDescription)
                    }
                }
            } label: {
                HStack {
                    Text(title)
                    if check.wrappedValue == .running {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(disabled || check.wrappedValue == .running)

            switch check.wrappedValue {
            case .idle, .running:
                EmptyView()
            case .passed:
                Label("Clave y modelo correctos.", systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Outcome of a «Probar clave» check.
private enum KeyCheck: Equatable {
    case idle
    case running
    case passed
    case failed(String)
}
