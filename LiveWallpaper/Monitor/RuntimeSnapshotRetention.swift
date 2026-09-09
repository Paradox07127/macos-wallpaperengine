import Foundation

extension Runtime {
    /// Keep only modules that remain enabled under the same data identity.
    /// Disabled modules and changed grants must not replay the previous source.
    static func retainedSnapshot(
        _ snapshot: MonitorSnapshot?,
        previous: MonitorRuntimeOptions?,
        next: MonitorRuntimeOptions
    ) -> MonitorSnapshot? {
        guard var snapshot, let previous else { return nil }
        if !next.system || !previous.system {
            snapshot.system = nil
        }
        if !next.music || !previous.music {
            snapshot.nowPlaying = nil
        }
        if !next.agents || !previous.agents {
            snapshot.agents = nil
        } else {
            snapshot.agents = snapshot.agents?.filter { session in
                switch session.provider {
                case .claude: previous.claudeRoot == next.claudeRoot
                case .codex: previous.codexRoot == next.codexRoot
                }
            }
        }
        // Connected/error badges are refreshed by the newly started sources.
        snapshot.health = nil
        return snapshot
    }
}
