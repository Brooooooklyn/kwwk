import Foundation
import KWWKAI
import KWWKAgent
import NIOConcurrencyHelpers

/// Lock-protected snapshot of the welcome card's context, bridging the
/// MainActor (where login/logout/model-switch state changes) and the render
/// path (where the @Sendable `headerProvider` re-renders the header on a
/// resize full-repaint). Writers call `update` from the MainActor; readers
/// take an immutable copy under the lock — no unsynchronized MainActor reads.
final class WelcomeHeaderState: Sendable {
    private let context: NIOLockedValueBox<WelcomeContext>

    init(_ context: WelcomeContext) {
        self.context = NIOLockedValueBox(context)
    }

    func update(_ context: WelcomeContext) {
        self.context.withLockedValue { $0 = context }
    }

    func snapshot() -> WelcomeContext {
        context.withLockedValue { $0 }
    }
}
