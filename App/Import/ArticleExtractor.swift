import UIKit
import WebKit

/// Datos que devuelve `extractor.js`.
struct ExtractedArticle: Decodable {
    var title: String
    var byline: String?
    var siteName: String?
    var published: String?
    var excerpt: String?
    var lang: String?
    var leadImage: String?
    var url: String?
    var markdown: String
    var images: [String]
}

enum ExtractionError: LocalizedError {
    case scriptMissing
    case loadFailed(String)
    case noContent
    case invalidResult
    /// La dirección devuelve un PDF en lugar de una página web.
    case pdfDocument(URL?)

    var errorDescription: String? {
        switch self {
        case .scriptMissing: return "Falta el extractor de artículos en la app."
        case .loadFailed(let reason): return "No se pudo cargar la página: \(reason)"
        case .noContent: return "No se encontró el texto del artículo en esa página."
        case .invalidResult: return "La página devolvió un resultado inesperado."
        case .pdfDocument: return "La dirección es un PDF, no una página web."
        }
    }
}

/// Carga la página en un WKWebView fuera de pantalla (con JavaScript, como Safari)
/// y ejecuta `extractor.js` en un mundo de contenido aislado.
@MainActor
final class ArticleExtractor: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadFinished = false
    private var committed = false

    static func extract(from url: URL) async throws -> ExtractedArticle {
        let extractor = ArticleExtractor()
        defer { extractor.tearDown() }
        return try await extractor.run(url: url)
    }

    private static let script: String? = {
        guard let url = Bundle.main.url(forResource: "extractor", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private func run(url: URL) async throws -> ExtractedArticle {
        guard let script = Self.script else { throw ExtractionError.scriptMissing }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        configuration.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        if let rules = await Self.blockingRules() {
            configuration.userContentController.add(rules)
        }

        let webView = WKWebView(frame: CGRect(x: -2000, y: 0, width: 390, height: 844), configuration: configuration)
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        // Dentro de una ventana los temporizadores de la página no se congelan.
        Self.keyWindow()?.insertSubview(webView, at: 0)
        self.webView = webView

        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
        try await waitForLoad(timeout: 25)
        // Margen para el contenido que se pinta con JavaScript tras la carga.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let json = try await evaluate(script, in: webView)
        guard let data = json.data(using: .utf8) else { throw ExtractionError.invalidResult }
        let article: ExtractedArticle
        do {
            article = try JSONDecoder().decode(ExtractedArticle.self, from: data)
        } catch {
            throw ExtractionError.invalidResult
        }
        guard article.markdown.trimmingCharacters(in: .whitespacesAndNewlines).count >= 120 else {
            throw ExtractionError.noContent
        }
        return article
    }

    private func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: - Carga

    private func waitForLoad(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if loadFinished {
                continuation.resume()
                return
            }
            loadContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finishLoading(error: nil)
            }
        }
    }

    private func finishLoading(error: Error?) {
        loadFinished = true
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame, Self.isPDF(navigationResponse.response) else { return .allow }
        finishLoading(error: ExtractionError.pdfDocument(navigationResponse.response.url))
        return .cancel
    }

    private static func isPDF(_ response: URLResponse) -> Bool {
        let mimeType = response.mimeType?.lowercased() ?? ""
        if mimeType == "application/pdf" || mimeType == "application/x-pdf" { return true }
        return mimeType == "application/octet-stream" && response.url?.pathExtension.lowercased() == "pdf"
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committed = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    private func handle(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        // Fallos de subrecursos tras empezar a pintar: se extrae lo que haya.
        if committed {
            finishLoading(error: nil)
        } else {
            finishLoading(error: ExtractionError.loadFailed(error.localizedDescription))
        }
    }

    // MARK: - JavaScript

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value as? String ?? "")
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Bloquea imágenes, vídeo y fuentes: el extractor solo necesita el HTML.
    private static func blockingRules() async -> WKContentRuleList? {
        let rules = """
        [{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},"action":{"type":"block"}}]
        """
        let store: WKContentRuleListStore? = WKContentRuleListStore.default()
        guard let store else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(forIdentifier: "leonera-block-media", encodedContentRuleList: rules) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
