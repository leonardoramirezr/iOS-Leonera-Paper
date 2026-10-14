import Foundation

/// Estilos de texto en línea que el lector sabe pintar.
struct InlineStyle: OptionSet, Hashable {
    let rawValue: UInt8

    static let bold = InlineStyle(rawValue: 1 << 0)
    static let italic = InlineStyle(rawValue: 1 << 1)
    static let code = InlineStyle(rawValue: 1 << 2)
    static let highlight = InlineStyle(rawValue: 1 << 3)
    static let strike = InlineStyle(rawValue: 1 << 4)
}

enum BlockKind: Equatable {
    case heading(level: Int)
    case paragraph
    /// `marker` vacío indica un párrafo de continuación dentro de un elemento de lista.
    case listItem(marker: String, level: Int)
    case quote(level: Int)
    case code
    case rule
    case image
    case tableRow(header: Bool)

    /// Bloques cuyo texto procede del Markdown en línea y por tanto se puede resaltar.
    var isHighlightable: Bool {
        switch self {
        case .heading, .paragraph, .listItem, .quote, .tableRow: return true
        case .code, .rule, .image: return false
        }
    }
}

/// Un tramo `==resaltado==` tal y como quedó en el texto pintado.
struct HighlightSpan: Equatable {
    /// Rango en el texto pintado.
    var range: NSRange
    /// Rango del `==` de apertura en el Markdown.
    var openMarker: NSRange
    /// Rango del `==` de cierre en el Markdown (nil si el bloque terminó sin cerrarlo).
    var closeMarker: NSRange?
}

struct RenderedBlock: Equatable {
    var kind: BlockKind
    /// Rango en el texto pintado, sin el salto de línea final.
    var range: NSRange
    var highlights: [HighlightSpan]
}

struct ImageReference: Equatable {
    /// Posición del carácter U+FFFC que representa la imagen en el texto pintado.
    var location: Int
    var alt: String
    var source: String
    var isBlock: Bool
}

struct LinkReference: Equatable {
    var range: NSRange
    var destination: String
}

/// Resultado de interpretar un Markdown: el texto plano que se muestra, su
/// correspondencia carácter a carácter con el Markdown original y los bloques.
struct RenderedDocument {
    static let attachmentCharacter: UInt16 = 0xFFFC

    var units: [UInt16] = []
    /// Para cada unidad UTF-16 pintada, dónde empieza y termina en el Markdown (-1 si es sintética).
    var sourceStart: [Int32] = []
    var sourceEnd: [Int32] = []
    var styles: [InlineStyle] = []
    var blocks: [RenderedBlock] = []
    var images: [ImageReference] = []
    var links: [LinkReference] = []
    var frontMatter: [String: String] = [:]

    var text: String { String(decoding: units, as: UTF16.self) }
    var length: Int { units.count }

    var title: String? {
        if let title = frontMatter["title"], !title.isEmpty { return title }
        for block in blocks {
            if case .heading(1) = block.kind { return substring(block.range) }
        }
        return nil
    }

    func substring(_ range: NSRange) -> String {
        let lower = max(0, min(range.location, units.count))
        let upper = max(lower, min(NSMaxRange(range), units.count))
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    func isMapped(_ index: Int) -> Bool { sourceStart[index] >= 0 }
}

enum MarkdownParser {
    static func parse(_ source: String) -> RenderedDocument {
        var parser = Parser(source: Array(source.utf16))
        parser.run()
        return parser.doc
    }
}

// MARK: - Implementación

private enum Ch {
    static let tab: UInt16 = 0x09
    static let newline: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let bang: UInt16 = 0x21
    static let quote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let lparen: UInt16 = 0x28
    static let rparen: UInt16 = 0x29
    static let star: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let minus: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let colon: UInt16 = 0x3A
    static let lt: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let gt: UInt16 = 0x3E
    static let lbracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let rbracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let pipe: UInt16 = 0x7C
    static let tilde: UInt16 = 0x7E
    static let lineSeparator: UInt16 = 0x2028

    static func isSpace(_ u: UInt16) -> Bool { u == space || u == tab }

    static func isWhitespace(_ u: UInt16) -> Bool {
        u == space || u == tab || u == newline || u == carriageReturn || u == 0xA0 || u == lineSeparator
    }

    static func isPunctuation(_ u: UInt16) -> Bool {
        (u >= 0x21 && u <= 0x2F) || (u >= 0x3A && u <= 0x40) || (u >= 0x5B && u <= 0x60) || (u >= 0x7B && u <= 0x7E)
    }

    static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }

    static func isAlphanumeric(_ u: UInt16) -> Bool {
        if isDigit(u) { return true }
        let lower = u | 0x20
        if lower >= 0x61 && lower <= 0x7A { return true }
        return u >= 0xC0 && u != lineSeparator && u != 0xFFFC
    }
}

private struct Line {
    var start: Int
    var end: Int
}

private struct InlineState {
    var style: InlineStyle = []
    var openHighlight: (marker: NSRange, rendered: Int)?
    var highlights: [HighlightSpan] = []
}

private struct Parser {
    let s: [UInt16]
    var lines: [Line] = []
    var doc = RenderedDocument()

    init(source: [UInt16]) {
        s = source
        var start = 0
        for index in 0..<s.count where s[index] == Ch.newline {
            lines.append(Line(start: start, end: Self.trimmedCR(s, start, index)))
            start = index + 1
        }
        if start < s.count {
            lines.append(Line(start: start, end: Self.trimmedCR(s, start, s.count)))
        }
    }

    private static func trimmedCR(_ s: [UInt16], _ start: Int, _ end: Int) -> Int {
        end > start && s[end - 1] == Ch.carriageReturn ? end - 1 : end
    }

    // MARK: Utilidades de línea

    func firstNonSpace(_ line: Line) -> Int {
        var i = line.start
        while i < line.end && Ch.isSpace(s[i]) { i += 1 }
        return i
    }

    func indentWidth(_ line: Line) -> Int {
        var width = 0
        var i = line.start
        while i < line.end && Ch.isSpace(s[i]) {
            width += s[i] == Ch.tab ? 4 : 1
            i += 1
        }
        return width
    }

    func isBlank(_ line: Line) -> Bool { firstNonSpace(line) >= line.end }

    func lineText(_ line: Line) -> String { String(decoding: s[line.start..<line.end], as: UTF16.self) }

    func trimmedEnd(_ start: Int, _ end: Int) -> Int {
        var e = end
        while e > start && Ch.isSpace(s[e - 1]) { e -= 1 }
        return e
    }

    func fence(_ line: Line) -> (char: UInt16, count: Int)? {
        guard indentWidth(line) <= 3 else { return nil }
        let i = firstNonSpace(line)
        guard i < line.end, s[i] == Ch.backtick || s[i] == Ch.tilde else { return nil }
        let char = s[i]
        var j = i
        while j < line.end && s[j] == char { j += 1 }
        return j - i >= 3 ? (char, j - i) : nil
    }

    func heading(_ line: Line) -> (level: Int, content: Line)? {
        guard indentWidth(line) <= 3 else { return nil }
        let i = firstNonSpace(line)
        var j = i
        while j < line.end && s[j] == Ch.hash { j += 1 }
        let level = j - i
        guard level >= 1, level <= 6, j == line.end || Ch.isSpace(s[j]) else { return nil }
        var start = j
        while start < line.end && Ch.isSpace(s[start]) { start += 1 }
        var end = trimmedEnd(start, line.end)
        var k = end
        while k > start && s[k - 1] == Ch.hash { k -= 1 }
        if k < end && (k == start || Ch.isSpace(s[k - 1])) { end = trimmedEnd(start, k) }
        return (level, Line(start: start, end: end))
    }

    func isRule(_ line: Line) -> Bool {
        guard indentWidth(line) <= 3 else { return false }
        var char: UInt16 = 0
        var count = 0
        for i in line.start..<line.end {
            let u = s[i]
            if Ch.isSpace(u) { continue }
            guard u == Ch.minus || u == Ch.star || u == Ch.underscore else { return false }
            if char == 0 { char = u } else if u != char { return false }
            count += 1
        }
        return count >= 3
    }

    func quoteContent(_ line: Line) -> (level: Int, content: Line)? {
        guard indentWidth(line) <= 3 else { return nil }
        var i = firstNonSpace(line)
        guard i < line.end, s[i] == Ch.gt else { return nil }
        var level = 0
        while i < line.end && s[i] == Ch.gt {
            level += 1
            i += 1
            if i < line.end && Ch.isSpace(s[i]) { i += 1 }
            var k = i
            while k < line.end && Ch.isSpace(s[k]) { k += 1 }
            if k < line.end && s[k] == Ch.gt { i = k } else { break }
        }
        return (level, Line(start: i, end: line.end))
    }

    func listItem(_ line: Line) -> (marker: String, ordered: Bool, indent: Int, content: Line)? {
        let indent = indentWidth(line)
        let i = firstNonSpace(line)
        guard i < line.end else { return nil }
        let u = s[i]
        if u == Ch.minus || u == Ch.star || u == Ch.plus {
            guard i + 1 < line.end, Ch.isSpace(s[i + 1]) else { return nil }
            var start = i + 1
            while start < line.end && Ch.isSpace(s[start]) { start += 1 }
            return ("•", false, indent, Line(start: start, end: line.end))
        }
        var j = i
        while j < line.end && Ch.isDigit(s[j]) && j - i < 9 { j += 1 }
        guard j > i, j < line.end, s[j] == Ch.dot || s[j] == Ch.rparen,
              j + 1 < line.end, Ch.isSpace(s[j + 1]) else { return nil }
        let number = String(decoding: s[i..<j], as: UTF16.self)
        var start = j + 1
        while start < line.end && Ch.isSpace(s[start]) { start += 1 }
        return ("\(Int(number) ?? 1).", true, indent, Line(start: start, end: line.end))
    }

    func isTableRow(_ line: Line) -> Bool {
        let i = firstNonSpace(line)
        return i < line.end && s[i] == Ch.pipe
    }

    func isTableSeparator(_ line: Line) -> Bool {
        var sawDash = false
        for i in line.start..<line.end {
            let u = s[i]
            if u == Ch.minus { sawDash = true; continue }
            if u == Ch.pipe || u == Ch.colon || Ch.isSpace(u) { continue }
            return false
        }
        return sawDash
    }

    func startsBlock(_ line: Line) -> Bool {
        fence(line) != nil || heading(line) != nil || isRule(line) || quoteContent(line) != nil
            || listItem(line) != nil || isTableRow(line)
    }

    // MARK: Bloques

    mutating func run() {
        var index = parseFrontMatter()
        var previousWasListItem = false
        var listLevel = 0

        while index < lines.count {
            let line = lines[index]
            if isBlank(line) {
                index += 1
                continue
            }

            if let open = fence(line) {
                index = parseCodeBlock(from: index, fence: open)
                previousWasListItem = false
                continue
            }

            if let heading = heading(line) {
                emitInlineBlock(.heading(level: heading.level), segments: [heading.content])
                index += 1
                previousWasListItem = false
                continue
            }

            if isRule(line) {
                let start = doc.length
                emitSynthetic("⁂", style: [])
                finishBlock(.rule, start: start, highlights: [])
                index += 1
                previousWasListItem = false
                continue
            }

            if quoteContent(line) != nil {
                index = parseQuote(from: index)
                previousWasListItem = false
                continue
            }

            if let item = listItem(line) {
                var segments = [item.content]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    if isBlank(next) || startsBlock(next) { break }
                    segments.append(Line(start: firstNonSpace(next), end: next.end))
                    index += 1
                }
                listLevel = min(item.indent / 2, 6)
                emitInlineBlock(.listItem(marker: item.marker, level: listLevel), segments: segments)
                previousWasListItem = true
                continue
            }

            if isTableRow(line) {
                var rows: [Line] = []
                while index < lines.count, isTableRow(lines[index]) {
                    rows.append(lines[index])
                    index += 1
                }
                let separator = rows.firstIndex(where: { isTableSeparator($0) })
                for (rowIndex, row) in rows.enumerated() where rowIndex != separator {
                    let header = separator.map { rowIndex < $0 } ?? false
                    emitTableRow(row, header: header)
                }
                previousWasListItem = false
                continue
            }

            // Párrafo (o imagen sola).
            var segments: [Line] = []
            let continuesList = previousWasListItem && indentWidth(line) >= 2
            while index < lines.count {
                let next = lines[index]
                if isBlank(next) || (!segments.isEmpty && startsBlock(next)) { break }
                segments.append(Line(start: firstNonSpace(next), end: next.end))
                index += 1
            }
            if segments.count == 1, let image = standaloneImage(segments[0]) {
                let start = doc.length
                doc.images.append(ImageReference(location: start, alt: image.alt, source: image.source, isBlock: true))
                emitSynthetic("\u{FFFC}", style: [])
                finishBlock(.image, start: start, highlights: [])
            } else if continuesList {
                emitInlineBlock(.listItem(marker: "", level: listLevel), segments: segments)
            } else {
                emitInlineBlock(.paragraph, segments: segments)
                previousWasListItem = false
            }
        }
    }

    mutating func parseFrontMatter() -> Int {
        guard let first = lines.first, lineText(first) == "---" else { return 0 }
        var index = 1
        while index < lines.count {
            let text = lineText(lines[index])
            if text == "---" || text == "..." {
                return index + 1
            }
            if let colon = text.firstIndex(of: ":") {
                let key = text[..<colon].trimmingCharacters(in: .whitespaces)
                var value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                }
                if !key.isEmpty { doc.frontMatter[key] = value }
            }
            index += 1
        }
        // Sin cierre: no era front matter.
        doc.frontMatter = [:]
        return 0
    }

    mutating func parseCodeBlock(from startIndex: Int, fence open: (char: UInt16, count: Int)) -> Int {
        var index = startIndex + 1
        var content: [Line] = []
        while index < lines.count {
            let line = lines[index]
            if let close = fence(line), close.char == open.char, close.count >= open.count,
               trimmedEnd(firstNonSpace(line), line.end) - firstNonSpace(line) == close.count {
                index += 1
                break
            }
            content.append(line)
            index += 1
        }
        let start = doc.length
        for (offset, line) in content.enumerated() {
            if offset > 0 {
                emit(Ch.lineSeparator, line.start - 1, line.start, [])
            }
            for i in line.start..<line.end {
                emit(s[i], i, i + 1, [])
            }
        }
        if content.isEmpty { emitSynthetic(" ", style: []) }
        finishBlock(.code, start: start, highlights: [])
        return index
    }

    mutating func parseQuote(from startIndex: Int) -> Int {
        var index = startIndex
        var paragraph: [Line] = []
        var level = 1

        while index < lines.count, let quote = quoteContent(lines[index]) {
            let content = quote.content
            let isEmpty = firstNonSpace(content) >= content.end
            if !paragraph.isEmpty && (isEmpty || quote.level != level) {
                emitInlineBlock(.quote(level: level), segments: paragraph)
                paragraph.removeAll()
            }
            if !isEmpty {
                level = quote.level
                paragraph.append(Line(start: firstNonSpace(content), end: content.end))
            }
            index += 1
        }
        if !paragraph.isEmpty {
            emitInlineBlock(.quote(level: level), segments: paragraph)
        }
        return index
    }

    func standaloneImage(_ line: Line) -> (alt: String, source: String)? {
        let start = firstNonSpace(line)
        let end = trimmedEnd(start, line.end)
        guard end - start > 4, s[start] == Ch.bang, s[start + 1] == Ch.lbracket,
              let match = matchLink(at: start + 1, limit: end), match.end == end else { return nil }
        return (unescaped(match.label), match.destination)
    }

    // MARK: Emisión

    mutating func emit(_ unit: UInt16, _ start: Int, _ end: Int, _ style: InlineStyle) {
        doc.units.append(unit)
        doc.sourceStart.append(Int32(start))
        doc.sourceEnd.append(Int32(end))
        doc.styles.append(style)
    }

    mutating func emitSynthetic(_ string: String, style: InlineStyle) {
        for unit in string.utf16 {
            doc.units.append(unit)
            doc.sourceStart.append(-1)
            doc.sourceEnd.append(-1)
            doc.styles.append(style)
        }
    }

    mutating func finishBlock(_ kind: BlockKind, start: Int, highlights: [HighlightSpan]) {
        doc.blocks.append(RenderedBlock(kind: kind, range: NSRange(location: start, length: doc.length - start),
                                        highlights: highlights))
        emitSynthetic("\n", style: [])
    }

    mutating func emitInlineBlock(_ kind: BlockKind, segments: [Line]) {
        let start = doc.length
        if case let .listItem(marker, _) = kind, !marker.isEmpty {
            emitSynthetic(marker + "\t", style: [])
        }
        var state = InlineState()
        for (offset, segment) in segments.enumerated() {
            let isLast = offset == segments.count - 1
            var end = trimmedEnd(segment.start, segment.end)
            var hardBreak = false
            if !isLast {
                if end > segment.start && s[end - 1] == Ch.backslash {
                    hardBreak = true
                    end -= 1
                } else if segment.end - end >= 2 {
                    hardBreak = true
                }
            }
            parseInline(segment.start, end, &state)
            if !isLast {
                // El salto de línea del Markdown se pinta como espacio (o salto forzado).
                emit(hardBreak ? Ch.lineSeparator : Ch.space, segment.end, segment.end + 1, state.style)
            }
        }
        closeHighlight(&state, closeMarker: nil)
        finishBlock(kind, start: start, highlights: state.highlights)
    }

    mutating func emitTableRow(_ row: Line, header: Bool) {
        let start = doc.length
        var cells: [Line] = []
        var i = firstNonSpace(row)
        let end = trimmedEnd(i, row.end)
        if i < end && s[i] == Ch.pipe { i += 1 }
        var cellStart = i
        var inCode = false
        while i < end {
            let u = s[i]
            if u == Ch.backslash { i += 2; continue }
            if u == Ch.backtick { inCode.toggle() }
            if u == Ch.pipe && !inCode {
                cells.append(Line(start: cellStart, end: i))
                cellStart = i + 1
            }
            i += 1
        }
        if cellStart < end { cells.append(Line(start: cellStart, end: min(end, row.end))) }

        var state = InlineState()
        if header { state.style.insert(.bold) }
        for (offset, cell) in cells.enumerated() {
            var cellStart = cell.start
            while cellStart < cell.end && Ch.isSpace(s[cellStart]) { cellStart += 1 }
            let cellEnd = trimmedEnd(cellStart, cell.end)
            if offset > 0 {
                emitSynthetic("  │  ", style: state.style.subtracting(.highlight))
            }
            parseInline(cellStart, cellEnd, &state)
        }
        closeHighlight(&state, closeMarker: nil)
        finishBlock(.tableRow(header: header), start: start, highlights: state.highlights)
    }

    mutating func closeHighlight(_ state: inout InlineState, closeMarker: NSRange?) {
        guard let open = state.openHighlight else { return }
        state.highlights.append(HighlightSpan(range: NSRange(location: open.rendered, length: doc.length - open.rendered),
                                              openMarker: open.marker, closeMarker: closeMarker))
        state.openHighlight = nil
        state.style.remove(.highlight)
    }

    // MARK: En línea

    mutating func parseInline(_ from: Int, _ to: Int, _ state: inout InlineState) {
        var i = from
        while i < to {
            let u = s[i]
            switch u {
            case Ch.backslash:
                if i + 1 < to && Ch.isPunctuation(s[i + 1]) {
                    emit(s[i + 1], i, i + 2, state.style)
                    i += 2
                } else {
                    emit(u, i, i + 1, state.style)
                    i += 1
                }

            case Ch.backtick:
                var run = 0
                while i + run < to && s[i + run] == Ch.backtick { run += 1 }
                if let close = findBacktickRun(length: run, from: i + run, to: to) {
                    var contentStart = i + run
                    var contentEnd = close
                    if contentEnd - contentStart >= 2, s[contentStart] == Ch.space, s[contentEnd - 1] == Ch.space {
                        contentStart += 1
                        contentEnd -= 1
                    }
                    // Todo el código se asocia al tramo completo para no partirlo al resaltar.
                    for k in contentStart..<contentEnd {
                        emit(s[k], i, close + run, state.style.union(.code))
                    }
                    i = close + run
                } else {
                    for k in i..<(i + run) { emit(s[k], k, k + 1, state.style) }
                    i += run
                }

            case Ch.equals where i + 1 < to && s[i + 1] == Ch.equals:
                let marker = NSRange(location: i, length: 2)
                if state.openHighlight != nil {
                    closeHighlight(&state, closeMarker: marker)
                } else {
                    state.openHighlight = (marker, doc.length)
                    state.style.insert(.highlight)
                }
                i += 2

            case Ch.star, Ch.underscore:
                var run = 0
                while i + run < to && s[i + run] == u { run += 1 }
                let previous = i > from ? s[i - 1] : Ch.space
                let next = i + run < to ? s[i + run] : Ch.space
                let literal = (Ch.isWhitespace(previous) && Ch.isWhitespace(next))
                    || (u == Ch.underscore && Ch.isAlphanumeric(previous) && Ch.isAlphanumeric(next))
                if literal {
                    for k in i..<(i + run) { emit(s[k], k, k + 1, state.style) }
                } else {
                    var remaining = run
                    while remaining >= 2 {
                        state.style.formSymmetricDifference(.bold)
                        remaining -= 2
                    }
                    if remaining == 1 { state.style.formSymmetricDifference(.italic) }
                }
                i += run

            case Ch.tilde where i + 1 < to && s[i + 1] == Ch.tilde:
                state.style.formSymmetricDifference(.strike)
                i += 2

            case Ch.bang where i + 1 < to && s[i + 1] == Ch.lbracket:
                if let match = matchLink(at: i + 1, limit: to) {
                    doc.images.append(ImageReference(location: doc.length, alt: unescaped(match.label),
                                                     source: match.destination, isBlock: false))
                    emitSynthetic("\u{FFFC}",
                                  style: state.style)
                    i = match.end
                } else {
                    emit(u, i, i + 1, state.style)
                    i += 1
                }

            case Ch.lbracket:
                if let match = matchLink(at: i, limit: to) {
                    let renderedStart = doc.length
                    parseInline(match.label.start, match.label.end, &state)
                    let range = NSRange(location: renderedStart, length: doc.length - renderedStart)
                    if range.length > 0 {
                        doc.links.append(LinkReference(range: range, destination: match.destination))
                    }
                    i = match.end
                } else {
                    emit(u, i, i + 1, state.style)
                    i += 1
                }

            case Ch.lt:
                if let autolink = matchAutolink(at: i, limit: to) {
                    let renderedStart = doc.length
                    for k in (i + 1)..<(autolink - 1) { emit(s[k], i, autolink, state.style) }
                    let destination = String(decoding: s[(i + 1)..<(autolink - 1)], as: UTF16.self)
                    doc.links.append(LinkReference(range: NSRange(location: renderedStart, length: doc.length - renderedStart),
                                                   destination: destination))
                    i = autolink
                } else if let lineBreak = matchLineBreakTag(at: i, limit: to) {
                    emit(Ch.lineSeparator, i, lineBreak, state.style)
                    i = lineBreak
                } else {
                    emit(u, i, i + 1, state.style)
                    i += 1
                }

            default:
                emit(u, i, i + 1, state.style)
                i += 1
            }
        }
    }

    func findBacktickRun(length: Int, from: Int, to: Int) -> Int? {
        var i = from
        while i < to {
            if s[i] == Ch.backtick {
                var run = 0
                while i + run < to && s[i + run] == Ch.backtick { run += 1 }
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Reconoce `[etiqueta](destino)` empezando en el corchete de apertura.
    func matchLink(at i: Int, limit: Int) -> (label: Line, destination: String, end: Int)? {
        guard i < limit, s[i] == Ch.lbracket else { return nil }
        var depth = 0
        var j = i
        while j < limit {
            let u = s[j]
            if u == Ch.backslash { j += 2; continue }
            if u == Ch.lbracket { depth += 1 }
            if u == Ch.rbracket {
                depth -= 1
                if depth == 0 { break }
            }
            j += 1
        }
        guard j + 1 < limit, s[j] == Ch.rbracket, s[j + 1] == Ch.lparen else { return nil }
        var k = j + 2
        var parens = 1
        while k < limit {
            let u = s[k]
            if u == Ch.backslash { k += 2; continue }
            if u == Ch.lparen { parens += 1 }
            if u == Ch.rparen {
                parens -= 1
                if parens == 0 { break }
            }
            k += 1
        }
        guard k < limit, s[k] == Ch.rparen else { return nil }
        var destination = String(decoding: s[(j + 2)..<k], as: UTF16.self).trimmingCharacters(in: .whitespaces)
        if destination.hasPrefix("<"), let close = destination.firstIndex(of: ">") {
            destination = String(destination[destination.index(after: destination.startIndex)..<close])
        } else if let space = destination.firstIndex(of: " ") {
            // Descarta el título opcional: [texto](url "título")
            destination = String(destination[..<space])
        }
        return (Line(start: i + 1, end: j), unescaped(destination), k + 1)
    }

    func matchAutolink(at i: Int, limit: Int) -> Int? {
        var j = i + 1
        while j < limit && s[j] != Ch.gt && !Ch.isWhitespace(s[j]) && s[j] != Ch.lt { j += 1 }
        guard j < limit, s[j] == Ch.gt else { return nil }
        let content = String(decoding: s[(i + 1)..<j], as: UTF16.self)
        guard content.hasPrefix("http://") || content.hasPrefix("https://") || content.hasPrefix("mailto:") else { return nil }
        return j + 1
    }

    func matchLineBreakTag(at i: Int, limit: Int) -> Int? {
        let candidates = ["<br>", "<br/>", "<br />", "<BR>"]
        for candidate in candidates {
            let units = Array(candidate.utf16)
            if i + units.count <= limit && Array(s[i..<(i + units.count)]) == units { return i + units.count }
        }
        return nil
    }

    func unescaped(_ line: Line) -> String {
        unescaped(String(decoding: s[line.start..<line.end], as: UTF16.self))
    }

    func unescaped(_ string: String) -> String {
        var result = ""
        var iterator = string.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                if next.isASCII, next.isPunctuation || next.isSymbol {
                    result.append(next)
                } else {
                    result.append(character)
                    result.append(next)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }
}
