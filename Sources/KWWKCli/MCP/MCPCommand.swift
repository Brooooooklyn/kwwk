import ArgumentParser
import Foundation
import KWWKAI
import KWWKMCP

extension KWWK {
    /// `kwwk mcp …`: manage MCP servers without editing `mcp.json` by hand.
    /// Returns the process exit code.
    public static func runMCPCommand(_ arguments: [String]) async -> Int32 {
        await MCPCommand.run(
            arguments,
            cwd: FileManager.default.currentDirectoryPath,
            homeDirectory: cliHomeDirectory(),
            environment: ProcessInfo.processInfo.environment,
            io: .standard
        )
    }
}

/// Where `kwwk mcp` writes its output.
struct MCPCommandIO: Sendable {
    var out: @Sendable (String) -> Void
    var err: @Sendable (String) -> Void

    static let standard = MCPCommandIO(
        out: { print($0) },
        err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    )
}

/// The servers of one `mcp.json` file, edited in place. Other top-level
/// keys and other servers are kept as they are.
struct MCPConfigEditor {
    let url: URL
    let scope: MCPConfigScope

    func root() throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let object) = value else {
            throw MCPConfigFile.ConfigError(message: "\(url.path) is not a JSON object")
        }
        return object
    }

    func servers() throws -> [String: JSONValue] {
        guard case .object(let servers)? = try root()["mcpServers"] else { return [:] }
        return servers
    }

    func set(_ name: String, _ entry: JSONValue) throws {
        var root = try root()
        var servers = try self.servers()
        servers[name] = entry
        root["mcpServers"] = .object(servers)
        try write(root)
    }

    @discardableResult
    func remove(_ name: String) throws -> Bool {
        var root = try root()
        var servers = try self.servers()
        guard servers.removeValue(forKey: name) != nil else { return false }
        root["mcpServers"] = .object(servers)
        try write(root)
        return true
    }

    private func write(_ root: [String: JSONValue]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(root))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        // The user file may hold tokens in headers or env; the project file
        // is meant to be shared.
        if scope == .user {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

enum MCPCommand {
    /// `kwwk mcp`'s command tree. Declarations only: `run` parses one and
    /// hands it to `Context`.
    struct Root: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "kwwk mcp",
            abstract: "Manage MCP servers.",
            subcommands: [Add.self, AddJSON.self, List.self, Get.self, Remove.self, Login.self, Logout.self]
        )
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a Streamable HTTP server (<name> <url>) or a stdio server (<name> -- <command> [args...])."
        )

        @Option(name: .shortAndLong, help: "stdio or http (default: http for a URL, else stdio).")
        var transport: String?

        @Option(name: .shortAndLong, help: scopeHelp, transform: MCPCommand.scope)
        var scope: MCPConfigScope = .user

        @Option(
            name: .shortAndLong,
            help: ArgumentHelp("Environment of a stdio server (repeatable).", valueName: "KEY=value")
        )
        var env: [String] = []

        @Option(
            name: [.customShort("H"), .long],
            help: ArgumentHelp("Header of an HTTP server (repeatable).", valueName: "Name: value")
        )
        var header: [String] = []

        @Option(name: .customLong("description"), help: "One line telling the model what the server offers.")
        var serverDescription: String?

        @Option(help: "Pre-registered OAuth client.")
        var clientId: String?

        @Option(help: "Secret of the pre-registered OAuth client.")
        var clientSecret: String?

        @Option(help: "client_name for dynamic registration.")
        var clientName: String?

        @Option(help: "OAuth scope to request.")
        var oauthScope: String?

        @Option(help: "Fixed OAuth callback port.")
        var callbackPort: Int?

        @Flag(name: .customLong("no-oauth"), help: "Never use OAuth for this server.")
        var noOAuth = false

        @Argument(help: "Server name.")
        var name: String

        @Argument(help: "The server's URL, or after -- a stdio server's command and its arguments.")
        var target: [String] = []

        func validate() throws {
            if let callbackPort, !(1...65_535).contains(callbackPort) {
                throw ValidationError("--callback-port needs a port number")
            }
        }
    }

    struct AddJSON: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a server from its mcp.json entry.")

        @Option(name: .shortAndLong, help: scopeHelp, transform: MCPCommand.scope)
        var scope: MCPConfigScope = .user

        @Argument(help: "Server name.")
        var name: String

        @Argument(help: "The server's mcp.json entry.")
        var json: String
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List servers and check each one.")
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a server's configuration.")

        @Argument(help: "Server name.")
        var name: String
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a server (and its sign-in).",
            aliases: ["rm"]
        )

        @Option(name: .shortAndLong, help: "user or project (default: both).", transform: MCPCommand.scope)
        var scope: MCPConfigScope?

        @Argument(help: "Server name.")
        var name: String
    }

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sign in to an OAuth server.")

        @Flag(name: .customLong("no-browser"), help: "Print the sign-in URL instead of opening a browser.")
        var noBrowser = false

        @Option(help: "Fixed OAuth callback port.")
        var callbackPort: UInt16?

        @Argument(help: "Server name.")
        var name: String

        func validate() throws {
            if callbackPort == 0 { throw ValidationError("--callback-port needs a port number") }
        }
    }

    struct Logout: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget a server's sign-in.")

        @Argument(help: "Server name.")
        var name: String
    }

    static let scopeHelp: ArgumentHelp = "user: ~/.kwwk/mcp.json (default); project: .kwwk/mcp.json in this directory."

    static func scope(_ value: String) throws -> MCPConfigScope {
        guard let scope = MCPConfigScope(rawValue: value) else {
            throw ValidationError("--scope must be user or project")
        }
        return scope
    }

    static func run(
        _ arguments: [String],
        cwd: String,
        homeDirectory: String,
        environment: [String: String],
        io: MCPCommandIO
    ) async -> Int32 {
        var command: ParsableCommand
        do {
            command = try Root.parseAsRoot(arguments)
        } catch {
            return usage(error, io: io)
        }
        let context = Context(cwd: cwd, homeDirectory: homeDirectory, environment: environment, io: io)
        let name = type(of: command)._commandName
        do {
            switch command {
            case let add as Add: try context.add(add)
            case let add as AddJSON: try context.addJSON(add)
            case is List: await context.list()
            case let get as Get: try await context.get(get.name)
            case let remove as Remove: try await context.remove(remove.name, scope: remove.scope)
            case let login as Login:
                try await context.login(login.name, openBrowser: !login.noBrowser, port: login.callbackPort)
            case let logout as Logout: try await context.logout(logout.name)
            default:
                // `kwwk mcp`, `--help` and `help <command>`: their run throws
                // the help request.
                do { try command.run() } catch { return usage(error, io: io) }
            }
            return 0
        } catch let error as UsageError {
            io.err("kwwk mcp \(name): \(error.message)")
            return 2
        } catch {
            io.err("kwwk mcp \(name): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return 1
        }
    }

    /// Help goes to stdout with exit 0; a parse error to stderr with exit 2.
    private static func usage(_ error: Error, io: MCPCommandIO) -> Int32 {
        let text = Root.fullMessage(for: error)
        guard Root.exitCode(for: error) == .success else {
            io.err(text)
            return 2
        }
        io.out(text)
        return 0
    }

    struct UsageError: Error {
        let message: String
    }

    struct Context {
        let cwd: String
        let homeDirectory: String
        let environment: [String: String]
        let io: MCPCommandIO

        func editor(_ scope: MCPConfigScope) -> MCPConfigEditor {
            MCPConfigEditor(url: MCPConfigFile.path(scope: scope, cwd: cwd, homeDirectory: homeDirectory), scope: scope)
        }

        func displayPath(_ scope: MCPConfigScope) -> String {
            let path = editor(scope).url.path
            return path.hasPrefix(homeDirectory + "/") ? "~" + path.dropFirst(homeDirectory.count) : path
        }

        var trustsProject: Bool {
            ["1", "true", "yes"].contains(environment[MCPRuntime.allowProjectServersVariable]?.lowercased() ?? "")
        }

        // MARK: add

        func add(_ add: Add) throws {
            var env: [String: String] = [:]
            for pair in add.env {
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    throw UsageError(message: "--env needs KEY=value, got \(pair)")
                }
                env[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            }
            var headers: [String: String] = [:]
            for header in add.header {
                guard let colon = header.firstIndex(of: ":"), colon != header.startIndex else {
                    throw UsageError(message: "--header needs \"Name: value\", got \(header)")
                }
                headers[String(header[..<colon]).trimmingCharacters(in: .whitespaces)] =
                    String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            var oauth: [String: JSONValue] = [:]
            if let clientId = add.clientId { oauth["clientId"] = .string(clientId) }
            if let clientSecret = add.clientSecret { oauth["clientSecret"] = .string(clientSecret) }
            if let clientName = add.clientName { oauth["clientName"] = .string(clientName) }
            if let scope = add.oauthScope { oauth["scope"] = .string(scope) }
            if let port = add.callbackPort { oauth["callbackPort"] = .int(port) }

            let name = add.name
            let target = add.target
            guard !target.isEmpty else { throw UsageError(message: "missing URL or -- command for \(name)") }
            let isURL = target.count == 1
                && ["http", "https"].contains(URL(string: target[0])?.scheme?.lowercased() ?? "")
            let transport = add.transport ?? (isURL ? "http" : "stdio")

            var entry: [String: JSONValue] = [:]
            switch transport {
            case "http", "streamable-http":
                guard target.count == 1 else { throw UsageError(message: "an HTTP server takes exactly one URL") }
                guard env.isEmpty else { throw UsageError(message: "--env applies to stdio servers") }
                entry["type"] = "http"
                entry["url"] = .string(target[0])
                if !headers.isEmpty { entry["headers"] = .object(headers.mapValues { .string($0) }) }
                if add.noOAuth {
                    guard oauth.isEmpty else {
                        throw UsageError(message: "--no-oauth conflicts with OAuth options")
                    }
                    entry["oauth"] = .bool(false)
                } else if !oauth.isEmpty {
                    entry["oauth"] = .object(oauth)
                }
            case "stdio":
                guard headers.isEmpty, oauth.isEmpty, !add.noOAuth else {
                    throw UsageError(message: "--header and OAuth options apply to HTTP servers")
                }
                entry["command"] = .string(target[0])
                if target.count > 1 { entry["args"] = .array(target.dropFirst().map { .string($0) }) }
                if !env.isEmpty { entry["env"] = .object(env.mapValues { .string($0) }) }
            case "sse":
                throw UsageError(
                    message: "the legacy SSE transport is not supported; use the server's Streamable HTTP URL"
                )
            default:
                throw UsageError(message: "--transport must be stdio or http")
            }
            if let description = add.serverDescription { entry["description"] = .string(description) }
            try write(name: name, entry: .object(entry), scope: add.scope)
        }

        func addJSON(_ add: AddJSON) throws {
            let entry: JSONValue
            do {
                entry = try JSONDecoder().decode(JSONValue.self, from: Data(add.json.utf8))
            } catch {
                throw UsageError(message: "invalid JSON")
            }
            try write(name: add.name, entry: entry, scope: add.scope)
        }

        private func write(name: String, entry: JSONValue, scope: MCPConfigScope) throws {
            guard let parsed = try MCPConfigFile.validate(
                name: name, raw: entry, cwd: cwd, homeDirectory: homeDirectory, environment: environment
            ) else {
                throw UsageError(message: "the entry is disabled (\"enabled\": false)")
            }
            let editor = editor(scope)
            guard try editor.servers()[name] == nil else {
                throw UsageError(message: "MCP server \(name) already exists in \(displayPath(scope)); remove it first")
            }
            try editor.set(name, entry)
            let kind: String
            if case .http = parsed.server.transport { kind = "HTTP" } else { kind = "stdio" }
            io.out("Added \(kind) MCP server \(name) to \(scope.rawValue) config (\(displayPath(scope))).")
            if parsed.oauth != nil {
                io.out("If it needs a sign-in, run: kwwk mcp login \(name)")
            }
            if scope == .project && !trustsProject {
                io.out("Project servers load only with \(MCPRuntime.allowProjectServersVariable)=1.")
            }
        }

        // MARK: list / get

        func loaded() -> MCPConfigFile.Loaded {
            MCPConfigFile.load(
                cwd: cwd,
                homeDirectory: homeDirectory,
                trustProject: trustsProject,
                environment: environment
            )
        }

        func list() async {
            let loaded = loaded()
            for warning in loaded.warnings { io.err("warning: \(warning)") }
            guard !loaded.entries.isEmpty else {
                io.out("No MCP servers configured. Add one with: kwwk mcp add <name> <url>")
                return
            }
            io.out("Checking MCP server health…\n")
            let runtime = MCPRuntime(cwd: cwd, homeDirectory: homeDirectory, environment: environment)
            if let manager = runtime.manager {
                let wait = loaded.entries.map(\.server.startupTimeoutSeconds).max() ?? 30
                await manager.waitForStartup(timeout: wait)
                let states = Dictionary(
                    await manager.statuses().map { ($0.name, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for entry in loaded.entries {
                    let name = entry.server.name
                    let status = states[name]
                    let health: String
                    switch status?.state {
                    case .connected?: health = "✔ Connected (\(status?.toolCount ?? 0) tools)"
                    case .authorizationRequired?:
                        // Only servers with an OAuth provider get here.
                        health = "! Needs authentication (kwwk mcp login \(name))"
                    case .failed(let reason)?, .disconnected(let reason)?:
                        health = "✘ Failed to connect: \(reason.split(whereSeparator: \.isNewline).first ?? "")"
                    case .connecting?: health = "… Still connecting"
                    case .closed?, nil: health = entry.server.exposure == .hidden ? "hidden" : "not started"
                    }
                    io.out("\(name) (\(entry.scope.rawValue)): \(Self.target(entry.server.transport)) - \(health)")
                }
                await runtime.shutdown()
            }
        }

        static func target(_ transport: MCPTransportConfig) -> String {
            switch transport {
            case .http(let url, _): return url.absoluteString + " (HTTP)"
            case .stdio(let command, let args, _, _): return ([command] + args).joined(separator: " ")
            }
        }

        func get(_ name: String) async throws {
            var found = false
            for scope in MCPConfigScope.allCases {
                guard let raw = try editor(scope).servers()[name] else { continue }
                found = true
                io.out("\(name):")
                io.out("  Scope: \(scope.rawValue) (\(displayPath(scope)))")
                if scope == .project && !trustsProject {
                    io.out(
                        "  Not loaded: set \(MCPRuntime.allowProjectServersVariable)=1 to trust this project's servers"
                    )
                }
                let fields = raw.cliObject ?? [:]
                if let url = fields["url"]?.cliString {
                    io.out("  Type: http")
                    io.out("  URL: \(url)")
                    for (header, value) in (fields["headers"]?.cliObject ?? [:]).sorted(by: { $0.key < $1.key }) {
                        io.out("  Header: \(header): \(Self.redacted(header, value.cliString ?? ""))")
                    }
                    if case .bool(false)? = fields["oauth"] {
                        io.out("  OAuth: off")
                    } else if (fields["headers"]?.cliObject ?? [:]).keys.contains(where: { $0.lowercased() == "authorization" }) {
                        io.out("  OAuth: off (sends its own Authorization header)")
                    } else {
                        let record = MCPOAuthFileStore.readRecords(
                            url: MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory)
                        )[name]
                        // Login stores the URL with ${VAR} expanded, so compare against that.
                        var expander = Expander(home: homeDirectory, environment: environment)
                        let resolvedURL = URL(string: expander.expand(url, field: "url"))?.absoluteString ?? url
                        let signedIn = record?.serverURL == resolvedURL && record?.tokens != nil
                        io.out("  OAuth: on, \(signedIn ? "signed in" : "not signed in (kwwk mcp login \(name))")")
                        for (key, value) in (fields["oauth"]?.cliObject ?? [:]).sorted(by: { $0.key < $1.key }) {
                            let text = value.cliString ?? (value.cliInt.map(String.init) ?? "\(value)")
                            io.out("    \(key): \(Self.redacted(key, text))")
                        }
                    }
                } else if let command = fields["command"]?.cliString {
                    io.out("  Type: stdio")
                    io.out("  Command: \(command)")
                    let args = (fields["args"]?.cliArray ?? []).compactMap(\.cliString)
                    if !args.isEmpty { io.out("  Args: \(args.joined(separator: " "))") }
                    for (key, value) in (fields["env"]?.cliObject ?? [:]).sorted(by: { $0.key < $1.key }) {
                        io.out("  Env: \(key)=\(Self.redacted(key, value.cliString ?? ""))")
                    }
                }
                if let description = fields["description"]?.cliString { io.out("  Description: \(description)") }
                if case .bool(false)? = fields["enabled"] { io.out("  Enabled: no") }
                io.out("  To remove it: kwwk mcp remove \(name) --scope \(scope.rawValue)")
            }
            guard found else { throw UsageError(message: "no MCP server named \(name)") }
        }

        /// Values of secret-looking names are hidden, unless they only
        /// reference an environment variable.
        static func redacted(_ name: String, _ value: String) -> String {
            let lowered = name.lowercased()
            let secret = ["token", "secret", "key", "authorization", "password", "cookie"]
                .contains { lowered.contains($0) }
            guard secret, !value.isEmpty else { return value }
            if value.hasPrefix("${"), value.hasSuffix("}") { return value }
            return "***"
        }

        // MARK: remove

        func remove(_ name: String, scope: MCPConfigScope?) async throws {
            var removed: [MCPConfigScope] = []
            for candidate in scope.map({ [$0] }) ?? MCPConfigScope.allCases where try editor(candidate).remove(name) {
                removed.append(candidate)
            }
            guard !removed.isEmpty else {
                throw UsageError(
                    message: "no MCP server named \(name)\(scope.map { " in \($0.rawValue) config" } ?? "")"
                )
            }
            for candidate in removed {
                io.out("Removed MCP server \(name) from \(candidate.rawValue) config (\(displayPath(candidate))).")
            }
            try await MCPOAuthFileStore(url: MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory))
                .remove(server: name)
        }

        // MARK: login / logout

        func login(_ name: String, openBrowser: Bool, port: UInt16?) async throws {
            let (provider, store) = try oauthProvider(name, port: port)
            await store.remember(port: provider.callbackPort, server: name)
            io.out("Signing in to \(name)…")
            try await provider.login(openBrowser: openBrowser)
            io.out("Signed in to \(name).")
        }

        func logout(_ name: String) async throws {
            _ = try oauthProvider(name, port: nil)
            try await MCPOAuthFileStore(url: MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory))
                .remove(server: name)
            io.out("Signed out of \(name).")
        }

        private func oauthProvider(_ name: String, port: UInt16?) throws -> (CLIMCPOAuthProvider, MCPOAuthFileStore) {
            guard let entry = loaded().entries.first(where: { $0.server.name == name }) else {
                throw UsageError(message: "no MCP server named \(name)")
            }
            guard case .http(let url, _) = entry.server.transport, var settings = entry.oauth else {
                throw UsageError(message: "\(name) does not use OAuth")
            }
            if let port { settings.callbackPort = port }
            let storeURL = MCPOAuthFileStore.defaultURL(homeDirectory: homeDirectory)
            let store = MCPOAuthFileStore(url: storeURL)
            let callbackPort = MCPOAuthCLI.callbackPort(
                server: name,
                serverURL: url,
                settings: settings,
                records: MCPOAuthFileStore.readRecords(url: storeURL)
            )
            return (
                CLIMCPOAuthProvider(
                    server: name,
                    serverURL: url,
                    settings: settings,
                    store: store,
                    callbackPort: callbackPort
                ),
                store
            )
        }
    }
}

private extension JSONValue {
    var cliObject: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var cliString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var cliArray: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var cliInt: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}
