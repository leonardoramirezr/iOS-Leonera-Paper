import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UIKit
import Vision

/// Resultado de convertir un PDF a Markdown.
struct ConvertedPDF: Sendable {
    var title: String?
    var author: String?
    var created: Date?
    var excerpt: String?
    var pageCount: Int
    /// Cuerpo del artículo (sin título ni *front matter*).
    var markdown: String
    /// Ruta relativa (`images/…`) de la portada: la primera página renderizada.
    var cover: String?
}

enum PDFConversionError: LocalizedError {
    case unreadable
    case locked
    case noContent

    var errorDescription: String? {
        switch self {
        case .unreadable: return "El archivo no es un PDF válido o está dañado."
        case .locked: return "El PDF está protegido con contraseña."
        case .noContent: return "No se encontró texto en el PDF."
        }
    }
}

/// Convierte un PDF en Markdown.
///
/// El texto sale de PDFKit con su fuente y su posición en la página, y se agrupa en
/// párrafos, títulos (por tamaño o negrita), listas y bloques de código (fuente
/// monoespaciada). Se quitan encabezados, pies y números de página repetidos y se
/// unen las palabras cortadas con guion a final de línea. Las páginas escaneadas
/// (sin texto) pasan por el OCR de Vision y, si tampoco así hay texto, se guardan
/// como imagen. Las imágenes incrustadas (JPEG, JPEG 2000 y RGB/gris sin comprimir)
/// se extraen a `images/` y se colocan al final de la página en la que aparecen.
enum PDFConverter {
    static func convert(fileURL: URL, imagesFolder: URL,
                        progress: (_ page: Int, _ total: Int) -> Void) throws -> ConvertedPDF {
        guard let document = PDFDocument(url: fileURL) else { throw PDFConversionError.unreadable }
        if document.isLocked && !document.unlock(withPassword: "") { throw PDFConversionError.locked }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw PDFConversionError.unreadable }

        var images = ImageStore(folder: imagesFolder)
        var lines: [TextLine] = []
        var boxes = Array(repeating: CGRect.zero, count: pageCount)

        for index in 0..<pageCount {
            progress(index + 1, pageCount)
            guard let page = document.page(at: index) else { continue }
            autoreleasepool {
                var pageLines = textLines(of: page, index: index)
                boxes[index] = page.bounds(for: .cropBox)
                if pageLines.reduce(0, { $0 + $1.text.count }) < 20 {
                    let rendered = page.thumbnail(of: CGSize(width: 2200, height: 2200), for: .cropBox)
                    let recognized = recognizedLines(in: rendered, page: index, pageBox: boxes[index])
                    if recognized.lines.reduce(0, { $0 + $1.text.count }) > pageLines.reduce(0, { $0 + $1.text.count }) {
                        pageLines = recognized.lines
                        boxes[index] = recognized.box
                    }
                    if pageLines.isEmpty, let jpeg = scaled(rendered, longestSide: 1600).jpegData(compressionQuality: 0.8) {
                        images.add(jpeg, ext: "jpg", page: index, name: String(format: "page-%03d", index + 1),
                                   alt: "Página \(index + 1)")
                    }
                }
                lines.append(contentsOf: pageLines)
                for image in embeddedImages(on: page) {
                    images.add(image.data, ext: image.ext, page: index)
                }
            }
        }

        var cover: String?
        if let first = document.page(at: 0),
           let jpeg = first.thumbnail(of: CGSize(width: 600, height: 600), for: .cropBox).jpegData(compressionQuality: 0.8) {
            cover = images.save(jpeg, name: "cover.jpg")
        }

        var builder = MarkdownBuilder(lines: lines, boxes: boxes)
        builder.removeRunningHeaders()
        builder.buildBlocks()
        builder.assignHeadings()

        let attributes = document.documentAttributes ?? [:]
        func attribute(_ key: PDFDocumentAttribute) -> Any? { attributes[key] ?? attributes[key.rawValue] }
        let metadataTitle = cleanTitle(attribute(.titleAttribute) as? String)
        let title = metadataTitle ?? builder.titleCandidate()
        if let title { builder.removeHeading(matching: title) }

        let placed = images.placed(pageCount: pageCount)
        let markdown = builder.markdown(images: placed)
        guard !markdown.isEmpty else { throw PDFConversionError.noContent }

        let author = (attribute(.authorAttribute) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ConvertedPDF(
            title: title,
            author: author?.isEmpty == false ? author : nil,
            created: attribute(.creationDateAttribute) as? Date,
            excerpt: builder.excerpt(),
            pageCount: pageCount,
            markdown: markdown,
            cover: cover
        )
    }

    // MARK: - Líneas de texto

    fileprivate struct Run {
        var text: String
        var style: InlineStyle
    }

    fileprivate struct TextLine {
        var runs: [Run]
        var text: String
        var size: CGFloat
        /// Rectángulo en el espacio de la página (origen abajo a la izquierda).
        var bounds: CGRect
        var page: Int
        var allBold: Bool
        var allItalic: Bool
        var monospaced: Bool
        /// Procede del OCR: tamaños aproximados y sin estilos.
        var recognized: Bool
    }

    private static func textLines(of page: PDFPage, index: Int) -> [TextLine] {
        guard let attributed = page.attributedString, attributed.length > 0 else { return [] }
        let string = attributed.string as NSString
        var lines: [TextLine] = []
        var location = 0
        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            location = max(NSMaxRange(lineRange), location + 1)
            var content = lineRange
            while content.length > 0, let scalar = UnicodeScalar(string.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                content.length -= 1
            }
            if content.length > 0, let line = makeLine(attributed, range: content, page: page, index: index) {
                lines.append(line)
            }
        }
        return lines
    }

    private static func makeLine(_ attributed: NSAttributedString, range: NSRange,
                                 page: PDFPage, index: Int) -> TextLine? {
        let string = attributed.string as NSString
        var runs: [Run] = []
        var sizes: [CGFloat: Int] = [:]
        var total = 0, bold = 0, italic = 0, mono = 0
        attributed.enumerateAttribute(.font, in: range) { value, runRange, _ in
            let text = clean(string.substring(with: runRange))
            guard !text.isEmpty else { return }
            let font = value as? UIFont
            let traits = fontTraits(font)
            var style: InlineStyle = []
            if traits.bold { style.insert(.bold) }
            if traits.italic { style.insert(.italic) }
            if traits.mono { style.insert(.code) }
            let count = text.filter { !$0.isWhitespace }.count
            total += count
            if traits.bold { bold += count }
            if traits.italic { italic += count }
            if traits.mono { mono += count }
            if let font, count > 0 { sizes[roundedSize(font.pointSize), default: 0] += count }
            runs.append(Run(text: text, style: style))
        }
        trimRuns(&runs)
        let text = runs.map(\.text).joined()
        guard total > 0, !text.isEmpty else { return nil }
        let bounds = page.selection(for: range)?.bounds(for: page) ?? .zero
        let size = sizes.max { $0.value < $1.value }?.key ?? roundedSize(max(bounds.height * 0.8, 1))
        return TextLine(runs: runs, text: text, size: size, bounds: bounds, page: index,
                        allBold: bold * 10 >= total * 9, allItalic: italic * 10 >= total * 9,
                        monospaced: mono * 10 >= total * 9, recognized: false)
    }

    private static func fontTraits(_ font: UIFont?) -> (bold: Bool, italic: Bool, mono: Bool) {
        guard let font else { return (false, false, false) }
        let name = font.fontName.lowercased()
        let symbolic = font.fontDescriptor.symbolicTraits
        let bold = symbolic.contains(.traitBold)
            || ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) }
        let italic = symbolic.contains(.traitItalic) || name.contains("italic") || name.contains("oblique")
        let mono = symbolic.contains(.traitMonoSpace)
            || ["mono", "courier", "consola", "menlo", "sourcecode", "inconsolata"].contains { name.contains($0) }
        return (bold, italic, mono)
    }

    private static let ligatures: [Character: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi",
        "\u{FB04}": "ffl", "\u{FB05}": "st", "\u{FB06}": "st",
    ]

    /// Normaliza el texto de PDFKit: ligaduras, espacios raros y caracteres de control.
    private static func clean(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf16.count)
        for character in text {
            if let replacement = ligatures[character] {
                result += replacement
                continue
            }
            switch character {
            case "\u{00AD}":
                // Guion blando: se conserva para unir la palabra al final de la línea.
                result.append(character)
            case "\t", "\u{00A0}", "\u{2000}"..."\u{200A}", "\u{202F}", "\u{205F}", "\u{3000}":
                result.append(" ")
            case "\u{200B}", "\u{2060}", "\u{FEFF}", "\u{FFFC}":
                continue
            default:
                if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { continue }
                result.append(character)
            }
        }
        return result
    }

    private static func trimRuns(_ runs: inout [Run]) {
        while let first = runs.first {
            let trimmed = String(first.text.drop { $0 == " " })
            if trimmed.isEmpty { runs.removeFirst() } else { runs[0].text = trimmed; break }
        }
        while let last = runs.last {
            var text = last.text
            while text.last == " " { text.removeLast() }
            if text.isEmpty { runs.removeLast() } else { runs[runs.count - 1].text = text; break }
        }
        for index in runs.indices {
            while runs[index].text.contains("  ") {
                runs[index].text = runs[index].text.replacingOccurrences(of: "  ", with: " ")
            }
        }
    }

    fileprivate static func roundedSize(_ size: CGFloat) -> CGFloat {
        (size * 2).rounded() / 2
    }

    // MARK: - OCR

    private static func recognizedLines(in image: UIImage, page: Int, pageBox: CGRect) -> (lines: [TextLine], box: CGRect) {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return ([], .zero) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return ([], .zero)
        }
        // Coordenadas en puntos de página, para que los tamaños se comparen con los del texto real.
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let longest = max(pageBox.width, pageBox.height)
        let factor = longest > 0 ? longest / max(width, height) : 1
        let box = CGRect(x: 0, y: 0, width: width * factor, height: height * factor)
        let lines = (request.results ?? []).compactMap { observation -> TextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = clean(candidate.string).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let normalized = observation.boundingBox
            let rect = CGRect(x: normalized.minX * box.width, y: normalized.minY * box.height,
                              width: normalized.width * box.width, height: normalized.height * box.height)
            return TextLine(runs: [Run(text: text, style: [])], text: text, size: roundedSize(max(rect.height * 0.85, 1)),
                            bounds: rect, page: page, allBold: false, allItalic: false, monospaced: false,
                            recognized: true)
        }
        return (lines, box)
    }

    private static func scaled(_ image: UIImage, longestSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > longestSide else { return image }
        let factor = longestSide / longest
        let size = CGSize(width: (image.size.width * factor).rounded(), height: (image.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Imágenes incrustadas

    private static func embeddedImages(on page: PDFPage) -> [(data: Data, ext: String)] {
        guard let dictionary = page.pageRef?.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return [] }
        var streams: [CGPDFStreamRef] = []
        collectImageStreams(in: resources, depth: 0, into: &streams)
        return streams.prefix(40).compactMap(encodedImage(from:))
    }

    private static func collectImageStreams(in resources: CGPDFDictionaryRef, depth: Int,
                                            into result: inout [CGPDFStreamRef]) {
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
        var images: [(name: String, stream: CGPDFStreamRef)] = []
        var forms: [CGPDFDictionaryRef] = []
        CGPDFDictionaryApplyBlock(xObjects, { key, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let info = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(info, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                images.append((String(cString: key), stream))
            case "Form":
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(info, "Resources", &nested), let nested {
                    forms.append(nested)
                }
            default:
                break
            }
            return true
        }, nil)
        images.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.append(contentsOf: images.map(\.stream))
        guard depth < 3 else { return }
        for form in forms where form != resources {
            collectImageStreams(in: form, depth: depth + 1, into: &result)
        }
    }

    private static func encodedImage(from stream: CGPDFStreamRef) -> (data: Data, ext: String)? {
        guard let info = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(info, "Width", &width), CGPDFDictionaryGetInteger(info, "Height", &height),
              width >= 48, height >= 48, width * height <= 40_000_000 else { return nil }
        var isMask: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(info, "ImageMask", &isMask), isMask != 0 { return nil }

        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        switch format {
        case .jpegEncoded:
            guard let source = CGImageSourceCreateWithData(cfData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
            return (cfData as Data, "jpg")
        case .JPEG2000:
            guard let source = CGImageSourceCreateWithData(cfData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return nil }
            return (jpeg, "jpg")
        case .raw:
            var bits: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(info, "BitsPerComponent", &bits), bits == 8,
                  let color = colorSpace(of: info) else { return nil }
            let bytesPerRow = width * color.components
            let expected = bytesPerRow * height
            let length = CFDataGetLength(cfData)
            guard length >= expected, length <= expected + 64, let provider = CGDataProvider(data: cfData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                      bitsPerPixel: 8 * color.components, bytesPerRow: bytesPerRow,
                                      space: color.space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else { return nil }
            if width * height <= 1_000_000, let png = UIImage(cgImage: image).pngData() {
                return (png, "png")
            }
            guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return nil }
            return (jpeg, "jpg")
        @unknown default:
            return nil
        }
    }

    private static func colorSpace(of info: CGPDFDictionaryRef) -> (space: CGColorSpace, components: Int)? {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(info, "ColorSpace", &name), let name {
            switch String(cString: name) {
            case "DeviceRGB": return (CGColorSpaceCreateDeviceRGB(), 3)
            case "DeviceGray": return (CGColorSpaceCreateDeviceGray(), 1)
            default: return nil
            }
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(info, "ColorSpace", &array), let array else { return nil }
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &family), let family, String(cString: family) == "ICCBased" else { return nil }
        var profile: CGPDFStreamRef?
        guard CGPDFArrayGetStream(array, 1, &profile), let profile,
              let profileInfo = CGPDFStreamGetDictionary(profile) else { return nil }
        var components: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(profileInfo, "N", &components) else { return nil }
        switch components {
        case 1: return (CGColorSpaceCreateDeviceGray(), 1)
        case 3: return (CGColorSpaceCreateDeviceRGB(), 3)
        default: return nil
        }
    }

    /// Imágenes guardadas en `images/`, sin duplicados.
    fileprivate struct ImageStore {
        struct Entry {
            var path: String
            var alt: String
            var firstPage: Int
            var pages: Set<Int>
        }

        let folder: URL
        private(set) var entries: [String: Entry] = [:]
        private var order: [String] = []
        private var counter = 0

        init(folder: URL) {
            self.folder = folder
        }

        mutating func add(_ data: Data, ext: String, page: Int, name: String? = nil, alt: String = "") {
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if entries[key] != nil {
                entries[key]?.pages.insert(page)
                return
            }
            guard order.count < 300 else { return }
            counter += 1
            let fileName = "\(name ?? String(format: "img-%03d", counter)).\(ext)"
            guard let path = save(data, name: fileName) else { return }
            entries[key] = Entry(path: path, alt: alt, firstPage: page, pages: [page])
            order.append(key)
        }

        func save(_ data: Data, name: String) -> String? {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                return "images/\(name)"
            } catch {
                return nil
            }
        }

        /// Imágenes por página. Las que se repiten en muchas páginas (logotipos,
        /// fondos) se descartan y se borran.
        func placed(pageCount: Int) -> [Int: [(path: String, alt: String)]] {
            var result: [Int: [(path: String, alt: String)]] = [:]
            for key in order {
                guard let entry = entries[key] else { continue }
                if entry.pages.count >= 3 && Double(entry.pages.count) >= Double(pageCount) * 0.3 {
                    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().appendingPathComponent(entry.path))
                    continue
                }
                result[entry.firstPage, default: []].append((entry.path, entry.alt))
            }
            return result
        }
    }

    // MARK: - Título

    private static func cleanTitle(_ value: String?) -> String? {
        guard var title = value?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - ", "Microsoft Excel - "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        let lowered = title.lowercased()
        if ["untitled", "sin título", "sin titulo", "document", "documento", "title", "título"].contains(lowered) { return nil }
        // Nombres de archivo («informe_final.docx») no sirven como título.
        if lowered.range(of: #"\.[a-z0-9]{2,5}$"#, options: .regularExpression) != nil { return nil }
        return title.count >= 3 ? title : nil
    }
}

// MARK: - Construcción del Markdown

private struct MarkdownBuilder {
    typealias TextLine = PDFConverter.TextLine
    typealias Run = PDFConverter.Run

    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case listItem(String)
        case code
    }

    struct Block {
        var lines: [TextLine]
        var kind: Kind
        var firstPage: Int { lines[0].page }
        var size: CGFloat { lines.map(\.size).max() ?? 0 }
        var plainText: String {
            MarkdownBuilder.collapse(MarkdownBuilder.joined(lines).map(\.text).joined())
        }
    }

    var lines: [TextLine]
    let boxes: [CGRect]
    var blocks: [Block] = []
    var bodySize: CGFloat = 12
    var normalGap: CGFloat = 3
    var rightEdge: [Int: CGFloat] = [:]
    /// Estilos que tiene casi todo el texto (p. ej., una fuente de cuerpo «Semibold»): se ignoran.
    var bodyStyle: InlineStyle = []
    var headingSizes: [CGFloat: Int] = [:]

    init(lines: [TextLine], boxes: [CGRect]) {
        self.lines = lines
        self.boxes = boxes
        computeMetrics()
    }

    // MARK: Métricas

    private mutating func computeMetrics() {
        var sizes: [CGFloat: Int] = [:]
        var total = 0, bold = 0, italic = 0
        for line in lines {
            let count = line.text.count
            sizes[line.size, default: 0] += count
            guard !line.recognized else { continue }
            total += count
            if line.allBold { bold += count }
            if line.allItalic { italic += count }
        }
        bodySize = sizes.max { $0.value < $1.value }?.key ?? 12
        if total > 0 && bold * 10 > total * 6 { bodyStyle.insert(.bold) }
        if total > 0 && italic * 10 > total * 6 { bodyStyle.insert(.italic) }

        var gaps: [CGFloat] = []
        for (previous, current) in zip(lines, lines.dropFirst()) where previous.page == current.page {
            guard isBody(previous), isBody(current) else { continue }
            let gap = previous.bounds.minY - current.bounds.maxY
            if gap > -bodySize * 0.5 && gap < bodySize * 3 { gaps.append(gap) }
        }
        gaps.sort()
        normalGap = gaps.isEmpty ? bodySize * 0.3 : gaps[gaps.count / 2]

        for line in lines where isBody(line) {
            rightEdge[line.page] = max(rightEdge[line.page] ?? 0, line.bounds.maxX)
        }
    }

    private func isBody(_ line: TextLine) -> Bool {
        abs(line.size - bodySize) <= max(0.6, bodySize * (line.recognized ? 0.2 : 0.05))
    }

    // MARK: Encabezados y pies de página

    mutating func removeRunningHeaders() {
        let pagesWithText = Set(lines.map(\.page)).count
        var pagesByKey: [String: Set<Int>] = [:]
        for line in lines {
            if let key = marginKey(line) { pagesByKey[key, default: []].insert(line.page) }
        }
        let threshold = max(2, Int((Double(pagesWithText) * 0.4).rounded(.up)))
        lines = lines.filter { line in
            guard let key = marginKey(line) else { return true }
            if Self.isPageNumber(key) { return false }
            return pagesWithText < 3 || (pagesByKey[key]?.count ?? 0) < threshold
        }
    }

    /// Texto normalizado (números como `#`) de las líneas del margen superior o inferior.
    private func marginKey(_ line: TextLine) -> String? {
        guard line.page < boxes.count else { return nil }
        let box = boxes[line.page]
        guard box.height > 0, line.text.count <= 120 else { return nil }
        let margin = box.height * 0.09
        guard line.bounds.minY >= box.maxY - margin || line.bounds.maxY <= box.minY + margin else { return nil }
        return Self.collapse(line.text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression))
    }

    private static func isPageNumber(_ key: String) -> Bool {
        let patterns = [
            #"^[-–—\s]*(p(á|a)g(ina|e)?\.?\s*)?#(\s*(/|de|of)\s*#)?[-–—\s]*$"#,
            #"^[ivxlcdm]{1,6}$"#,
        ]
        return patterns.contains { key.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: Bloques

    mutating func buildBlocks() {
        var current: Block?
        for line in lines {
            if var block = current, !startsNewBlock(line, in: block) {
                block.lines.append(line)
                current = block
            } else {
                if let block = current { blocks.append(block) }
                current = Block(lines: [line], kind: initialKind(of: line))
            }
        }
        if let block = current { blocks.append(block) }
    }

    private func initialKind(of line: TextLine) -> Kind {
        if line.monospaced { return .code }
        if let marker = Self.listMarker(line.text) { return .listItem(marker.marker) }
        return .paragraph
    }

    private func startsNewBlock(_ line: TextLine, in block: Block) -> Bool {
        guard let previous = block.lines.last else { return true }
        let recognized = line.recognized || previous.recognized
        let sizeTolerance = recognized ? max(previous.size, line.size) * 0.25 : max(0.75, previous.size * 0.08)
        let isCode = block.kind == .code
        if line.monospaced != isCode { return true }

        if line.page != previous.page {
            // Un párrafo sigue en la página siguiente si no terminó con punto.
            switch block.kind {
            case .paragraph, .listItem:
                return Self.endsSentence(previous.text) || abs(line.size - previous.size) > sizeTolerance
                    || Self.listMarker(line.text) != nil || line.allBold != previous.allBold
            default:
                return true
            }
        }

        let sameRow = abs(line.bounds.midY - previous.bounds.midY) < min(line.size, previous.size) * 0.4
            && line.bounds.minX >= previous.bounds.maxX - 2
        if sameRow { return false }
        if !isCode && Self.listMarker(line.text) != nil { return true }
        if abs(line.size - previous.size) > sizeTolerance { return true }
        if !recognized && line.allBold != previous.allBold { return true }
        // Más arriba que la línea anterior: otra columna o texto fuera de orden.
        if line.bounds.midY > previous.bounds.maxY { return true }
        let gap = previous.bounds.minY - line.bounds.maxY
        if gap > normalGap + max(line.size * 0.45, 2.5) { return true }

        switch block.kind {
        case .listItem:
            // Las líneas de continuación van sangradas respecto a la viñeta.
            return line.bounds.minX < block.lines[0].bounds.minX + line.size * 0.4
        case .paragraph:
            if line.bounds.minX > previous.bounds.minX + line.size * 1.2 { return true }
            let right = block.lines.count > 1
                ? block.lines.map(\.bounds.maxX).max() ?? 0
                : rightEdge[previous.page] ?? previous.bounds.maxX
            return previous.bounds.maxX < right - line.size * 3 && Self.endsSentence(previous.text)
        default:
            return false
        }
    }

    // MARK: Títulos

    mutating func assignHeadings() {
        var bySize: [Int] = []
        var byBold: [Int] = []
        for (index, block) in blocks.enumerated() where block.kind == .paragraph {
            let plain = block.plainText
            guard block.lines.count <= 3, plain.count >= 2, plain.count <= 200,
                  plain.contains(where: \.isLetter) else { continue }
            let recognized = block.lines.contains(where: \.recognized)
            if block.size >= bodySize * (recognized ? 1.35 : 1.15) {
                bySize.append(index)
            } else if !recognized, !bodyStyle.contains(.bold), block.lines.count == 1, block.lines[0].allBold,
                      plain.count <= 90, block.size >= bodySize - 0.75,
                      let last = plain.last, !".,;:".contains(last) {
                byBold.append(index)
            }
        }

        // Tamaños de mayor a menor: el mayor es ##, el siguiente ### y el resto ####.
        var level = 2
        var previous: CGFloat?
        for size in Set(bySize.map { blocks[$0].size }).sorted(by: >) {
            if let previous, previous - size > 0.75 { level = min(level + 1, 4) }
            headingSizes[size] = level
            previous = size
        }
        for index in bySize {
            blocks[index].kind = .heading(headingSizes[blocks[index].size] ?? 4)
        }
        let boldLevel = min((headingSizes.values.max() ?? 1) + 1, 4)
        for index in byBold {
            blocks[index].kind = .heading(boldLevel)
        }
    }

    /// El título más grande de la primera página.
    func titleCandidate() -> String? {
        let candidates = blocks.prefix(12).filter { block in
            guard case .heading = block.kind else { return false }
            return block.firstPage == 0
        }
        guard let best = candidates.max(by: { $0.size < $1.size }), best.size >= bodySize * 1.15 else { return nil }
        let title = best.plainText.replacingOccurrences(of: "\u{00AD}", with: "")
        return title.count >= 3 ? title : nil
    }

    /// Quita el primer título igual al del artículo (el Markdown ya lo lleva como `#`).
    mutating func removeHeading(matching title: String) {
        let target = Self.comparable(title)
        guard let index = blocks.prefix(12).firstIndex(where: { block in
            guard case .heading = block.kind else { return false }
            return Self.comparable(block.plainText) == target
        }) else { return }
        blocks.remove(at: index)
    }

    func excerpt() -> String? {
        guard let block = blocks.first(where: { $0.kind == .paragraph && $0.plainText.count >= 60 }) else { return nil }
        let text = block.plainText.replacingOccurrences(of: "\u{00AD}", with: "")
        guard text.count > 220 else { return text }
        let cut = text.prefix(220)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }

    // MARK: Markdown

    func markdown(images: [Int: [(path: String, alt: String)]]) -> String {
        var output: [String] = []
        var nextImagePage = 0
        func flushImages(before page: Int) {
            while nextImagePage < page {
                for image in images[nextImagePage] ?? [] {
                    output.append("![\(ArticleImporter.escape(image.alt))](\(image.path))")
                }
                nextImagePage += 1
            }
        }
        for block in blocks {
            flushImages(before: block.firstPage)
            if let rendered = render(block) { output.append(rendered) }
        }
        flushImages(before: (images.keys.max() ?? -1) + 1)
        return output.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func render(_ block: Block) -> String? {
        switch block.kind {
        case .heading(let level):
            let text = ArticleImporter.escape(block.plainText.replacingOccurrences(of: "\u{00AD}", with: ""))
            return text.isEmpty ? nil : String(repeating: "#", count: level) + " " + text
        case .code:
            let left = block.lines.map(\.bounds.minX).min() ?? 0
            let body = block.lines.map { line -> String in
                let width = max(line.size * 0.6, 1)
                let indent = min(max(Int(((line.bounds.minX - left) / width).rounded()), 0), 40)
                return String(repeating: " ", count: indent) + line.text
            }.joined(separator: "\n")
            let fence = body.contains("```") ? "~~~" : "```"
            return "\(fence)\n\(body)\n\(fence)"
        case .listItem(let marker):
            var runs = Self.joined(block.lines)
            let prefix = Self.listMarker(block.lines[0].text)?.prefixLength ?? 0
            Self.dropPrefix(prefix, from: &runs)
            let text = inline(runs)
            return text.isEmpty ? nil : "\(marker) \(text)"
        case .paragraph:
            let text = Self.protectLineStart(inline(Self.joined(block.lines)))
            return text.isEmpty ? nil : text
        }
    }

    private func inline(_ runs: [Run]) -> String {
        var merged: [Run] = []
        for run in runs where !run.text.isEmpty {
            var style = run.style.subtracting(bodyStyle)
            style.remove(.highlight)
            if let last = merged.last, last.style == style {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(Run(text: run.text, style: style))
            }
        }
        var result = ""
        for run in merged {
            let text = run.text.replacingOccurrences(of: "\u{00AD}", with: "")
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty, !run.style.isEmpty else {
                result += ArticleImporter.escape(text)
                continue
            }
            let leading = String(text.prefix { $0 == " " })
            let trailing = String(text.reversed().prefix { $0 == " " })
            if run.style.contains(.code) && !core.contains("`") {
                result += leading + "`\(core)`" + trailing
                continue
            }
            var marker = ""
            if run.style.contains(.bold) { marker += "**" }
            if run.style.contains(.italic) { marker += "*" }
            result += leading + marker + ArticleImporter.escape(core) + String(marker.reversed()) + trailing
        }
        return Self.collapse(result)
    }

    // MARK: Utilidades

    /// Une las líneas de un bloque: quita el guion de las palabras partidas y añade espacios.
    static func joined(_ lines: [TextLine]) -> [Run] {
        var runs: [Run] = []
        for line in lines {
            guard let lastRun = runs.last, let next = line.runs.first else {
                runs.append(contentsOf: line.runs)
                continue
            }
            let tail = lastRun.text
            let last = tail.last
            let beforeLast = tail.dropLast().last
            let nextFirst = next.text.first
            if last == "\u{00AD}" {
                runs[runs.count - 1].text.removeLast()
            } else if last == "-", beforeLast?.isLetter == true, nextFirst?.isLowercase == true {
                runs[runs.count - 1].text.removeLast()
            } else {
                runs.append(Run(text: " ", style: lastRun.style == next.style ? next.style : []))
            }
            runs.append(contentsOf: line.runs)
        }
        return runs
    }

    static func dropPrefix(_ count: Int, from runs: inout [Run]) {
        var remaining = count
        while remaining > 0, !runs.isEmpty {
            let length = runs[0].text.count
            if length <= remaining {
                remaining -= length
                runs.removeFirst()
            } else {
                runs[0].text = String(runs[0].text.dropFirst(remaining))
                remaining = 0
            }
        }
        while let first = runs.first {
            let trimmed = String(first.text.drop { $0 == " " })
            if trimmed.isEmpty { runs.removeFirst() } else { runs[0].text = trimmed; break }
        }
    }

    private static let bullets: Set<Character> = [
        "•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□", "►", "▶", "➢", "➤", "✓", "✔", "·",
        "\u{F0B7}", "\u{F0A7}", "\u{F076}", "\u{F0D8}", "\u{F0FC}", "\u{F0E0}",
    ]

    /// Marcador de lista al principio de la línea y cuántos caracteres ocupa.
    static func listMarker(_ text: String) -> (marker: String, prefixLength: Int)? {
        guard let first = text.first else { return nil }
        if bullets.contains(first) {
            let rest = text.dropFirst()
            guard rest.contains(where: { !$0.isWhitespace }) else { return nil }
            return ("-", 1)
        }
        if "-–—*".contains(first), text.dropFirst().first == " " {
            return ("-", 2)
        }
        let patterns: [(String, Bool)] = [
            (#"^\d{1,3}[.)] "#, true),
            (#"^\(\d{1,3}\) "#, true),
            (#"^[a-z]\) "#, false),
        ]
        for (pattern, ordered) in patterns {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(text[range])
            guard ordered else { return ("- " + matched.trimmingCharacters(in: .whitespaces), matched.count) }
            let number = matched.filter(\.isNumber)
            return ("\(Int(number) ?? 1).", matched.count)
        }
        return nil
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return true }
        return ".!?:;\"”»)…".contains(last)
    }

    /// Evita que un párrafo empiece con sintaxis de bloque de Markdown.
    static func protectLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if "#>|+".contains(first) || (first == "-" && text.dropFirst().first == " ") {
            return "\\" + text
        }
        if let range = text.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            var result = text
            let markerIndex = result.index(before: result.index(before: range.upperBound))
            result.insert("\\", at: markerIndex)
            return result
        }
        return text
    }

    static func collapse(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func comparable(_ text: String) -> String {
        collapse(text.replacingOccurrences(of: "\u{00AD}", with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }
}
