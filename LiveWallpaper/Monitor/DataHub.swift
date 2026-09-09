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
    private var isStopped = false

    /// Injectable throttle (tests); production default 0.5s (≤2Hz).
    init(
        broker: SnapshotBroker,
        throttleInterval: TimeInterval = 0.5,
        initialSnapshot: MonitorSnapshot? = nil,
        agentsEnabled: Bool = true
    ) {
        self.broker = broker
        self.throttleInterval = throttleInterval
        self.agentsEnabled = agentsEnabled
        if let initialSnapshot {
            system = initialSnapshot.system
            nowPlaying = initialSnapshot.nowPlaying
            if agentsEnabled, let agents = initialSnapshot.agents {
                agentsBySource = Dictionary(grouping: agents, by: { $0.provider.rawValue })
            }
            // Preserve measurement times: a retained frame is not a new sample.
            broker.publish(initialSnapshot)
        }
    }

    // MARK: - MonitorSnapshotSink

    func updateSystem(_ snapshot: MonitorSystemSnapshot) async {
        guard !isStopped else { return }
        system = snapshot
        schedulePublish()
    }

    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {
        guard !isStopped, agentsEnabled else { return }
        agentsBySource[sourceID] = sessions
        schedulePublish()
    }

    func updateHealth(_ health: MonitorSourceHealth) async {
        guard !isStopped else { return }
        healthBySource[health.sourceID] = health
        schedulePublish()
    }

    func updateNowPlaying(_ state: MonitorNowPlayingState?) async {
        guard !isStopped else { return }
        nowPlaying = state
        schedulePublish()
    }

    // MARK: - Module gating

    func setModuleEnabled(agents: Bool) {
        guard !isStopped else { return }
        agentsEnabled = agents
        if !agents {
            agentsBySource.removeAll()
        }
        schedulePublish()
    }

    /// Retire the writer before stopping its sources. Neither a trailing timer
    /// nor a late source callback may overwrite the next pipeline's snapshot.
    func stop() {
        isStopped = true
        trailingTask?.cancel()
        trailingTask = nil
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
        guard !isStopped else { return }
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
        let merged = agentsBySource.values.flatMap(\.self)
        return merged.sorted { lhs, rhs in
            let lp = lhs.status.attentionPriority
            let rp = rhs.status.attentionPriority
            if lp != rp {
                return lp > rp
            }
            return lhs.lastEventAt > rhs.lastEventAt
        }
    }

    private func composedHealth() -> [MonitorSourceHealth]? {
        guard !healthBySource.isEmpty else { return nil }
        return healthBySource.values.sorted { $0.sourceID < $1.sourceID }
    }
}
