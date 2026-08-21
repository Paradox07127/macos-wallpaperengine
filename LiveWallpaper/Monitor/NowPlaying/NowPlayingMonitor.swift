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

/// App-lifetime distributed-notification listener. The DNC observer deliberately
/// outlives every `NowPlayingSource`: overlay pause tears down the whole monitor
/// pipeline, and DNC only pushes on change, so an observer tied to source
/// lifetime would permanently miss track changes during occlusion/lock. With no
/// subscribers this only updates memory — it never pushes a sink.
@MainActor
final class NowPlayingMonitor: NSObject {
    static let shared = NowPlayingMonitor()

    nonisolated static let mappings = NowPlayingPlayerMapping.all
    nonisolated static var subscribedNotificationNames: [String] { mappings.map(\.notificationName) }

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

    init(
        registersObservers: Bool = true,
        runningBundleIDs: @escaping () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
    ) {
        self.runningBundleIDs = runningBundleIDs
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
