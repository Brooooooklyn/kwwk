import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension OAuthLogin {
    // MARK: - Cursor (browser PKCE poll flow)
    //
    // Cursor's CLI login: generate a PKCE verifier/challenge and a session
    // uuid, open `cursor.com/loginDeepControl` in the browser, then poll
    // `api2.cursor.sh/auth/poll?uuid=&verifier=` with exponential backoff until
    // it returns the access/refresh tokens. No local callback server. Mirrors
    // oh-my-pi's `loginCursor`.

    public static func loginCursor(
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let pkce = PKCE.random()
        let uuid = UUID().uuidString.lowercased()

        var comps = URLComponents(string: "https://cursor.com/loginDeepControl")!
        comps.queryItems = [
            URLQueryItem(name: "challenge", value: pkce.challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli"),
        ]
        callbacks.onProgress("waiting for Cursor browser authentication…")
        return try await present(comps.url!, callbacks: callbacks) {
            try await pollCursor(uuid: uuid, verifier: pkce.verifier, client: client)
        }
    }

    /// Polls with exponential backoff (1s → 10s, ×1.2), up to 150 attempts.
    /// A 404 — or a 200 that carries no token yet — means "still pending";
    /// 3 consecutive hard errors abort.
    private static func pollCursor(
        uuid: String,
        verifier: String,
        client: HTTPClient
    ) async throws -> OAuthCredentials {
        var delayMs: UInt64 = 1000
        let maxDelayMs: UInt64 = 10_000
        var consecutiveErrors = 0

        for _ in 0..<150 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            delayMs = min(delayMs * 12 / 10, maxDelayMs)

            var poll = URLComponents(string: "https://api2.cursor.sh/auth/poll")!
            poll.queryItems = [
                URLQueryItem(name: "uuid", value: uuid),
                URLQueryItem(name: "verifier", value: verifier),
            ]
            let response: HTTPURLResponse
            let body: Data
            do {
                (response, body) = try await client.request(
                    url: poll.url!, method: "GET",
                    headers: ["accept": "application/json"], body: nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw OAuthError.transport("cursor auth polling failed: \(error.localizedDescription)")
                }
                continue
            }
            if response.statusCode == 404 {
                consecutiveErrors = 0
                continue
            }
            if response.statusCode >= 400 {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw OAuthError.refreshFailed("cursor poll \(response.statusCode)")
                }
                continue
            }
            consecutiveErrors = 0
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let access = obj["accessToken"] as? String, !access.isEmpty else {
                continue
            }
            let refresh = obj["refreshToken"] as? String ?? ""
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            return OAuthCredentials(
                access: access,
                refresh: refresh.isEmpty ? access : refresh,
                // A token without a JWT `exp` gets an hour, minus the same
                // 5-minute margin every other expiry carries.
                expires: OAuth.jwtExpiryMillis(access) ?? (now + 55 * 60 * 1000)
            )
        }
        throw OAuthLoginError.timedOut
    }
}
