import Foundation

/// Services that can write a summary. All of them answer the OpenAI chat completions API, so one
/// request format serves every provider.
enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case gemini, groq, nvidia, openai, anthropic, cloudflare, mistral, openrouter, deepseek, xai, custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .gemini: return "Gemini"
        case .groq: return "Groq"
        case .nvidia: return "NVIDIA"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude"
        case .cloudflare: return "Cloudflare"
        case .mistral: return "Mistral"
        case .openrouter: return "OpenRouter"
        case .deepseek: return "DeepSeek"
        case .xai: return "xAI (Grok)"
        case .custom: return "Otro (compatible con OpenAI)"
        }
    }

    /// Model used when the provider is selected. Empty when the user has to name the model.
    var defaultModel: String {
        switch self {
        case .gemini: return "gemini-3.8-flash"
        case .groq: return "openai/gpt-oss-120b"
        case .nvidia: return "meta/llama-3.3-70b-instruct"
        case .openai: return "gpt-5-mini"
        case .anthropic: return "claude-opus-5-5"
        case .cloudflare: return "@cf/openai/gpt-oss-120b"
        case .mistral: return "mistral-small-latest"
        case .openrouter: return "openai/gpt-5-mini"
        case .deepseek: return "deepseek-flash"
        case .xai: return "grok-4.7"
        case .custom: return ""
        }
    }

    /// Page where the key is created, shown in Settings. Nil when the user supplies the service.
    var keyPage: String? {
        switch self {
        case .gemini: return "aistudio.google.com/apikey"
        case .groq: return "console.groq.com/keys"
        case .nvidia: return "build.nvidia.com"
        case .openai: return "platform.openai.com/api-keys"
        case .anthropic: return "platform.claude.com/settings/keys"
        case .cloudflare: return "dash.cloudflare.com/profile/api-tokens"
        case .mistral: return "console.mistral.ai/api-keys"
        case .openrouter: return "openrouter.ai/keys"
        case .deepseek: return "platform.deepseek.com/api_keys"
        case .xai: return "console.x.ai"
        case .custom: return nil
        }
    }

    /// Base URL of the OpenAI-compatible API, without `/chat/completions`. Cloudflare needs the
    /// account ID and the custom provider needs its base URL, both from Settings; nil while missing.
    func baseURL(cloudflareAccountID: String, customBaseURL: String) -> String? {
        switch self {
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: return "https://api.groq.com/openai/v1"
        case .nvidia: return "https://integrate.api.nvidia.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .cloudflare:
            guard !cloudflareAccountID.isEmpty else { return nil }
            return "https://api.cloudflare.com/client/v4/accounts/\(cloudflareAccountID)/ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .xai: return "https://api.x.ai/v1"
        case .custom: return customBaseURL.isEmpty ? nil : customBaseURL
        }
    }
}

/// What a summary request needs: the provider, its chat completions URL, the key and the model.
struct LLMConnection: Equatable, Sendable {
    var provider: LLMProvider
    var endpoint: URL
    var apiKey: String
    var model: String
}
