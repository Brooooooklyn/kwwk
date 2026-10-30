import Foundation

public extension Error {
    /// The text to show a person for this error: its own localized
    /// description when it has one, and its description otherwise.
    ///
    /// `"\(error)"` of a refused connection is `Error Domain=NSURLErrorDomain
    /// Code=-1004 "(null)"UserInfo={…}` on Linux, while the error carries
    /// curl's sentence as its localized description. `localizedDescription`
    /// alone is no answer either: for an error with no text of its own it is
    /// Foundation's "The operation couldn't be completed. (NSURLErrorDomain
    /// error -1004.)", which drops everything the description says.
    ///
    /// In order, the first non-empty one of: a `LocalizedError`'s
    /// `errorDescription`; the bridged NSError's `NSLocalizedDescriptionKey`;
    /// the description its domain's user-info provider gives (Apple's Cocoa
    /// domain: "The file doesn't exist."); and last `String(describing:)`.
    var displayDescription: String {
        let error: any Error = self
        if let text = (error as? LocalizedError)?.errorDescription, !text.isEmpty {
            return text
        }
        let bridged = error as NSError
        if let text = bridged.userInfo[NSLocalizedDescriptionKey] as? String, !text.isEmpty {
            return text
        }
        if let provider = NSError.userInfoValueProvider(forDomain: bridged.domain),
           let text = provider(bridged, NSLocalizedDescriptionKey) as? String, !text.isEmpty {
            return text
        }
        return String(describing: error)
    }
}
