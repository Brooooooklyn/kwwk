import Foundation

extension OpenAICompletionsProvider {
    /// Encode the reasoning/thinking request fields for the model's
    /// `thinkingFormat`, honoring `thinkingLevelMap` remapping and clamping.
    /// Ports pi's openai-completions reasoning branch.
    static func applyReasoning(
        _ root: inout [String: Any], model: Model, options: StreamOptions?, compat: ResolvedCompletionsCompat
    ) {
        guard model.reasoning else { return }

        let requested: ModelThinkingLevel? = options?.reasoning.map {
            clampThinkingLevel(model, ModelThinkingLevel(reasoning: $0))
        }
        let hasEffort: Bool = { if let r = requested, r != .off { return true }; return false }()
        let level = requested ?? .off

        // Wire value for a level: mapped string if present & non-null, else raw.
        func wire(_ l: ModelThinkingLevel) -> String {
            if let map = model.thinkingLevelMap, let entry = map[l.rawValue], let v = entry { return v }
            return l.rawValue
        }
        let offEntry = model.thinkingLevelMap?["off"]            // absent / explicit-null / string
        let offIsExplicitNull = (offEntry != nil && offEntry! == nil)
        let offString: String? = { if let e = offEntry, let v = e { return v }; return nil }()

        switch compat.thinkingFormat {
        case "zai":
            root["thinking"] = ["type": hasEffort ? "enabled" : "disabled"]
            if hasEffort, compat.supportsReasoningEffort { root["reasoning_effort"] = wire(level) }
        case "qwen":
            root["enable_thinking"] = hasEffort
        case "qwen-chat-template":
            root["chat_template_kwargs"] = ["enable_thinking": hasEffort, "preserve_thinking": true]
        case "chat-template":
            if let kwargs = buildChatTemplateKwargs(
                model: model,
                requestedLevel: level,
                hasEffort: hasEffort,
                compat: compat
            ) {
                root["chat_template_kwargs"] = kwargs
            }
        case "deepseek":
            if hasEffort { root["thinking"] = ["type": "enabled"] }
            else if !offIsExplicitNull { root["thinking"] = ["type": "disabled"] }
            if hasEffort, compat.supportsReasoningEffort { root["reasoning_effort"] = wire(level) }
        case "openrouter":
            if hasEffort { root["reasoning"] = ["effort": wire(level)] }
            else if !offIsExplicitNull { root["reasoning"] = ["effort": offString ?? "none"] }
        case "ant-ling":
            if hasEffort, let map = model.thinkingLevelMap, let entry = map[level.rawValue], let v = entry {
                root["reasoning"] = ["effort": v]
            }
        case "together":
            root["reasoning"] = ["enabled": hasEffort]
            if hasEffort, compat.supportsReasoningEffort { root["reasoning_effort"] = wire(level) }
        case "string-thinking":
            if hasEffort { root["thinking"] = wire(level) }
            else if !offIsExplicitNull { root["thinking"] = offString ?? "none" }
        default: // "openai"
            if hasEffort, compat.supportsReasoningEffort {
                root["reasoning_effort"] = wire(level)
            } else if !hasEffort, compat.supportsReasoningEffort, let off = offString {
                root["reasoning_effort"] = off
            }
        }
    }

    private static func buildChatTemplateKwargs(
        model: Model,
        requestedLevel: ModelThinkingLevel,
        hasEffort: Bool,
        compat: ResolvedCompletionsCompat
    ) -> [String: Any]? {
        var kwargs: [String: Any] = [:]
        for (key, value) in compat.chatTemplateKwargs {
            guard let resolved = resolveChatTemplateKwarg(
                value,
                model: model,
                requestedLevel: requestedLevel,
                hasEffort: hasEffort
            ) else { continue }
            kwargs[key] = anyFromJSONValue(resolved) ?? NSNull()
        }
        return kwargs.isEmpty ? nil : kwargs
    }

    private static func resolveChatTemplateKwarg(
        _ value: JSONValue,
        model: Model,
        requestedLevel: ModelThinkingLevel,
        hasEffort: Bool
    ) -> JSONValue? {
        guard case .object(let object) = value else { return value }
        guard case .string(let variable)? = object["$var"] else { return value }
        if case .bool(true)? = object["omitWhenOff"], !hasEffort {
            return nil
        }
        switch variable {
        case "thinking.enabled":
            return .bool(hasEffort)
        case "thinking.effort":
            if hasEffort {
                return thinkingMapValue(model, requestedLevel.rawValue, fallback: requestedLevel.rawValue)
            }
            return thinkingMapValue(model, "off", fallback: nil)
        default:
            return nil
        }
    }

    private static func thinkingMapValue(
        _ model: Model,
        _ key: String,
        fallback: String?
    ) -> JSONValue? {
        if let map = model.thinkingLevelMap, map.keys.contains(key) {
            guard let value = map[key] ?? nil else { return nil }
            return .string(value)
        }
        return fallback.map(JSONValue.string)
    }
}
