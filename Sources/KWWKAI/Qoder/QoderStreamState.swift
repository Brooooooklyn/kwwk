import Foundation

/// Lifts tool calls a model wrote into its text out of the stream. Qoder
/// serves OpenAI's own `tool_calls` when asked with a tools array, so this is
/// the fallback for a model that still writes a call as a `tool_call` block:
/// text is held back while it could be the start of the opening marker, and a
/// block is emitted as a call once its closing marker arrives. Ported from
/// magpie `qoderText` (`internal/gateway/qoder.go`).
///
/// The markers are spelled with escapes for their angle brackets, as magpie
/// spells them, so this source holds no literal tag.
struct QoderToolCallSplitter {
    static let open = "\u{3C}tool_call\u{3E}"
    static let close = "\u{3C}/tool_call\u{3E}"

    enum Fragment: Equatable {
        case text(String)
        case call(name: String, arguments: String)
    }

    private var textBuffer = ""
    private var callBuffer = ""
    private var inCall = false

    mutating func feed(_ input: String) -> [Fragment] {
        var out: [Fragment] = []
        var input = input
        while !input.isEmpty {
            if !inCall {
                let combined = textBuffer + input
                textBuffer = ""
                guard let marker = combined.range(of: Self.open) else {
                    // Keep back a tail that could still become the marker.
                    let keep = Self.markerPrefixLength(atEndOf: combined)
                    let emitted = String(combined.dropLast(keep))
                    if !emitted.isEmpty { out.append(.text(emitted)) }
                    textBuffer = String(combined.suffix(keep))
                    break
                }
                if marker.lowerBound > combined.startIndex {
                    out.append(.text(String(combined[..<marker.lowerBound])))
                }
                input = String(combined[marker.upperBound...])
                inCall = true
                continue
            }
            let combined = callBuffer + input
            callBuffer = ""
            guard let marker = combined.range(of: Self.close) else {
                callBuffer = combined
                break
            }
            let block = String(combined[..<marker.lowerBound])
            if let call = Self.parseCall(block) {
                out.append(.call(name: call.name, arguments: call.arguments))
            } else {
                out.append(.text(Self.open + block + Self.close))
            }
            input = String(combined[marker.upperBound...])
            inCall = false
        }
        return out
    }

    /// What is still held when the stream ends: an unfinished block goes out
    /// as the text it was.
    mutating func flush() -> String {
        defer {
            inCall = false
            callBuffer = ""
            textBuffer = ""
        }
        return inCall ? Self.open + callBuffer : textBuffer
    }

    /// The length of the longest proper prefix of the opening marker that
    /// `text` ends with.
    private static func markerPrefixLength(atEndOf text: String) -> Int {
        for size in stride(from: open.count - 1, to: 0, by: -1) where text.hasSuffix(open.prefix(size)) {
            return size
        }
        return 0
    }

    private static let function = try! NSRegularExpression(
        pattern: "\u{3C}function=([^\u{3E}]+)\u{3E}(.*?)\u{3C}/function\u{3E}",
        options: [.dotMatchesLineSeparators]
    )
    private static let parameter = try! NSRegularExpression(
        pattern: "\u{3C}parameter=([^\u{3E}]+)\u{3E}(.*?)\u{3C}/parameter\u{3E}",
        options: [.dotMatchesLineSeparators]
    )

    /// Reads one block: a JSON `{name, arguments}`, or the XML
    /// function/parameter form. A parameter's value is taken as it stands —
    /// JSON when it reads as JSON, a string otherwise; nothing is unescaped.
    static func parseCall(_ block: String) -> (name: String, arguments: String)? {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if let framed = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any],
           let name = (framed["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           let arguments = framed["arguments"] as? [String: Any], let text = json(arguments) {
            return (name, text)
        }
        let whole = NSRange(block.startIndex..., in: block)
        guard let match = function.firstMatch(in: block, range: whole),
              let nameRange = Range(match.range(at: 1), in: block),
              let bodyRange = Range(match.range(at: 2), in: block) else { return nil }
        let name = block[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let body = String(block[bodyRange])
        var arguments: [String: Any] = [:]
        for found in parameter.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let keyRange = Range(found.range(at: 1), in: body),
                  let valueRange = Range(found.range(at: 2), in: body) else { continue }
            let key = body[keyRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let value = body[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
            arguments[key] = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]))
                ?? value
        }
        return json(arguments).map { (name, $0) }
    }

    private static func json(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Accumulates the assistant message from Qoder's chunks and emits the
/// matching `AssistantMessageEvent`s.
final class QoderStreamState: @unchecked Sendable {
    private let api: String
    private let model: Model
    private let lock = NSLock()

    private var blocks: [AssistantBlock] = []
    private var textIndex: Int?
    private var thinkingIndex: Int?
    /// Tool-call block indexes in arrival order, each with its argument JSON
    /// so far.
    private var tools: [(index: Int, arguments: String)] = []
    private var finishReason: String?
    private var usage = Usage()
    private var stopReasonOverride: StopReason?

    init(api: String, model: Model) {
        self.api = api
        self.model = model
    }

    func appendThinking(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        let (index, isNew): (Int, Bool) = lock.withLock {
            if let index = thinkingIndex { return (index, false) }
            blocks.append(.thinking(ThinkingContent(thinking: "")))
            thinkingIndex = blocks.count - 1
            return (blocks.count - 1, true)
        }
        if isNew { emit(.thinkingStart(contentIndex: index, partial: snapshot())) }
        lock.withLock {
            if case .thinking(var thinking) = blocks[index] {
                thinking.thinking += delta
                blocks[index] = .thinking(thinking)
            }
        }
        emit(.thinkingDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    func appendText(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        endThinking(emit: emit)
        let (index, isNew): (Int, Bool) = lock.withLock {
            if let index = textIndex { return (index, false) }
            blocks.append(.text(TextContent(text: "")))
            textIndex = blocks.count - 1
            return (blocks.count - 1, true)
        }
        if isNew { emit(.textStart(contentIndex: index, partial: snapshot())) }
        lock.withLock {
            if case .text(var text) = blocks[index] {
                text.text += delta
                blocks[index] = .text(text)
            }
        }
        emit(.textDelta(contentIndex: index, delta: delta, partial: snapshot()))
    }

    /// Opens a tool call; argument deltas that follow belong to it until the
    /// next one opens.
    func startToolCall(id: String, name: String, emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let index: Int = lock.withLock {
            blocks.append(.toolCall(ToolCall(id: id, name: name, arguments: .object([:]))))
            tools.append((blocks.count - 1, ""))
            return blocks.count - 1
        }
        emit(.toolCallStart(contentIndex: index, partial: snapshot()))
    }

    func appendToolArguments(_ delta: String, emit: (AssistantMessageEvent) -> Void) {
        let index: Int? = lock.withLock {
            guard !tools.isEmpty else { return nil }
            tools[tools.count - 1].arguments += delta
            return tools[tools.count - 1].index
        }
        if let index { emit(.toolCallDelta(contentIndex: index, delta: delta, partial: snapshot())) }
    }

    /// Qoder counts the way OpenAI does: `prompt_tokens` holds the cached
    /// ones and `completion_tokens` the reasoning ones.
    func setUsage(prompt: Int, completion: Int, cached: Int, reasoning: Int) {
        lock.withLock {
            let cached = min(max(cached, 0), prompt)
            usage.input = prompt - cached
            usage.cacheRead = cached
            usage.output = completion
            usage.reasoning = reasoning
            usage.totalTokens = prompt + completion
        }
    }

    func setFinishReason(_ reason: String) {
        lock.withLock { finishReason = reason }
    }

    var sawFinishReason: Bool { lock.withLock { finishReason != nil } }

    /// True when a tool call's arguments so far do not read as JSON — a
    /// stream that stopped inside one.
    var hasIncompleteToolArguments: Bool {
        lock.withLock {
            tools.contains { !$0.arguments.isEmpty && Self.decode($0.arguments) == nil }
        }
    }

    func closeOpenBlocks(emit: (AssistantMessageEvent) -> Void) {
        endText(emit: emit)
        endThinking(emit: emit)
        let completed: [(Int, ToolCall)] = lock.withLock {
            var out: [(Int, ToolCall)] = []
            for tool in tools {
                guard case .toolCall(var call) = blocks[tool.index] else { continue }
                call.arguments = Self.decode(tool.arguments) ?? .object([:])
                blocks[tool.index] = .toolCall(call)
                out.append((tool.index, call))
            }
            return out
        }
        for (index, call) in completed {
            emit(.toolCallEnd(contentIndex: index, toolCall: call, partial: snapshot()))
        }
    }

    private func endText(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = lock.withLock {
            guard let index = textIndex, case .text(let text) = blocks[index] else { return nil }
            textIndex = nil
            return (index, text.text)
        }
        if let (index, content) = closed { emit(.textEnd(contentIndex: index, content: content, partial: snapshot())) }
    }

    private func endThinking(emit: (AssistantMessageEvent) -> Void) {
        let closed: (Int, String)? = lock.withLock {
            guard let index = thinkingIndex, case .thinking(let thinking) = blocks[index] else { return nil }
            thinkingIndex = nil
            return (index, thinking.thinking)
        }
        if let (index, content) = closed {
            emit(.thinkingEnd(contentIndex: index, content: content, partial: snapshot()))
        }
    }

    private static func decode(_ arguments: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))
    }

    func snapshot() -> AssistantMessage {
        lock.withLock {
            // A turn that called a tool stops for it, whatever Qoder named
            // the finish; `length` is OpenAI's word for a spent output limit.
            let derived: StopReason = !tools.isEmpty ? .toolUse : finishReason == "length" ? .length : .stop
            var settled = usage
            settled.cost = calculateCost(model: model, usage: settled)
            return AssistantMessage(
                content: blocks,
                api: api,
                provider: model.provider,
                model: model.id,
                usage: settled,
                stopReason: stopReasonOverride ?? derived,
                timestamp: Timestamp.now()
            )
        }
    }

    func aborted() -> AssistantMessage {
        lock.withLock { stopReasonOverride = .aborted }
        var message = snapshot()
        message.errorMessage = "Request was aborted"
        return message
    }

    func failed(_ failure: ProviderFailure) -> AssistantMessage {
        lock.withLock { stopReasonOverride = .error }
        var message = snapshot()
        message.errorMessage = failure.message
        message.failure = failure
        return message
    }
}
