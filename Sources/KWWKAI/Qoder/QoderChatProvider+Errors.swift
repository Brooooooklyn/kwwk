import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension QoderChatProvider {
    // MARK: - Errors

    /// Qoder's code for a request its queue holds back: the model is busy
    /// for this plan, with when to ask again.
    static let queuedCode = "10605"
    /// The codes Qoder's client counts as a plan's usage or credits used up
    /// (`QoderErrorCode` in the app's qoder-agent-sdk worker).
    static let quotaCodes: Set<String> = ["110", "112", "113", "114", "115", "116", "117", "118", "119", "122"]
    /// Refusals of this request, not of the account: sensitive content, not
    /// supported, input too long, too many media, a custom model's service.
    static let requestCodes: Set<String> = ["406", "416", "430", "80411", "80412", "100400", "100401", "100403"]
    /// How long to wait on a busy queue that names no wait, in seconds.
    static let busyWait = 30

    /// A refused request as kwwk's failure. Qoder says why in `message`, and
    /// the model vendor's own reason (an effort the model refuses, say) rides
    /// as JSON text in `details`. A refused sign-in and a spent plan get
    /// magpie's wording, which the failure classifier reads as authentication
    /// and quota; a refused sign-in keeps what Qoder said of it.
    ///
    /// Qoder's own `code` says what a refusal is before its status does, read
    /// as Qoder's client reads it: there only 105 is a lapsed sign-in, so a
    /// 401/403 carrying another code is not one here either. A real trial
    /// account's queued request came back 403 with code 10605 and read as
    /// "sign in again" (magpie-plugins qoder 0.2.14, #98, `busy.test.mjs`).
    static func failure(status: Int, body: Data) -> ProviderFailure {
        let status = (400...599).contains(status) ? status : 502
        var message = String(decoding: body.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var code = ""
        var queue: [String: Any]?
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            switch object["code"] {
            case let text as String: code = text
            case let number as NSNumber: code = number.stringValue
            default: break
            }
            let said = object["message"] as? String ?? ""
            if !said.isEmpty { message = said }
            let details = (object["details"] as? String).flatMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            } ?? object["details"] as? [String: Any]
            if let reason = (details?["error"] as? [String: Any])?["message"] as? String, !reason.isEmpty {
                message += ": " + reason
            }
            // The queue's state is a field, or the message itself as JSON
            // text.
            queue = object["queue"] as? [String: Any]
            if queue == nil, said.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
               let state = (try? JSONSerialization.jsonObject(with: Data(said.utf8))) as? [String: Any],
               ["isQueued", "serviceAvailable", "retryAfterSeconds"].contains(where: { state[$0] != nil }) {
                queue = state
            }
        }
        // Qoder's queue for the model: busy for now. The sign-in is fine, so
        // it is a 503 to ask again after the wait Qoder names.
        let isQueued = queue?["isQueued"] as? Bool == true
        if code == queuedCode || isQueued || queue?["serviceAvailable"] as? Bool == false {
            var wait = busyWait
            if let seconds = (queue?["retryAfterSeconds"] as? NSNumber)?.doubleValue, seconds > 0, seconds < 1e9 {
                wait = Int(seconds.rounded(.up))
            }
            let model = (queue?["modelKey"] as? String).flatMap { $0.isEmpty ? nil : " for \($0)" } ?? ""
            let tier = (queue?["queueType"] as? String)
                .flatMap { $0.isEmpty ? nil : " (this plan's queue: \($0))" } ?? ""
            return ProviderFailure(
                message: "Qoder \(isQueued ? "queued the request" : "is busy")\(model)\(tier); try again in \(wait)s",
                httpStatus: 503,
                retryAfterMs: Double(wait) * 1000
            )
        }
        if quotaCodes.contains(code) {
            return ProviderFailure(message: "usage limit reached: " + message, httpStatus: 429)
        }
        if requestCodes.contains(code) {
            return ProviderFailure(message: "Qoder refused the request (\(code)): \(message)", httpStatus: 400)
        }
        // A refused chat reads as a lapsed sign-in, but Qoder's own words go
        // with it: a 401 right after signing in is not a lapsed sign-in, and
        // only its reason says what it is (magpie-plugins qoder 0.2.12,
        // `usage.test.mjs` "a refused chat").
        if status == 401 || status == 403 {
            let said = message.isEmpty ? "" : " (Qoder said \(status): \(message.prefix(300)))"
            return ProviderFailure(message: "Qoder: the sign-in lapsed — sign in again" + said, httpStatus: 401)
        }
        if message.isEmpty { message = HTTPURLResponse.localizedString(forStatusCode: status) }
        if status == 429 || message.lowercased().contains("quota") {
            return ProviderFailure(message: "usage limit reached: " + message, httpStatus: 429)
        }
        return ProviderFailure(message: "Qoder: " + message, httpStatus: status)
    }
}
