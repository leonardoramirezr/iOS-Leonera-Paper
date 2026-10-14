import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Descarga las imágenes de un artículo a su carpeta `images/`.
enum ImageDownloader {
    enum Outcome: Sendable {
        /// Guardada en local; ruta relativa a la carpeta del artículo.
        case saved(String)
        /// No se pudo descargar o no es un formato que iOS sepa pintar: se deja la URL remota.
        case remote(String)
        /// Iconos, píxeles de seguimiento y similares: se elimina del artículo.
        case drop
    }

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func downloadAll(_ urls: [String], to folder: URL, referer: URL) async -> [Outcome] {
        guard !urls.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var outcomes = Array(repeating: Outcome.drop, count: urls.count)
        let concurrency = 6
        await withTaskGroup(of: (Int, Outcome).self) { group in
            var next = 0
            while next < min(concurrency, urls.count) {
                let index = next
                group.addTask { (index, await fetch(urls[index], index: index, folder: folder, referer: referer)) }
                next += 1
            }
            for await (index, outcome) in group {
                outcomes[index] = outcome
                if next < urls.count {
                    let index = next
                    group.addTask { (index, await fetch(urls[index], index: index, folder: folder, referer: referer)) }
                    next += 1
                }
            }
        }
        return outcomes
    }

    private static func fetch(_ string: String, index: Int, folder: URL, referer: URL) async -> Outcome {
        let isDataURI = string.hasPrefix("data:")
        let data: Data
        if isDataURI {
            guard let comma = string.firstIndex(of: ","),
                  string[..<comma].hasSuffix(";base64"),
                  let decoded = Data(base64Encoded: String(string[string.index(after: comma)...]),
                                     options: .ignoreUnknownCharacters) else { return .drop }
            data = decoded
        } else {
            guard let url = URL(string: string) else { return .drop }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue("image/avif,image/webp,image/heic,image/jpeg,image/png,image/*;q=0.8,*/*;q=0.5",
                             forHTTPHeaderField: "Accept")
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return .remote(string)
                }
                data = body
            } catch {
                return .remote(string)
            }
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return isDataURI ? .drop : .remote(string)
        }
        if width < 48 || height < 48 { return .drop }

        var ext = "img"
        if let type = CGImageSourceGetType(source) as String?, let utType = UTType(type) {
            ext = utType.preferredFilenameExtension ?? ext
        }
        if ext == "jpeg" { ext = "jpg" }
        let name = String(format: "img-%03d.%@", index + 1, ext)
        do {
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return .saved("images/\(name)")
        } catch {
            return isDataURI ? .drop : .remote(string)
        }
    }
}
