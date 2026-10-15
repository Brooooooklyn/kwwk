import ArgumentParser
import Foundation
import KWWKAI

/// Regenerates KWWK's bundled Devin model catalog by calling Codeium Cascade's
/// `GetCliModelConfigs` RPC with a real Devin session token, then collapsing
/// effort variants into logical models (see `DevinModels.normalize`). This is
/// a development-time tool — the runtime never syncs models and only reads
/// the bundled JSON. The roster is credential-scoped: generate with an account
/// whose plan exposes the models kwwk should ship.
///
/// Usage:
///
///   swift run kwwk-generate-devin-models [--seed-only] [output.json]
///
/// `--seed-only` skips discovery and writes only the curated SWE-1.6 seed
/// (the same rows oh-my-pi bundles), for builds without a Devin account.
///
/// Authentication (first match wins):
///   1. DEVIN_API_KEY environment variable
///   2. a `devin` login in ~/.kwwk/oauth.json (session tokens never refresh; an expired one triggers a browser login)
///   3. interactive browser login (persisted to ~/.kwwk/oauth.json)
///
/// By default the output is written to:
///
///   Sources/KWWKAI/Resources/devin-models.json
///
/// NOTE: when syncing the model catalogs, also regenerate the regular
/// catalog (`swift run kwwk-generate-models …`) — the two bundled files
/// are updated together.
///
@main
struct GenerateDevinModels: AsyncParsableCommand {
    static let defaultOutputPath = "Sources/KWWKAI/Resources/devin-models.json"

    static let configuration = CommandConfiguration(
        commandName: "kwwk-generate-devin-models",
        abstract: "Regenerate the bundled Devin model catalog from Codeium Cascade's GetCliModelConfigs RPC.",
        discussion: """
        Auth: the DEVIN_API_KEY environment variable, or a `devin` login in ~/.kwwk/oauth.json; with neither \\
        present a browser login is started and persisted.

        Also run `swift run kwwk-generate-models …` when syncing: the regular catalog (models.json) is \\
        regenerated separately.
        """
    )

    @Flag(name: .customLong("seed-only"), help: "Skip discovery; write only the curated SWE-1.6 seed.")
    var seedOnly = false

    @Argument(help: ArgumentHelp("Output path.", valueName: "output.json"))
    var outputPath: String = Self.defaultOutputPath

    func run() async throws {
        let models: [Model]
        if seedOnly {
            models = DevinModels.seedModels.sorted { $0.id < $1.id }
        } else {
            let token = try await Self.resolveToken()
            models = try await DevinModels.fetch(apiKey: token)
        }
        try Self.write(models, to: outputPath)
        print("generated \(outputPath)")
        print("  models: \(models.count)")
        for model in models {
            let thinking = model.reasoning ? " (reasoning)" : ""
            let router = model.compat?.modelRouter == true ? " (router)" : ""
            print("    \(model.id)  \(model.name)\(thinking)\(router)")
        }
    }

    private static func resolveToken() async throws -> String {
        if let token = ProcessInfo.processInfo.environment["DEVIN_API_KEY"], !token.isEmpty {
            return token
        }
        let store = try OAuthStore(url: OAuthStore.defaultURL())
        let manager = OAuthManager(store: store)
        do {
            return try await manager.apiKey(for: "devin")
        } catch OAuthError.missing, OAuthError.expired {
            return try await interactiveLogin(store: store)
        }
    }

    /// No usable stored Devin login: run the browser PKCE flow (same one the kwwk
    /// CLI uses), persist the credentials so future runs skip this, and use
    /// the fresh access token.
    private static func interactiveLogin(store: OAuthStore) async throws -> String {
        stderr("no usable Devin login found — starting browser login…")
        let callbacks = OAuthLogin.Callbacks(
            onAuthURL: { url in
                stderr("open in your browser:\n  \(url.absoluteString)")
                openBrowser(url)
            },
            onProgress: { message in stderr(message) }
        )
        let credentials = try await OAuthLogin.loginDevin(callbacks: callbacks)
        try await store.set(credentials, for: "devin")
        stderr("logged in; credentials saved to \(OAuthStore.defaultURL().path)")
        return credentials.access
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    /// Best-effort URL opener. macOS uses `/usr/bin/open`; Linux tries
    /// `xdg-open`; failures fall back to the URL already printed on stderr.
    private static func openBrowser(_ url: URL) {
        #if os(macOS)
        let opener = "/usr/bin/open"
        #else
        let opener = "/usr/bin/xdg-open"
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opener)
        process.arguments = [url.absoluteString]
        try? process.run()
    }

    private static func write(_ models: [Model], to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(models)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}
