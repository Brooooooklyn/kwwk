import Foundation
import Crypto

// MARK: - Conversation registry & blob store

/// Blob store and last server checkpoint per conversation, shared across the
/// requests of a session so server-side conversation state survives turns.
final class ConversationRegistry: @unchecked Sendable {
    struct Entry {
        let blobStore: CursorBlobStore
        var checkpoint: Data?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func state(for conversationId: String) -> Entry {
        lock.withLock {
            if let entry = entries[conversationId] { return entry }
            let entry = Entry(blobStore: CursorBlobStore(), checkpoint: nil)
            entries[conversationId] = entry
            return entry
        }
    }

    func setCheckpoint(_ data: Data, for conversationId: String) {
        lock.withLock {
            var entry = entries[conversationId] ?? Entry(blobStore: CursorBlobStore(), checkpoint: nil)
            entry.checkpoint = data
            entries[conversationId] = entry
        }
    }

    func remove(conversationId: String) {
        _ = lock.withLock {
            entries.removeValue(forKey: conversationId)
        }
    }
}

/// Key/value blob store the server reads from and writes to during a Run. Keys
/// are the raw blob ids (hex-encoded internally for dictionary use).
final class CursorBlobStore: @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]

    /// Store `data` under its sha256 hash and return that blob id.
    func store(_ data: Data) -> Data {
        let id = Data(SHA256.hash(data: data))
        set(id, data: data)
        return id
    }

    func set(_ id: Data, data: Data) {
        lock.withLock { blobs[id.hexString] = data }
    }

    func get(_ id: Data) -> Data? {
        lock.withLock { blobs[id.hexString] }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
