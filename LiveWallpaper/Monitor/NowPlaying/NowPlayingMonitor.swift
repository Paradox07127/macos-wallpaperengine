import AppKit
import Foundation

struct NowPlayingPlayerMapping: Sendable {
    let bundleID: String
    let notificationName: String
    let stateKey: String
    let titleKey: String
    let artistKey: String
    let albumKey: String
    let durationKey: String?
    /// Multiplies the raw duration number into seconds.
    let durationScale: Double
    let positionKey: String?
    /// Multiplies the raw position number into seconds.
    let positionScale: Double
    let trackIDKey: String?

    static let all: [NowPlayingPlayerMapping] = [
        // Spotify: `Duration` is integer milliseconds while `Playback Position` is float seconds — hence separate scales.
        NowPlayingPlayerMapping(
            bundleID: "com.spotify.client",
            notificationName: "com.spotify.client.PlaybackStateChanged",
            stateKey: "Player State",
            titleKey: "Name",
            artistKey: "Artist",
            albumKey: "Album",
            durationKey: "Duration",
            durationScale: 0.001,
            positionKey: "Playback Position",
            positionScale: 1.0,
            trackIDKey: "Track ID"
        ),
        // Apple Music mirrors every event as `com.apple.iTunes.playerInfo` with
        // identical content; registering both names would process each event
        // twice, so only the Music name may ever appear here.
        NowPlayingPlayerMapping(
            bundleID: "com.apple.Music",
            notificationName: "com.apple.Music.playerInfo",
            stateKey: "Player State",
            titleKey: "Name",
            artistKey: "Artist",
            albumKey: "Album",
            durationKey: "Total Time",
            durationScale: 0.001,
            positionKey: nil,
            positionScale: 1.0,
            trackIDKey: nil
        ),
    ]
}

@MainActor
final class NowPlayingMonitor: NSObject {
    #if LITE_BUILD
    static let shared = NowPlayingMonitor()
    #else
    static let shared = NowPlayingMonitor(systemProvider: readSystemSnapshot)

    private nonisolated static func readSystemSnapshot() async throws -> MonitorNowPlayingState? {
        try await NowPlayingSystemBridge.shared.snapshot()
    }
    #endif

    nonisolated static let mappings = NowPlayingPlayerMapping.all

    private struct PlayerRecord {
        var state: MonitorNowPlayingState
        var lastEventOrdinal: UInt64
        /// Ordinal of the most recent Playing report; arbitration picks the
        /// highest, so a late Paused can never hide another playing player.
        var lastPlayingOrdinal: UInt64?
    }

    private var records: [String: PlayerRecord] = [:]
    private var ordinal: UInt64 = 0
    private var subscribers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    private let runningBundleIDs: () -> Set<String>
    /// Raw launch-snapshot text for one player, or nil when nothing could be
    /// asked (player gone, no consent, script failure). The default reads
    /// through `NowPlayingController`, which never provokes a consent dialog.
    typealias LaunchSnapshotProvider = @MainActor (String) async -> String?
    private let launchSnapshotProvider: LaunchSnapshotProvider
    private var didAttemptLaunchSeed = false
    typealias SystemProvider = @Sendable () async throws -> MonitorNowPlayingState?
    private let systemProvider: SystemProvider?
    private let systemPollInterval: Duration
    private var systemTask: Task<Void, Never>?
    private var systemState: MonitorNowPlayingState?
    private var systemGeneration: UInt64 = 0

    init(
        registersObservers: Bool = true,
        runningBundleIDs: @escaping () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        launchSnapshotProvider: @escaping LaunchSnapshotProvider = { bundleID in
            await NowPlayingController.shared.value(for: .launchSnapshot, from: bundleID)?.stringValue
        },
        systemProvider: SystemProvider? = nil,
        systemPollInterval: Duration = .seconds(1)
    ) {
        self.runningBundleIDs = runningBundleIDs
        self.systemProvider = systemProvider
        self.systemPollInterval = systemPollInterval
        self.launchSnapshotProvider = launchSnapshotProvider
        super.init()
        guard registersObservers else { return }
        for mapping in Self.mappings {
            // Selector API on purpose: the block variant has no
            // `suspensionBehavior`, and the default behavior coalesces/delays
            // delivery while the app is inactive — this app's normal state.
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(handleNotification(_:)),
                name: Notification.Name(mapping.notificationName),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        // A force-killed player sends no Stopped frame; without this its last
        // record would stay "playing" forever (stale UI + a never-released
        // audio-capture retain downstream).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTermination(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        systemTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleNotification(_ notification: Notification) {
        ingest(name: notification.name.rawValue, userInfo: notification.userInfo ?? [:])
    }

    @objc private func handleAppTermination(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier
        else { return }
        playerDidTerminate(bundleID: bundleID)
    }

    func playerDidTerminate(bundleID: String) {
        let hadRecord = records.removeValue(forKey: bundleID) != nil
        let wasSystemPlayer = systemState?.playerBundleID == bundleID
        if wasSystemPlayer {
            systemState = nil
        }
        guard hadRecord || wasSystemPlayer else { return }
        ordinal &+= 1
        notifySubscribers()
    }

    func ingest(name: String, userInfo: [AnyHashable: Any]) {
        guard let mapping = Self.mappings.first(where: { $0.notificationName == name }) else { return }
        ordinal &+= 1

        let stateString = userInfo[mapping.stateKey] as? String
        if stateString == "Stopped" {
            records.removeValue(forKey: mapping.bundleID)
            notifySubscribers()
            return
        }

        let phase: MonitorNowPlayingPhase?
        switch stateString {
        case "Playing": phase = .playing
        case "Paused": phase = .paused
        default: phase = nil
        }

        let title = userInfo[mapping.titleKey] as? String
        if let title, !title.isEmpty {
            var state = MonitorNowPlayingState(
                phase: phase ?? records[mapping.bundleID]?.state.phase ?? .paused,
                title: title
            )
            state.artist = nonEmpty(userInfo[mapping.artistKey] as? String)
            state.album = nonEmpty(userInfo[mapping.albumKey] as? String)
            if let key = mapping.durationKey, let number = userInfo[key] as? NSNumber {
                state.duration = number.doubleValue * mapping.durationScale
            }
            if let key = mapping.positionKey, let number = userInfo[key] as? NSNumber {
                state.position = number.doubleValue * mapping.positionScale
                state.positionSampledAt = Date().timeIntervalSince1970
            }
            if let key = mapping.trackIDKey {
                state.trackID = nonEmpty(userInfo[key] as? String)
            }
            state.playerBundleID = mapping.bundleID
            var record = records[mapping.bundleID]
                ?? PlayerRecord(state: state, lastEventOrdinal: ordinal, lastPlayingOrdinal: nil)
            record.state = state
            record.lastEventOrdinal = ordinal
            if state.phase == .playing { record.lastPlayingOrdinal = ordinal }
            records[mapping.bundleID] = record
            notifySubscribers()
        } else if let phase, var record = records[mapping.bundleID] {
            // Metadata-free frames (Music sends bare `Player State`) update the
            // phase without clearing metadata; with no prior record there is no
            // title, and title-less media is never published.
            record.state.phase = phase
            record.lastEventOrdinal = ordinal
            if phase == .playing { record.lastPlayingOrdinal = ordinal }
            records[mapping.bundleID] = record
            notifySubscribers()
        }
    }

    // MARK: - Arbitration

    var currentState: MonitorNowPlayingState {
        if var systemState {
            let fallback = arbitratedRecord()?.state
            if systemState.phase == .playing || fallback?.phase != .playing {
                if let fallback, fallback.playerBundleID == systemState.playerBundleID,
                   fallback.title == systemState.title, fallback.artist == systemState.artist {
                    if systemState.playerBundleID == "com.spotify.client" {
                        systemState.trackID = fallback.trackID ?? systemState.trackID
                    }
                    systemState.artwork = systemState.artwork ?? fallback.artwork
                }
                return systemState
            }
        }
        if let record = arbitratedRecord() { return record.state }
        let knownPlayers = Set(Self.mappings.map(\.bundleID))
        let anyRunning = !runningBundleIDs().isDisjoint(with: knownPlayers)
        return MonitorNowPlayingState(phase: anyRunning ? .awaitingFirstEvent : .noPlayer, title: "")
    }

    /// current = most recent Playing reporter; none playing → most recent event
    /// (already carrying its own paused phase).
    private func arbitratedRecord() -> PlayerRecord? {
        let playing = records.values.filter { $0.state.phase == .playing }
        if let winner = playing.max(by: { ($0.lastPlayingOrdinal ?? 0) < ($1.lastPlayingOrdinal ?? 0) }) {
            return winner
        }
        return records.values.max { $0.lastEventOrdinal < $1.lastEventOrdinal }
    }

    // MARK: - Subscriptions

    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        subscribers[id] = handler
        handler(ordinal, currentState)
        seedFromRunningPlayersIfNeeded()
        startSystemPollingIfNeeded()
    }

    private func startSystemPollingIfNeeded() {
        guard systemTask == nil, let provider = systemProvider else { return }
        systemGeneration &+= 1
        let generation = systemGeneration
        let interval = systemPollInterval
        systemTask = Task { [weak self] in
            var failures = 0
            var inactivityFactor = 1
            while !Task.isCancelled {
                do {
                    let state = try await provider()
                    guard !Task.isCancelled else { return }
                    self?.applySystemState(state, generation: generation)
                    failures = 0
                    inactivityFactor = state?.phase == .playing ? 1 : state == nil ? 3 : 2
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.applySystemState(nil, generation: generation)
                    failures = min(failures + 1, 4)
                }
                do {
                    try await Task.sleep(for: failures == 0 ? interval * inactivityFactor : .seconds(1 << failures))
                } catch { return }
            }
        }
    }

    private func applySystemState(_ state: MonitorNowPlayingState?, generation: UInt64) {
        guard systemGeneration == generation, !subscribers.isEmpty, systemState != state else { return }
        systemState = state
        ordinal &+= 1
        notifySubscribers()
    }

    private func seedFromRunningPlayersIfNeeded() {
        guard !didAttemptLaunchSeed else { return }
        didAttemptLaunchSeed = true
        guard records.isEmpty else { return }
        let running = runningBundleIDs()
        let candidates = Self.mappings.map(\.bundleID).filter { running.contains($0) }
        guard !candidates.isEmpty else { return }
        Task { [weak self] in
            for bundleID in candidates {
                guard let self else { return }
                guard let raw = await self.launchSnapshotProvider(bundleID),
                      let seed = Self.parseLaunchSnapshot(raw) else { continue }
                self.applyLaunchSeed(seed, bundleID: bundleID)
            }
        }
    }

    struct LaunchSeed: Equatable {
        var phase: MonitorNowPlayingPhase
        var title: String
        var artist: String?
        var album: String?
    }

    /// Lines are `state\ntitle\nartist\nalbum`; a stopped player answers "".
    /// Unknown state words (a future player, a localization surprise) drop the
    /// seed rather than guess — the notification path still corrects us.
    nonisolated static func parseLaunchSnapshot(_ raw: String) -> LaunchSeed? {
        let lines = raw.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        let phase: MonitorNowPlayingPhase
        switch lines[0] {
        case "playing": phase = .playing
        case "paused": phase = .paused
        default: return nil
        }
        let title = lines[1]
        guard !title.isEmpty else { return nil }
        func field(_ index: Int) -> String? {
            guard lines.count > index, !lines[index].isEmpty else { return nil }
            return lines[index]
        }
        return LaunchSeed(phase: phase, title: title, artist: field(2), album: field(3))
    }

    /// Test seam for the seed path; a real notification that raced in wins.
    func applyLaunchSeed(_ seed: LaunchSeed, bundleID: String) {
        guard records[bundleID] == nil else { return }
        ordinal &+= 1
        var state = MonitorNowPlayingState(phase: seed.phase, title: seed.title)
        state.artist = seed.artist
        state.album = seed.album
        state.playerBundleID = bundleID
        records[bundleID] = PlayerRecord(
            state: state,
            lastEventOrdinal: ordinal,
            lastPlayingOrdinal: seed.phase == .playing ? ordinal : nil
        )
        notifySubscribers()
    }

    func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty {
            systemGeneration &+= 1
            systemTask?.cancel()
            systemTask = nil
            systemState = nil
        }
    }

    private func notifySubscribers() {
        guard !subscribers.isEmpty else { return }
        let state = currentState
        for handler in subscribers.values {
            handler(ordinal, state)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
