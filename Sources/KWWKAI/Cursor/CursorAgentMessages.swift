import Foundation

/// Typed encoders/decoders for the subset of Cursor's `agent.v1` protobuf
/// schema that the chat transport needs. Field numbers are taken verbatim from
/// `agent.proto` (mirrored from oh-my-pi's bundled schema). Only the messages
/// kwwk sends or reads are modeled; everything else is skipped on decode.
enum CursorProto {

    // MARK: - Encoders (client → server)

    /// `McpToolDefinition { name=1, description=2, input_schema=3(bytes),
    /// provider_identifier=4, tool_name=5 }`. `inputSchema` carries the tool's
    /// JSON schema encoded as a `google.protobuf.Value`.
    static func encodeMcpToolDefinition(
        name: String,
        description: String,
        providerIdentifier: String,
        toolName: String,
        inputSchema: Data
    ) -> Data {
        var w = ProtoWriter()
        w.stringField(1, name)
        if !description.isEmpty { w.stringField(2, description) }
        if !inputSchema.isEmpty { w.bytesField(3, inputSchema) }
        w.stringField(4, providerIdentifier)
        w.stringField(5, toolName)
        return w.data
    }

    /// One image attached to a user message.
    struct UserImage {
        var uuid: String
        var mimeType: String
        var data: Data
    }

    /// `UserMessage { text=1, message_id=2, selected_context=3 }`. Images ride
    /// in `SelectedContext { selected_images=1: SelectedImage { uuid=2,
    /// mime_type=7, data=8 } }`.
    static func encodeUserMessage(text: String, messageId: String, images: [UserImage] = []) -> Data {
        var w = ProtoWriter()
        w.stringField(1, text)
        w.stringField(2, messageId)
        if !images.isEmpty {
            w.messageField(3) { ctx in
                for image in images {
                    ctx.messageField(1) { img in
                        img.stringField(2, image.uuid)
                        img.stringField(7, image.mimeType)
                        img.bytesField(8, image.data)
                    }
                }
            }
        }
        return w.data
    }

    /// `ConversationStep { assistant_message=1: AssistantMessage{ text=1 } }`.
    static func encodeAssistantStep(text: String) -> Data {
        var w = ProtoWriter()
        w.messageField(1) { m in m.stringField(1, text) }
        return w.data
    }

    /// `ConversationTurnStructure { agent_conversation_turn=1:
    /// AgentConversationTurnStructure{ user_message=1(bytes), steps=2(repeated bytes) } }`.
    static func encodeAgentTurn(userMessage: Data, steps: [Data]) -> Data {
        var w = ProtoWriter()
        w.messageField(1) { turn in
            turn.bytesField(1, userMessage)
            for step in steps { turn.bytesField(2, step) }
        }
        return w.data
    }

    /// `ConversationStateStructure { root_prompt_messages_json=1(repeated bytes),
    /// turns=8(repeated bytes) }`. When `preserving` carries the server's last
    /// checkpoint for this conversation, every field except 1 and 8 is copied
    /// through verbatim so server-maintained state (todos, file states, summary
    /// archives, subagent state, …) survives into the next request. The history
    /// fields are always rebuilt fresh — the server's echoed checkpoint replaces
    /// historical user entries with empty placeholders.
    static func encodeConversationState(
        rootPromptIds: [Data],
        turns: [Data],
        preserving checkpoint: Data? = nil
    ) -> Data {
        var w = ProtoWriter()
        for id in rootPromptIds { w.bytesField(1, id) }
        for turn in turns { w.bytesField(8, turn) }
        if let checkpoint {
            var reader = ProtoReader(checkpoint)
            while let field = reader.next() {
                guard field.number != 1, field.number != 8 else { continue }
                w.copyField(field)
            }
        }
        return w.data
    }

    /// The `root_prompt_messages_json` (field 1) entries of an encoded
    /// `ConversationStateStructure`, used to decide whether a cached checkpoint
    /// still matches the current system prompt.
    static func rootPromptIds(ofState data: Data) -> [Data] {
        var ids: [Data] = []
        var reader = ProtoReader(data)
        while let field = reader.next() {
            if field.number == 1, let bytes = field.value.asData { ids.append(bytes) }
        }
        return ids
    }

    /// The `ConversationAction` driving this run: a fresh user message, or a
    /// resume (continue the turn without new user input, e.g. after trailing
    /// tool results).
    enum RunAction {
        case userMessage(Data)
        case resume
    }

    /// Full `AgentClientMessage { run_request=1 }` carrying an
    /// `AgentRunRequest { conversation_state=1, action=2, model_details=3,
    /// conversation_id=5 }`. `action` is a `ConversationAction
    /// { user_message_action=1 | resume_action=2 }`.
    static func encodeRunRequestMessage(
        conversationState: Data,
        action runAction: RunAction,
        modelId: String,
        modelName: String,
        conversationId: String,
        customSystemPrompt: String?
    ) -> Data {
        var action = ProtoWriter()
        switch runAction {
        case .userMessage(let userMessage):
            // ConversationAction { user_message_action=1: UserMessageAction { user_message=1 } }
            action.messageField(1) { uma in
                uma.bytesField(1, userMessage)
            }
        case .resume:
            // ConversationAction { resume_action=2: ResumeAction {} }
            action.messageField(2) { _ in }
        }

        // ModelDetails { model_id=1, display_model_id=3, display_name=4 }
        var modelDetails = ProtoWriter()
        modelDetails.stringField(1, modelId)
        modelDetails.stringField(3, modelId)
        modelDetails.stringField(4, modelName.isEmpty ? modelId : modelName)

        // AgentRunRequest
        var run = ProtoWriter()
        run.bytesField(1, conversationState)
        run.bytesField(2, action.data)
        run.bytesField(3, modelDetails.data)
        run.stringField(5, conversationId)
        if let sys = customSystemPrompt, !sys.isEmpty { run.stringField(8, sys) }

        var msg = ProtoWriter()
        msg.bytesField(1, run.data)
        return msg.data
    }

    /// `AgentClientMessage { client_heartbeat=7: ClientHeartbeat{} }`.
    static func encodeHeartbeat() -> Data {
        var w = ProtoWriter()
        w.messageField(7) { _ in }
        return w.data
    }

    /// `AgentClientMessage { kv_client_message=3: KvClientMessage { id=1,
    /// get_blob_result=2: GetBlobResult{ blob_data=1(optional bytes) } } }`.
    static func encodeGetBlobResult(id: UInt32, blobData: Data?) -> Data {
        var kv = ProtoWriter()
        kv.uint32Field(1, id)
        kv.messageField(2) { r in
            if let blobData, !blobData.isEmpty { r.bytesField(1, blobData) }
        }
        var w = ProtoWriter()
        w.bytesField(3, kv.data)
        return w.data
    }

    /// `AgentClientMessage { kv_client_message=3: KvClientMessage { id=1,
    /// set_blob_result=3: SetBlobResult{} } }`.
    static func encodeSetBlobResult(id: UInt32) -> Data {
        var kv = ProtoWriter()
        kv.uint32Field(1, id)
        kv.messageField(3) { _ in }
        var w = ProtoWriter()
        w.bytesField(3, kv.data)
        return w.data
    }

    /// Wrap a pre-encoded exec-result payload as an
    /// `AgentClientMessage { exec_client_message=2: ExecClientMessage { id=1,
    /// exec_id=15, <resultField>=payload } }`.
    static func encodeExecClientMessage(
        id: UInt32,
        execId: String,
        resultField: Int,
        payload: Data
    ) -> Data {
        var exec = ProtoWriter()
        exec.uint32Field(1, id)
        if !execId.isEmpty { exec.stringField(15, execId) }
        exec.bytesField(resultField, payload)
        var w = ProtoWriter()
        w.bytesField(2, exec.data)
        return w.data
    }

    /// `AgentClientMessage { exec_client_control_message=5:
    /// ExecClientControlMessage { throw=2: ExecClientThrow { id=1, error=2,
    /// error_code=4 } } }` — the protocol's failure channel for an exec the
    /// client cannot answer at all. Cursor's own executor sends this (then a
    /// stream close) for a frame no handler claims, and the server surfaces
    /// the error to the model. An `ExecClientMessage` with no result set is
    /// not an answer: the server keeps waiting on it.
    static func encodeExecThrow(id: UInt32, error: String, errorCode: String) -> Data {
        var thrown = ProtoWriter()
        thrown.uint32Field(1, id)
        thrown.stringField(2, error)
        thrown.stringField(4, errorCode)
        var ctrl = ProtoWriter()
        ctrl.bytesField(2, thrown.data)
        var w = ProtoWriter()
        w.bytesField(5, ctrl.data)
        return w.data
    }

    /// `AgentClientMessage { exec_client_control_message=5:
    /// ExecClientControlMessage { stream_close=1: ExecClientStreamClose{ id=1 } } }`.
    static func encodeExecStreamClose(id: UInt32) -> Data {
        var ctrl = ProtoWriter()
        ctrl.messageField(1) { c in c.uint32Field(1, id) }
        var w = ProtoWriter()
        w.bytesField(5, ctrl.data)
        return w.data
    }
}
