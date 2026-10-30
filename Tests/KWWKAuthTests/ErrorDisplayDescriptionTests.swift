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
    private struct Silent: LocalizedError, CustomStringConvertible {
        var errorDescription: String? { "" }
        var description: String { "silent(code: 7)" }
    }

    private static let url = "http://127.0.0.1:3425/v1/messages"

    @Test func nsErrorWithALocalizedDescriptionGivesIt() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
            NSLocalizedDescriptionKey: "Could not connect to the server.",
            NSURLErrorFailingURLStringErrorKey: Self.url,
        ])
        #expect(error.displayDescription == "Could not connect to the server.")
    }

    // No text of its own: Foundation's "The operation couldn't be completed.
    // (NSURLErrorDomain error -1004.)" would drop the code and URL, so the
    // description is what is shown.
    @Test func nsErrorWithOnlyURLKeysFallsBackToItsDescription() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
            NSURLErrorFailingURLStringErrorKey: Self.url,
        ])
        #expect(error.displayDescription == String(describing: error))
        #expect(error.displayDescription != error.localizedDescription)
        #expect(error.displayDescription.contains("-1004"))
    }

    @Test func urlErrorWithALocalizedDescriptionGivesIt() {
        let error = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        #expect(error.displayDescription == "The request timed out.")
    }

    @Test func localizedErrorGivesItsErrorDescription() {
        #expect(Localized().displayDescription == "The team has not connected a login.")
    }

    @Test func emptyErrorDescriptionFallsBackToTheDescription() {
        #expect(Silent().displayDescription == "silent(code: 7)")
    }

    @Test func plainSwiftErrorKeepsItsOwnDescription() {
        #expect(Described().displayDescription == "read(): Connection reset by peer (errno: 104)")
        #expect(Named.maxRetriesExceeded.displayDescription == "maxRetriesExceeded")
    }

    #if canImport(Darwin)
    // Apple's Cocoa domain names the failure through its user-info provider,
    // with neither a LocalizedError nor a description key behind it.
    @Test func domainProviderDescriptionIsUsed() {
        let error = CocoaError(.fileNoSuchFile)
        #expect(error.displayDescription == error.localizedDescription)
        #expect(!error.displayDescription.contains("Error Domain="))
    }
    #endif
}
