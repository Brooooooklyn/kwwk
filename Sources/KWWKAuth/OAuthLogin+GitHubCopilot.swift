import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension OAuthLogin {
    // MARK: - GitHub Copilot (device flow)
    //
    // Copilot uses GitHub's device-authorization grant: we POST to
    // `/login/device/code`, show the user the one-time `user_code`, and
    // poll `/login/oauth/access_token` until the user enters the code in
    // their browser. No callback server.

    public static func loginGitHubCopilot(
        clientID: String = "Iv1.b507a08c87ecfe98",
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient(),
        // Waits the given seconds before a poll; tests pass their own to read
        // the waits without sitting through them.
        pollSleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0)) * 1_000_000_000)
        }
    ) async throws -> OAuthCredentials {
        callbacks.onProgress("requesting GitHub device code…")
        let (deviceResponse, deviceBody) = try await client.request(
            url: URL(string: "https://github.com/login/device/code")!,
            method: "POST",
            headers: [
                "accept": "application/json",
                "content-type": "application/x-www-form-urlencoded",
            ],
            body: Data(OAuth.urlEncodedForm([
                "client_id": clientID,
                "scope": "read:user",
            ]).utf8)
        )
        if deviceResponse.statusCode >= 400 {
            throw OAuthError.refreshFailed("copilot device code \(deviceResponse.statusCode): \(String(data: deviceBody, encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: deviceBody) as? [String: Any],
              let userCode = obj["user_code"] as? String,
              let deviceCode = obj["device_code"] as? String,
              let verifyURLString = (obj["verification_uri_complete"] as? String)
                ?? (obj["verification_uri"] as? String),
              let plainVerifyURL = URL(string: verifyURLString) else {
            throw OAuthError.invalidResponse("copilot device code response")
        }
        let verifyURL = gitHubVerificationURL(plainVerifyURL, userCode: userCode)
        let interval = (obj["interval"] as? Int) ?? 5

        await callbacks.onUserCode?(userCode, verifyURL)
        callbacks.onProgress("enter code in your browser: \(userCode)")
        return try await present(verifyURL, callbacks: callbacks) {
            try await pollGitHubCopilot(
                clientID: clientID,
                deviceCode: deviceCode,
                interval: interval,
                client: client,
                pollSleep: pollSleep
            )
        }
    }

    /// GitHub's answer names the bare page; its `user_code` query fills the
    /// code in, so the user confirms it instead of typing it.
    static func gitHubVerificationURL(_ url: URL, userCode: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "user_code" }) else { return url }
        items.append(URLQueryItem(name: "user_code", value: userCode))
        components.queryItems = items
        return components.url ?? url
    }

    private static func pollGitHubCopilot(
        clientID: String,
        deviceCode: String,
        interval initialInterval: Int,
        client: HTTPClient,
        pollSleep: @Sendable (Int) async throws -> Void
    ) async throws -> OAuthCredentials {
        let pollURL = URL(string: "https://github.com/login/oauth/access_token")!
        let deadline = Date().addingTimeInterval(15 * 60)
        var interval = initialInterval
        var misses = 0
        while Date() < deadline {
            try await pollSleep(interval)
            let (pollResponse, pollBody) = try await client.request(
                url: pollURL,
                method: "POST",
                headers: [
                    "accept": "application/json",
                    "content-type": "application/x-www-form-urlencoded",
                ],
                body: Data(OAuth.urlEncodedForm([
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]).utf8)
            )
            // A body that isn't JSON (a proxy's page), or an error status
            // that names no OAuth error, is a hiccup, asked again — but five
            // in a row end the sign-in with the last one, rather than wait
            // out the 15 minutes saying nothing after GitHub's page said the
            // device was connected (magpie #723, commit 63c382bb). An OAuth
            // error is an answer whatever its status: RFC 8628 sends
            // `authorization_pending` as a 400, and github.com's 200 is its
            // own habit.
            guard let polled = (try? JSONSerialization.jsonObject(with: pollBody)) as? [String: Any],
                  pollResponse.statusCode < 400 || polled["error"] is String
            else {
                misses += 1
                if misses >= 5 {
                    let text = String(data: pollBody.prefix(200), encoding: .utf8) ?? ""
                    throw OAuthError.refreshFailed("copilot device flow \(pollResponse.statusCode): \(text)")
                }
                continue
            }
            misses = 0
            if let err = polled["error"] as? String {
                if err == "authorization_pending" { continue }
                if err == "slow_down" {
                    // GitHub raises the interval it holds this device code
                    // to by 5 s on every `slow_down` and names the new one;
                    // the raise lasts (RFC 8628 §3.5). Waiting longer once
                    // and then polling at the old pace again was answered
                    // `slow_down` again and again, each one raising the
                    // interval further.
                    // magpie keeps the raise the same way (copilot_signin.go).
                    interval = max(polled["interval"] as? Int ?? 0, interval + 5)
                    continue
                }
                throw OAuthError.refreshFailed("copilot device flow: \(err)")
            }
            if let pat = polled["access_token"] as? String {
                // Immediately exchange the PAT for a session token so the
                // stored creds are ready to use.
                let provider = GitHubCopilotOAuthProvider()
                let base = OAuthCredentials(access: "", refresh: pat, expires: 0, extras: [:])
                return try await provider.refresh(base, using: client)
            }
        }
        throw OAuthError.transport("copilot device flow timed out")
    }
}

// MARK: - GitHub Copilot post-login setup

extension OAuthLogin {
    /// Enable every model in `modelIds` on the Copilot account via
    /// `POST {baseURL}/models/<id>/policy` with `{state: "enabled"}`.
    /// Claude/Grok/Gemini models require this one-shot opt-in before the
    /// chat endpoints will route to them; GPT-family models don't need it
    /// but the call is idempotent so we fire for everything.
    ///
    /// Errors are swallowed per-model (best-effort): a 403 for a model the
    /// account doesn't have entitlement for shouldn't abort the whole
    /// login flow. Progress is reported through `onProgress` if set.
    public static func enableCopilotModels(
        sessionToken: String,
        baseURL: URL = URL(string: "https://api.individual.githubcopilot.com")!,
        modelIds: [String],
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async {
        let baseString: String = {
            var s = baseURL.absoluteString
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }()
        let body = Data(#"{"state":"enabled"}"#.utf8)
        for id in modelIds {
            guard let url = URL(string: "\(baseString)/models/\(id)/policy") else { continue }
            var headers = GitHubCopilotOAuthProvider().extraHeaders
            headers["content-type"] = "application/json"
            headers["authorization"] = "Bearer \(sessionToken)"
            headers["openai-intent"] = "chat-policy"
            headers["x-interaction-type"] = "chat-policy"
            do {
                let (response, _) = try await client.request(
                    url: url,
                    method: "POST",
                    headers: headers,
                    body: body
                )
                if response.statusCode >= 400 {
                    callbacks.onProgress("  · \(id): policy \(response.statusCode) (skipped)")
                } else {
                    callbacks.onProgress("  · \(id): enabled")
                }
            } catch {
                callbacks.onProgress("  · \(id): \(error.localizedDescription)")
            }
        }
    }
}
