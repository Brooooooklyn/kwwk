import Foundation

public extension Error {
    /// The text to show a person for this error: its `localizedDescription`,
    /// never an `NSError` printed whole. `"\(error)"` of a refused connection
    /// is `Error Domain=NSURLErrorDomain Code=-1004 "(null)"UserInfo={…}` on
    /// Linux, where the localized description is curl's sentence, or Apple's
    /// "Could not connect to the server."
    ///
    /// One kind of error keeps its own description: a plain Swift error,
    /// neither `LocalizedError` nor `CustomNSError` (SwiftNIO's `IOError`, an
    /// enum that writes no message). Foundation has no text for it, and its
    /// `localizedDescription` is only "The operation couldn’t be completed.
    /// (NIOCore.IOError error 1.)". Its description ("Connection reset by
    /// peer (errno: 104)") is the only account of what happened, and is no
    /// `NSError` dump. `ProviderFailure` reads that account to tell a dropped
    /// connection from a rejected request, so it must not be lost either.
    var displayDescription: String {
        let error: any Error = self
        if error is LocalizedError || error is CustomNSError { return error.localizedDescription }
        // Such an error bridges to an NSError named after its own type; an
        // NSError proper, URLError and POSIXError carry a domain of their own.
        if (error as NSError).domain == String(reflecting: type(of: error)) {
            return String(describing: error)
        }
        return error.localizedDescription
    }
}
