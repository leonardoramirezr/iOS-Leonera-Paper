import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

enum DriveError: LocalizedError {
    case missingClientID
    case notConnected
    case cancelled
    case couldNotStart
    case invalidCallback
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: return "Falta el Client ID de Google (Ajustes › Google Drive)."
        case .notConnected: return "Conecta tu cuenta de Google en Ajustes."
        case .cancelled: return "Inicio de sesión cancelado."
        case .couldNotStart: return "No se pudo abrir el inicio de sesión de Google."
        case .invalidCallback: return "Google devolvió una respuesta no válida."
        case .api(let message): return message
        }
    }
}

/// Copia opcional de los artículos en Google Drive, sin SDK: OAuth 2.0 con PKCE
/// (ASWebAuthenticationSession) y la API REST v3 con el alcance `drive.file`,
/// que solo da acceso a los archivos que crea la propia app.
@MainActor
@Observable
final class DriveSync {
    private enum Keys {
        static let clientID = "drive.clientID"
        static let autoUpload = "drive.autoUpload"
        static let email = "drive.email"
        static let rootFolder = "drive.rootFolderID"
        static let refreshToken = "google.refreshToken"
    }

    private static let scopes = "openid email https://www.googleapis.com/auth/drive.file"
    private static let rootFolderName = "Leonera Paper"

    var customClientID: String {
        didSet { UserDefaults.standard.set(customClientID, forKey: Keys.clientID) }
    }
    var autoUpload: Bool {
        didSet { UserDefaults.standard.set(autoUpload, forKey: Keys.autoUpload) }
    }
    private(set) var isConnected: Bool
    private(set) var accountEmail: String?
    private(set) var activeUploads = 0
    var lastError: String?

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessTokenExpiry = Date.distantPast
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private let anchorProvider = PresentationAnchorProvider()

    init() {
        let defaults = UserDefaults.standard
        customClientID = defaults.string(forKey: Keys.clientID) ?? ""
        autoUpload = defaults.bool(forKey: Keys.autoUpload)
        accountEmail = defaults.string(forKey: Keys.email)
        isConnected = Keychain.string(for: Keys.refreshToken) != nil
    }

    /// Client ID incluido al compilar (variable `GOOGLE_CLIENT_ID`), si lo hay.
    var bundledClientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    var clientID: String {
        bundledClientID ?? customClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isUploading: Bool { activeUploads > 0 }

    // MARK: - Sesión

    func connect() async {
        lastError = nil
        let clientID = clientID
        guard !clientID.isEmpty else {
            lastError = DriveError.missingClientID.localizedDescription
            return
        }
        let verifier = Self.randomURLSafe(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(byteCount: 16)
        let scheme = Self.redirectScheme(for: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        do {
            let callback = try await authenticate(url: components.url!, scheme: scheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let error = items.first(where: { $0.name == "error" })?.value {
                throw DriveError.api("Google rechazó el acceso: \(error)")
            }
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw DriveError.invalidCallback
            }
            let tokens = try await tokenRequest([
                "client_id": clientID,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI,
            ])
            store(tokens)
            if !autoUpload { autoUpload = true }
        } catch DriveError.cancelled {
            return
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        if let token = Keychain.string(for: Keys.refreshToken) {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncoded(["token": token])
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.set(nil, for: Keys.refreshToken)
        UserDefaults.standard.removeObject(forKey: Keys.email)
        UserDefaults.standard.removeObject(forKey: Keys.rootFolder)
        accessToken = nil
        accessTokenExpiry = .distantPast
        accountEmail = nil
        isConnected = false
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? DriveError.cancelled)
                }
            }
            session.presentationContextProvider = anchorProvider
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            if !session.start() {
                continuation.resume(throwing: DriveError.couldNotStart)
            }
        }
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var expiresIn: Int?
        var refreshToken: String?
        var idToken: String?
    }

    private struct GoogleErrorResponse: Decodable {
        var error: String?
        var errorDescription: String?
    }

    private func tokenRequest(_ parameters: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(parameters)
        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let failure = try? decoder.decode(GoogleErrorResponse.self, from: data)
            if failure?.error == "invalid_grant" { disconnect() }
            throw DriveError.api(failure?.errorDescription ?? failure?.error ?? "Error al obtener el token de Google.")
        }
        return try decoder.decode(TokenResponse.self, from: data)
    }

    private func store(_ tokens: TokenResponse) {
        accessToken = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600))
        if let refresh = tokens.refreshToken {
            Keychain.set(refresh, for: Keys.refreshToken)
        }
        if let email = tokens.idToken.flatMap(Self.email(fromIDToken:)) {
            accountEmail = email
            UserDefaults.standard.set(email, forKey: Keys.email)
        }
        isConnected = Keychain.string(for: Keys.refreshToken) != nil
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = Keychain.string(for: Keys.refreshToken) else {
            isConnected = false
            throw DriveError.notConnected
        }
        guard !clientID.isEmpty else { throw DriveError.missingClientID }
        let tokens = try await tokenRequest([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        store(tokens)
        return tokens.accessToken
    }

    // MARK: - Subida

    /// Sube el artículo (Markdown, imágenes y PDF original) a `Leonera Paper/<carpeta>/`. Si ya se
    /// subió antes, solo actualiza el Markdown (p. ej. tras resaltar).
    func upload(article: Article, storage: ArticleStorage) async throws -> DriveInfo {
        activeUploads += 1
        defer { activeUploads -= 1 }

        let markdown = try Data(contentsOf: storage.markdownURL(for: article))
        if let info = article.drive, try await fileExists(info.markdownFileID) {
            try await updateFile(id: info.markdownFileID, mimeType: "text/markdown", data: markdown)
            return DriveInfo(folderID: info.folderID, markdownFileID: info.markdownFileID, uploadedAt: Date())
        }

        let root = try await rootFolderID()
        let folderID = try await createFolder(named: article.folderName, parent: root)
        let imagesFolder = storage.imagesURL(inFolder: storage.folderURL(for: article))
        let images = ((try? FileManager.default.contentsOfDirectory(at: imagesFolder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !images.isEmpty {
            let imagesID = try await createFolder(named: "images", parent: folderID)
            for image in images {
                let data = try Data(contentsOf: image)
                let mime = UTType(filenameExtension: image.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                _ = try await createFile(named: image.lastPathComponent, mimeType: mime, data: data, parent: imagesID)
            }
        }
        if let pdf = storage.pdfURL(for: article), let data = try? Data(contentsOf: pdf) {
            _ = try await createFile(named: pdf.lastPathComponent, mimeType: "application/pdf", data: data, parent: folderID)
        }
        let fileID = try await createFile(named: article.fileName, mimeType: "text/markdown", data: markdown, parent: folderID)
        return DriveInfo(folderID: folderID, markdownFileID: fileID, uploadedAt: Date())
    }

    private func rootFolderID() async throws -> String {
        if let cached = UserDefaults.standard.string(forKey: Keys.rootFolder), try await fileExists(cached) {
            return cached
        }
        let query = "name = '\(Self.rootFolderName)' and mimeType = 'application/vnd.google-apps.folder' and 'root' in parents and trashed = false"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        struct FileList: Decodable { struct File: Decodable { var id: String }; var files: [File] }
        let data = try await send(URLRequest(url: components.url!))
        let id: String
        if let existing = try JSONDecoder().decode(FileList.self, from: data).files.first?.id {
            id = existing
        } else {
            id = try await createFolder(named: Self.rootFolderName, parent: "root")
        }
        UserDefaults.standard.set(id, forKey: Keys.rootFolder)
        return id
    }

    private func fileExists(_ id: String) async throws -> Bool {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        components.queryItems = [URLQueryItem(name: "fields", value: "id,trashed")]
        struct File: Decodable { var id: String; var trashed: Bool? }
        do {
            let data = try await send(URLRequest(url: components.url!))
            return try JSONDecoder().decode(File.self, from: data).trashed != true
        } catch DriveHTTPError.status(404) {
            return false
        }
    }

    private func createFolder(named name: String, parent: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parent],
        ])
        return try decodeID(try await send(request))
    }

    private func createFile(named name: String, mimeType: String, data: Data, parent: String) async throws -> String {
        let boundary = "leonera-\(UUID().uuidString)"
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
        var body = Data()
        body.append(string: "--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metadata)
        body.append(string: "\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append(string: "\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try decodeID(try await send(request))
    }

    private func updateFile(id: String, mimeType: String, data: Data) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media&fields=id")!)
        request.httpMethod = "PATCH"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request)
    }

    private func decodeID(_ data: Data) throws -> String {
        struct Created: Decodable { var id: String }
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    private enum DriveHTTPError: Error {
        case status(Int)
    }

    private func send(_ request: URLRequest, retrying: Bool = true) async throws -> Data {
        var authorized = request
        authorized.timeoutInterval = 60
        authorized.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: authorized)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retrying {
            accessToken = nil
            return try await send(request, retrying: false)
        }
        if status == 404 { throw DriveHTTPError.status(404) }
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { struct Body: Decodable { var message: String? }; var error: Body? }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error?.message
            throw DriveError.api(message ?? "Google Drive respondió con el código \(status).")
        }
        return data
    }

    // MARK: - Utilidades

    static func redirectScheme(for clientID: String) -> String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return parameters
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

private final class PresentationAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first.map { UIWindow(windowScene: $0) } ?? UIWindow()
    }
}

private extension Data {
    mutating func append(string: String) {
        append(Data(string.utf8))
    }
}
