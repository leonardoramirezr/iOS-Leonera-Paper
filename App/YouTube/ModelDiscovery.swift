import Foundation

/// Where an LLM provider lists the models its key can use, with the key that reads them.
struct ModelListRequest: Equatable, Sendable {
    var provider: LLMProvider
    var url: URL
    var apiKey: String
}

/// Reads the models a provider offers to a key, so Settings can offer them instead of asking for names.
enum ModelDiscovery {
    /// Name fragments of models that cannot answer a chat request: embeddings, speech, images, moderation.
    private static let nonChatFragments = [
        "embed", "whisper", "transcrib", "tts", "moderation", "guard", "rerank", "image", "imagen", "veo", "dall-e", "sora",
    ]

    /// Chat models of an LLM provider, sorted. Providers list every model they serve, so the ones
    /// that are not for chat are dropped by name.
    static func chatModels(_ request: ModelListRequest) async throws -> [String] {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 30)
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        if request.provider == .anthropic {
            // Anthropic's native models endpoint reads the key from this header instead.
            urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let data = try await AIService.send(urlRequest, service: request.provider.name, retries: 0)
        let ids: [String]
        if request.provider == .cloudflare {
            ids = try cloudflareChatModelIDs(data)
        } else {
            ids = try openAIModelIDs(data)
        }
        return Array(Set(ids.filter { !isNonChat($0) })).sorted()
    }

    /// Ids of an OpenAI style list (`{"data": [{"id": …}]}`), also used by Groq for Whisper.
    static func openAIModelIDs(_ data: Data) throws -> [String] {
        let list = try JSONDecoder().decode(OpenAIModelList.self, from: data)
        return list.data.map { model in
            // Gemini names its models `models/<name>`; the chat endpoint takes the bare name.
            model.id.hasPrefix("models/") ? String(model.id.dropFirst("models/".count)) : model.id
        }
    }

    /// Text generation models of the Workers AI catalog, which is what Cloudflare lists.
    private static func cloudflareChatModelIDs(_ data: Data) throws -> [String] {
        let catalog = try JSONDecoder().decode(CloudflareCatalog.self, from: data)
        return catalog.result
            .filter { ($0.task?.name ?? "Text Generation") == "Text Generation" }
            .map(\.name)
    }

    private static func isNonChat(_ id: String) -> Bool {
        let lowercased = id.lowercased()
        return nonChatFragments.contains { lowercased.contains($0) }
    }

    private struct OpenAIModelList: Decodable {
        struct Model: Decodable {
            var id: String
        }

        var data: [Model]
    }

    private struct CloudflareCatalog: Decodable {
        struct Model: Decodable {
            struct Task: Decodable {
                var name: String
            }

            var name: String
            var task: Task?
        }

        var result: [Model]
    }
}
