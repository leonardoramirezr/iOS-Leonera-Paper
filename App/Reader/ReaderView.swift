import SwiftUI

struct ReaderView: View {
    @Environment(Library.self) private var library
    @Environment(ReaderPreferences.self) private var preferences
    @Environment(DriveSync.self) private var drive
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL

    @State private var model: ReaderModel
    @State private var showsSettings = false

    init(article: Article, library: Library) {
        _model = State(initialValue: ReaderModel(article: article, library: library))
    }

    var body: some View {
        let theme = preferences.theme
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ReaderTextView(
                    model: model,
                    renderVersion: model.renderVersion,
                    theme: theme,
                    horizontalInset: model.horizontalInset(for: geometry.size.width, preferences: preferences)
                )
                SelectionOverlay(model: model, theme: theme, size: geometry.size)
                if let error = model.loadError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Color(theme.secondary))
                        .padding()
                }
            }
            .onAppear { layout(width: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in layout(width: width) }
            .onChange(of: preferences.layoutKey) { _, _ in layout(width: geometry.size.width) }
        }
        .background(Color(theme.background).ignoresSafeArea())
        .navigationTitle(model.article.displaySite)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(theme.background), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
        .preferredColorScheme(theme.colorScheme)
        .tint(Color(theme.isEInk ? theme.text : theme.accent))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("Estilo de lectura")
                .popover(isPresented: $showsSettings) {
                    ReaderSettingsView()
                        .presentationCompactAdaptation(.popover)
                }

                Menu {
                    ShareLink(item: model.markdownURL) {
                        Label("Compartir Markdown", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        openURL(model.article.sourceURL)
                    } label: {
                        Label("Abrir original", systemImage: "safari")
                    }
                    if drive.isConnected {
                        Button {
                            if let current = library.article(id: model.articleID) {
                                library.uploadToDrive(current)
                            }
                        } label: {
                            Label("Subir a Google Drive", systemImage: "icloud.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Más opciones")
            }
        }
        .onDisappear { model.saveProgress() }
    }

    private func layout(width: CGFloat) {
        model.layoutIfNeeded(width: width, preferences: preferences, displayScale: displayScale)
    }
}

/// Selector de estilo de lectura (tema, tipografía y espaciado).
struct ReaderSettingsView: View {
    @Environment(ReaderPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ReaderTheme.all, id: \.id) { theme in
                    ThemeSwatch(theme: theme, isSelected: preferences.themeID == theme.id) {
                        preferences.themeID = theme.id
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    preferences.fontSize = max(14, preferences.fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                Text("\(Int(preferences.fontSize)) pt")
                    .font(.callout.monospacedDigit())
                    .frame(width: 56)
                Button {
                    preferences.fontSize = min(32, preferences.fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
            }
            .buttonStyle(.bordered)

            HStack {
                Text("Tipografía").font(.callout)
                Spacer()
                Picker("Tipografía", selection: $preferences.font) {
                    ForEach(ReaderFont.allCases) { font in
                        Text(font.name).tag(font)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Interlineado").font(.caption).foregroundStyle(.secondary)
                Slider(value: $preferences.lineSpacing, in: 1.1...2.0, step: 0.05)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Márgenes").font(.caption).foregroundStyle(.secondary)
                Slider(value: $preferences.margin, in: 12...48, step: 2)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

private struct ThemeSwatch: View {
    let theme: ReaderTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                Text(theme.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Color(theme.text))
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(theme.background)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
