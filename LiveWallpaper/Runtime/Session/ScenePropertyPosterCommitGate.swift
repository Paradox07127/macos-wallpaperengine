#if !LITE_BUILD
    import Foundation
    import LiveWallpaperCore

    struct ScenePropertyOverridesRevision: Hashable, Sendable {
        struct Entry: Hashable, Sendable {
            let key: String
            let value: WallpaperEngineProjectPropertyValue
        }

        let entries: [Entry]

        init(_ overrides: [String: WallpaperEngineProjectPropertyValue]) {
            entries = overrides
                .map { Entry(key: $0.key, value: $0.value) }
                .sorted { $0.key < $1.key }
        }
    }

    struct ScenePropertyPosterCommit: Equatable, Sendable {
        let sequence: UInt64
        let overridesRevision: ScenePropertyOverridesRevision
    }

    @MainActor
    final class ScenePropertyPosterCommitGate {
        private struct Waiter {
            let commit: ScenePropertyPosterCommit
            let continuation: CheckedContinuation<Bool, Never>
        }

        private var nextSequence: UInt64 = 0
        private var stagedCommit: ScenePropertyPosterCommit?
        private var resolvedCommit: (commit: ScenePropertyPosterCommit, result: Bool)?
        private var waiters: [UUID: Waiter] = [:]
        private var isValid = true

        func stage(
            overrides: [String: WallpaperEngineProjectPropertyValue]
        ) -> ScenePropertyPosterCommit {
            finishAll(result: false)
            nextSequence &+= 1
            let commit = ScenePropertyPosterCommit(
                sequence: nextSequence,
                overridesRevision: ScenePropertyOverridesRevision(overrides)
            )
            stagedCommit = commit
            return commit
        }

        func staged(matching revision: ScenePropertyOverridesRevision) -> ScenePropertyPosterCommit? {
            guard stagedCommit?.overridesRevision == revision else { return nil }
            return stagedCommit
        }

        func wait(for expected: ScenePropertyPosterCommit) async -> Bool {
            guard isValid, stagedCommit == expected, !Task.isCancelled else { return false }
            if let resolvedCommit, resolvedCommit.commit == expected {
                return resolvedCommit.result
            }
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard isValid, stagedCommit == expected, !Task.isCancelled else {
                        continuation.resume(returning: false)
                        return
                    }
                    if let resolvedCommit, resolvedCommit.commit == expected {
                        continuation.resume(returning: resolvedCommit.result)
                    } else {
                        waiters[id] = Waiter(commit: expected, continuation: continuation)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.finish(id, result: false)
                }
            }
        }

        func resolve(_ commit: ScenePropertyPosterCommit, result: Bool) {
            guard isValid else { return }
            resolvedCommit = (commit, result)
            for id in waiters.compactMap({ $0.value.commit == commit ? $0.key : nil }) {
                finish(id, result: result)
            }
        }

        func invalidate() {
            guard isValid else { return }
            isValid = false
            stagedCommit = nil
            resolvedCommit = nil
            finishAll(result: false)
        }

        private func finishAll(result: Bool) {
            for id in Array(waiters.keys) {
                finish(id, result: result)
            }
        }

        private func finish(_ id: UUID, result: Bool) {
            guard let waiter = waiters.removeValue(forKey: id) else { return }
            waiter.continuation.resume(returning: result)
        }
    }
#endif
