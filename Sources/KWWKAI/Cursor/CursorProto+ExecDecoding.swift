import Foundation

extension CursorProto {
    // MARK: - Exec decoding (server → client)

    /// The typed exec cases kwwk dispatches on. Raw values are the
    /// `ExecServerMessage` oneof field numbers.
    enum ExecCase: Int {
        case shell = 2
        case write = 3
        case delete = 4
        case grep = 5
        case read = 7
        case ls = 8
        case diagnostics = 9
        case requestContext = 10
        case mcp = 11
        case shellStream = 14
        case backgroundShellSpawn = 16
        case listMcpResources = 17
        case readMcpResource = 18
        case mcpState = 36
        case fetch = 20
        case recordScreen = 21
        case computerUse = 22
        case writeShellStdin = 23
    }

    struct ExecMessage {
        var id: UInt32 = 0
        var execId = ""
        var execCase: ExecCase?
        var payload = Data()
    }

    /// Decode `ExecServerMessage { id=1, exec_id=15, span_context=19, oneof }`.
    /// The oneof case is matched against the known field-number set, so an
    /// optional `span_context` (or any future non-oneof field) can never be
    /// mistaken for the exec case.
    static func decodeExecMessage(_ data: Data) -> ExecMessage {
        var msg = ExecMessage()
        var reader = ProtoReader(data)
        while let field = reader.next() {
            switch field.number {
            case 1: if let v = field.value.asUInt64 { msg.id = UInt32(truncatingIfNeeded: v) }
            case 15: msg.execId = field.value.asString ?? ""
            default:
                if let execCase = ExecCase(rawValue: field.number), let payload = field.value.asData {
                    msg.execCase = execCase
                    msg.payload = payload
                }
            }
        }
        return msg
    }

    struct ShellArgs {
        var command = ""
        var workingDirectory = ""
        var timeout: Int32 = 0
        var toolCallId = ""
    }

    /// `ShellArgs { command=1, working_directory=2, timeout=3, tool_call_id=4 }`.
    static func decodeShellArgs(_ data: Data) -> ShellArgs {
        var args = ShellArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: args.command = f.value.asString ?? ""
            case 2: args.workingDirectory = f.value.asString ?? ""
            case 3: args.timeout = f.value.asInt32 ?? 0
            case 4: args.toolCallId = f.value.asString ?? ""
            default: break
            }
        }
        return args
    }

    struct PathArgs {
        var path = ""
        var toolCallId = ""
    }

    /// `ReadArgs`/`DeleteArgs`/`DiagnosticsArgs { path=1, tool_call_id=2 }` and
    /// `LsArgs { path=1, …, tool_call_id=3 }` — pass the tool_call_id field
    /// number of the specific message.
    static func decodePathArgs(_ data: Data, toolCallIdField: Int = 2) -> PathArgs {
        var args = PathArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            if f.number == 1 { args.path = f.value.asString ?? "" }
            if f.number == toolCallIdField { args.toolCallId = f.value.asString ?? "" }
        }
        return args
    }

    struct GrepArgs {
        var pattern = ""
        var path = ""
        var glob = ""
        var outputMode = ""
        var caseInsensitive = false
        var toolCallId = ""
    }

    /// `GrepArgs { pattern=1, path=2, glob=3, output_mode=4, case_insensitive=8,
    /// tool_call_id=11 }`.
    static func decodeGrepArgs(_ data: Data) -> GrepArgs {
        var args = GrepArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: args.pattern = f.value.asString ?? ""
            case 2: args.path = f.value.asString ?? ""
            case 3: args.glob = f.value.asString ?? ""
            case 4: args.outputMode = f.value.asString ?? ""
            case 8: args.caseInsensitive = f.value.asBool ?? false
            case 11: args.toolCallId = f.value.asString ?? ""
            default: break
            }
        }
        return args
    }

    struct WriteArgs {
        var path = ""
        var fileText = ""
        var fileBytes = Data()
        var returnFileContentAfterWrite = false
        var toolCallId = ""
    }

    /// `WriteArgs { path=1, file_text=2, tool_call_id=3,
    /// return_file_content_after_write=4, file_bytes=5 }`.
    static func decodeWriteArgs(_ data: Data) -> WriteArgs {
        var args = WriteArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: args.path = f.value.asString ?? ""
            case 2: args.fileText = f.value.asString ?? ""
            case 3: args.toolCallId = f.value.asString ?? ""
            case 4: args.returnFileContentAfterWrite = f.value.asBool ?? false
            case 5:
                if let fileBytes = f.value.asData {
                    args.fileBytes = fileBytes
                }
            default: break
            }
        }
        return args
    }

    struct McpArgs {
        var name = ""
        var toolName = ""
        var toolCallId = ""
        var providerIdentifier = ""
        /// Raw map values; each is a protobuf-encoded `google.protobuf.Value`
        /// (with raw JSON text as a legacy fallback shape).
        var rawArgs: [String: Data] = [:]

        var arguments: JSONValue {
            var out: [String: JSONValue] = [:]
            for (key, bytes) in rawArgs {
                out[key] = CursorProto.decodeMcpArgValue(bytes)
            }
            return .object(out)
        }
    }

    /// Decode one `McpArgs.args` map value, mirroring oh-my-pi's
    /// `decodeMcpArgValue`: the bytes are a protobuf `google.protobuf.Value`;
    /// a Value that holds a string may itself be JSON text (double-encoded), so
    /// a string that opens like a JSON object, array or string gets one more
    /// parse attempt. Any other string stays a string — reparsing it turned
    /// `"12"` into the integer 12 and failed string-typed schemas. Bytes that
    /// don't decode as a Value fall back to JSON text, then to a bare string.
    static func decodeMcpArgValue(_ bytes: Data) -> JSONValue {
        if let value = decodeProtoValue(bytes) {
            if case .string(let s) = value,
               let first = s.first(where: { !$0.isWhitespace }), "{[\"".contains(first) {
                return decodeLooseJSON(Data(s.utf8))
            }
            return value
        }
        return decodeLooseJSON(bytes)
    }

    /// `McpArgs { name=1, args=2(map<string,bytes>), tool_call_id=3,
    /// provider_identifier=4, tool_name=5 }`.
    static func decodeMcpArgs(_ data: Data) -> McpArgs {
        var args = McpArgs()
        var reader = ProtoReader(data)
        while let f = reader.next() {
            switch f.number {
            case 1: args.name = f.value.asString ?? ""
            case 2:
                guard let entry = f.value.asData else { break }
                var e = ProtoReader(entry)
                var key = ""
                var value = Data()
                while let ef = e.next() {
                    if ef.number == 1 { key = ef.value.asString ?? "" }
                    if ef.number == 2 { value = ef.value.asData ?? Data() }
                }
                if !key.isEmpty { args.rawArgs[key] = value }
            case 3: args.toolCallId = f.value.asString ?? ""
            case 4: args.providerIdentifier = f.value.asString ?? ""
            case 5: args.toolName = f.value.asString ?? ""
            default: break
            }
        }
        return args
    }

    /// Parse bytes as JSON; fall back to treating them as a bare string.
    static func decodeLooseJSON(_ bytes: Data) -> JSONValue {
        if let decoded = try? JSONDecoder().decode(JSONValue.self, from: bytes) {
            return decoded
        }
        return .string(String(data: bytes, encoding: .utf8) ?? "")
    }
}
