import Foundation

extension CursorProto {
    // MARK: Exec result payloads

    /// `RequestContextResult { success=1: RequestContextSuccess { request_context=1:
    /// RequestContext { rules=2, env=4, tools=7(repeated McpToolDefinition) } } }`.
    /// `workspacePath` populates `RequestContextEnv { os_version=1,
    /// workspace_paths=2, shell=3, time_zone=10 }` — the server-side harness
    /// takes its authoritative cwd from here, not from the system prompt text.
    /// The system prompt also rides as a global user rule
    /// (`CursorRule { full_path=1, content=2, type=3 { global=1 }, source=4 }`):
    /// Cursor's harness builds its own system prompt and only reliably
    /// surfaces client instructions through rules (as omp does).
    static func encodeRequestContextResult(
        toolDefs: [Data], systemPrompt: String? = nil, workspacePath: String?,
        osVersion: String, shell: String, timeZone: String
    ) -> Data {
        var requestContext = ProtoWriter()
        if let systemPrompt, !systemPrompt.isEmpty {
            requestContext.messageField(2) { rule in
                rule.stringField(1, "/kwwk/system-prompt.mdc")
                rule.stringField(2, systemPrompt)
                rule.messageField(3) { type in type.messageField(1) { _ in } }
                rule.int32Field(4, 2) // CURSOR_RULE_SOURCE_USER
            }
        }
        if let workspacePath, !workspacePath.isEmpty {
            requestContext.messageField(4) { env in
                env.stringField(1, osVersion)
                env.stringField(2, workspacePath)
                env.stringField(3, shell)
                env.stringField(10, timeZone)
            }
        }
        for def in toolDefs { requestContext.bytesField(7, def) }
        var success = ProtoWriter()
        success.bytesField(1, requestContext.data)
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `McpStateExecResult { success=1: McpStateSuccess { servers=1:
    /// McpStateServer { server_name=1, server_identifier=2, tools=5,
    /// status=7 } } }`. Cursor's server loads MCP tools lazily: the model sees
    /// only tool names until its `GetMcpTools` call makes the server ask the
    /// client for the full definitions through this exec. kwwk hosts no MCP
    /// servers of its own — every advertised tool sits under one synthetic
    /// server, `providerIdentifier`, reported as connected. `serverIdentifiers`
    /// filters the answer when the server asks about specific servers; the
    /// success case is set even when nothing matches, since an unset oneof
    /// reads as a malformed reply.
    static func encodeMcpStateResult(
        toolDefs: [Data], providerIdentifier: String, serverIdentifiers: [String]
    ) -> Data {
        var success = ProtoWriter()
        let wanted = serverIdentifiers.isEmpty || serverIdentifiers.contains(providerIdentifier)
        if wanted, !toolDefs.isEmpty {
            success.messageField(1) { server in
                server.stringField(1, providerIdentifier)
                server.stringField(2, providerIdentifier)
                for def in toolDefs { server.bytesField(5, def) }
                server.stringField(7, "connected")
            }
        }
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `McpStateExecArgs { server_identifiers=1 (repeated), kick_only=2 }` →
    /// the requested server identifiers (empty means all).
    static func decodeMcpStateServerIdentifiers(_ data: Data) -> [String] {
        var out: [String] = []
        var reader = ProtoReader(data)
        while let f = reader.next() {
            if f.number == 1, let id = f.value.asString { out.append(id) }
        }
        return out
    }

    /// One MCP tool-result content item: text or image.
    enum McpContent {
        case text(String)
        case image(base64: String, mimeType: String)
    }

    /// `McpResult { success=1: McpSuccess { content=1(repeated), is_error=2 } }`.
    static func encodeMcpSuccess(content: [McpContent], isError: Bool) -> Data {
        var success = ProtoWriter()
        for item in content {
            success.messageField(1) { ci in
                switch item {
                case .text(let t):
                    ci.messageField(1) { tc in tc.stringField(1, t) }
                case .image(let b64, let mime):
                    ci.messageField(2) { ic in
                        if let data = Data(base64Encoded: b64) { ic.bytesField(1, data) }
                        ic.stringField(2, mime)
                    }
                }
            }
        }
        if isError { success.boolField(2, true) }
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `McpResult { error=2: McpError { error=1 } }`.
    static func encodeMcpError(_ message: String) -> Data {
        var err = ProtoWriter()
        err.stringField(1, message)
        var result = ProtoWriter()
        result.bytesField(2, err.data)
        return result.data
    }

    /// `McpResult { tool_not_found=5: McpToolNotFound { name=1 } }`.
    static func encodeMcpToolNotFound(name: String) -> Data {
        var nf = ProtoWriter()
        nf.stringField(1, name)
        var result = ProtoWriter()
        result.bytesField(5, nf.data)
        return result.data
    }

    /// Encode a `*Rejected { path/command=…, reason=… }` result for a native
    /// Cursor tool that kwwk does not execute locally. `pathField`/`reasonField`
    /// give the field numbers inside the specific Rejected message, and
    /// `resultField` gives the `rejected` case number inside the *Result oneof.
    static func encodeRejectedPathResult(
        resultField: Int, path: String, reason: String
    ) -> Data {
        var rejected = ProtoWriter()
        rejected.stringField(1, path)
        rejected.stringField(2, reason)
        var result = ProtoWriter()
        result.bytesField(resultField, rejected.data)
        return result.data
    }

    /// `ShellResult { rejected=4: ShellRejected { command=1, working_directory=2,
    /// reason=3, is_readonly=4 } }`.
    static func encodeShellRejected(command: String, workingDirectory: String, reason: String) -> Data {
        var rejected = ProtoWriter()
        rejected.stringField(1, command)
        rejected.stringField(2, workingDirectory)
        rejected.stringField(3, reason)
        var result = ProtoWriter()
        result.bytesField(4, rejected.data)
        return result.data
    }

    /// `GrepResult { error=2: GrepError { error=1 } }`.
    static func encodeGrepError(_ message: String) -> Data {
        var err = ProtoWriter()
        err.stringField(1, message)
        var result = ProtoWriter()
        result.bytesField(2, err.data)
        return result.data
    }

    /// `FetchResult { error=2: FetchError { url=1, error=2 } }`.
    static func encodeFetchError(url: String, message: String) -> Data {
        var err = ProtoWriter()
        err.stringField(1, url)
        err.stringField(2, message)
        var result = ProtoWriter()
        result.bytesField(2, err.data)
        return result.data
    }

    // MARK: - Exec success results (client → server)

    /// `ReadResult { success=1: ReadSuccess { path=1, content=2, total_lines=3,
    /// file_size=4, truncated=6 } }`.
    static func encodeReadSuccess(path: String, content: String) -> Data {
        var success = ProtoWriter()
        success.stringField(1, path)
        success.stringField(2, content)
        success.int32Field(3, Int32(content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count))
        success.varintField(4, UInt64(content.utf8.count))
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `ReadResult { error=2: ReadError { path=1, error=2 } }` — the same shape
    /// serves `WriteError(5)`, `LsError(2)`, `DeleteError(7)`,
    /// `DiagnosticsError(2)`: `{ path=1, error=2 }` under `resultField`.
    static func encodePathError(resultField: Int, path: String, error: String) -> Data {
        var err = ProtoWriter()
        err.stringField(1, path)
        err.stringField(2, error)
        var result = ProtoWriter()
        result.bytesField(resultField, err.data)
        return result.data
    }

    /// `WriteResult { success=1: WriteSuccess { path=1, lines_created=2,
    /// file_size=3 } }`.
    static func encodeWriteSuccess(path: String, fileText: String, byteCount: Int) -> Data {
        var success = ProtoWriter()
        success.stringField(1, path)
        success.int32Field(2, Int32(fileText.isEmpty ? 0 : fileText.split(separator: "\n", omittingEmptySubsequences: false).count))
        success.int32Field(3, Int32(byteCount))
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `ShellResult { success=1: ShellSuccess { command=1, working_directory=2,
    /// exit_code=3, stdout=5 } }`.
    static func encodeShellSuccess(command: String, workingDirectory: String, stdout: String) -> Data {
        var success = ProtoWriter()
        success.stringField(1, command)
        success.stringField(2, workingDirectory)
        success.stringField(5, stdout)
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `ShellResult { failure=2: ShellFailure { command=1, working_directory=2,
    /// exit_code=3, stderr=6 } }`.
    static func encodeShellFailure(command: String, workingDirectory: String, error: String) -> Data {
        var failure = ProtoWriter()
        failure.stringField(1, command)
        failure.stringField(2, workingDirectory)
        failure.int32Field(3, 1)
        failure.stringField(6, error)
        var result = ProtoWriter()
        result.bytesField(2, failure.data)
        return result.data
    }

    /// `LsResult { success=1: LsSuccess { directory_tree_root=1 } }` from the
    /// text listing of kwwk's `ls` tool: `dir/`-suffixed entries become child
    /// dirs, everything else child files.
    static func encodeLsSuccess(path: String, listing: String) -> Data {
        let rootPath = path.isEmpty ? "." : path
        let entries = listing
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }

        var root = ProtoWriter()
        root.stringField(1, rootPath)
        var fileCount = 0
        for entry in entries {
            // `split` with a multi-character separator is the Collection
            // overload, which is iOS 16+. components(separatedBy:) has been
            // there since iOS 2 and gives the same answer: skipping the empty
            // leading component is what omittingEmptySubsequences does, and an
            // entry that is nothing but separators falls back to itself.
            let name = entry.components(separatedBy: " (").first { !$0.isEmpty } ?? entry
            if name.hasSuffix("/") {
                root.messageField(2) { dir in
                    let dirName = String(name.dropLast())
                    dir.stringField(1, "\(rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath)/\(dirName)")
                }
            } else {
                root.messageField(3) { file in file.stringField(1, name) }
                fileCount += 1
            }
        }
        root.boolField(4, true)
        root.varintField(6, UInt64(fileCount))

        var success = ProtoWriter()
        success.bytesField(1, root.data)
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }

    /// `GrepResult { success=1: GrepSuccess { pattern=1, path=2, output_mode=3,
    /// workspace_results=4(map) } }` with the match text folded into a single
    /// content-mode `GrepFileMatch` per file parsed from `path:line:text`
    /// output lines.
    static func encodeGrepSuccess(pattern: String, path: String, output: String) -> Data {
        struct Match {
            var line: Int32
            var content: String
        }
        var byFile: [(file: String, matches: [Match])] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.hasPrefix("["), !line.lowercased().hasPrefix("no matches") else { continue }
            // Parse `file:line:content`; anything else attaches to a "" file.
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            var file = ""
            var lineNumber: Int32 = 0
            var content = line
            if parts.count == 3, let n = Int32(parts[1]) {
                file = String(parts[0])
                lineNumber = n
                content = String(parts[2])
            }
            if let idx = byFile.firstIndex(where: { $0.file == file }) {
                byFile[idx].matches.append(Match(line: lineNumber, content: content))
            } else {
                byFile.append((file, [Match(line: lineNumber, content: content)]))
            }
        }

        // GrepUnionResult { content=3: GrepContentResult { matches=1, total_lines=2, total_matched_lines=3 } }
        var contentResult = ProtoWriter()
        var total = 0
        for entry in byFile {
            contentResult.messageField(1) { fm in
                fm.stringField(1, entry.file)
                for match in entry.matches {
                    fm.messageField(2) { cm in
                        cm.int32Field(1, match.line)
                        cm.stringField(2, match.content)
                    }
                }
            }
            total += entry.matches.count
        }
        contentResult.int32Field(2, Int32(total))
        contentResult.int32Field(3, Int32(total))
        var union = ProtoWriter()
        union.bytesField(3, contentResult.data)

        var success = ProtoWriter()
        success.stringField(1, pattern)
        success.stringField(2, path)
        success.stringField(3, "content")
        // workspace_results map entry { key=1, value=2 }
        success.messageField(4) { entry in
            entry.stringField(1, path.isEmpty ? "." : path)
            entry.bytesField(2, union.data)
        }
        var result = ProtoWriter()
        result.bytesField(1, success.data)
        return result.data
    }
}
