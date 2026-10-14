import Observation
import SwiftUI
import UIKit

/// Estilos de lectura: dos claros, tres oscuros y uno de tinta electrónica.
enum ReaderThemeID: String, CaseIterable, Identifiable {
    case paper
    case sepia
    case night
    case slate
    case black
    case eink

    var id: String { rawValue }
}

struct ReaderTheme: Equatable {
    var id: ReaderThemeID
    var name: String
    var background: UIColor
    var surface: UIColor
    var text: UIColor
    var secondary: UIColor
    var link: UIColor
    var highlight: UIColor
    var codeBackground: UIColor
    var accent: UIColor
    var isDark: Bool
    /// Tinta electrónica: sin color, sin sombras ni animaciones, resaltado en gris subrayado.
    var isEInk: Bool

    static func theme(_ id: ReaderThemeID) -> ReaderTheme {
        switch id {
        case .paper:
            return ReaderTheme(id: id, name: "Papel",
                               background: UIColor(hex: 0xFFFFFF), surface: UIColor(hex: 0xF4F4F6),
                               text: UIColor(hex: 0x1D1D1F), secondary: UIColor(hex: 0x6E6E73),
                               link: UIColor(hex: 0x0B63CE), highlight: UIColor(hex: 0xFFE27A),
                               codeBackground: UIColor(hex: 0xF0F0F2), accent: UIColor(hex: 0xC26A00),
                               isDark: false, isEInk: false)
        case .sepia:
            return ReaderTheme(id: id, name: "Sepia",
                               background: UIColor(hex: 0xF6EEDC), surface: UIColor(hex: 0xEFE4CC),
                               text: UIColor(hex: 0x4B3A26), secondary: UIColor(hex: 0x8A7559),
                               link: UIColor(hex: 0x9A5B13), highlight: UIColor(hex: 0xF2CD5C),
                               codeBackground: UIColor(hex: 0xEADFC6), accent: UIColor(hex: 0x9A5B13),
                               isDark: false, isEInk: false)
        case .night:
            return ReaderTheme(id: id, name: "Noche",
                               background: UIColor(hex: 0x1C1C1E), surface: UIColor(hex: 0x2C2C2E),
                               text: UIColor(hex: 0xE3E3E6), secondary: UIColor(hex: 0x9A9AA0),
                               link: UIColor(hex: 0x6CB4FF), highlight: UIColor(hex: 0x6B5A12),
                               codeBackground: UIColor(hex: 0x2A2A2D), accent: UIColor(hex: 0xF0B43C),
                               isDark: true, isEInk: false)
        case .slate:
            return ReaderTheme(id: id, name: "Pizarra",
                               background: UIColor(hex: 0x22272E), surface: UIColor(hex: 0x2D333B),
                               text: UIColor(hex: 0xC5D1DE), secondary: UIColor(hex: 0x8B98A6),
                               link: UIColor(hex: 0x6CB6FF), highlight: UIColor(hex: 0x5C4B16),
                               codeBackground: UIColor(hex: 0x2D333B), accent: UIColor(hex: 0xE0A93A),
                               isDark: true, isEInk: false)
        case .black:
            return ReaderTheme(id: id, name: "Negro",
                               background: UIColor(hex: 0x000000), surface: UIColor(hex: 0x161618),
                               text: UIColor(hex: 0xC9C9C9), secondary: UIColor(hex: 0x808080),
                               link: UIColor(hex: 0x5AA9FF), highlight: UIColor(hex: 0x4D4100),
                               codeBackground: UIColor(hex: 0x151515), accent: UIColor(hex: 0xD9A030),
                               isDark: true, isEInk: false)
        case .eink:
            return ReaderTheme(id: id, name: "Tinta electrónica",
                               background: UIColor(hex: 0xF2F2EE), surface: UIColor(hex: 0xF2F2EE),
                               text: UIColor(hex: 0x000000), secondary: UIColor(hex: 0x3A3A3A),
                               link: UIColor(hex: 0x000000), highlight: UIColor(hex: 0xC9C9C4),
                               codeBackground: UIColor(hex: 0xE4E4DF), accent: UIColor(hex: 0x000000),
                               isDark: false, isEInk: true)
        }
    }

    static let all: [ReaderTheme] = ReaderThemeID.allCases.map(theme)

    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case newYork
    case system
    case iowan
    case georgia

    var id: String { rawValue }

    var name: String {
        switch self {
        case .newYork: return "New York"
        case .system: return "San Francisco"
        case .iowan: return "Iowan"
        case .georgia: return "Georgia"
        }
    }

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        var base: UIFont
        switch self {
        case .newYork:
            let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            base = descriptor.map { UIFont(descriptor: $0, size: size) } ?? UIFont.systemFont(ofSize: size)
        case .system:
            base = UIFont.systemFont(ofSize: size)
        case .iowan:
            base = UIFont(name: "IowanOldStyle-Roman", size: size) ?? UIFont.systemFont(ofSize: size)
        case .georgia:
            base = UIFont(name: "Georgia", size: size) ?? UIFont.systemFont(ofSize: size)
        }
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if traits != base.fontDescriptor.symbolicTraits,
           let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
            base = UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

/// Preferencias de lectura persistentes.
@MainActor
@Observable
final class ReaderPreferences {
    private enum Keys {
        static let theme = "reader.theme"
        static let font = "reader.font"
        static let fontSize = "reader.fontSize"
        static let lineSpacing = "reader.lineSpacing"
        static let margin = "reader.margin"
    }

    var themeID: ReaderThemeID {
        didSet { UserDefaults.standard.set(themeID.rawValue, forKey: Keys.theme) }
    }
    var font: ReaderFont {
        didSet { UserDefaults.standard.set(font.rawValue, forKey: Keys.font) }
    }
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }
    var lineSpacing: Double {
        didSet { UserDefaults.standard.set(lineSpacing, forKey: Keys.lineSpacing) }
    }
    var margin: Double {
        didSet { UserDefaults.standard.set(margin, forKey: Keys.margin) }
    }

    init() {
        let defaults = UserDefaults.standard
        themeID = ReaderThemeID(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .paper
        font = ReaderFont(rawValue: defaults.string(forKey: Keys.font) ?? "") ?? .newYork
        let size = defaults.double(forKey: Keys.fontSize)
        fontSize = size > 0 ? size : 19
        let spacing = defaults.double(forKey: Keys.lineSpacing)
        lineSpacing = spacing > 0 ? spacing : 1.45
        let margin = defaults.double(forKey: Keys.margin)
        self.margin = margin > 0 ? margin : 22
    }

    var theme: ReaderTheme { ReaderTheme.theme(themeID) }

    /// Cambia cuando hay que volver a maquetar el texto.
    var layoutKey: String {
        "\(themeID.rawValue)|\(font.rawValue)|\(fontSize)|\(lineSpacing)|\(margin)"
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
