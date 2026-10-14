import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension OAuthLogin {
    // MARK: - Z.AI GLM Coding Plan (browser sign-in)
    //
    // Ported from oh-my-pi's `zai.ts` (ZCode's desktop "Individual Plan"
    // flow): an authorization-code grant (no PKCE) against chat.z.ai, a JSON
    // token exchange on zcode.z.ai that yields a short-lived OAuth access
    // token, then a business-API sequence on api.z.ai that provisions a
    // durable `id.secret` API key. The minted key persists in the sentinel
    // credentials shape (refresh "", expires .max) so the stored `zai`
    // registration consumes it exactly like a hand-entered key.

    public static func loginZai(
        clientID: String = ZaiOAuth.clientID,
        port: UInt16 = ZaiOAuth.callbackPort,
        callbacks: Callbacks,
        client: HTTPClient = URLSessionHTTPClient()
    ) async throws -> OAuthCredentials {
        let state = PKCE.randomHex()
        let server = try await openLoopback(callbacks, port: port)
        defer { server.stop() }
        let redirect = server.redirectURI

        var comps = URLComponents(url: ZaiOAuth.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "state", value: state),
        ]
        callbacks.onProgress("waiting for Z.AI callback on \(redirect)…")

        let params = try await present(comps.url!, callbacks: callbacks) {
            try await server.waitForCallback()
        }
        try checkCallbackError(params, provider: "zai")
        guard let code = params["code"], !code.isEmpty else {
            throw OAuthError.invalidResponse("zai callback had no code")
        }
        if let callbackState = params["state"], callbackState != state {
            throw OAuthError.invalidResponse("zai OAuth state mismatch")
        }

        // Token exchange — non-standard JSON body (no grant_type or PKCE);
        // matches ZCode verbatim.
        callbacks.onProgress("exchanging authorization code…")
        let exchange = try zaiUnwrap(
            try await zaiJSON(
                url: ZaiOAuth.tokenURL, method: "POST",
                body: ["provider": "zai", "code": code, "redirect_uri": redirect, "state": state],
                client: client
            ),
            operation: "token exchange"
        )
        guard let zaiObj = (exchange as? [String: Any])?["zai"] as? [String: Any],
              let oauthToken = zaiString(zaiObj["access_token"]) else {
            throw OAuthError.invalidResponse("zai token response missing access token")
        }

        // Business login: the biz APIs reject the raw OAuth token; exchange
        // it for a biz bearer first.
        callbacks.onProgress("provisioning Z.AI API key…")
        let login = try zaiUnwrap(
            try await zaiJSON(
                url: ZaiOAuth.businessLoginURL, method: "POST",
                body: ["token": oauthToken], client: client
            ),
            operation: "business login"
        )
        let loginObj = login as? [String: Any]
        guard let bizToken = zaiString(loginObj?["access_token"]) ?? zaiString(loginObj?["accessToken"]) else {
            throw OAuthError.invalidResponse("zai business login returned no access token")
        }

        // Resolve the default organization/project, then find-or-create the
        // kwwk-named key under it.
        let customer = try zaiUnwrap(
            try await zaiJSON(
                url: ZaiOAuth.bizBaseURL.appendingPathComponent("api/biz/customer/getCustomerInfo"),
                method: "GET", body: nil, authorization: "Bearer \(bizToken)", client: client
            ),
            operation: "customer lookup"
        )
        let orgs = (customer as? [String: Any])?["organizations"] as? [[String: Any]] ?? []
        guard let (organizationId, projectId) = zaiDefaultProject(orgs) else {
            throw OAuthError.invalidResponse("zai key provisioning: no organization/project on account")
        }

        let keysURL = ZaiOAuth.bizBaseURL
            .appendingPathComponent("api/biz/v1/organization/\(organizationId)/projects/\(projectId)/api_keys")
        let listed = try zaiUnwrap(
            try await zaiJSON(
                url: keysURL, method: "GET", body: nil, authorization: "Bearer \(bizToken)", client: client
            ),
            operation: "api key list"
        )
        let record: [String: Any]?
        // A listed entry counts only when it names its key id: one without
        // an `apiKey` cannot be copied, so the key is made instead (the
        // magpie zcode plugin's projectKey skips such entries the same way).
        if let existing = zaiKeyArray(listed).first(where: {
            ($0["name"] as? String) == ZaiOAuth.keyName && zaiString($0["apiKey"]) != nil
        }) {
            record = existing
        } else {
            record = try zaiUnwrap(
                try await zaiJSON(
                    url: keysURL, method: "POST",
                    body: ["name": ZaiOAuth.keyName], authorization: "Bearer \(bizToken)", client: client
                ),
                operation: "api key create"
            ) as? [String: Any]
        }
        guard let apiKey = zaiString(record?["apiKey"]) else {
            throw OAuthError.invalidResponse("zai key provisioning returned no apiKey")
        }

        // Always fetch the secret via the copy endpoint: list entries mask it
        // (`*****abcd`) and the create response's inline secret is not
        // reliable across account states, whereas copy returns it in full.
        let copied = try zaiUnwrap(
            try await zaiJSON(
                url: keysURL.appendingPathComponent("copy/\(apiKey)"),
                method: "GET", body: nil, authorization: "Bearer \(bizToken)", client: client
            ),
            operation: "api key copy"
        )
        guard let secretKey = zaiString((copied as? [String: Any])?["secretKey"]) else {
            throw OAuthError.invalidResponse("zai key provisioning returned no secretKey")
        }

        let key = "\(apiKey).\(secretKey)"

        // A key is minted for any Z.ai account, plan or not, and without a
        // GLM Coding Plan the coding endpoint answers every request with
        // code 1113. ZCode asks the account's subscriptions with the key
        // itself (bare, no `Bearer`) and so does magpie's zcode plugin
        // (`plan()`, which signs a planless account out with these words);
        // measured 2026-10-12: 200 `{"code":200,"data":[{"productName":
        // "GLM Coding Lite","status":"VALID",…}]}`. Only a list that was
        // read and holds no valid subscription refuses the sign-in: a read
        // that fails leaves the key, which is good either way.
        if let plan = await zaiCodingPlan(key: key, client: client) {
            guard !plan.isEmpty else {
                throw OAuthError.invalidResponse(
                    "this Z.ai account has no GLM Coding Plan of its own (a seat on a team's plan can't be used here) — subscribe at z.ai/subscribe, then sign in again"
                )
            }
            callbacks.onProgress("signed in to \(plan)")
        }

        return OAuthCredentials(access: key, refresh: "", expires: .max)
    }

    // MARK: - Z.AI helpers

    /// The account's own default organization and project, as ZCode picks
    /// them: a project of `projectType` 2 is a team's coding plan and never
    /// holds a personal key, the organization named "默认机构" and the
    /// project named "默认项目" win, else the first of each. Ported from the
    /// magpie zcode plugin's `mintKey`; the account shape is the one in
    /// magpie's zcode_test.go (an "other" organization listed ahead of
    /// 默认机构, whose first project is a team's). `isDefault`, which
    /// oh-my-pi reads, still wins when the account carries it.
    package static func zaiDefaultProject(_ orgs: [[String: Any]]) -> (organization: String, project: String)? {
        func flagged(_ record: [String: Any]) -> Bool { (record["isDefault"] as? Bool) == true }
        func named(_ record: [String: Any], _ field: String, _ name: String) -> Bool {
            (record[field] as? String)?.contains(name) == true
        }
        var candidates: [(org: [String: Any], id: String, project: String)] = []
        for org in orgs {
            guard let id = zaiString(org["organizationId"]) else { continue }
            let own = (org["projects"] as? [[String: Any]] ?? []).filter { project in
                guard zaiString(project["projectId"]) != nil else { return false }
                // The type arrives as "2" or 2.
                if let type = project["projectType"] as? String { return type != "2" }
                if let type = project["projectType"] as? NSNumber { return type.intValue != 2 }
                return true
            }
            let project = own.first(where: flagged)
                ?? own.first { named($0, "projectName", "默认项目") }
                ?? own.first
            guard let projectId = zaiString(project?["projectId"]) else { continue }
            candidates.append((org, id, projectId))
        }
        let chosen = candidates.first { flagged($0.org) }
            ?? candidates.first { named($0.org, "organizationName", "默认机构") }
            ?? candidates.first
        return chosen.map { ($0.id, $0.project) }
    }

    /// The name of the account's valid GLM Coding Plan, "" when the list was
    /// read and holds none, nil when it could not be read.
    private static func zaiCodingPlan(key: String, client: HTTPClient) async -> String? {
        guard let listed = try? zaiUnwrap(
            try await zaiJSON(
                url: ZaiOAuth.bizBaseURL.appendingPathComponent("api/biz/subscription/list"),
                method: "GET", body: nil, authorization: key, client: client
            ),
            operation: "subscription list"
        ), let subscriptions = listed as? [[String: Any]] else { return nil }
        let valid = subscriptions.first { ($0["status"] as? String)?.uppercased() == "VALID" }
        guard let valid else { return "" }
        return zaiString(valid["productName"]) ?? "GLM Coding Plan"
    }

    /// One JSON round-trip: optional JSON body, optional authorization, ≥400 throws
    /// with the response text, empty bodies come back nil.
    private static func zaiJSON(
        url: URL,
        method: String,
        body: [String: Any]?,
        authorization: String? = nil,
        client: HTTPClient
    ) async throws -> Any? {
        var headers = ["accept": "application/json"]
        if body != nil { headers["content-type"] = "application/json" }
        if let authorization { headers["authorization"] = authorization }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (response, responseBody) = try await client.request(
            url: url, method: method, headers: headers, body: data
        )
        if response.statusCode >= 400 {
            throw OAuthError.refreshFailed("zai \(url.lastPathComponent) \(response.statusCode): \(String(data: responseBody, encoding: .utf8) ?? "")")
        }
        guard !responseBody.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: responseBody)
    }

    /// Z.AI's `{code, msg, data, success}` envelope: the OAuth token endpoint
    /// signals success with `code: 0`, the biz endpoints with `code: 200` /
    /// `success: true`. Accept both; surface `msg` on failure. Bodies without
    /// a status wrapper pass through unchanged.
    private static func zaiUnwrap(_ body: Any?, operation: String) throws -> Any? {
        guard let obj = body as? [String: Any],
              obj["code"] != nil || obj["success"] != nil else {
            return body
        }
        let success: Bool = {
            if let flag = obj["success"] as? Bool, flag == false { return false }
            switch obj["code"] {
            case nil, is NSNull: return true
            case let n as NSNumber: return n.intValue == 0 || n.intValue == 200
            case let s as String: return s == "0" || s == "200"
            default: return false
            }
        }()
        guard success else {
            let msg = (obj["msg"] as? String) ?? "code \(obj["code"] ?? "?")"
            throw OAuthError.refreshFailed("zai \(operation) failed: \(msg)")
        }
        return obj.keys.contains("data") ? obj["data"] : obj
    }

    /// Non-empty trimmed string, or nil.
    private static func zaiString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Coerce an api_keys list response (bare array or common wrapper
    /// shapes) to an array of records.
    private static func zaiKeyArray(_ value: Any?) -> [[String: Any]] {
        if let arr = value as? [[String: Any]] { return arr }
        if let obj = value as? [String: Any] {
            for field in ["list", "keys", "apiKeys", "records"] {
                if let arr = obj[field] as? [[String: Any]] { return arr }
            }
        }
        return []
    }
}
