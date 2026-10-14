import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension OAuthLogin {
    // MARK: - Kimi For Coding (device flow)
    //
    // Kimi's coding plan uses an OAuth device-authorization grant against
    // `auth.kimi.com`: POST `/api/oauth/device_authorization` for a one-time
    // user code, hand the verification URL to the browser, and poll
    // `/api/oauth/token` until the user approves. Mirrors oh-my-pi's
    // `loginKimi`. Every request carries the `X-Msh-*` device headers, and
    // Kimi binds the grant to `X-Msh-Device-Id`: the id is returned in
    // `extras.deviceId` so whoever refreshes the login sends the same one.

    public static func loginKimiCoding(
        clientID: String = KimiOAuth.clientID,
        host: URL = KimiOAuth.host,
        // The device fingerprint. Nil uses this machine's, with the id
        // persisted at `~/.kwwk/kimi-device-id`; an app passes its own.
        identity: KimiDeviceIdentity? = nil,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let identity = identity ?? .host()
        var headers = KimiOAuth.commonHeaders(identity: identity)
        headers["accept"] = "application/json"
        headers["content-type"] = "application/x-www-form-urlencoded"

        callbacks.onProgress("requesting Kimi device code…")
        let (deviceResponse, deviceBody) = try await client.request(
            url: host.appendingPathComponent("api/oauth/device_authorization"),
            method: "POST",
            headers: headers,
            body: Data(OAuth.urlEncodedForm(["client_id": clientID]).utf8)
        )
        if deviceResponse.statusCode >= 400 {
            throw OAuthError.refreshFailed("kimi device code \(deviceResponse.statusCode): \(String(data: deviceBody, encoding: .utf8) ?? "")")
        }
        let grant = try DeviceGrant(deviceBody, provider: "kimi", requireHTTPS: false)

        var credentials = try await runDeviceFlow(
            grant,
            provider: "kimi",
            tokenURL: host.appendingPathComponent("api/oauth/token"),
            headers: headers,
            clientID: clientID,
            defaultTokenLifetime: 15 * 60,
            callbacks: callbacks,
            client: client
        )
        credentials.extras["deviceId"] = .string(identity.deviceId)
        return credentials
    }

    // MARK: - xAI Grok (device flow)
    //
    // xAI's subscription auth is an RFC 8628 device-authorization grant
    // against `auth.x.ai`: POST `/oauth2/device/code` for a one-time user
    // code, hand the verification URL to the browser, and poll
    // `/oauth2/token` until the user approves. Same client id + scope as the
    // official Grok CLI (and pi / oh-my-pi). The resulting Bearer token
    // authenticates `api.x.ai` requests directly.

    public static func loginXai(
        clientID: String = XaiOAuth.clientID,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let headers = [
            "accept": "application/json",
            "content-type": "application/x-www-form-urlencoded",
        ]

        callbacks.onProgress("requesting xAI device code…")
        let (deviceResponse, deviceBody) = try await client.request(
            url: XaiOAuth.deviceCodeURL,
            method: "POST",
            headers: headers,
            body: Data(OAuth.urlEncodedForm([
                "client_id": clientID,
                "scope": XaiOAuth.scope,
            ]).utf8)
        )
        if deviceResponse.statusCode >= 400 {
            throw OAuthError.refreshFailed("xai device code \(deviceResponse.statusCode): \(String(data: deviceBody, encoding: .utf8) ?? "")")
        }
        // The verification URI is handed to the browser; refuse anything a
        // malicious response could use to launch a non-https handler.
        let grant = try DeviceGrant(deviceBody, provider: "xai", requireHTTPS: true)

        return try await runDeviceFlow(
            grant,
            provider: "xai",
            tokenURL: XaiOAuth.tokenURL,
            headers: headers,
            clientID: clientID,
            defaultTokenLifetime: 3600,
            callbacks: callbacks,
            client: client
        )
    }

    // MARK: - RFC 8628 device grant

    /// The device-authorization answer the user approves against.
    struct DeviceGrant: Sendable {
        let userCode: String
        let deviceCode: String
        let verificationURL: URL
        /// Seconds between polls. RFC 8628 allows 0 (no minimum wait); only
        /// negative or malformed values fall back to the default.
        let interval: Int
        let expiresIn: Int

        init(_ body: Data, provider: String, requireHTTPS: Bool) throws {
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let userCode = obj["user_code"] as? String,
                  let deviceCode = obj["device_code"] as? String,
                  let verifyURLString = (obj["verification_uri_complete"] as? String)
                    ?? (obj["verification_uri"] as? String),
                  let verifyURL = URL(string: verifyURLString),
                  !requireHTTPS || verifyURL.scheme == "https" else {
                throw OAuthError.invalidResponse("\(provider) device code response")
            }
            self.userCode = userCode
            self.deviceCode = deviceCode
            self.verificationURL = verifyURL
            self.interval = (obj["interval"] as? Int).flatMap { $0 >= 0 ? $0 : nil } ?? 5
            self.expiresIn = (obj["expires_in"] as? Int) ?? 15 * 60
        }
    }

    /// Shows the code, opens the verification page, and polls the token
    /// endpoint until the user approves, declines or the code expires.
    static func runDeviceFlow(
        _ grant: DeviceGrant,
        provider: String,
        tokenURL: URL,
        headers: [String: String],
        clientID: String,
        defaultTokenLifetime: Int,
        callbacks: Callbacks,
        client: HTTPClient
    ) async throws -> OAuthCredentials {
        await callbacks.onUserCode?(grant.userCode, grant.verificationURL)
        callbacks.onProgress("enter code in your browser: \(grant.userCode)")
        let form = Data(OAuth.urlEncodedForm([
            "client_id": clientID,
            "device_code": grant.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]).utf8)
        return try await present(grant.verificationURL, callbacks: callbacks) {
            let deadline = Date().addingTimeInterval(TimeInterval(grant.expiresIn))
            var interval = grant.interval
            // A gateway blip — a thrown request or a non-JSON error page — must
            // not kill an approval the user is halfway through; only three in a
            // row give up.
            var consecutiveErrors = 0

            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                let response: HTTPURLResponse
                let body: Data
                do {
                    (response, body) = try await client.request(
                        url: tokenURL, method: "POST", headers: headers, body: form
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        throw OAuthError.transport("\(provider) device flow: \(error.localizedDescription)")
                    }
                    continue
                }
                guard let polled = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                    if response.statusCode >= 400 {
                        consecutiveErrors += 1
                        if consecutiveErrors >= 3 {
                            throw OAuthError.refreshFailed("\(provider) device flow: HTTP \(response.statusCode)")
                        }
                    }
                    continue
                }
                consecutiveErrors = 0
                if let err = polled["error"] as? String {
                    switch err {
                    case "authorization_pending":
                        continue
                    case "slow_down":
                        interval += 5
                        if let serverInterval = polled["interval"] as? Int, serverInterval > interval {
                            interval = serverInterval
                        }
                        continue
                    case "expired_token":
                        throw OAuthLoginError.timedOut
                    case "access_denied", "authorization_denied":
                        throw OAuthLoginError.cancelled
                    default:
                        let description = (polled["error_description"] as? String).map { ": \($0)" } ?? ""
                        throw OAuthLoginError.denied("\(provider) \(err)\(description)")
                    }
                }
                if response.statusCode < 400, let access = polled["access_token"] as? String {
                    // `offline_access` is in the requested scope, so the grant
                    // must carry a refresh token — without one the login would
                    // silently die at first expiry.
                    guard let refresh = polled["refresh_token"] as? String, !refresh.isEmpty else {
                        throw OAuthError.invalidResponse("\(provider) token response missing refresh token")
                    }
                    let expiresIn = (polled["expires_in"] as? Int) ?? defaultTokenLifetime
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    return OAuthCredentials(
                        access: access,
                        refresh: refresh,
                        expires: now + Int64(expiresIn) * 1000 - OAuth.expiryMarginMs
                    )
                }
            }
            throw OAuthLoginError.timedOut
        }
    }
}
