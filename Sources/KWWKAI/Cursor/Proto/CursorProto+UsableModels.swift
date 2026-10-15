import Foundation

extension CursorProto {
    // MARK: - GetUsableModels (used only by the kwwk-generate-cursor-models script)

    /// `GetUsableModelsRequest { custom_model_ids=1(repeated string) }` — sent empty.
    static func encodeGetUsableModelsRequest() -> Data { Data() }

    struct UsableModel {
        var modelId: String
        var displayName: String
        var displayNameShort: String
        var displayModelId: String
        var aliases: [String]
        var hasThinking: Bool
    }

    /// Decode `GetUsableModelsResponse { models=1(repeated ModelDetails) }`.
    /// `ModelDetails { model_id=1, thinking_details=2, display_model_id=3,
    /// display_name=4, display_name_short=5, aliases=6 }`.
    static func decodeUsableModels(_ data: Data) -> [UsableModel] {
        var out: [UsableModel] = []
        var reader = ProtoReader(data)
        while let field = reader.next() {
            guard field.number == 1, let bytes = field.value.asData else { continue }
            var m = UsableModel(
                modelId: "",
                displayName: "",
                displayNameShort: "",
                displayModelId: "",
                aliases: [],
                hasThinking: false
            )
            var inner = ProtoReader(bytes)
            while let f = inner.next() {
                switch f.number {
                case 1: m.modelId = f.value.asString ?? ""
                case 2: m.hasThinking = true
                case 3: m.displayModelId = f.value.asString ?? ""
                case 4: m.displayName = f.value.asString ?? ""
                case 5: m.displayNameShort = f.value.asString ?? ""
                case 6: if let s = f.value.asString { m.aliases.append(s) }
                default: break
                }
            }
            if !m.modelId.isEmpty { out.append(m) }
        }
        return out
    }
}
