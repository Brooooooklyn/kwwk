import Foundation

extension FauxProvider {
    // MARK: Streaming

    static func streamDeltasImmediately(
        to stream: AssistantMessageStream,
        message: AssistantMessage,
        minTokenSize: Int,
        maxTokenSize: Int,
        cancellation: CancellationHandle?
    ) {
        var partial = message
        partial.content = []

        if cancellation?.isCancelled == true {
            let aborted = abortedMessage(from: partial)
            stream.push(.error(reason: .aborted, error: aborted))
            stream.end(aborted)
            return
        }

        stream.push(.start(partial: partial))

        for (index, block) in message.content.enumerated() {
            if cancellation?.isCancelled == true {
                let aborted = abortedMessage(from: partial)
                stream.push(.error(reason: .aborted, error: aborted))
                stream.end(aborted)
                return
            }
            switch block {
            case .fallback:
                partial.content.append(block)
            case .thinking(let t):
                partial.content.append(.thinking(ThinkingContent(thinking: "")))
                stream.push(.thinkingStart(contentIndex: index, partial: partial))
                for chunk in splitByTokenSize(t.thinking, min: minTokenSize, max: maxTokenSize) {
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    if case .thinking(var current) = partial.content[index] {
                        current.thinking += chunk
                        partial.content[index] = .thinking(current)
                    }
                    stream.push(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.thinkingEnd(contentIndex: index, content: t.thinking, partial: partial))

            case .text(let t):
                partial.content.append(.text(TextContent(text: "")))
                stream.push(.textStart(contentIndex: index, partial: partial))
                for chunk in splitByTokenSize(t.text, min: minTokenSize, max: maxTokenSize) {
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    if case .text(var current) = partial.content[index] {
                        current.text += chunk
                        partial.content[index] = .text(current)
                    }
                    stream.push(.textDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.textEnd(contentIndex: index, content: t.text, partial: partial))

            case .toolCall(let call):
                partial.content.append(.toolCall(ToolCall(id: call.id, name: call.name, arguments: .object([:]))))
                stream.push(.toolCallStart(contentIndex: index, partial: partial))
                let argsJSON = (try? JSONValueEncoder.encode(call.arguments)) ?? "{}"
                for chunk in splitByTokenSize(argsJSON, min: minTokenSize, max: maxTokenSize) {
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    stream.push(.toolCallDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                partial.content[index] = .toolCall(call)
                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: partial))
            }
        }

        if message.stopReason == .error || message.stopReason == .aborted {
            stream.push(.error(reason: message.stopReason, error: message))
            stream.end(message)
            return
        }
        stream.push(.done(reason: message.stopReason, message: message))
        stream.end(message)
    }

    static func streamDeltas(
        to stream: AssistantMessageStream,
        message: AssistantMessage,
        minTokenSize: Int,
        maxTokenSize: Int,
        tokensPerSecond: Double?,
        cancellation: CancellationHandle?
    ) async {
        var partial = message
        partial.content = []

        if cancellation?.isCancelled == true {
            let aborted = abortedMessage(from: partial)
            stream.push(.error(reason: .aborted, error: aborted))
            stream.end(aborted)
            return
        }

        stream.push(.start(partial: partial))

        for (index, block) in message.content.enumerated() {
            if cancellation?.isCancelled == true {
                let aborted = abortedMessage(from: partial)
                stream.push(.error(reason: .aborted, error: aborted))
                stream.end(aborted)
                return
            }
            switch block {
            case .fallback:
                partial.content.append(block)
            case .thinking(let t):
                partial.content.append(.thinking(ThinkingContent(thinking: "")))
                stream.push(.thinkingStart(contentIndex: index, partial: partial))
                for chunk in splitByTokenSize(t.thinking, min: minTokenSize, max: maxTokenSize) {
                    await scheduleChunk(chunk, tokensPerSecond: tokensPerSecond)
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    if case .thinking(var current) = partial.content[index] {
                        current.thinking += chunk
                        partial.content[index] = .thinking(current)
                    }
                    stream.push(.thinkingDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.thinkingEnd(contentIndex: index, content: t.thinking, partial: partial))

            case .text(let t):
                partial.content.append(.text(TextContent(text: "")))
                stream.push(.textStart(contentIndex: index, partial: partial))
                for chunk in splitByTokenSize(t.text, min: minTokenSize, max: maxTokenSize) {
                    await scheduleChunk(chunk, tokensPerSecond: tokensPerSecond)
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    if case .text(var current) = partial.content[index] {
                        current.text += chunk
                        partial.content[index] = .text(current)
                    }
                    stream.push(.textDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                stream.push(.textEnd(contentIndex: index, content: t.text, partial: partial))

            case .toolCall(let call):
                partial.content.append(.toolCall(ToolCall(id: call.id, name: call.name, arguments: .object([:]))))
                stream.push(.toolCallStart(contentIndex: index, partial: partial))
                let argsJSON = (try? JSONValueEncoder.encode(call.arguments)) ?? "{}"
                for chunk in splitByTokenSize(argsJSON, min: minTokenSize, max: maxTokenSize) {
                    await scheduleChunk(chunk, tokensPerSecond: tokensPerSecond)
                    if cancellation?.isCancelled == true {
                        let aborted = abortedMessage(from: partial)
                        stream.push(.error(reason: .aborted, error: aborted))
                        stream.end(aborted)
                        return
                    }
                    stream.push(.toolCallDelta(contentIndex: index, delta: chunk, partial: partial))
                }
                partial.content[index] = .toolCall(call)
                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: partial))
            }
        }

        if message.stopReason == .error || message.stopReason == .aborted {
            stream.push(.error(reason: message.stopReason, error: message))
            stream.end(message)
            return
        }
        stream.push(.done(reason: message.stopReason, message: message))
        stream.end(message)
    }

    static func abortedMessage(from partial: AssistantMessage) -> AssistantMessage {
        var m = partial
        m.stopReason = .aborted
        m.errorMessage = "Request was aborted"
        m.timestamp = Timestamp.now()
        return m
    }

    static func splitByTokenSize(_ text: String, min: Int, max: Int) -> [String] {
        guard !text.isEmpty else { return [""] }
        var chunks: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let tokenSize = min + Int.random(in: 0...Swift.max(0, max - min))
            let charSize = Swift.max(1, tokenSize * 4)
            let end = remaining.index(remaining.startIndex, offsetBy: Swift.min(charSize, remaining.count))
            chunks.append(String(remaining[remaining.startIndex..<end]))
            remaining = remaining[end...]
        }
        return chunks.isEmpty ? [""] : chunks
    }

    static func scheduleChunk(_ chunk: String, tokensPerSecond: Double?) async {
        guard let rate = tokensPerSecond, rate > 0 else { return }
        let delayMs = Double(estimateTokens(chunk)) / rate * 1000
        try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
    }
}
