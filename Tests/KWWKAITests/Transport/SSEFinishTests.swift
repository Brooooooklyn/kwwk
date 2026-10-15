import Foundation
import Testing
@testable import KWWKAI

/// Some servers close the connection right after the last field line, with
/// no trailing newline. `finish()` must still read that line.
@Suite("SSE finish with an unterminated last line")
struct SSEFinishTests {
    @Test("a final data line with no newline is kept")
    func unterminatedDataLine() {
        let parser = SSEParser()
        parser.ingest("event: message_stop\ndata: {\"type\":\"message_stop\"}")
        #expect(parser.drain().isEmpty)
        let messages = parser.finish()
        #expect(messages.map(\.event) == ["message_stop"])
        #expect(messages.map(\.data) == ["{\"type\":\"message_stop\"}"])
    }

    @Test("a final data line ending in a bare \\r is kept without the \\r")
    func unterminatedDataLineWithCR() {
        let parser = SSEParser()
        parser.ingest("data: one\r\n\r\ndata: two\r")
        let messages = parser.drain() + parser.finish()
        #expect(messages.map(\.data) == ["one", "two"])
    }

    @Test("a newline-terminated stream finishes as before")
    func terminatedStream() {
        let parser = SSEParser()
        parser.ingest("data: one\n\ndata: two\n")
        #expect(parser.drain().map(\.data) == ["one"])
        #expect(parser.finish().map(\.data) == ["two"])
        #expect(parser.finish().isEmpty)
    }
}
