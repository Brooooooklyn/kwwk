import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KWWKAuth

@Suite("Error display description")
struct ErrorDisplayDescriptionTests {
    private struct Described: Error, CustomStringConvertible {
        var description: String { "read(): Connection reset by peer (errno: 104)" }
    }
    private enum Named: Error { case maxRetriesExceeded }
    private struct Localized: LocalizedError {
        var errorDescription: String? { "The team has not connected a login." }
    }

    @Test func nsErrorGivesItsLocalizedDescription() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
            NSLocalizedDescriptionKey: "Could not connect to the server.",
            NSURLErrorFailingURLStringErrorKey: "http://127.0.0.1:3425/v1/messages",
        ])
        #expect(error.displayDescription == "Could not connect to the server.")
    }

    @Test func foundationErrorStructsGiveTheirLocalizedDescription() {
        let url = URLError(.timedOut)
        #expect(url.displayDescription == url.localizedDescription)
        #expect(!url.displayDescription.contains("Error Domain="))
        let posix = POSIXError(.ECONNRESET)
        #expect(posix.displayDescription == posix.localizedDescription)
        #expect(!posix.displayDescription.contains("Error Domain="))
    }

    @Test func localizedErrorGivesItsErrorDescription() {
        #expect(Localized().displayDescription == "The team has not connected a login.")
    }

    @Test func plainSwiftErrorKeepsItsOwnDescription() {
        #expect(Described().displayDescription == "read(): Connection reset by peer (errno: 104)")
        #expect(Named.maxRetriesExceeded.displayDescription == "maxRetriesExceeded")
    }
}
