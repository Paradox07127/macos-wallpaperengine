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
    /// Reads the playhead. Present even for players whose notification already
    /// carries a position — the script is the only route for the ones that
    /// don't, and having the row filled in keeps the two lists symmetric.
    let positionQueryPhrase: String?
    /// Reads a cover URL straight off the player instead of resolving one over
    /// the network. Only some players expose it.
    let artworkURLQueryPhrase: String?

    static let all: [NowPlayingControlMapping] = [
        NowPlayingControlMapping(
            bundleID: "com.spotify.client",
            applicationName: "Spotify",
            playPausePhrase: "playpause",
            nextPhrase: "next track",
            previousPhrase: "previous track",
            seekPhrase: "set player position to",
            positionQueryPhrase: "player position",
            // Spotify's dictionary hands out the cover URL directly, which
            // saves the oEmbed lookup that otherwise stands between us and it.
            artworkURLQueryPhrase: "artwork url of current track"
        ),
        NowPlayingControlMapping(
            bundleID: "com.apple.Music",
            applicationName: "Music",
            playPausePhrase: "playpause",
            nextPhrase: "next track",
            previousPhrase: "previous track",
            seekPhrase: "set player position to",
            // The one field Music's notification never sends. Its dictionary
            // has always had it (`sdef /System/Applications/Music.app`:
            // `<property name="player position" code="pPos" type="real">`), so
            // the missing progress bar was us not asking, not Music not telling.
            positionQueryPhrase: "player position",
            // Music's dictionary exposes artwork as raw image data, not a URL;
            // pulling a picture through an Apple Event is not worth it when
            // the iTunes Search route already works.
            artworkURLQueryPhrase: nil
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

/// A read of a player's own state.
///
/// Unlike a transport command, a query is never the result of the user
/// clicking anything, so it must never provoke the Automation consent dialog:
/// this layer is wallpaper, and a modal nobody asked for is worse than a
/// missing progress bar. `value(for:from:)` therefore answers nil until
/// consent already exists for that target.
enum NowPlayingQuery: Sendable, Hashable {
    case playerPosition
    case artworkURL
}

/// An AppleScript result, kept in the shape the descriptor had.
///
/// Reals must not come back through `stringValue`: AppleScript formats those
/// for the current locale, so a machine reading `12,345` as a Double would get
/// nil in half of Europe.
enum NowPlayingScriptValue: Sendable, Equatable {
    case text(String)
    case number(Double)

    var doubleValue: Double? {
        switch self {
        case let .number(value): return value
        case let .text(text): return Double(text)
        }
    }

    var stringValue: String? {
        switch self {
        case let .text(text): return text.isEmpty ? nil : text
        case let .number(value): return String(value)
        }
    }
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
    /// Same round trip, but the descriptor's value comes back.
    typealias QueryExecutor = @Sendable (String) -> Result<NowPlayingScriptValue, NowPlayingScriptError>
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
        /// `errOSASyntaxError`: our own script text failed to compile. Reporting
        /// this as `notPermitted` used to latch the player as denied for the
        /// rest of the launch over a bug that has nothing to do with consent.
        static let scriptCompileFailed: OSStatus = -2740
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
    private let queryExecutor: QueryExecutor
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
        queryExecutor: @escaping QueryExecutor = NowPlayingController.runAppleScriptQuery,
        probe: @escaping PermissionProbe = NowPlayingController.determinePermission
    ) {
        self.executor = executor
        self.queryExecutor = queryExecutor
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

    /// nil when this player has no vocabulary for the query.
    nonisolated static func script(for query: NowPlayingQuery, bundleID: String?) -> String? {
        guard let mapping = NowPlayingControlMapping.mapping(for: bundleID) else { return nil }
        let phrase: String?
        switch query {
        case .playerPosition: phrase = mapping.positionQueryPhrase
        case .artworkURL: phrase = mapping.artworkURLQueryPhrase
        }
        guard let phrase else { return nil }
        return "tell application \"\(mapping.applicationName)\" to get \(phrase)"
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

    /// Reads one value off a player. nil whenever nothing was asked — no
    /// vocabulary, or consent not already established — so a caller can never
    /// tell a refusal apart from an unasked question, which is deliberate:
    /// both mean "carry on without it".
    ///
    /// Unthrottled on purpose. The throttle exists to swallow double-clicks on
    /// a button; a poller sets its own cadence and would only be silently
    /// starved by a shared window.
    func value(for query: NowPlayingQuery, from bundleID: String?) async -> NowPlayingScriptValue? {
        guard let bundleID, let script = Self.script(for: query, bundleID: bundleID) else { return nil }
        // Consent is granted per target in System Settings and survives
        // relaunches, but this map starts empty every launch — so without this
        // the playhead only ever appeared after the user happened to press a
        // transport button, in a session where they had already granted it
        // months ago. The probe reads the existing answer and never prompts.
        if authorization(for: bundleID) == .notDetermined {
            await refreshAuthorization(for: bundleID)
        }
        guard authorization(for: bundleID) == .authorized else { return nil }
        let queryExecutor = self.queryExecutor
        let result = await withCheckedContinuation { continuation in
            Self.executionQueue.async { continuation.resume(returning: queryExecutor(script)) }
        }
        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            // Consent can be revoked between calls; record it so the next
            // command reports the real reason instead of a script failure.
            if error.status == Status.notPermitted { authorizations[bundleID] = .denied }
            return nil
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
            return .failure(NowPlayingScriptError(status: Status.scriptCompileFailed, message: nil))
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

    nonisolated static let runAppleScriptQuery: QueryExecutor = { source in
        guard let script = NSAppleScript(source: source) else {
            return .failure(NowPlayingScriptError(status: Status.scriptCompileFailed, message: nil))
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let status = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? Status.notPermitted
            return .failure(NowPlayingScriptError(
                status: status,
                message: errorInfo[NSAppleScript.errorMessage] as? String
            ))
        }
        switch descriptor.descriptorType {
        case typeIEEE64BitFloatingPoint, typeIEEE32BitFloatingPoint,
             typeSInt16, typeSInt32, typeSInt64, typeUInt32:
            return .success(.number(descriptor.doubleValue))
        default:
            return .success(.text(descriptor.stringValue ?? ""))
        }
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
