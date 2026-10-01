import AppKit
extension Bundle { static var module: Bundle { .main } }

/// Pure model-configuration logic only: nothing here reads or writes the Keychain or real preferences.
@main @MainActor
struct ModelsTests {
    static func main() {
        func provider(_ id: String, _ kind: ModelProvider.Kind, _ base: String, _ models: [String]) -> ModelProvider {
            ModelProvider(id: id, name: id, kind: kind, apiBase: base, models: models.map { ModelEntry(id: $0) })
        }

        // Endpoints follow Spotcat's rules: full path kept, /v1 completed, otherwise /v1/… appended; empty uses the official base.
        let endpoints: [(ModelProvider.Kind, String, String)] = [
            (.anthropic, "", "https://api.anthropic.com/v1/messages"),
            (.anthropic, "https://api.anthropic.com/", "https://api.anthropic.com/v1/messages"),
            (.anthropic, "https://api.minimax.io/anthropic", "https://api.minimax.io/anthropic/v1/messages"),
            (.openai, "", "https://api.openai.com/v1/chat/completions"),
            (.openai, "https://openrouter.ai/api", "https://openrouter.ai/api/v1/chat/completions"),
            (.openai, "https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions")
        ]
        for (kind, base, expected) in endpoints {
            let url = provider("p", kind, base, []).endpoint?.absoluteString
            precondition(url == expected, "\(kind) \(base) → \(url ?? "nil"), expected \(expected)")
        }
        precondition(provider("p", .openai, "not a url", []).endpoint == nil, "invalid base URLs are rejected")

        // Provider IDs are required, restricted to a safe alphabet without "/", and unique.
        let taken = [provider("openrouter", .openai, "", [])]
        precondition(ModelsConfig.providerIDProblem("deepseek", takenBy: taken) == nil)
        precondition(ModelsConfig.providerIDProblem("z.ai_2-b", takenBy: taken) == nil)
        for bad in ["", "OpenAI", "a/b", "has space", "-lead", "中文"] {
            precondition(ModelsConfig.providerIDProblem(bad, takenBy: taken) != nil, "provider ID \(bad) must be rejected")
        }
        precondition(ModelsConfig.providerIDProblem("openrouter", takenBy: taken) != nil, "duplicate provider IDs must be rejected")

        // Model IDs may contain "/" (OpenRouter) but must be present, without spaces, and unique within the provider.
        let entries = { (ids: [String]) in ids.map { ModelEntry(id: $0) } }
        precondition(ModelsConfig.modelsProblem(entries(["xiaomi/mimo-v2.5", "deepseek-v4-flash"])) == nil)
        precondition(ModelsConfig.modelsProblem([]) == nil)
        precondition(ModelsConfig.modelsProblem(entries(["a", "a"])) != nil)
        precondition(ModelsConfig.modelsProblem(entries(["a b"])) != nil)
        precondition(ModelsConfig.modelsProblem([ModelEntry(id: "", title: "Only a title")]) != nil)
        precondition(ModelEntry(id: "m").displayTitle == "m" && ModelEntry(id: "m", title: "M").displayTitle == "M")

        // The default model falls back to the first model when the saved one disappears.
        var config = ModelsConfig(providers: [provider("one", .anthropic, "", ["m1", "m2"]), provider("two", .openai, "", ["x"])],
                                  defaultModel: "two/x")
        precondition(config.resolvedDefault?.provider.id == "two" && config.resolvedDefault?.model.id == "x")
        config.providers.removeLast()
        precondition(config.resolvedDefault?.model.id == "m1")
        config.normalizeDefault()
        precondition(config.defaultModel == "one/m1")
        config.providers = []
        config.normalizeDefault()
        precondition(config.defaultModel.isEmpty && config.resolvedDefault == nil)

        // Provider IDs come from names and never collide.
        config.providers = [provider("openrouter", .openai, "", [])]
        precondition(config.uniqueID(for: "OpenRouter") == "openrouter-2")
        precondition(config.uniqueID(for: "Z.AI") == "z-ai" && config.uniqueID(for: "  ") == "provider")

        // Presets are recognized from format plus base URL; anything else is custom.
        precondition(ModelsConfig.preset(matching: provider("p", .openai, "https://api.deepseek.com/", []))?.id == "deepseek")
        precondition(ModelsConfig.preset(matching: provider("p", .anthropic, "https://api.deepseek.com", [])) == nil)

        // Configs round-trip through JSON.
        let saved = ModelsConfig(providers: [provider("a", .anthropic, "https://x.test", ["m"])], defaultModel: "a/m")
        precondition((try? JSONDecoder().decode(ModelsConfig.self, from: JSONEncoder().encode(saved))) == saved)

        // Model lists saved by earlier builds as plain strings still load.
        let legacy = #"{"providers":[{"id":"a","name":"A","kind":"openai","apiBase":"","models":["m1","m2"]}],"defaultModel":"a/m2"}"#
        let decoded = try? JSONDecoder().decode(ModelsConfig.self, from: Data(legacy.utf8))
        precondition(decoded?.providers.first?.models == entries(["m1", "m2"]) && decoded?.resolvedDefault?.model.id == "m2")
        // A model ID with "/" still resolves, because provider IDs never contain "/".
        let routed = ModelsConfig(providers: [provider("openrouter", .openai, "", ["xiaomi/mimo-v2.5"])], defaultModel: "openrouter/xiaomi/mimo-v2.5")
        precondition(routed.resolvedDefault?.model.id == "xiaomi/mimo-v2.5")

        // JSON replies are found inside code fences or surrounding text.
        precondition(AIClient.jsonObject(in: "```json\n{\"title\": \"T\", \"tags\": [\"a\"]}\n```")?["title"] as? String == "T")
        precondition(AIClient.jsonObject(in: "no json here") == nil)

        print("Passed models checks: endpoints, ID validation, default fallback, provider IDs, presets, persistence, JSON replies")
    }
}
