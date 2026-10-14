import Foundation

/// Convierte una selección sobre el texto pintado en ediciones `==…==` del Markdown.
enum HighlightEditor {
    enum Action: Equatable {
        case add
        case remove
    }

    private struct Edit {
        var range: NSRange
        var replacement: String
    }

    /// `.remove` si todo lo seleccionado ya está resaltado, `.add` si no, nil si no hay texto resaltable.
    static func action(for selection: NSRange, in doc: RenderedDocument) -> Action? {
        var anyText = false
        var allHighlighted = true
        for block in doc.blocks where block.kind.isHighlightable {
            guard let range = intersection(selection, block.range) else { continue }
            for index in range where isContent(index, in: doc) {
                anyText = true
                if !doc.styles[index].contains(.highlight) {
                    allHighlighted = false
                    break
                }
            }
        }
        guard anyText else { return nil }
        return allHighlighted ? .remove : .add
    }

    /// Devuelve el Markdown con la selección resaltada (o sin resaltar), o nil si no cambia nada.
    static func apply(_ action: Action, selection: NSRange, in doc: RenderedDocument, source: String) -> String? {
        var edits: [Edit] = []

        for block in doc.blocks where block.kind.isHighlightable {
            guard let range = intersection(selection, block.range),
                  let trimmed = trim(range, in: doc) else { continue }

            switch action {
            case .remove:
                for span in block.highlights where overlaps(span.range, trimmed) {
                    edits.append(contentsOf: deletions(for: span))
                }

            case .add:
                var lower = trimmed.lowerBound
                var upper = trimmed.upperBound
                for span in block.highlights where touches(span.range, trimmed, in: doc) {
                    lower = min(lower, span.range.location)
                    upper = max(upper, NSMaxRange(span.range))
                    edits.append(contentsOf: deletions(for: span))
                }
                guard let first = (lower..<upper).first(where: { doc.isMapped($0) }),
                      let last = (lower..<upper).last(where: { doc.isMapped($0) }) else { continue }
                edits.append(Edit(range: NSRange(location: Int(doc.sourceStart[first]), length: 0), replacement: "=="))
                edits.append(Edit(range: NSRange(location: Int(doc.sourceEnd[last]), length: 0), replacement: "=="))
            }
        }

        guard !edits.isEmpty else { return nil }

        // Se aplican de atrás hacia delante para que las posiciones sigan siendo válidas.
        edits.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location { return lhs.range.location > rhs.range.location }
            return lhs.range.length > rhs.range.length
        }
        var units = Array(source.utf16)
        for edit in edits {
            let lower = max(0, min(edit.range.location, units.count))
            let upper = max(lower, min(NSMaxRange(edit.range), units.count))
            units.replaceSubrange(lower..<upper, with: Array(edit.replacement.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - Utilidades

    private static func deletions(for span: HighlightSpan) -> [Edit] {
        var result = [Edit(range: span.openMarker, replacement: "")]
        if let close = span.closeMarker { result.append(Edit(range: close, replacement: "")) }
        return result
    }

    private static func intersection(_ a: NSRange, _ b: NSRange) -> Range<Int>? {
        let lower = max(a.location, b.location)
        let upper = min(NSMaxRange(a), NSMaxRange(b))
        return lower < upper ? lower..<upper : nil
    }

    private static func isContent(_ index: Int, in doc: RenderedDocument) -> Bool {
        doc.isMapped(index) && !isWhitespace(doc.units[index])
    }

    private static func trim(_ range: Range<Int>, in doc: RenderedDocument) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper && !isContent(lower, in: doc) { lower += 1 }
        while upper > lower && !isContent(upper - 1, in: doc) { upper -= 1 }
        return lower < upper ? lower..<upper : nil
    }

    private static func overlaps(_ span: NSRange, _ range: Range<Int>) -> Bool {
        span.location < range.upperBound && NSMaxRange(span) > range.lowerBound
    }

    /// Un resaltado toca la selección si se solapan o si entre ambos solo hay espacios.
    private static func touches(_ span: NSRange, _ range: Range<Int>, in doc: RenderedDocument) -> Bool {
        if span.location <= range.upperBound && NSMaxRange(span) >= range.lowerBound { return true }
        let gap = NSMaxRange(span) < range.lowerBound
            ? NSMaxRange(span)..<range.lowerBound
            : range.upperBound..<span.location
        return !gap.contains { isContent($0, in: doc) }
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0 || unit == 0x2028
    }
}
