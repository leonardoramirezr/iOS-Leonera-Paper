import SwiftUI
import UIKit

/// Panel con la definición de la palabra seleccionada.
struct DictionaryPanel: View {
    let term: String
    let theme: ReaderTheme

    @Environment(DictionaryService.self) private var dictionary
    @State private var override: DictionarySource?
    @State private var state: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded(DictionaryEntry)
        case notFound
        case failed(String)
    }

    private var selected: DictionarySource { override ?? dictionary.preferredSource }
    private var effective: DictionarySource { dictionary.effectiveSource(for: selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color(theme.isEInk ? theme.text : theme.secondary.withAlphaComponent(0.25)))
                .frame(height: theme.isEInk ? 1 : 0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: theme.isEInk ? 4 : 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.isEInk ? 4 : 16, style: .continuous)
                .strokeBorder(theme.isEInk ? Color(theme.text) : Color(theme.secondary).opacity(0.2),
                              lineWidth: theme.isEInk ? 1.5 : 0.5)
        )
        .shadow(color: theme.isEInk ? .clear : .black.opacity(0.22), radius: 16, y: 4)
        .environment(\.colorScheme, theme.colorScheme)
        .task(id: "\(term)|\(effective.rawValue)|\(dictionary.hasOxfordCredentials)") {
            await load()
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term)
                    .font(.headline)
                    .foregroundStyle(Color(theme.text))
                    .lineLimit(1)
                Text(sourceDescription)
                    .font(.caption)
                    .foregroundStyle(Color(theme.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Diccionario", selection: Binding(
                    get: { selected },
                    set: { newValue in
                        override = newValue
                        dictionary.preferredSource = newValue
                    }
                )) {
                    ForEach(DictionarySource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
            } label: {
                Label(effective.shortTitle, systemImage: "character.book.closed")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(theme.background)))
                    .overlay(Capsule().strokeBorder(Color(theme.isEInk ? theme.text : theme.secondary.withAlphaComponent(0.3)),
                                                    lineWidth: theme.isEInk ? 1 : 0.5))
                    .foregroundStyle(Color(theme.text))
            }
            .accessibilityLabel("Cambiar diccionario")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sourceDescription: String {
        if case .loaded(let entry) = state, effective != .system {
            return entry.source.title
        }
        if effective == .system {
            return selected == .automatic ? "Oxford (diccionarios de iOS)" : DictionarySource.system.title
        }
        return effective.title
    }

    // MARK: - Contenido

    @ViewBuilder
    private var content: some View {
        if effective == .system {
            SystemDictionaryView(term: term)
        } else if !dictionary.hasOxfordCredentials {
            message(
                "Para consultar \(effective.title) aquí hace falta una clave de la Oxford Dictionaries API (Ajustes › Diccionario).",
                action: "Ver en los diccionarios de iOS"
            ) { override = .system }
        } else {
            switch state {
            case .loading:
                ProgressView()
                    .tint(Color(theme.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let entry):
                EntryView(entry: entry, theme: theme)
            case .notFound:
                message("«\(term)» no aparece en \(effective == .automatic ? "los diccionarios de Oxford" : effective.title).",
                        action: "Buscar en los diccionarios de iOS") { override = .system }
            case .failed(let reason):
                message(reason, action: "Buscar en los diccionarios de iOS") { override = .system }
            }
        }
    }

    private func message(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text)
                .font(.callout)
                .foregroundStyle(Color(theme.secondary))
            Button(action: perform) {
                Text(action).font(.callout.weight(.semibold))
            }
            .tint(Color(theme.isEInk ? theme.text : theme.link))
        }
        .padding(16)
    }

    private func load() async {
        guard effective != .system, dictionary.hasOxfordCredentials else { return }
        state = .loading
        do {
            let entry = try await dictionary.lookup(term, source: effective)
            guard !Task.isCancelled else { return }
            state = entry.map(LoadState.loaded) ?? .notFound
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct EntryView: View {
    let entry: DictionaryEntry
    let theme: ReaderTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(entry.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if !section.category.isEmpty {
                                Text(section.category.lowercased())
                                    .font(.subheadline.italic())
                                    .foregroundStyle(Color(theme.accent))
                            }
                            if let pronunciation = section.pronunciation {
                                Text(pronunciation)
                                    .font(.subheadline)
                                    .foregroundStyle(Color(theme.secondary))
                            }
                        }
                        ForEach(Array(section.senses.enumerated()), id: \.element.id) { index, sense in
                            SenseView(number: "\(index + 1)", sense: sense, isTranslation: entry.source == .englishSpanish,
                                      theme: theme)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SenseView: View {
    let number: String
    let sense: DictionaryEntry.Sense
    let isTranslation: Bool
    let theme: ReaderTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number)
                .font(.callout.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color(theme.secondary))
            VStack(alignment: .leading, spacing: 4) {
                if !sense.labels.isEmpty {
                    Text(sense.labels.joined(separator: ", "))
                        .font(.caption.italic())
                        .foregroundStyle(Color(theme.secondary))
                }
                if !sense.text.isEmpty {
                    Text(sense.text)
                        .font(.body.weight(isTranslation ? .semibold : .regular))
                        .foregroundStyle(Color(theme.text))
                }
                if let detail = sense.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(Color(theme.secondary))
                }
                ForEach(sense.examples, id: \.self) { example in
                    Text(example)
                        .font(.callout.italic())
                        .foregroundStyle(Color(theme.secondary))
                }
                ForEach(Array(sense.subsenses.enumerated()), id: \.element.id) { index, subsense in
                    SenseView(number: "\(number).\(index + 1)", sense: subsense, isTranslation: isTranslation, theme: theme)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// Diccionarios del sistema (en iOS: Oxford Spanish Dictionary, Oxford Dictionary of English…).
struct SystemDictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> Container {
        Container()
    }

    func updateUIViewController(_ controller: Container, context: Context) {
        controller.show(term)
    }

    final class Container: UIViewController {
        private var currentTerm: String?
        private var child: UIViewController?

        func show(_ term: String) {
            guard term != currentTerm else { return }
            currentTerm = term
            if let child {
                child.willMove(toParent: nil)
                child.view.removeFromSuperview()
                child.removeFromParent()
            }
            let reference = UIReferenceLibraryViewController(term: term)
            addChild(reference)
            reference.view.frame = view.bounds
            reference.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(reference.view)
            reference.didMove(toParent: self)
            child = reference
        }
    }
}
