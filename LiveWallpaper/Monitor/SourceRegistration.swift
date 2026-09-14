import Foundation

enum SourceRegistration {
    @MainActor private static var registered = false

    static let sharedCursorStore = TailCursorStore()

    static func flushCursorStoreForTermination() {
        sharedCursorStore.flush()
    }

    /// Deliberately not inside the agents factory: the Now Playing source must
    /// exist whenever a music layer is visible, with or without any board.
    static let nowPlayingFactory: Runtime.SourceFactory = { options in
        guard options.music else { return [] }
        return [NowPlayingSource(audioReactive: options.musicAudioReactive)]
    }

    @MainActor static func registerDefaultFactories() {
        guard !registered else { return }
        registered = true
        _ = NowPlayingMonitor.shared
        Runtime.extraSourceFactories.append(nowPlayingFactory)
        Runtime.extraSourceFactories.append { options in
            guard options.agents else { return [] }
            let cursorStore = sharedCursorStore
            var sources: [any MonitorDataSource] = []
            if let root = options.claudeRoot {
                sources.append(ClaudeAgentSource(rootURL: root, cursorStore: cursorStore))
            }
            if let root = options.codexRoot {
                sources.append(CodexAgentSource(rootURL: root, cursorStore: cursorStore))
            }
            return sources
        }
    }
}
