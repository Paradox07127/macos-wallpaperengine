import AppKit
import Foundation

/// Per-player userInfo decoding — a data row, not a code branch, so a new
/// player is a new row and the ingest path stays untouched.
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
        // Spotify: `Duration` is integer milliseconds while `Playback Position`
        // is float seconds (fixtures 2026-08-20) — hence separate scales.
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

/// App-lifetime distributed-notification listener that deliberately outlives every `NowPlayingSource`:
/// overlay pause tears down the whole monitor pipeline, and DNC only pushes on change, so an observer
/// tied to source lifetime would permanently miss track changes during occlusion/lock. With no
/// subscribers this only updates memory, never pushes a sink.
@MainActor
final class NowPlayingMonitor: NSObject {
    static let shared = NowPlayingMonitor()

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

    init(
        registersObservers: Bool = true,
        runningBundleIDs: @escaping () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        },
        launchSnapshotProvider: @escaping LaunchSnapshotProvider = { bundleID in
            await NowPlayingController.shared.value(for: .launchSnapshot, from: bundleID)?.stringValue
        }
    ) {
        self.runningBundleIDs = runningBundleIDs
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
        // The shared instance never deallocates; this keeps test instances from
        // leaving a dangling DNC registration behind.
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

    /// Terminated player == Stopped: drop its record so arbitration falls to
    /// the other player or the no-track phases. Also the test seam.
    func playerDidTerminate(bundleID: String) {
        guard records.removeValue(forKey: bundleID) != nil else { return }
        ordinal &+= 1
        notifySubscribers()
    }

    /// Exactly what the selector delivers — also the test seam.
    func ingest(name: String, userInfo: [AnyHashable: Any]) {
        guard let mapping = Self.mappings.first(where: { $0.notificationName == name }) else { return }
        ordinal &+= 1

        let stateString = userInfo[mapping.stateKey] as? String
        if stateString == "Stopped" {
            // Stopped == the player no longer provides media: drop its record so
            // arbitration falls to the other player or the no-track phases.
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

    /// Replays the current state synchronously so a starting source has no
    /// resume gap. The ordinal lets subscribers drop out-of-order hops.
    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        subscribers[id] = handler
        handler(ordinal, currentState)
        seedFromRunningPlayersIfNeeded()
    }

    /// DNC only pushes on change, so a launch while a song is already playing
    /// leaves the monitor blind until the next track — the "wallpaper shows the
    /// song only after a reload" symptom. One AppleScript read per RUNNING
    /// player closes that gap; the query layer already refuses to prompt for
    /// consent, so a never-authorized player just stays on the old behavior.
    /// Demand-driven (first subscriber), once per process: later launches of a
    /// player are covered by its own notifications.
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
