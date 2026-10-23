import Foundation

/// Error answered by a speech or language model provider.
struct AIServiceError: LocalizedError {
    var service: String
    var status: Int
    var message: String

    var errorDescription: String? {
        switch status {
        case 401, 403:
            return "\(service): la clave de la API no es válida o no tiene permiso (Ajustes › Resúmenes de YouTube). \(message)"
        case 429:
            return "\(service): se alcanzó el límite de uso de la API. Vuelve a intentarlo más tarde. \(message)"
        default:
            return "\(service): \(message)"
        }
    }
}

enum AIService {
    /// Sends a request, with `body` when it has one. Rate limits and overloads (429, 500, 502, 503)
    /// are retried up to `retries` times, waiting what the server asks for when it is short.
    static func send(_ request: URLRequest, body: Data? = nil, service: String, retries: Int = 3) async throws -> Data {
        var attempt = 0
        while true {
            let (data, response) = try await perform(request, body: body)
            guard let http = response as? HTTPURLResponse else {
                throw AIServiceError(service: service, status: 0, message: "respuesta no válida.")
            }
            if (200..<300).contains(http.statusCode) { return data }

            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
            if [429, 500, 502, 503].contains(http.statusCode), attempt < retries, (retryAfter ?? 0) <= 60 {
                attempt += 1
                let delay = retryAfter ?? Double(5 * attempt * attempt)
                try await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
                continue
            }
            throw AIServiceError(service: service, status: http.statusCode,
                                 message: errorMessage(in: data)
                                    ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    private static func perform(_ request: URLRequest, body: Data?) async throws -> (Data, URLResponse) {
        guard let body else { return try await URLSession.shared.data(for: request) }
        return try await URLSession.shared.upload(for: request, from: body)
    }

    /// `{"error": {"message": …}}` (OpenAI style), also wrapped in an array as Gemini sometimes does.
    private static func errorMessage(in data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        if let error = object?["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object?["error"] as? String
    }
}
