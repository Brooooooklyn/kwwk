import Foundation
import Testing
@testable import KWWKAI

@Suite("Cursor end-stream failures")
struct CursorEndStreamFailureTests {

    /// The end-stream a Free plan got for a named model, 2026-10-11. Its code
    /// alone reads as a rate limit to wait out; Cursor says asking again
    /// cannot help.
    @Test("a refusal Cursor marks not retryable is not retried")
    func refusalIsNotRetried() throws {
        let body = Data(#"{"error":{"code":"resource_exhausted","message":"Error","details":[{"type":"aiserver.v1.ErrorDetails","debug":{"error":"ERROR_RATE_LIMITED_CHANGEABLE","details":{"title":"Named models unavailable","detail":"Free plans can only use Auto. Switch to Auto or upgrade plans to continue.","isRetryable":false,"showRequestId":false,"analyticsMetadata":{"actionRequired":"upgrade"}},"isExpected":true},"value":"CDMS"}]}}"#.utf8)
        let failure = try #require(CursorConnectResponse.failureFromEndStream(body))
        #expect(failure.providerCode == "resource_exhausted")
        #expect(failure.shouldRetry == false)
        #expect(!failure.isRetryable)
        #expect(failure.message.hasSuffix(
            "Named models unavailable: Free plans can only use Auto. Switch to Auto or upgrade plans to continue."
        ))
    }

    @Test("an error Cursor does not mark keeps its code's reading")
    func unmarkedErrorKeepsItsCode() throws {
        for body in [
            #"{"error":{"code":"resource_exhausted","message":"busy"}}"#,
            #"{"error":{"code":"unavailable","message":"Error","details":[{"debug":{"details":{"title":"Overloaded","detail":"Try again.","isRetryable":true}}}]}}"#,
        ] {
            let failure = try #require(CursorConnectResponse.failureFromEndStream(Data(body.utf8)))
            #expect(failure.shouldRetry == nil)
            #expect(failure.isRetryable)
        }
        // A stream that ended well carries no error.
        #expect(CursorConnectResponse.failureFromEndStream(Data("{}".utf8)) == nil)
    }
}
