import Foundation

enum MonitorSourceRegistration {
    @MainActor private static var registered = false

    /// Shared across pipeline rebuilds; termination flushes so debounce can't drop last cursor writes.
    static let sharedCursorStore = MonitorTailCursorStore()

    static func flushCursorStoreForTermination() {
        sharedCursorStore.flush()
    }

    /// Idempotent; MainActor before first `MonitorRuntime.acquire`.
    @MainActor static func registerDefaultFactories() {
        guard !registered else { return }
        registered = true
        MonitorRuntime.extraSourceFactories.append { options in
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
