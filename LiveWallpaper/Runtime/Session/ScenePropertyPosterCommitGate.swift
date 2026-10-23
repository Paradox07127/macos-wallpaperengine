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
        private var nextSequence: UInt64 = 0

        func stage(
            overrides: [String: WallpaperEngineProjectPropertyValue]
        ) -> ScenePropertyPosterCommit {
            nextSequence &+= 1
            let commit = ScenePropertyPosterCommit(
                sequence: nextSequence,
                overridesRevision: ScenePropertyOverridesRevision(overrides)
            )
            return commit
        }
    }
#endif
