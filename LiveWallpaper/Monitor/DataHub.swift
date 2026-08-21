import Foundation

/// Fan-in point for all `MonitorDataSource`s.
actor DataHub: MonitorSnapshotSink {
    private let broker: SnapshotBroker
    private let throttleInterval: TimeInterval

    private var system: MonitorSystemSnapshot?
    private var agentsBySource: [String: [MonitorAgentSessionState]] = [:]
    private var healthBySource: [String: MonitorSourceHealth] = [:]
    private var nowPlaying: MonitorNowPlayingState?

    private var agentsEnabled = true

    private var lastPublish: Date?
    private var trailingTask: Task<Void, Never>?

    /// Injectable throttle (tests); production default 0.5s (≤2Hz).
    init(broker: SnapshotBroker, throttleInterval: TimeInterval = 0.5) {
        self.broker = broker
        self.throttleInterval = throttleInterval
    }

    // MARK: - MonitorSnapshotSink

    func updateSystem(_ snapshot: MonitorSystemSnapshot) async {
        system = snapshot
        schedulePublish()
    }

    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {
        guard agentsEnabled else { return }
        agentsBySource[sourceID] = sessions
        schedulePublish()
    }

    func updateHealth(_ health: MonitorSourceHealth) async {
        healthBySource[health.sourceID] = health
        schedulePublish()
    }

    func updateNowPlaying(_ state: MonitorNowPlayingState?) async {
        nowPlaying = state
        schedulePublish()
    }

    // MARK: - Module gating

    func setModuleEnabled(agents: Bool) {
        agentsEnabled = agents
        if !agents { agentsBySource.removeAll() }
        schedulePublish()
    }

    // MARK: - Throttled publish

    private func schedulePublish() {
        let now = Date()
        if let last = lastPublish, now.timeIntervalSince(last) < throttleInterval {
            scheduleTrailingPublish(after: last)
        } else {
            publishNow(at: now)
        }
    }

    private func scheduleTrailingPublish(after last: Date) {
        guard trailingTask == nil else { return }
        let delay = throttleInterval - Date().timeIntervalSince(last)
        let nanos = UInt64(max(0, delay) * 1_000_000_000)
        trailingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            await self?.firePendingTrailingPublish()
        }
    }

    private func firePendingTrailingPublish() {
        trailingTask = nil
        publishNow(at: Date())
    }

    private func publishNow(at date: Date) {
        lastPublish = date
        broker.publish(compose(at: date))
    }

    private func compose(at date: Date) -> MonitorSnapshot {
        MonitorSnapshot(
            timestamp: date.timeIntervalSince1970,
            system: system,
            agents: composedAgents(),
            health: composedHealth(),
            nowPlaying: nowPlaying
        )
    }

    private func composedAgents() -> [MonitorAgentSessionState]? {
        guard agentsEnabled, !agentsBySource.isEmpty else { return nil }
        let merged = agentsBySource.values.flatMap { $0 }
        return merged.sorted { lhs, rhs in
            let lp = lhs.status.attentionPriority
            let rp = rhs.status.attentionPriority
            if lp != rp { return lp > rp }
            return lhs.lastEventAt > rhs.lastEventAt
        }
    }

    private func composedHealth() -> [MonitorSourceHealth]? {
        guard !healthBySource.isEmpty else { return nil }
        return healthBySource.values.sorted { $0.sourceID < $1.sourceID }
    }
}
