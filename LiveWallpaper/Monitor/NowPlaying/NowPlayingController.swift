import AppKit
import CoreServices
import Foundation

// MARK: - Commands

enum NowPlayingCommand: Hashable, Sendable {
    case playPause
    case next
    case previous
    case seek(seconds: Double)
}

/// Per-player AppleScript vocabulary — a data row, not a code branch, mirroring
/// `NowPlayingPlayerMapping`: a new player is a new row and the send path stays
/// untouched. `seekPhrase` is nil for a player with no position vocabulary.
struct NowPlayingControlMapping: Sendable {
    let bundleID: String
    /// The name `tell application "…"` addresses.
    let applicationName: String
    let playPausePhrase: String
    let nextPhrase: String
    let previousPhrase: String
    let seekPhrase: String?

    static let all: [NowPlayingControlMapping] = [
        NowPlayingControlMapping(
            bundleID: "com.spotify.client",
            applicationName: "Spotify",
            playPausePhrase: "playpause",
            nextPhrase: "next track",
            previousPhrase: "previous track",
            seekPhrase: "set player position to"
        ),
        NowPlayingControlMapping(
            bundleID: "com.apple.Music",
            applicationName: "Music",
            playPausePhrase: "playpause",
            nextPhrase: "next track",
            previousPhrase: "previous track",
            seekPhrase: "set player position to"
        ),
    ]

    static func mapping(for bundleID: String?) -> NowPlayingControlMapping? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleID == bundleID }
    }
}

// MARK: - Failures

enum NowPlayingControlFailure: Error, Equatable, Sendable {
    /// No state, or a state whose player never identified itself.
    case noPlayer
    /// A player we have no control row for.
    case unsupportedPlayer
    /// Known-denied: nothing was sent, and nothing will be until the user
    /// flips the switch in System Settings.
    case notAuthorized
    /// Dropped as a repeat inside the throttle window; nothing was sent.
    case throttled
    /// The player (or the Apple Event machinery) rejected the script.
    case scriptFailed(OSStatus)
}

/// What one script execution reports back. Carries the OSStatus because the
/// authorization state is read out of it (-1743 means the user said no).
struct NowPlayingScriptError: Error, Equatable, Sendable {
    var status: OSStatus
    var message: String?
}

// MARK: - Controller

/// Sends transport commands to whichever player the Now Playing layer is
/// showing. Execution is AppleScript through `NSAppleScript` — an Apple Event
/// is a synchronous round trip to another process, so it never runs on the main
/// thread; the result hops back here before any UI reads it.
@MainActor
final class NowPlayingController: ObservableObject {
    static let shared = NowPlayingController()

    enum Authorization: Sendable {
        case authorized
        case denied
        case notDetermined
    }

    /// Script text in, outcome out. The only impure part of this class, so
    /// tests can exercise every rule without an Apple Event ever leaving the
    /// process.
    typealias Executor = @Sendable (String) -> Result<Void, NowPlayingScriptError>
    /// Bundle ID in, `AEDeterminePermissionToAutomateTarget` status out.
    typealias PermissionProbe = @Sendable (String) -> OSStatus

    /// Carbon `MacErrors.h` values. Spelled out rather than imported so the
    /// mapping below is readable and does not depend on which of these Apple
    /// currently surfaces to Swift.
    enum Status {
        static let notPermitted: OSStatus = -1743
        static let wouldRequireUserConsent: OSStatus = -1744
        /// The target app is not running — says nothing about permission.
        static let procNotFound: OSStatus = -600
    }

    /// Long enough to swallow a double-click on a transport button, short
    /// enough that deliberate repeated taps still land.
    static let throttleWindow: TimeInterval = 0.3

    /// Automation consent is granted per target app in System Settings, so a
    /// denial for one player says nothing about the other. Keyed by bundle ID:
    /// a single shared value would let a denied Spotify silently mute every
    /// command sent to Music.
    @Published private(set) var authorizations: [String: Authorization] = [:]

    func authorization(for bundleID: String?) -> Authorization {
        guard let bundleID else { return .notDetermined }
        return authorizations[bundleID] ?? .notDetermined
    }

    private let executor: Executor
    private let probe: PermissionProbe
    /// Keyed by the whole command, so two *different* seeks in quick succession
    /// both land while a repeated tap of the same button does not.
    private var lastSent: [Key: Date] = [:]
    /// Seek keys carry their seconds, so the map would grow one entry per scrub
    /// for the life of the process. The window is 0.3 s — nothing older than
    /// that can still throttle anything, so a wholesale clear is safe.
    private static let lastSentCapacity = 32

    private struct Key: Hashable {
        var bundleID: String
        var command: NowPlayingCommand
    }

    /// Apple Events are a synchronous IPC round trip: a serial queue of our own
    /// keeps them off both the main thread and the cooperative pool, and keeps
    /// two `NSAppleScript` executions from overlapping.
    private static let executionQueue = DispatchQueue(label: "com.loomscreen.nowplaying.control")

    init(
        executor: @escaping Executor = NowPlayingController.runAppleScript,
        probe: @escaping PermissionProbe = NowPlayingController.determinePermission
    ) {
        self.executor = executor
        self.probe = probe
    }

    // MARK: Script generation (pure, test-visible)

    /// nil when nothing can be sent: no player, an unknown player, or a command
    /// this player has no vocabulary for.
    nonisolated static func script(
        for command: NowPlayingCommand,
        bundleID: String?,
        duration: Double? = nil
    ) -> String? {
        guard let mapping = NowPlayingControlMapping.mapping(for: bundleID) else { return nil }
        let phrase: String
        switch command {
        case .playPause: phrase = mapping.playPausePhrase
        case .next: phrase = mapping.nextPhrase
        case .previous: phrase = mapping.previousPhrase
        case let .seek(seconds):
            guard let seekPhrase = mapping.seekPhrase else { return nil }
            phrase = "\(seekPhrase) \(secondsLiteral(clampedSeek(seconds: seconds, duration: duration)))"
        }
        return "tell application \"\(mapping.applicationName)\" to \(phrase)"
    }

    nonisolated static func clampedSeek(seconds: Double, duration: Double?) -> Double {
        guard seconds.isFinite else { return 0 }
        var value = max(0, seconds)
        if let duration, duration.isFinite, duration > 0 {
            value = min(value, duration)
        }
        return value
    }

    /// Fixed notation on purpose: `"\(1e2)"` would render `1e+02`, which is not
    /// an AppleScript number literal.
    nonisolated static func secondsLiteral(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    // MARK: Sending

    @discardableResult
    func send(
        _ command: NowPlayingCommand,
        to bundleID: String?,
        duration: Double? = nil,
        now: Date = Date()
    ) async -> Result<Void, NowPlayingControlFailure> {
        guard let bundleID else { return .failure(.noPlayer) }
        guard let script = Self.script(for: command, bundleID: bundleID, duration: duration) else {
            return .failure(.unsupportedPlayer)
        }
        // A denied target never prompts again, so retrying would only burn a
        // blocking round trip per click and hide the reason from the user. Read
        // per target: the other player may be perfectly usable.
        guard authorization(for: bundleID) != .denied else { return .failure(.notAuthorized) }

        let key = Key(bundleID: bundleID, command: command)
        if let last = lastSent[key], now.timeIntervalSince(last) < Self.throttleWindow {
            return .failure(.throttled)
        }
        if lastSent.count >= Self.lastSentCapacity { lastSent.removeAll(keepingCapacity: true) }
        lastSent[key] = now

        switch await run(script) {
        case .success:
            authorizations[bundleID] = .authorized
            return .success(())
        case let .failure(error):
            if error.status == Status.notPermitted {
                authorizations[bundleID] = .denied
                return .failure(.notAuthorized)
            }
            return .failure(.scriptFailed(error.status))
        }
    }

    /// Reads the current Automation permission without ever asking the user, so
    /// Settings can explain a denial without provoking a prompt.
    func refreshAuthorization(for bundleID: String?) async {
        guard let bundleID, NowPlayingControlMapping.mapping(for: bundleID) != nil else { return }
        let probe = self.probe
        let status = await withCheckedContinuation { continuation in
            Self.executionQueue.async { continuation.resume(returning: probe(bundleID)) }
        }
        switch status {
        case noErr: authorizations[bundleID] = .authorized
        case Status.notPermitted: authorizations[bundleID] = .denied
        case Status.wouldRequireUserConsent: authorizations[bundleID] = .notDetermined
        // procNotFound and anything else say nothing about permission: a player
        // that is not running cannot be probed, and must not read as denied.
        default: break
        }
    }

    #if DEBUG
    // Test-only introspection; no production reader.
    var debugThrottleKeyCount: Int { lastSent.count }
    #endif

    private func run(_ script: String) async -> Result<Void, NowPlayingScriptError> {
        let executor = self.executor
        return await withCheckedContinuation { continuation in
            Self.executionQueue.async { continuation.resume(returning: executor(script)) }
        }
    }
}

// MARK: - Real execution

extension NowPlayingController {
    /// Compiled and run fresh per command: `NSAppleScript` is not safe to share
    /// across threads, and these scripts are one line each.
    nonisolated static let runAppleScript: Executor = { source in
        guard let script = NSAppleScript(source: source) else {
            return .failure(NowPlayingScriptError(status: Status.notPermitted, message: nil))
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .success(()) }
        let status = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? Status.notPermitted
        return .failure(NowPlayingScriptError(
            status: status,
            message: errorInfo[NSAppleScript.errorMessage] as? String
        ))
    }

    nonisolated static let determinePermission: PermissionProbe = { bundleID in
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else {
            return Status.procNotFound
        }
        // askUserIfNeeded false: this is a read of the current state, so an
        // undetermined target answers -1744 instead of putting up a dialog.
        return AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false)
    }
}
