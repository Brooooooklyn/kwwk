import Foundation

// MARK: - Kimi For Coding (Moonshot coding plan)
//
// Kimi's coding-plan auth is an OAuth device-authorization grant against
// `auth.kimi.com` (see `OAuthLogin.loginKimiCoding`). Refresh is a standard
// `grant_type=refresh_token` form POST to the same token endpoint. Every
// request carries the `X-Msh-*` device-identity headers the Kimi CLI sends.

public struct KimiCodingOAuthProvider: OAuthProvider {
    public let id = "kimi-coding"
    public let name = "Kimi For Coding"
    public let tokenURL: URL
    public let clientID: String
    /// The fingerprint sent when the credentials don't name their own device
    /// id. Nil uses this machine's, with the id persisted at
    /// `~/.kwwk/kimi-device-id`.
    public let identity: KimiDeviceIdentity?

    public init(
        tokenURL: URL = URL(string: "https://auth.kimi.com/api/oauth/token")!,
        clientID: String = KimiOAuth.clientID,
        identity: KimiDeviceIdentity? = nil
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.identity = identity
    }

    public func refresh(
        _ credentials: OAuthCredentials, using client: HTTPClient
    ) async throws -> OAuthCredentials {
        // Kimi binds the grant to the device id it was approved on, so the
        // id the login recorded wins over this provider's default; a login
        // that recorded none gets the default written back, so every later
        // refresh — wherever it runs — sends the same one.
        var identity = identity ?? .host()
        if case .string(let recorded)? = credentials.extras["deviceId"], !recorded.isEmpty {
            identity.deviceId = recorded
        }
        let form = OAuth.urlEncodedForm([
            "grant_type": "refresh_token",
            "refresh_token": credentials.refresh,
            "client_id": clientID,
        ])
        var headers = KimiOAuth.commonHeaders(identity: identity)
        headers["content-type"] = "application/x-www-form-urlencoded"
        headers["accept"] = "application/json"
        let json = try await OAuthRefreshError.postForToken(
            provider: id, url: tokenURL, headers: headers, body: Data(form.utf8), client: client
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var extras = credentials.extras
        extras["deviceId"] = .string(identity.deviceId)
        return OAuthCredentials(
            access: json.accessToken,
            refresh: json.refreshToken ?? credentials.refresh,
            expires: now + Int64(json.expiresIn * 1000) - OAuth.expiryMarginMs,
            extras: extras
        )
    }
}

/// The device fingerprint Kimi's endpoints check on every login and refresh
/// (`X-Msh-Device-*`). A refresh must present the device id its login did.
public struct KimiDeviceIdentity: Sendable, Equatable {
    public var deviceId: String
    public var deviceName: String
    public var deviceModel: String
    public var osVersion: String

    public init(deviceId: String, deviceName: String, deviceModel: String, osVersion: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }

    /// This machine: its host name, OS and CPU, and `deviceId` — or, when
    /// nil, the id persisted at `~/.kwwk/kimi-device-id`.
    public static func host(deviceId: String? = nil) -> KimiDeviceIdentity {
        KimiDeviceIdentity(
            deviceId: deviceId ?? KimiOAuth.persistentDeviceId(),
            deviceName: ProcessInfo.processInfo.hostName,
            deviceModel: KimiOAuth.deviceModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

/// Constants + device-identity headers shared by the Kimi device-flow login
/// and the refresh provider. Kimi's endpoints expect the CLI's `X-Msh-*`
/// fingerprint headers alongside a `KimiCLI/<version>` User-Agent (the same
/// agent string the bundled kimi-coding catalog models pin for chat requests).
public enum KimiOAuth {
    public static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    public static let host = URL(string: "https://auth.kimi.com")!
    /// Keep in sync with the `User-Agent` header on the bundled `kimi-coding`
    /// catalog models.
    static let cliVersion = "1.5"

    /// Headers for Kimi OAuth endpoints, carrying `identity`.
    public static func commonHeaders(identity: KimiDeviceIdentity) -> [String: String] {
        [
            "User-Agent": "KimiCLI/\(cliVersion)",
            "X-Msh-Platform": "kimi_cli",
            "X-Msh-Version": cliVersion,
            "X-Msh-Device-Name": sanitized(identity.deviceName),
            "X-Msh-Device-Model": sanitized(identity.deviceModel),
            "X-Msh-Os-Version": sanitized(identity.osVersion),
            "X-Msh-Device-Id": sanitized(identity.deviceId),
        ]
    }

    /// Header values must be printable ASCII; anything else (or an empty
    /// result) collapses to "unknown".
    private static func sanitized(_ value: String) -> String {
        let filtered = value.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value <= 0x7E }
            .map(Character.init)
        let result = String(filtered).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "unknown" : result
    }

    static func deviceModel() -> String {
        #if os(macOS)
        let system = "macOS"
        #elseif os(iOS)
        let system = "iOS"
        #elseif os(Linux)
        let system = "Linux"
        #else
        let system = "unknown"
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return "\(system) \(arch)"
    }

    /// Process-stable fallback id, used only when the id file can't be
    /// written: login and refresh both go through `commonHeaders`, and Kimi
    /// may reject a refresh whose `X-Msh-Device-Id` differs from login's, so
    /// the id must at least survive the process even when it can't survive
    /// a restart.
    private static let fallbackLock = NSLock()
    nonisolated(unsafe) private static var fallbackDeviceId: String?

    /// Read (or create, 0600) the stable device id beside the OAuth store.
    /// Best-effort: an unwritable directory falls back to one id per process.
    package static func persistentDeviceId(
        at url: URL = OAuthStore.defaultURL()
            .deletingLastPathComponent()
            .appendingPathComponent("kimi-device-id")
    ) -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let wrote = FileManager.default.createFile(
            atPath: url.path,
            contents: Data("\(fresh)\n".utf8),
            attributes: [.posixPermissions: 0o600]
        )
        if wrote { return fresh }
        fallbackLock.lock()
        defer { fallbackLock.unlock() }
        if let cached = fallbackDeviceId { return cached }
        fallbackDeviceId = fresh
        return fresh
    }
}
