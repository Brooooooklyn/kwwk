import Foundation
import KWWKAI
import KWWKAgent

/// Lock-protected snapshot of the welcome card's context, bridging the
/// MainActor (where login/logout/model-switch state changes) and the render
/// path (where the @Sendable `headerProvider` re-renders the header on a
/// resize full-repaint). Writers call `update` from the MainActor; readers
/// take an immutable copy under the lock — no unsynchronized MainActor reads.
final class WelcomeHeaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var context: WelcomeContext

    init(_ context: WelcomeContext) {
        self.context = context
    }

    func update(_ context: WelcomeContext) {
        lock.withLock { self.context = context }
    }

    func snapshot() -> WelcomeContext {
        lock.withLock { context }
    }
}
