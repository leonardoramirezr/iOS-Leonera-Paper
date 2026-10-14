import Foundation
import Observation
import UIKit

struct ReaderSelection: Equatable {
    var range: NSRange
    var text: String
    /// Rectángulo de la selección en coordenadas de la parte visible del lector.
    var rect: CGRect
    var action: HighlightEditor.Action?
}

/// Estado del lector de un artículo: Markdown, maquetación, selección y resaltados.
@MainActor
@Observable
final class ReaderModel {
    let articleID: UUID
    private(set) var article: Article
    private(set) var loadError: String?
    private(set) var renderVersion = 0
    private(set) var selection: ReaderSelection?
    /// Término (debounced) que se busca en el diccionario.
    private(set) var lookupTerm: String?

    @ObservationIgnored private(set) var source = ""
    @ObservationIgnored private(set) var document = RenderedDocument()
    @ObservationIgnored private(set) var attributedText = NSAttributedString()
    @ObservationIgnored weak var textView: ReaderUITextView?
    @ObservationIgnored private var layoutWidth: CGFloat = 0
    @ObservationIgnored private var layoutKey = ""
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var restoredProgress = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private weak var lastPreferences: ReaderPreferences?
    @ObservationIgnored private var lastDisplayScale: CGFloat = 3
    @ObservationIgnored private let library: Library

    init(article: Article, library: Library) {
        self.articleID = article.id
        self.article = article
        self.library = library
    }

    var markdownURL: URL { library.markdownURL(for: article) }
    var folderURL: URL { library.folderURL(for: article) }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        do {
            source = try String(contentsOf: markdownURL, encoding: .utf8)
            document = MarkdownParser.parse(source)
            loadError = nil
        } catch {
            loadError = "No se pudo abrir el archivo: \(error.localizedDescription)"
        }
    }

    // MARK: - Maquetación

    /// Margen horizontal: el preferido, o más en pantallas anchas para no pasar de ~70 caracteres por línea.
    func horizontalInset(for width: CGFloat, preferences: ReaderPreferences) -> CGFloat {
        let maxMeasure = CGFloat(preferences.fontSize) * 36
        return max(CGFloat(preferences.margin), (width - maxMeasure) / 2)
    }

    func layoutIfNeeded(width: CGFloat, preferences: ReaderPreferences, displayScale: CGFloat) {
        guard width > 0 else { return }
        lastPreferences = preferences
        lastDisplayScale = displayScale
        loadIfNeeded()
        themeIDForDecorations = preferences.themeID
        let key = preferences.layoutKey
        guard abs(width - layoutWidth) > 0.5 || key != layoutKey else { return }
        layoutWidth = width
        layoutKey = key
        let inset = horizontalInset(for: width, preferences: preferences)
        let style = AttributedRenderer.Style(
            theme: preferences.theme,
            font: preferences.font,
            fontSize: CGFloat(preferences.fontSize),
            lineSpacing: CGFloat(preferences.lineSpacing),
            contentWidth: width - inset * 2,
            displayScale: displayScale,
            baseFolder: folderURL
        )
        attributedText = AttributedRenderer.render(document, style: style)
        renderVersion += 1
    }

    // MARK: - Selección

    func selectionDidChange(in textView: UITextView) {
        let range = textView.selectedRange
        guard range.length > 0, range.location != NSNotFound, NSMaxRange(range) <= document.length else {
            clearSelectionState()
            return
        }
        let text = document.substring(range)
        selection = ReaderSelection(range: range, text: text, rect: selectionRect(in: textView),
                                    action: HighlightEditor.action(for: range, in: document))
        scheduleLookup(for: text)
    }

    func viewportDidChange(in textView: UITextView) {
        guard var current = selection else { return }
        current.rect = selectionRect(in: textView)
        selection = current
    }

    private func selectionRect(in textView: UITextView) -> CGRect {
        guard let textRange = textView.selectedTextRange else { return .null }
        var rect = textView.selectionRects(for: textRange)
            .map(\.rect)
            .filter { $0.width > 0.5 && $0.height > 0.5 && !$0.isInfinite }
            .reduce(CGRect.null) { $0.union($1) }
        if rect.isNull { rect = textView.firstRect(for: textRange) }
        // De coordenadas del contenido a coordenadas visibles.
        return rect.offsetBy(dx: -textView.contentOffset.x, dy: -textView.contentOffset.y)
    }

    private func scheduleLookup(for text: String) {
        lookupTask?.cancel()
        let term = DictionaryService.lookupTerm(from: text)
        guard let term else {
            lookupTerm = nil
            return
        }
        if lookupTerm == nil {
            lookupTerm = term
            return
        }
        lookupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.lookupTerm = term
        }
    }

    private func clearSelectionState() {
        lookupTask?.cancel()
        selection = nil
        lookupTerm = nil
    }

    func clearSelection() {
        if let textView {
            textView.selectedRange = NSRange(location: textView.selectedRange.location, length: 0)
            textView.resignFirstResponder()
        }
        clearSelectionState()
    }

    // MARK: - Resaltado

    func toggleHighlight() {
        guard let selection, let action = selection.action,
              let updated = HighlightEditor.apply(action, selection: selection.range, in: document, source: source) else {
            clearSelection()
            return
        }
        do {
            try updated.write(to: markdownURL, atomically: true, encoding: .utf8)
        } catch {
            loadError = "No se pudo guardar el resaltado: \(error.localizedDescription)"
            return
        }
        let newDocument = MarkdownParser.parse(updated)
        source = updated
        if newDocument.units == document.units, let textView {
            // Solo cambian los fondos: se actualizan sin rehacer la maquetación ni mover el scroll.
            document = newDocument
            let storage = textView.textStorage
            storage.beginEditing()
            AttributedRenderer.applyDecorations(to: storage, doc: newDocument, theme: ReaderTheme.theme(themeIDForDecorations))
            storage.endEditing()
            attributedText = NSAttributedString(attributedString: storage)
        } else {
            document = newDocument
            layoutKey = ""
            if let lastPreferences {
                layoutIfNeeded(width: layoutWidth, preferences: lastPreferences, displayScale: lastDisplayScale)
            }
        }
        clearSelection()
        library.markdownDidChange(articleID)
    }

    /// Tema activo para repintar los resaltados (lo fija la vista al maquetar).
    @ObservationIgnored var themeIDForDecorations: ReaderThemeID = .paper

    // MARK: - Progreso de lectura

    func saveProgress() {
        guard let textView else { return }
        let maxOffset = textView.contentSize.height - textView.bounds.height
        guard maxOffset > 0 else { return }
        library.updateProgress(articleID, progress: Double(textView.contentOffset.y / maxOffset))
    }

    func restoreProgressIfNeeded() {
        guard !restoredProgress, let textView, let progress = article.readingProgress, progress > 0.01 else { return }
        restoredProgress = true
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        textView.layoutIfNeeded()
        let maxOffset = textView.contentSize.height - textView.bounds.height
        guard maxOffset > 0 else { return }
        textView.setContentOffset(CGPoint(x: 0, y: maxOffset * CGFloat(progress)), animated: false)
    }
}
