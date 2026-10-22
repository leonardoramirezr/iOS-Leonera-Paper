import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// UITextView de solo lectura con selección. El menú de edición del sistema se
/// suprime: en su lugar se muestra el botón de resaltar y el panel del diccionario.
final class ReaderUITextView: UITextView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }

    private var lastFocusReclaim = Date.distantPast

    /// Se llama al tocar una de las asas de la selección (para ampliarla o reducirla).
    private var onSelectionHandleTouch: (() -> Void)?

    func observeSelectionHandleTouches(_ handler: @escaping () -> Void) {
        onSelectionHandleTouch = handler
        addGestureRecognizer(TouchDownRecognizer { [weak self] location in
            self?.touchDidBegin(at: location)
        })
    }

    /// Las asas son vistas privadas del sistema: se detecta el toque cerca de los extremos
    /// de la selección, donde el sistema las dibuja.
    private func touchDidBegin(at location: CGPoint) {
        guard selectedRange.length > 0, let range = selectedTextRange else { return }
        let hitArea: (UITextPosition) -> CGRect = { [self] position in
            caretRect(for: position).insetBy(dx: -22, dy: -22)
        }
        if hitArea(range.start).contains(location) || hitArea(range.end).contains(location) {
            onSelectionHandleTouch?()
        }
    }

    /// Al aparecer, el diccionario del sistema toma el foco y la selección (con sus
    /// asas para ampliarla) deja de dibujarse. Si el foco se lo ha llevado el
    /// diccionario, se recupera para que la palabra siga marcada.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange.length > 0 {
            DispatchQueue.main.async { [weak self] in self?.reclaimFocusIfTakenByDictionary() }
        }
        return resigned
    }

    private func reclaimFocusIfTakenByDictionary() {
        guard selectedRange.length > 0, window != nil, !isFirstResponder,
              Date().timeIntervalSince(lastFocusReclaim) > 0.5 else { return }
        if let responder = UIResponder.current {
            // Solo si lo tomó al aparecer, no si el usuario toca su campo de búsqueda.
            var next: UIResponder? = responder
            while let current = next, !(current is SystemDictionaryView.Container) {
                next = current.next
            }
            guard let container = next as? SystemDictionaryView.Container,
                  Date().timeIntervalSince(container.shownAt) < 2 else { return }
        }
        lastFocusReclaim = Date()
        becomeFirstResponder()
    }

    /// Índice del primer carácter visible, para conservar la posición al volver a maquetar.
    func topVisibleCharacterIndex() -> Int? {
        guard textStorage.length > 0 else { return nil }
        let point = CGPoint(x: bounds.midX, y: contentOffset.y + adjustedContentInset.top + 4)
        guard let position = closestPosition(to: point) else { return nil }
        return offset(from: beginningOfDocument, to: position)
    }

    func scroll(toCharacterIndex index: Int) {
        guard let position = position(from: beginningOfDocument, offset: min(index, textStorage.length)) else { return }
        layoutIfNeeded()
        let caret = caretRect(for: position)
        guard !caret.isNull, !caret.isInfinite else { return }
        let maxOffset = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let y = min(max(caret.minY - adjustedContentInset.top - 4, -adjustedContentInset.top), maxOffset)
        setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
}

struct ReaderTextView: UIViewRepresentable {
    let model: ReaderModel
    let renderVersion: Int
    let theme: ReaderTheme
    let horizontalInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> ReaderUITextView {
        // TextKit 1: geometría de selección y adjuntos de imagen más fiables.
        let textView = ReaderUITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.dataDetectorTypes = []
        textView.textContainer.lineFragmentPadding = 0
        textView.layoutManager.allowsNonContiguousLayout = false
        textView.keyboardDismissMode = .none
        textView.delegate = context.coordinator
        textView.observeSelectionHandleTouches { [weak model] in model?.dismissDictionary() }
        model.textView = textView
        return textView
    }

    func updateUIView(_ textView: ReaderUITextView, context: Context) {
        textView.backgroundColor = theme.background
        textView.tintColor = theme.accent
        textView.indicatorStyle = theme.isDark ? .white : .black
        var linkAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: theme.link]
        if theme.isEInk {
            linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        textView.linkTextAttributes = linkAttributes
        let insets = UIEdgeInsets(top: 24, left: horizontalInset, bottom: 140, right: horizontalInset)
        if textView.textContainerInset != insets {
            textView.textContainerInset = insets
        }

        let coordinator = context.coordinator
        if coordinator.renderVersion != renderVersion {
            let isFirstRender = coordinator.renderVersion == nil
            coordinator.renderVersion = renderVersion
            let anchor = isFirstRender ? nil : textView.topVisibleCharacterIndex()
            textView.attributedText = model.attributedText
            if let anchor {
                textView.scroll(toCharacterIndex: anchor)
            } else {
                DispatchQueue.main.async { model.restoreProgressIfNeeded() }
            }
        }
    }

    static func dismantleUIView(_ textView: ReaderUITextView, coordinator: Coordinator) {
        coordinator.model.saveProgress()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let model: ReaderModel
        var renderVersion: Int?
        private var lastProgressSave = Date.distantPast

        init(model: ReaderModel) {
            self.model = model
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            model.selectionDidChange(in: textView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            model.viewportDidChange(in: textView)
            if Date().timeIntervalSince(lastProgressSave) > 3 {
                lastProgressSave = Date()
                model.saveProgress()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            model.saveProgress()
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            // Menú vacío: no se muestra el menú del sistema.
            UIMenu(children: [])
        }
    }
}

/// Avisa del inicio de cada toque sin reconocer nada ni interferir con los demás gestos.
private final class TouchDownRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let handler: (CGPoint) -> Void

    init(handler: @escaping (CGPoint) -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view {
            handler(touch.location(in: view))
        }
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension UIResponder {
    private static weak var captured: UIResponder?

    /// Primer respondedor actual de la app.
    static var current: UIResponder? {
        captured = nil
        UIApplication.shared.sendAction(#selector(captureFirstResponder), to: nil, from: nil, for: nil)
        return captured
    }

    @objc private func captureFirstResponder() {
        UIResponder.captured = self
    }
}
