import Foundation

/// Splits a reply that opens with `<thinking>…</thinking>` into its thinking
/// and the text after, however the tags fall across pieces. Kiro's thinking
/// mode has the model think aloud inside those tags, in the same
/// `assistantResponseEvent` content as its answer. Byte-for-byte port of
/// magpie's `kiroThinkParser`.
struct KiroThinkParser {
    enum Piece: Equatable {
        case thinking(String)
        case text(String)
    }

    private enum State { case undecided, thinking, text }

    private static let open = Array("<thinking>".utf8)
    private static let close = Array("</thinking>".utf8)
    private static let newlines = Array("\r\n".utf8)
    private static let whitespace = Array(" \t\r\n".utf8)

    private var state = State.undecided
    private var buffer: [UInt8] = []
    /// Whether any thinking was said yet: it opens on a line of its own.
    private var said = false

    mutating func feed(_ text: String) -> [Piece] {
        buffer += Array(text.utf8)
        var out: [Piece] = []
        while true {
            switch state {
            case .undecided:
                let trimmed = Array(buffer.drop { Self.whitespace.contains($0) })
                if trimmed.starts(with: Self.open) {
                    buffer = Array(trimmed.dropFirst(Self.open.count))
                    state = .thinking
                } else if trimmed.count < Self.open.count, Self.open.starts(with: trimmed) {
                    return out // may yet be the tag
                } else {
                    state = .text
                }
            case .thinking:
                if !said {
                    buffer = Array(buffer.drop { Self.newlines.contains($0) })
                    if buffer.isEmpty { return out }
                }
                if let index = Self.firstIndex(of: Self.close, in: buffer) {
                    if index > 0 {
                        out.append(.thinking(String(decoding: buffer[..<index], as: UTF8.self)))
                        said = true
                    }
                    buffer = Array(buffer[(index + Self.close.count)...].drop { Self.newlines.contains($0) })
                    state = .text
                    continue
                }
                // Hold back what may be the start of the closing tag.
                let sure = buffer.count - Self.partialSuffix(buffer, of: Self.close)
                if sure > 0 {
                    out.append(.thinking(String(decoding: buffer[..<sure], as: UTF8.self)))
                    buffer = Array(buffer[sure...])
                    said = true
                }
                return out
            case .text:
                if !buffer.isEmpty {
                    out.append(.text(String(decoding: buffer, as: UTF8.self)))
                    buffer = []
                }
                return out
            }
        }
    }

    /// Says what is held back: the reply, or a part of it, has ended.
    mutating func end() -> [Piece] {
        guard !buffer.isEmpty else { return [] }
        let held = String(decoding: buffer, as: UTF8.self)
        buffer = []
        if state == .thinking { return [.thinking(held)] }
        state = .text
        return [.text(held)]
    }

    private static func firstIndex(of tag: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= tag.count else { return nil }
        return (0...(bytes.count - tag.count)).first { bytes[$0...].starts(with: tag) }
    }

    /// How much of the end of `bytes` is the start of `tag`.
    private static func partialSuffix(_ bytes: [UInt8], of tag: [UInt8]) -> Int {
        var length = min(tag.count - 1, bytes.count)
        while length > 0 {
            if bytes.suffix(length).elementsEqual(tag.prefix(length)) { return length }
            length -= 1
        }
        return 0
    }
}

/// Follows a `generateAssistantResponse` reply frame by frame and emits the
/// matching `AssistantMessageEvent`s: its text (whose thinking, asked for,
/// comes first between `<thinking>` tags), its tool calls — each a run of
/// frames naming it, the arguments in pieces — and what it says of itself.
/// Ported from magpie's `kiroDecoder` / `decodeKiro`.
struct KiroReply {
    private let api: String
    private let model: Model
    /// Whether the request asked the model to think aloud.
    private let thinking: Bool
    /// The caller's name for a tool `KiroRequest.toolName` cut.
    private let toolNames: [String: String]

    private var blocks: [AssistantBlock] = []
    private var textIndex: Int?
    private var thinkingIndex: Int?
    private var think = KiroThinkParser()
    /// The call being streamed: its block, id, and arguments so far.
    private var tool: (index: Int, id: String, arguments: String)?
    private var toolCount = 0
    private var stop = ""
    private var usage = Usage()
    private var contextPercentage = 0.0
    /// Bytes of text, thinking and arguments said, for an output estimate.
    private var said = 0
    private(set) var frames = 0

    init(api: String, model: Model, thinking: Bool, toolNames: [String: String]) {
        self.api = api
        self.model = model
        self.thinking = thinking
        self.toolNames = toolNames
    }

    // MARK: - Frames

    mutating func apply(_ message: AWSEventMessage, emit: (AssistantMessageEvent) -> Void) throws {
        frames += 1
        var kind = message.headers[":event-type"] ?? ""
        if let type = message.headers[":message-type"], type == "exception" || type == "error" {
            kind = message.headers[":exception-type"] ?? ""
            if kind.isEmpty { kind = message.headers[":error-code"] ?? "" }
            throw Self.exception(kind: kind, payload: message.payload)
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any] else { return }
        switch kind {
        case "assistantResponseEvent":
            let text = payload["content"] as? String ?? ""
            said += text.utf8.count
            if thinking {
                say(think.feed(text), emit: emit)
            } else if !text.isEmpty {
                say([.text(text)], emit: emit)
            }
        case "reasoningContentEvent":
            if let text = payload["text"] as? String, !text.isEmpty {
                said += text.utf8.count
                say([.thinking(text)], emit: emit)
            } else if let signature = payload["signature"] as? String, !signature.isEmpty {
                let index = thinkingIndex ?? blocks.lastIndex { if case .thinking = $0 { return true }; return false }
                if let index, case .thinking(var block) = blocks[index] {
                    block.thinkingSignature = signature
                    blocks[index] = .thinking(block)
                }
            }
        case "toolUseEvent":
            let id = payload["toolUseId"] as? String ?? ""
            var name = payload["name"] as? String ?? ""
            name = toolNames[name] ?? name
            if !id.isEmpty, id != tool?.id {
                // The text before a call is all said.
                say(think.end(), emit: emit)
                endText(emit: emit)
                endThinking(emit: emit)
                endTool(emit: emit)
                blocks.append(.toolCall(ToolCall(id: id, name: name, arguments: .object([:]))))
                tool = (blocks.count - 1, id, "")
                toolCount += 1
                emit(.toolCallStart(contentIndex: blocks.count - 1, partial: snapshot()))
            }
            // The arguments come as pieces of a JSON string, or, from some
            // models, as one object.
            var piece = ""
            if let text = payload["input"] as? String {
                piece = text
            } else if let object = payload["input"] as? [String: Any], !object.isEmpty,
                      let data = try? JSONSerialization.data(withJSONObject: object) {
                piece = String(decoding: data, as: UTF8.self)
            }
            said += piece.utf8.count
            if !piece.isEmpty, let index = tool?.index {
                tool?.arguments += piece
                emit(.toolCallDelta(contentIndex: index, delta: piece, partial: snapshot()))
            }
        case "metadataEvent", "messageMetadataEvent":
            if let reason = payload["stopReason"] as? String, !reason.isEmpty { stop = reason }
            if let tokens = payload["tokenUsage"] as? [String: Any] {
                func count(_ key: String) -> Int { (tokens[key] as? NSNumber)?.intValue ?? 0 }
                let uncached = count("uncachedInputTokens")
                usage.input += uncached != 0 ? uncached : count("inputTokens")
                usage.output += count("outputTokens")
                usage.cacheRead += count("cacheReadInputTokens")
                usage.cacheWrite += count("cacheWriteInputTokens")
                if let percentage = (tokens["contextUsagePercentage"] as? NSNumber)?.doubleValue, percentage > 0 {
                    contextPercentage = percentage
                }
            }
        case "contextUsageEvent":
            if let percentage = (payload["contextUsagePercentage"] as? NSNumber)?.doubleValue, percentage > 0 {
                contextPercentage = percentage
            }
        case "error", "throttlingError", "validationError", "serviceUnavailableError", "internalServerException":
            throw Self.exception(kind: kind, payload: message.payload)
        default:
            break
        }
    }

    /// What an error in the stream says: `{"message": …, "reason": …}`, the
    /// kind in the frame's headers.
    ///
    /// Kiro sends a throttle, a spent allowance or a server error this way
    /// too, under a 200 and before any of the answer (magpie-plugins kiro
    /// 0.1.4, errors.test.mjs, where a quota exception is read as a quota).
    /// A spent allowance is worded as `KiroProvider.httpFailure` words the
    /// same reasons, so it ends the turn as a quota instead of being asked
    /// again as a throttle: `ServiceQuotaExceededException`, or any kind
    /// whose reason is the month's count.
    static func exception(kind: String, payload: Data) -> ProviderFailure {
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        var message = [object?["message"], object?["Message"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            ?? String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = object?["reason"] as? String, !reason.isEmpty { message += " (\(reason))" }
        if kind.lowercased().contains("servicequotaexceeded") || KiroProvider.saysUsageLimit(message) {
            message = "usage limit reached: " + message
        } else if kind.lowercased().contains("throttl") {
            message = "rate limited: " + message
        } else if !kind.isEmpty {
            message = "\(kind): \(message)"
        }
        return ProviderFailure(message: "Kiro: " + message, providerCode: kind.isEmpty ? nil : kind)
    }

    // MARK: - Blocks

    private mutating func say(_ pieces: [KiroThinkParser.Piece], emit: (AssistantMessageEvent) -> Void) {
        for piece in pieces {
            switch piece {
            case .thinking(let delta):
                endText(emit: emit)
                endTool(emit: emit)
                if thinkingIndex == nil {
                    blocks.append(.thinking(ThinkingContent(thinking: "")))
                    thinkingIndex = blocks.count - 1
                    emit(.thinkingStart(contentIndex: blocks.count - 1, partial: snapshot()))
                }
                guard let index = thinkingIndex, case .thinking(var block) = blocks[index] else { continue }
                block.thinking += delta
                blocks[index] = .thinking(block)
                emit(.thinkingDelta(contentIndex: index, delta: delta, partial: snapshot()))
            case .text(let delta):
                endThinking(emit: emit)
                // Text after a call: the call's arguments are all in.
                endTool(emit: emit)
                if textIndex == nil {
                    blocks.append(.text(TextContent(text: "")))
                    textIndex = blocks.count - 1
                    emit(.textStart(contentIndex: blocks.count - 1, partial: snapshot()))
                }
                guard let index = textIndex, case .text(var block) = blocks[index] else { continue }
                block.text += delta
                blocks[index] = .text(block)
                emit(.textDelta(contentIndex: index, delta: delta, partial: snapshot()))
            }
        }
    }

    private mutating func endText(emit: (AssistantMessageEvent) -> Void) {
        guard let index = textIndex, case .text(let block) = blocks[index] else { return }
        textIndex = nil
        emit(.textEnd(contentIndex: index, content: block.text, partial: snapshot()))
    }

    private mutating func endThinking(emit: (AssistantMessageEvent) -> Void) {
        guard let index = thinkingIndex, case .thinking(let block) = blocks[index] else { return }
        thinkingIndex = nil
        emit(.thinkingEnd(contentIndex: index, content: block.thinking, partial: snapshot()))
    }

    private mutating func endTool(emit: (AssistantMessageEvent) -> Void) {
        guard let current = tool, case .toolCall(var call) = blocks[current.index] else { return }
        tool = nil
        call.arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(current.arguments.utf8))) ?? .object([:])
        blocks[current.index] = .toolCall(call)
        emit(.toolCallEnd(contentIndex: current.index, toolCall: call, partial: snapshot()))
    }

    // MARK: - Outcome

    /// Says what the thinking parser held back and closes the open blocks.
    /// A reply that broke off is closed too, as magpie's `decodeKiro` flushes
    /// before it reports the error, so text already received is not lost.
    mutating func close(emit: (AssistantMessageEvent) -> Void) {
        say(think.end(), emit: emit)
        endText(emit: emit)
        endThinking(emit: emit)
        endTool(emit: emit)
    }

    /// The reply has ended whole: says what was held back, closes its blocks
    /// and settles its usage and stop reason.
    mutating func finish(emit: (AssistantMessageEvent) -> Void) -> AssistantMessage {
        close(emit: emit)
        if usage.input == 0, contextPercentage > 0, model.contextWindow > 0 {
            // Kiro says how full the context is rather than how many tokens.
            usage.input = Int(contextPercentage / 100 * Double(model.contextWindow))
        }
        if usage.output == 0 { usage.output = (said + 3) / 4 }
        usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite
        if toolCount == 0, stop.uppercased() == "CONTENT_FILTERED" {
            return failed(ProviderFailure(
                message: "Kiro: the reply was filtered (CONTENT_FILTERED)", rawStopReason: "content_filtered"
            ))
        }
        return snapshot()
    }

    func snapshot() -> AssistantMessage {
        var stopReason = StopReason.stop
        if toolCount > 0 {
            stopReason = .toolUse
        } else if stop.uppercased() == "MAX_TOKENS" {
            stopReason = .length
        }
        var usage = usage
        usage.cost = calculateCost(model: model, usage: usage)
        return AssistantMessage(
            content: blocks, api: api, provider: model.provider, model: model.id,
            usage: usage, stopReason: stopReason, timestamp: Timestamp.now()
        )
    }

    func aborted() -> AssistantMessage {
        var message = snapshot()
        message.stopReason = .aborted
        message.errorMessage = "Request was aborted"
        return message
    }

    func failed(_ failure: ProviderFailure) -> AssistantMessage {
        var message = snapshot()
        message.stopReason = .error
        message.errorMessage = failure.message
        message.failure = failure
        return message
    }
}
