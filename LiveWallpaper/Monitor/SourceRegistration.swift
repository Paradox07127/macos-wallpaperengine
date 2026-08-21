import Foundation

enum SourceRegistration {
    @MainActor private static var registered = false

    /// Shared across pipeline rebuilds; termination flushes so debounce can't drop last cursor writes.
    static let sharedCursorStore = TailCursorStore()

    static func flushCursorStoreForTermination() {
        sharedCursorStore.flush()
    }

    /// Deliberately not inside the agents factory: the Now Playing source must
    /// exist whenever its widget is placed, with or without agent widgets.
    static let nowPlayingFactory: Runtime.SourceFactory = { options in
        guard options.activeWidgetKinds?.contains(.nowPlaying) == true else { return [] }
        // Nil demand = no per-widget information, so fail open rather than
        // starve the effects.
        return [NowPlayingSource(audioReactive: options.sampleDemand?.audioSpectrum ?? true)]
    }

    /// Idempotent; MainActor before first `Runtime.acquire`.
    @MainActor static func registerDefaultFactories() {
        guard !registered else { return }
        registered = true
        // Prime the app-lifetime observer now, not on first pipeline build: an
        // app launched behind the lock screen builds no pipeline until unlock,
        // and track changes in that window would otherwise be lost.
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
