import Foundation

/// One model a provider offers: the ID sent to the API and an optional display title.
struct ModelEntry: Codable, Equatable, Sendable {
    var id: String
    var title: String

    init(id: String, title: String = "") {
        self.id = id
        self.title = title
    }

    var displayTitle: String { title.isEmpty ? id : title }
}

/// A model provider the user brings their own key for: API format, address, and the models to offer.
/// Same structure as Spotcat's model settings. The API key lives in the Keychain, not in this struct.
struct ModelProvider: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Anthropic Messages API (/v1/messages)
        case anthropic
        /// OpenAI-compatible Chat Completions (/v1/chat/completions)
        case openai
    }

    /// Unique among providers; the first half of a "provider/model" reference, so it never contains "/".
    var id: String
    var name: String
    var kind: Kind
    /// Empty means the official address for `kind`.
    var apiBase: String
    var models: [ModelEntry]

    init(id: String, name: String, kind: Kind, apiBase: String, models: [ModelEntry]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.apiBase = apiBase
        self.models = models
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, apiBase, models }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        apiBase = try container.decode(String.self, forKey: .apiBase)
        // Earlier builds stored plain model ID strings.
        if let entries = try? container.decode([ModelEntry].self, forKey: .models) {
            models = entries
        } else {
            models = try container.decode([String].self, forKey: .models).map { ModelEntry(id: $0) }
        }
    }

    static let defaultBase: [Kind: String] = [
        .anthropic: "https://api.anthropic.com",
        .openai: "https://api.openai.com/v1"
    ]

    /// Uses a base that already ends in the full path as is, completes one ending in /v1, and appends /v1/… otherwise.
    var endpoint: URL? {
        let trimmed = apiBase.trimmingCharacters(in: .whitespaces)
        let base = (trimmed.isEmpty ? Self.defaultBase[kind]! : trimmed)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let path = kind == .anthropic ? "/v1/messages" : "/v1/chat/completions"
        let full = base.hasSuffix(path) ? base : base.hasSuffix("/v1") ? base + path.dropFirst(3) : base + path
        guard let url = URL(string: full), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }

    static func keyAccount(for id: String) -> String { "provider.\(id).apiKey" }

    private var keyAccount: String { Self.keyAccount(for: id) }

    var apiKey: String? {
        get { Keychain.read(account: keyAccount) }
        nonmutating set { Keychain.write(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), account: keyAccount) }
    }

    var hasKey: Bool { apiKey != nil }
}

struct ModelsConfig: Codable, Equatable, Sendable {
    var providers: [ModelProvider] = []
    /// "provider id/model name"
    var defaultModel = ""

    struct Preset: Sendable {
        let id: String
        let label: String
        let kind: ModelProvider.Kind
        let apiBase: String
        let model: ModelEntry
    }

    /// Choosing a preset fills in the format, address, and a starting model.
    static let presets: [Preset] = [
        Preset(id: "anthropic", label: "Anthropic", kind: .anthropic, apiBase: "https://api.anthropic.com", model: ModelEntry(id: "claude-opus-5-5", title: "Claude Opus 5.5")),
        Preset(id: "openai", label: "OpenAI", kind: .openai, apiBase: "https://api.openai.com/v1", model: ModelEntry(id: "gpt-5.6-sol", title: "GPT-5.6 Sol")),
        Preset(id: "openrouter", label: "OpenRouter", kind: .openai, apiBase: "https://openrouter.ai/api", model: ModelEntry(id: "xiaomi/mimo-v2.5", title: "MiMo V2.5")),
        Preset(id: "deepseek", label: "DeepSeek", kind: .openai, apiBase: "https://api.deepseek.com", model: ModelEntry(id: "deepseek-v4-flash", title: "DeepSeek V4 Flash")),
        Preset(id: "minimax", label: "MiniMax", kind: .anthropic, apiBase: "https://api.minimax.io/anthropic", model: ModelEntry(id: "MiniMax-M3", title: "MiniMax M3")),
        Preset(id: "glm", label: "Z.AI", kind: .anthropic, apiBase: "https://api.z.ai/api/anthropic", model: ModelEntry(id: "GLM-5.2", title: "GLM-5.2")),
        Preset(id: "custom", label: "", kind: .openai, apiBase: "", model: ModelEntry(id: ""))
    ]

    static func preset(matching provider: ModelProvider) -> Preset? {
        let base = provider.apiBase.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return presets.first { $0.id != "custom" && $0.apiBase == base && $0.kind == provider.kind }
    }

    static func reference(_ provider: ModelProvider, _ model: ModelEntry) -> String { "\(provider.id)/\(model.id)" }

    var allModels: [(provider: ModelProvider, model: ModelEntry)] {
        providers.flatMap { provider in provider.models.map { (provider, $0) } }
    }

    /// The default model; falls back to the first model when the saved one was removed.
    var resolvedDefault: (provider: ModelProvider, model: ModelEntry)? {
        allModels.first { Self.reference($0.provider, $0.model) == defaultModel } ?? allModels.first
    }

    /// Keeps `defaultModel` pointing at a model that still exists.
    mutating func normalizeDefault() {
        defaultModel = resolvedDefault.map { Self.reference($0.provider, $0.model) } ?? ""
    }

    // MARK: - Validation

    /// Provider IDs: lowercase letters, digits, ".", "_" and "-", starting with a letter or digit.
    static func providerIDProblem(_ id: String, takenBy others: [ModelProvider]) -> String? {
        if id.isEmpty { return L("Enter a provider ID.", "请填写服务商 ID。") }
        if id.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) == nil {
            return L("Provider ID can use only lowercase letters, digits, “.”, “_”, and “-”.", "服务商 ID 只能包含小写字母、数字、“.”、“_”和“-”。")
        }
        if let other = others.first(where: { $0.id == id }) {
            return L("Provider ID “\(id)” is already used by \(other.name).", "服务商 ID「\(id)」已被 \(other.name) 使用。")
        }
        return nil
    }

    /// Model IDs are sent to the API as typed, so only empty, blank-containing, or repeated IDs are rejected.
    static func modelsProblem(_ models: [ModelEntry]) -> String? {
        var seen = Set<String>()
        for model in models {
            if model.id.isEmpty { return L("Enter an ID for every model, or remove the empty row.", "请为每个模型填写 ID，或删除空行。") }
            if model.id.contains(where: \.isWhitespace) { return L("Model ID “\(model.id)” cannot contain spaces.", "模型 ID「\(model.id)」不能包含空格。") }
            if !seen.insert(model.id).inserted { return L("Model ID “\(model.id)” appears more than once.", "模型 ID「\(model.id)」重复了。") }
        }
        return nil
    }

    func uniqueID(for name: String) -> String {
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "provider" : slug
        var candidate = base
        var index = 2
        while providers.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }
}

/// Persists the model configuration in UserDefaults; keys stay in the Keychain.
@MainActor
enum ModelsStore {
    static let didChange = Notification.Name("ModelsStore.didChange")
    private static let preferenceKey = "ai.models"
    private static let legacyKeyAccount = "anthropic-api-key"

    static var config: ModelsConfig {
        get { load() }
        set {
            var value = newValue
            value.normalizeDefault()
            if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: preferenceKey) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var isConfigured: Bool {
        config.resolvedDefault?.provider.hasKey == true
    }

    /// Saves an edited provider; when its ID changed, moves its key and keeps the default model pointing at it.
    static func save(_ provider: ModelProvider, replacing oldID: String?, apiKey: String) {
        var value = config
        if let oldID, let index = value.providers.firstIndex(where: { $0.id == oldID }) {
            value.providers[index] = provider
            if oldID != provider.id {
                Keychain.write(nil, account: ModelProvider.keyAccount(for: oldID))
                if value.defaultModel.hasPrefix(oldID + "/") {
                    value.defaultModel = provider.id + value.defaultModel.dropFirst(oldID.count)
                }
            }
        } else {
            value.providers.append(provider)
        }
        provider.apiKey = apiKey
        config = value
    }

    static func remove(_ providerID: String) {
        var value = config
        value.providers.first { $0.id == providerID }?.apiKey = nil
        value.providers.removeAll { $0.id == providerID }
        config = value
    }

    private static func load(defaults: UserDefaults = .standard) -> ModelsConfig {
        if let data = defaults.data(forKey: preferenceKey), let value = try? JSONDecoder().decode(ModelsConfig.self, from: data) {
            return value
        }
        return migrateSingleKeySettings(defaults: defaults)
    }

    /// Earlier builds had one Anthropic key, model, and base URL; turn them into an Anthropic provider once.
    private static func migrateSingleKeySettings(defaults: UserDefaults) -> ModelsConfig {
        var value = ModelsConfig()
        let key = Keychain.read(account: legacyKeyAccount)
        let model = defaults.string(forKey: "ai.model")
        let base = defaults.string(forKey: "ai.baseURL")
        if key != nil || model != nil || base != nil {
            let provider = ModelProvider(id: "anthropic", name: "Anthropic", kind: .anthropic,
                                         apiBase: base ?? "https://api.anthropic.com", models: [ModelEntry(id: model ?? "claude-opus-5-5")])
            if let key { provider.apiKey = key }
            value.providers = [provider]
            value.normalizeDefault()
            log("migrated single-key AI settings into provider \(provider.id)")
        }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: preferenceKey) }
        Keychain.write(nil, account: legacyKeyAccount)
        defaults.removeObject(forKey: "ai.model")
        defaults.removeObject(forKey: "ai.baseURL")
        return value
    }
}
