import UIKit
import UniformTypeIdentifiers

/// Extensión «Compartir»: recoge la URL de Safari (o un texto con una URL), la deja
/// en la cola compartida y abre Leonera Paper para que la convierta a Markdown.
/// When the link is a YouTube video it first asks for the size of the summary.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let stack = UIStackView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var started = false
    private var lengthChoice: CheckedContinuation<SummaryLength?, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        titleLabel.text = "Leonera Paper"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        statusLabel.text = "Guardando artículo…"
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        spinner.startAnimating()

        [titleLabel, spinner, statusLabel].forEach(stack.addArrangedSubview)
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await handleSharedItems() }
    }

    @MainActor
    private func handleSharedItems() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        guard let shared = await Self.findURL(in: items) else {
            finish(message: "No se encontró ninguna URL que guardar.", success: false)
            return
        }

        var summaryLength: SummaryLength?
        if YouTubeLink.isVideo(shared.url) {
            guard let chosen = await askSummaryLength() else {
                extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain,
                                                                   code: NSUserCancelledError))
                return
            }
            summaryLength = chosen
        }

        SharedQueue.enqueue(url: shared.url, title: shared.title, summaryLength: summaryLength)
        var opened = false
        if let link = AppLinks.importURL(for: shared.url, summaryLength: summaryLength) {
            opened = openContainingApp(link)
        }
        finish(message: opened ? "Abriendo Leonera Paper…" : "Guardado. Se convertirá al abrir Leonera Paper.",
               success: true)
    }

    // MARK: - Tamaño del resumen

    /// Shows one button per summary size and waits for a tap. Nil when the user cancels.
    @MainActor
    private func askSummaryLength() async -> SummaryLength? {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = "Tamaño del resumen del vídeo"
        statusLabel.textColor = .label

        let options = UIStackView()
        options.axis = .vertical
        options.spacing = 8
        options.alignment = .fill
        for length in SummaryLength.allCases {
            var configuration: UIButton.Configuration = length == .medium ? .filled() : .tinted()
            configuration.title = length.title
            configuration.subtitle = length.detail
            configuration.titleAlignment = .center
            configuration.cornerStyle = .large
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.chooseSummaryLength(length)
            })
            options.addArrangedSubview(button)
        }
        var cancel = UIButton.Configuration.plain()
        cancel.title = "Cancelar"
        options.addArrangedSubview(UIButton(configuration: cancel, primaryAction: UIAction { [weak self] _ in
            self?.chooseSummaryLength(nil)
        }))

        stack.addArrangedSubview(options)
        options.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let chosen = await withCheckedContinuation { continuation in
            lengthChoice = continuation
        }
        stack.removeArrangedSubview(options)
        options.removeFromSuperview()
        spinner.isHidden = false
        spinner.startAnimating()
        statusLabel.text = "Guardando vídeo…"
        statusLabel.textColor = .secondaryLabel
        return chosen
    }

    @MainActor
    private func chooseSummaryLength(_ length: SummaryLength?) {
        lengthChoice?.resume(returning: length)
        lengthChoice = nil
    }

    @MainActor
    private func finish(message: String, success: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = message
        statusLabel.textColor = success ? .label : .systemRed
        let delay: UInt64 = success ? 700_000_000 : 1_600_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Las extensiones no pueden usar `UIApplication.shared`; se recorre la cadena de
    /// respondedores hasta la aplicación y se invoca `openURL:options:completionHandler:`.
    @MainActor
    private func openContainingApp(_ url: URL) -> Bool {
        let selector = sel_registerName("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let implementation = application.method(for: selector)
                let open = unsafeBitCast(implementation, to: OpenURL.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    // MARK: - Lectura de los elementos compartidos

    private struct SharedURL {
        var url: URL
        var title: String?
    }

    private static func findURL(in items: [NSExtensionItem]) async -> SharedURL? {
        for item in items {
            let title = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(from: provider, type: UTType.url.identifier) {
                    return SharedURL(url: url, title: title?.isEmpty == false ? title : nil)
                }
            }
            for provider in item.attachments ?? [] {
                for type in [UTType.plainText.identifier, UTType.text.identifier]
                where provider.hasItemConformingToTypeIdentifier(type) {
                    if let url = await loadURL(from: provider, type: type) {
                        return SharedURL(url: url, title: nil)
                    }
                }
            }
            if let text = title, let url = firstWebURL(in: text) {
                return SharedURL(url: url, title: nil)
            }
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider, type: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                var url: URL?
                switch item {
                case let value as URL:
                    url = value
                case let value as NSURL:
                    url = value as URL
                case let value as String:
                    url = firstWebURL(in: value)
                case let value as NSAttributedString:
                    url = firstWebURL(in: value.string)
                case let value as Data:
                    url = URL(dataRepresentation: value, relativeTo: nil)
                        ?? String(data: value, encoding: .utf8).flatMap(firstWebURL(in:))
                default:
                    url = nil
                }
                if let candidate = url, let scheme = candidate.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    continuation.resume(returning: candidate)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func firstWebURL(in text: String) -> URL? {
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil {
            return url
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }
}
