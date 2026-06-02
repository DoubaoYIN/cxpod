import Foundation

struct ProviderTemplate: Identifiable {
    let id: String
    let displayName: String
    let category: Category
    let baseURL: String
    let wireAPI: String
    let defaultModel: String
    let envKeyName: String
    let requiresOpenAIAuth: Bool
    let notes: String

    enum Category: String, CaseIterable {
        case domestic = "国内厂商"
        case relay = "中转站"
    }

    func generateJSON(apiKey: String) -> [String: Any] {
        var mp: [String: Any] = [
            "name": id,
            "base_url": baseURL,
            "wire_api": wireAPI,
        ]
        if !envKeyName.isEmpty {
            mp["env_key"] = envKeyName
        }
        if requiresOpenAIAuth {
            mp["requires_openai_auth"] = true
        }
        var result: [String: Any] = [
            "id": id,
            "display_name": displayName,
            "badge_emoji": badgeEmoji,
            "kind": "relay",
            "model_provider_toml": mp,
        ]
        if !defaultModel.isEmpty {
            result["default_model"] = defaultModel
        }
        return result
    }

    var badgeEmoji: String {
        switch id {
        case "minimax": return "🟠"
        case "glm": return "🟣"
        case "volcengine": return "🔴"
        case "aliyun": return "🟤"
        case "deepseek": return "🔷"
        case "kimi": return "🟡"
        default: return "🔵"
        }
    }

    static let builtIn: [ProviderTemplate] = [
        ProviderTemplate(
            id: "minimax", displayName: "MiniMax", category: .domestic,
            baseURL: "https://api.minimax.chat/v1", wireAPI: "responses",
            defaultModel: "MiniMax-M1", envKeyName: "MINIMAX_API_KEY", requiresOpenAIAuth: false,
            notes: "MiniMax 海螺 AI"
        ),
        ProviderTemplate(
            id: "deepseek", displayName: "DeepSeek", category: .domestic,
            baseURL: "https://api.deepseek.com/v1", wireAPI: "chat",
            defaultModel: "deepseek-chat", envKeyName: "DEEPSEEK_API_KEY", requiresOpenAIAuth: false,
            notes: "OpenAI 兼容端点"
        ),
        ProviderTemplate(
            id: "kimi", displayName: "Kimi", category: .domestic,
            baseURL: "https://api.moonshot.cn/v1", wireAPI: "chat",
            defaultModel: "moonshot-v1-auto", envKeyName: "KIMI_API_KEY", requiresOpenAIAuth: false,
            notes: "OpenAI 兼容端点"
        ),
        ProviderTemplate(
            id: "relay", displayName: "中转站", category: .relay,
            baseURL: "", wireAPI: "responses",
            defaultModel: "", envKeyName: "", requiresOpenAIAuth: true,
            notes: "通用中转站，填入 URL 和 Key 即可"
        ),
    ]
}
