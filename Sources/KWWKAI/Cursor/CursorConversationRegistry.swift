import Foundation
import Crypto
import NIOConcurrencyHelpers

// MARK: - Conversation registry & blob store

/// Blob store and last server checkpoint per conversation, shared across the
/// requests of a session so server-side conversation state survives turns.
final class ConversationRegistry: Sendable {
    struct Entry: Sendable {
        let blobStore: CursorBlobStore
        var checkpoint: Data?
    }

    private let entries = NIOLockedValueBox([String: Entry]())

    func state(for conversationId: String) -> Entry {
        entries.withLockedValue { entries in
            if let entry = entries[conversationId] { return entry }
            let entry = Entry(blobStore: CursorBlobStore(), checkpoint: nil)
            entries[conversationId] = entry
            return entry
        }
    }

    func setCheckpoint(_ data: Data, for conversationId: String) {
        entries.withLockedValue { entries in
            var entry = entries[conversationId] ?? Entry(blobStore: CursorBlobStore(), checkpoint: nil)
            entry.checkpoint = data
            entries[conversationId] = entry
        }
    }

    func remove(conversationId: String) {
        _ = entries.withLockedValue { entries in
            entries.removeValue(forKey: conversationId)
        }
    }
}

/// Key/value blob store the server reads from and writes to during a Run. Keys
/// are the raw blob ids (hex-encoded internally for dictionary use).
final class CursorBlobStore: Sendable {
    private let blobs = NIOLockedValueBox([String: Data]())

    /// Store `data` under its sha256 hash and return that blob id.
    func store(_ data: Data) -> Data {
        let id = Data(SHA256.hash(data: data))
        set(id, data: data)
        return id
    }

    func set(_ id: Data, data: Data) {
        blobs.withLockedValue { $0[id.hexString] = data }
    }

    func get(_ id: Data) -> Data? {
        blobs.withLockedValue { $0[id.hexString] }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
