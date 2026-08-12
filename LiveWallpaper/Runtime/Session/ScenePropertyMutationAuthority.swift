import os

/// Cross-actor latest-intent generation for incremental scene proposals.
/// Lock only covers generation R/W — never renderer work while held.
struct ScenePropertyMutationToken: Equatable, Sendable {
    fileprivate let generation: UInt64
}

final class ScenePropertyMutationAuthority: Sendable {
    private let generation = OSAllocatedUnfairLock(initialState: UInt64(0))

    @discardableResult
    func advance() -> ScenePropertyMutationToken {
        generation.withLock { generation in
            generation &+= 1
            return ScenePropertyMutationToken(generation: generation)
        }
    }

    func currentToken() -> ScenePropertyMutationToken {
        generation.withLock {
            ScenePropertyMutationToken(generation: $0)
        }
    }

    func isCurrent(_ token: ScenePropertyMutationToken) -> Bool {
        generation.withLock { generation in
            generation == token.generation
        }
    }
}
