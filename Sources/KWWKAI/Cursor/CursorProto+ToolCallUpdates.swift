import Foundation

extension CursorProto {
    // MARK: - Interaction-update tool calls

    struct TodoItem {
        var id = ""
        var content = ""
        /// 1=pending, 2=in_progress, 3=completed (proto enum raw values).
        var status: Int32 = 0
    }

    /// A decoded `ToolCall` (the interaction-update variant) — only the two
    /// cases kwwk surfaces: MCP calls and the server-native todo tool.
    enum InteractionToolCall {
        case mcp(McpArgs)
        case todos([TodoItem])
    }

    struct ToolCallUpdate {
        var callId = ""
        var toolCall: InteractionToolCall?
        /// Cumulative JSON-text snapshot of the args so far
        /// (`PartialToolCallUpdate.args_text_delta`).
        var argsTextSnapshot = ""
    }

    /// Decode `ToolCallStartedUpdate` / `ToolCallCompletedUpdate
    /// { call_id=1, tool_call=2 }` or `PartialToolCallUpdate { call_id=1,
    /// tool_call=2, args_text_delta=3 }`.
    static func decodeToolCallUpdate(_ data: Data) -> ToolCallUpdate {
        var update = ToolCallUpdate()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: update.callId = f.value.asString ?? ""
            case 2:
                guard let bytes = f.value.asData else { break }
                update.toolCall = decodeInteractionToolCall(bytes)
            case 3: update.argsTextSnapshot = f.value.asString ?? ""
            default: break
            }
        }
        return update
    }

    /// `ToolCall { update_todos_tool_call=9: UpdateTodosToolCall { args=1:
    /// UpdateTodosArgs { todos=1 } }, mcp_tool_call=15: McpToolCall { args=1:
    /// McpArgs } }` — every other native tool case is ignored (those arrive via
    /// the exec channel instead).
    private static func decodeInteractionToolCall(_ data: Data) -> InteractionToolCall? {
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 15:
                guard let call = f.value.asData,
                      let args = firstSubmessage(call, number: 1) else { break }
                return .mcp(decodeMcpArgs(args))
            case 9:
                guard let call = f.value.asData,
                      let args = firstSubmessage(call, number: 1) else { break }
                var todos: [TodoItem] = []
                var a = ProtoReader(args)
                while let tf = a.next() {
                    guard tf.number == 1, let bytes = tf.value.asData else { continue }
                    var todo = TodoItem()
                    var t = ProtoReader(bytes)
                    while let field = t.next() {
                        switch field.number {
                        case 1: todo.id = field.value.asString ?? ""
                        case 2: todo.content = field.value.asString ?? ""
                        case 3: todo.status = field.value.asInt32 ?? 0
                        default: break
                        }
                    }
                    todos.append(todo)
                }
                return .todos(todos)
            default:
                break
            }
        }
        return nil
    }

    private static func firstSubmessage(_ data: Data, number: Int) -> Data? {
        var reader = ProtoReader(data)
        while let f = reader.next() {
            if f.number == number { return f.value.asData }
        }
        return nil
    }
}
