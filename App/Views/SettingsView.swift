import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(DriveSync.self) private var drive
    @Environment(DictionaryService.self) private var dictionary
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false

    var body: some View {
        @Bindable var drive = drive
        @Bindable var dictionary = dictionary
        @Bindable var preferences = preferences

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
                    LabeledContent("Versión", value: Self.version)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
