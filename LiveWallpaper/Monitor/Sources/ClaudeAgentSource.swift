import Foundation

final class ClaudeAgentSource: MonitorDataSource {
    let sourceID = "claude"

    struct TailBootstrap {
        let reader: JSONLTailReader
        let restoredModel: ClaudeSessionModel?
    }

    private let engine: Engine

    init(rootURL: URL, cursorStore: TailCursorStore? = nil) {
        engine = Engine(rootURL: rootURL, cursorStore: cursorStore)
    }

    /// Reconnects the scanner-owned session identity to a privacy-minimized durable aggregate.
    static func makeTailBootstrap(
        url: URL,
        candidateSessionID: String,
        storedCursor: TailCursorState?,
        storedAggregate: SessionAggregateState?
    ) -> TailBootstrap {
        guard let storedCursor,
              let storedAggregate, storedAggregate.activity != nil,
              let restoredModel = ClaudeSessionModel.restore(
                  from: storedAggregate,
                  sessionId: candidateSessionID
              ) else {
            return TailBootstrap(reader: JSONLTailReader(url: url, resumeFrom: nil), restoredModel: nil)
        }
        return TailBootstrap(
            reader: JSONLTailReader(url: url, resumeFrom: storedCursor),
            restoredModel: restoredModel
        )
    }

    func start(sink: any MonitorSnapshotSink) async {
        await engine.start(sink: sink)
    }

    func stop() async {
        await engine.stop()
    }
}

// MARK: - Engine (all mutable state, isolated)

private actor Engine {
    private let rootURL: URL
    // `var`: the scanner keeps a per-directory listing cache across rescans.
    private var scanner: ClaudeSessionScanner
    private let cursorStore: TailCursorStore?

    private var sink: (any MonitorSnapshotSink)?
    private var pollTask: Task<Void, Never>?

    private var readers: [String: JSONLTailReader] = [:]
    private var models: [String: ClaudeSessionModel] = [:]
    private var sourceURLs: [String: URL] = [:]

    private var lastScan: Date = .distantPast
    private var consecutiveIOFailures = 0

    private var waitTracker = MonitorAgentWaitTracker()
    private var polling = AgentPollingPolicy()
    private var changed = false
    private var catchingUp = false
    private var lastProcessProbe = Date.distantPast
    private var liveness: [String: Bool] = [:]
    private var descriptors: [ClaudePIDDescriptor] = []

    /// Cadence.
    private static let rescanInterval: TimeInterval = 10
    // Drop ended sessions from the pushed list once this stale.
    private static let endedRetention: TimeInterval = 2 * 3600
    private static let ioFailureThreshold = 3

    init(rootURL: URL, cursorStore: TailCursorStore?) {
        self.rootURL = rootURL
        scanner = ClaudeSessionScanner(rootURL: rootURL)
        self.cursorStore = cursorStore
    }

    func start(sink: any MonitorSnapshotSink) {
        self.sink = sink
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        let task = pollTask
        pollTask = nil
        task?.cancel()
        // No producer may mutate the cursor generation after the termination flush snapshots it.
        if let task {
            await task.value
        }
        sink = nil
        readers.removeAll()
        models.removeAll()
        sourceURLs.removeAll()
        cursorStore?.flush()
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let liveCount = await tick()
            let interval = polling.interval(changed: changed, working: liveCount > 0, catchingUp: catchingUp)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func tick() async -> Int {
        let now = Date()
        changed = false
        catchingUp = false

        if now.timeIntervalSince(lastScan) >= Self.rescanInterval {
            lastScan = now
            do {
                try rescan(now: now)
                consecutiveIOFailures = 0
            } catch {
                // Projects root unreadable ⇒ permission problem.
                await pushHealth(state: "unauthorized", detail: "cannot read ~/.claude/projects", now: now)
                return 0
            }
        }

        if now.timeIntervalSince(lastProcessProbe) >= 5 {
            descriptors = scanner.loadPIDDescriptors()
            liveness = scanner.livenessBySession(descriptors)
            lastProcessProbe = now
        }

        var pollFailed = false
        for (sessionId, reader) in readers {
            do {
                let outcome = try reader.poll(byteBudget: 128 * 1024)
                catchingUp = catchingUp || reader.hasUnreadBytes
                if outcome.fileVanished {
                    readers[sessionId] = nil
                    if let url = sourceURLs[sessionId] {
                        cursorStore?.remove(for: url)
                    }
                    continue
                }
                if outcome.didRotate {
                    models[sessionId] = ClaudeSessionModel(sessionId: sessionId)
                    if let url = sourceURLs[sessionId] {
                        cursorStore?.removeAggregate(for: url)
                    }
                }
                changed = changed || !outcome.newLines.isEmpty
                if !outcome.newLines.isEmpty {
                    var model = models[sessionId] ?? ClaudeSessionModel(sessionId: sessionId)
                    for data in outcome.newLines {
                        if var line = ClaudeTranscriptLine(data: data) {
                            if sourceURLs[sessionId]?.deletingLastPathComponent().lastPathComponent == "subagents" {
                                line.isSidechain = false
                            }
                            model.ingest(line)
                        }
                    }
                    model.activity.partialHistory = model.activity.partialHistory || reader.startedMidFile
                    models[sessionId] = model
                }
                if let url = sourceURLs[sessionId],
                   let cursorState = reader.cursorState {
                    if let model = models[sessionId] {
                        cursorStore?.set(cursorState, aggregate: model.snapshotState(), for: url)
                    } else {
                        cursorStore?.set(cursorState, for: url)
                    }
                }
            } catch {
                pollFailed = true
            }
        }

        let sessions = composeSessions(now: now, liveness: liveness)
        await pushAgents(sessions)

        if pollFailed {
            consecutiveIOFailures += 1
            if consecutiveIOFailures >= Self.ioFailureThreshold {
                await pushHealth(state: "error", detail: "transcript read failures", now: now)
            } else {
                await pushHealth(state: "ok", detail: nil, now: now)
            }
        } else {
            consecutiveIOFailures = 0
            await pushHealth(state: "ok", detail: nil, now: now)
        }

        return sessions.filter { $0.status == .running }.count
    }

    private func rescan(now: Date) throws {
        let candidates = try scanner.discoverTranscripts(now: now)
        let discovered = Set(candidates.map(\.sessionId))

        for candidate in candidates where readers[candidate.sessionId] == nil {
            let storedCursor = cursorStore?.state(for: candidate.url)
            let storedAggregate = cursorStore?.aggregate(for: candidate.url, provider: .claude)
            let bootstrap = ClaudeAgentSource.makeTailBootstrap(
                url: candidate.url,
                candidateSessionID: candidate.sessionId,
                storedCursor: storedCursor,
                storedAggregate: storedAggregate
            )
            readers[candidate.sessionId] = bootstrap.reader
            if let restoredModel = bootstrap.restoredModel {
                models[candidate.sessionId] = restoredModel
            } else if models[candidate.sessionId] == nil {
                models[candidate.sessionId] = ClaudeSessionModel(sessionId: candidate.sessionId)
                if storedAggregate != nil {
                    cursorStore?.removeAggregate(for: candidate.url)
                }
            }
            for object in JSONLTailReader.headerObjects(at: candidate.url) {
                models[candidate.sessionId]?.hydrateMetadata(object)
            }
            sourceURLs[candidate.sessionId] = candidate.url
        }

        for sessionId in Array(models.keys) where !discovered.contains(sessionId) {
            let lastEvent = models[sessionId]?.lastEventAt ?? .distantPast
            if now.timeIntervalSince(lastEvent) > Self.endedRetention {
                readers[sessionId] = nil
                models[sessionId] = nil
                sourceURLs[sessionId] = nil
            }
        }
    }

    private func composeSessions(now: Date, liveness: [String: Bool]) -> [MonitorAgentSessionState] {
        var states: [MonitorAgentSessionState] = []
        for (sessionId, model) in models {
            let parentID = sourceURLs[sessionId].flatMap { url -> String? in
                guard url.deletingLastPathComponent().lastPathComponent == "subagents" else { return nil }
                return url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            }
            let alive = liveness[sessionId] ?? parentID.flatMap { liveness[$0] } ?? false
            var state = model.snapshot(now: now, processAlive: alive)
            state.parentSessionID = parentID.map { "claude:" + $0 }
            state.livenessEvidence = liveness[sessionId] != nil ? "processDescriptor" : (parentID != nil ? "parentProcess" : "unknown")
            state.title = state.title ?? descriptors.first(where: { $0.sessionId == sessionId })?.name.flatMap(AgentSignalDeriver.displayMetadata)
            // Overlay the cross-scan wait clock: stamp the flip into needsInput with
            // the session's last event time, carry it while blocked, clear otherwise.
            state.waitSince = waitTracker.waitSince(
                sessionID: state.id,
                status: state.status,
                eventTime: state.lastEventAt
            )
            if state.status == .ended,
               now.timeIntervalSince1970 - state.lastEventAt > Self.endedRetention {
                continue
            }
            states.append(state)
        }
        waitTracker.retainOnly(Set(states.map(\.id)))
        states.sort { $0.lastEventAt > $1.lastEventAt }
        return states
    }

    // MARK: - Sink helpers

    private func pushAgents(_ sessions: [MonitorAgentSessionState]) async {
        await sink?.updateAgents(sourceID: sourceID, sessions: sessions)
    }

    private func pushHealth(state: String, detail: String?, now: Date) async {
        await sink?.updateHealth(MonitorSourceHealth(
            sourceID: sourceID,
            state: state,
            detail: detail,
            lastUpdateAt: now.timeIntervalSince1970
        ))
    }

    private var sourceID: String {
        "claude"
    }
}
