import SwiftUI

/// Posición del botón de resaltar y del panel del diccionario respecto a la palabra.
struct OverlayLayout: Equatable {
    static let menuSize = CGSize(width: 48, height: 48)

    var menu: CGRect
    var dictionary: CGRect?

    init(word: CGRect, container: CGSize, wantsDictionary: Bool) {
        let gap: CGFloat = 10
        let edge: CGFloat = 8
        let menuSize = Self.menuSize

        // Menú: justo debajo de la palabra; si está muy abajo, encima.
        let menuBelow = word.maxY + gap + menuSize.height + 24 <= container.height
        var menuY = menuBelow ? word.maxY + gap : word.minY - gap - menuSize.height
        menuY = min(max(menuY, edge), max(edge, container.height - menuSize.height - edge))
        let menuX = min(max(word.midX - menuSize.width / 2, edge), max(edge, container.width - menuSize.width - edge))
        menu = CGRect(x: menuX, y: menuY, width: menuSize.width, height: menuSize.height)

        guard wantsDictionary else {
            dictionary = nil
            return
        }

        // Diccionario: a todo el ancho, en el lado (arriba o abajo) con más espacio libre.
        let desired = min(max(container.height * 0.4, 220), 380)
        let minimum: CGFloat = 130
        if container.height - word.maxY >= word.minY {
            let top = (menuBelow ? menu.maxY : word.maxY) + gap
            let height = min(desired, container.height - top - edge)
            dictionary = height >= minimum ? CGRect(x: 0, y: top, width: container.width, height: height) : nil
        } else {
            let bottom = (menuBelow ? word.minY : menu.minY) - gap
            let height = min(desired, bottom - edge)
            dictionary = height >= minimum ? CGRect(x: 0, y: bottom - height, width: container.width, height: height) : nil
        }
    }
}

struct SelectionOverlay: View {
    let model: ReaderModel
    let theme: ReaderTheme
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            if let selection = model.selection, isVisible(selection.rect) {
                let layout = OverlayLayout(word: selection.rect, container: size, wantsDictionary: model.lookupTerm != nil)
                if let frame = layout.dictionary, let term = model.lookupTerm {
                    DictionaryPanel(term: term, theme: theme, onClose: { model.dismissDictionary() })
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                }
                if let action = selection.action {
                    HighlightButton(isActive: action == .remove, theme: theme) {
                        model.toggleHighlight()
                    }
                    .position(x: layout.menu.midX, y: layout.menu.midY)
                    .transition(.opacity)
                }
            }
        }
        .animation(theme.isEInk ? nil : .easeOut(duration: 0.15), value: model.selection?.range)
        .animation(theme.isEInk ? nil : .easeOut(duration: 0.15), value: model.lookupTerm)
    }

    private func isVisible(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.maxY > 0 && rect.minY < size.height
    }
}

struct HighlightButton: View {
    let isActive: Bool
    let theme: ReaderTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "highlighter")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: OverlayLayout.menuSize.width, height: OverlayLayout.menuSize.height)
                .background(Circle().fill(fillColor))
                .overlay(Circle().strokeBorder(strokeColor, lineWidth: theme.isEInk ? 1.5 : 0.5))
                .shadow(color: theme.isEInk ? .clear : .black.opacity(0.18), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "Quitar resaltado" : "Resaltar")
    }

    private var fillColor: Color {
        if isActive { return Color(theme.isEInk ? theme.text : theme.highlight) }
        return Color(theme.surface)
    }

    private var iconColor: Color {
        if isActive && theme.isEInk { return Color(theme.background) }
        return Color(theme.text)
    }

    private var strokeColor: Color {
        theme.isEInk ? Color(theme.text) : Color(theme.secondary).opacity(0.3)
    }
}
