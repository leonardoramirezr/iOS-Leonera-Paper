import ImageIO
import UIKit

/// Pinta un `RenderedDocument` como NSAttributedString con el estilo de lectura elegido.
@MainActor
enum AttributedRenderer {
    struct Style {
        var theme: ReaderTheme
        var font: ReaderFont
        var fontSize: CGFloat
        var lineSpacing: CGFloat
        var contentWidth: CGFloat
        var displayScale: CGFloat
        var baseFolder: URL
    }

    static func render(_ doc: RenderedDocument, style: Style) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: doc.text, attributes: [
            .font: style.font.font(size: style.fontSize),
            .foregroundColor: style.theme.text,
        ])
        guard result.length == doc.length else { return result }

        for block in doc.blocks {
            let paragraphRange = NSRange(location: block.range.location,
                                         length: min(block.range.length + 1, result.length - block.range.location))
            result.addAttribute(.paragraphStyle, value: paragraphStyle(for: block.kind, style: style), range: paragraphRange)
            applyFonts(in: block, doc: doc, to: result, style: style)
            switch block.kind {
            case .quote, .rule:
                result.addAttribute(.foregroundColor, value: style.theme.secondary, range: block.range)
            case .listItem(let marker, _) where !marker.isEmpty:
                let markerLength = (marker as NSString).length
                result.addAttribute(.foregroundColor, value: style.theme.secondary,
                                    range: NSRange(location: block.range.location, length: min(markerLength, block.range.length)))
            default:
                break
            }
        }

        for (index, unit) in doc.units.enumerated() where unit == 0x2502 {
            result.addAttribute(.foregroundColor, value: style.theme.secondary, range: NSRange(location: index, length: 1))
        }

        for link in doc.links {
            guard let url = URL(string: link.destination) ?? URL(string: link.destination.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { continue }
            result.addAttribute(.link, value: url, range: link.range)
        }

        for image in doc.images {
            let attachment = NSTextAttachment()
            let (rendered, size) = loadImage(image, style: style)
            attachment.image = rendered
            attachment.bounds = CGRect(origin: .zero, size: size)
            result.addAttribute(.attachment, value: attachment, range: NSRange(location: image.location, length: 1))
        }

        applyDecorations(to: result, doc: doc, theme: style.theme)
        return result
    }

    /// Fondos de resaltado y de código. Se puede volver a aplicar sobre el texto ya
    /// mostrado sin rehacer la maquetación (los resaltados no cambian el texto).
    static func applyDecorations(to text: NSMutableAttributedString, doc: RenderedDocument, theme: ReaderTheme) {
        let full = NSRange(location: 0, length: text.length)
        guard text.length == doc.length else { return }
        text.removeAttribute(.backgroundColor, range: full)
        text.removeAttribute(.underlineStyle, range: full)
        text.removeAttribute(.strikethroughStyle, range: full)

        for block in doc.blocks where block.kind == .code {
            text.addAttribute(.backgroundColor, value: theme.codeBackground, range: block.range)
        }

        var index = 0
        while index < doc.length {
            let style = doc.styles[index]
            var end = index + 1
            while end < doc.length && doc.styles[end] == style { end += 1 }
            let range = NSRange(location: index, length: end - index)
            if style.contains(.highlight) {
                text.addAttribute(.backgroundColor, value: theme.highlight, range: range)
                if theme.isEInk {
                    text.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
                    text.addAttribute(.underlineColor, value: theme.text, range: range)
                }
            } else if style.contains(.code) {
                text.addAttribute(.backgroundColor, value: theme.codeBackground, range: range)
            }
            if style.contains(.strike) {
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            index = end
        }
    }

    // MARK: - Tipografía

    private static func baseSize(for kind: BlockKind, style: Style) -> CGFloat {
        switch kind {
        case .heading(let level):
            switch level {
            case 1: return style.fontSize * 1.55
            case 2: return style.fontSize * 1.3
            case 3: return style.fontSize * 1.15
            default: return style.fontSize * 1.05
            }
        case .code: return style.fontSize * 0.8
        case .tableRow: return style.fontSize * 0.85
        default: return style.fontSize
        }
    }

    private static func applyFonts(in block: RenderedBlock, doc: RenderedDocument, to text: NSMutableAttributedString, style: Style) {
        let size = baseSize(for: block.kind, style: style)
        var isHeading = false
        var isQuote = false
        if case .heading = block.kind { isHeading = true }
        if case .quote = block.kind { isQuote = true }

        if block.kind == .code {
            text.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: size, weight: .regular), range: block.range)
            return
        }

        var index = block.range.location
        let end = NSMaxRange(block.range)
        while index < end {
            let inline = doc.styles[index]
            var runEnd = index + 1
            while runEnd < end && doc.styles[runEnd] == inline { runEnd += 1 }
            let font: UIFont
            if inline.contains(.code) {
                font = UIFont.monospacedSystemFont(ofSize: size * 0.88, weight: inline.contains(.bold) || isHeading ? .semibold : .regular)
            } else {
                font = style.font.font(size: size,
                                       bold: isHeading || inline.contains(.bold),
                                       italic: inline.contains(.italic) != isQuote)
            }
            text.addAttribute(.font, value: font, range: NSRange(location: index, length: runEnd - index))
            index = runEnd
        }
    }

    private static func paragraphStyle(for kind: BlockKind, style: Style) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineSpacing
        paragraph.paragraphSpacing = style.fontSize * 0.85
        paragraph.hyphenationFactor = 0.2

        switch kind {
        case .heading(let level):
            paragraph.lineHeightMultiple = 1.15
            paragraph.paragraphSpacingBefore = style.fontSize * (level <= 2 ? 0.9 : 0.6)
            paragraph.paragraphSpacing = style.fontSize * 0.45
            paragraph.hyphenationFactor = 0
        case .listItem(let marker, let level):
            let indent = style.fontSize * 1.6
            let head = indent * CGFloat(level + 1)
            paragraph.headIndent = head
            paragraph.firstLineHeadIndent = marker.isEmpty ? head : head - indent
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: head)]
            paragraph.defaultTabInterval = indent
            paragraph.paragraphSpacing = style.fontSize * 0.4
        case .quote(let level):
            let indent = style.fontSize * 1.2 * CGFloat(level)
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = indent
            paragraph.tailIndent = -style.fontSize * 0.5
        case .code:
            paragraph.lineHeightMultiple = 1.2
            paragraph.hyphenationFactor = 0
            paragraph.lineBreakMode = .byCharWrapping
        case .rule:
            paragraph.alignment = .center
            paragraph.paragraphSpacingBefore = style.fontSize * 0.4
        case .image:
            paragraph.alignment = .center
            paragraph.lineHeightMultiple = 1
            paragraph.paragraphSpacingBefore = style.fontSize * 0.3
            paragraph.paragraphSpacing = style.fontSize * 0.6
        case .tableRow(let header):
            paragraph.lineHeightMultiple = 1.25
            paragraph.paragraphSpacing = header ? style.fontSize * 0.35 : style.fontSize * 0.25
            paragraph.hyphenationFactor = 0
        case .paragraph:
            break
        }
        return paragraph
    }

    // MARK: - Imágenes

    private static let cache = NSCache<NSString, UIImage>()

    private static func loadImage(_ image: ImageReference, style: Style) -> (UIImage, CGSize) {
        let maxWidth = max(40, style.contentWidth)
        let isRemote = image.source.hasPrefix("http://") || image.source.hasPrefix("https://")
        if !isRemote {
            let path = image.source.removingPercentEncoding ?? image.source
            let url = style.baseFolder.appendingPathComponent(path)
            let key = "\(url.path)|\(Int(maxWidth))|\(Int(style.displayScale))" as NSString
            if let cached = cache.object(forKey: key) {
                return (cached, fittedSize(cached.size, maxWidth: maxWidth))
            }
            if let decoded = downsample(url, targetPixelWidth: maxWidth * style.displayScale) {
                cache.setObject(decoded, forKey: key)
                return (decoded, fittedSize(decoded.size, maxWidth: maxWidth))
            }
        }
        let placeholder = placeholderImage(text: image.alt.isEmpty ? "Imagen no disponible" : image.alt,
                                           width: min(maxWidth, 320), theme: style.theme)
        return (placeholder, placeholder.size)
    }

    private static func fittedSize(_ size: CGSize, maxWidth: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxWidth, height: maxWidth * 0.6) }
        // Las imágenes web vienen en píxeles CSS: se muestran a ese tamaño en puntos, sin pasar del ancho.
        let width = min(maxWidth, size.width)
        return CGSize(width: width, height: (width * size.height / size.width).rounded())
    }

    /// Decodifica a la resolución justa para la pantalla. El `size` de la imagen
    /// resultante conserva las dimensiones originales en píxeles.
    private static func downsample(_ url: URL, targetPixelWidth: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let longestSide = CGFloat(max(pixelWidth, pixelHeight))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // El lado largo necesario para que el ancho alcance la resolución de pantalla.
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(longestSide, targetPixelWidth * longestSide / CGFloat(pixelWidth))),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let scale = CGFloat(max(cgImage.width, cgImage.height)) / longestSide
        return UIImage(cgImage: cgImage, scale: max(scale, 0.01), orientation: .up)
    }

    private static func placeholderImage(text: String, width: CGFloat, theme: ReaderTheme) -> UIImage {
        let size = CGSize(width: width, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 10)
            theme.codeBackground.setFill()
            path.fill()
            theme.secondary.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1
            path.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: theme.secondary,
                .paragraphStyle: paragraph,
            ]
            let label = "🖼  " + text
            let textRect = rect.insetBy(dx: 12, dy: (size.height - 18) / 2)
            (label as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: attributes, context: nil)
            _ = context
        }
    }
}
