import os
import XCTest
@testable import LiveWallpaper

/// No test here may let a real Apple Event out of the process: one would put up
/// an Automation consent dialog and drive whatever the user is listening to.
/// Every case injects a fake executor, so the only things under test are the
/// text we would have sent and the rules around sending it.
@MainActor
final class NowPlayingControllerTests: XCTestCase {
    private static let spotify = "com.spotify.client"
    private static let music = "com.apple.Music"

    /// The executor runs on the controller's own queue, so the recorder has to
    /// be safe to touch from there as well as from the test.
    private struct Locked<Value: Sendable>: Sendable {
        private let storage: OSAllocatedUnfairLock<Value>
        init(_ value: Value) { storage = OSAllocatedUnfairLock(initialState: value) }
        var value: Value { storage.withLock { $0 } }
        func mutate<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
            storage.withLock(body)
        }
    }

    private struct Recorder: Sendable {
        struct State: Sendable {
            var scripts: [String] = []
            var outcome: Result<Void, NowPlayingScriptError> = .success(())
        }

        let state = Locked(State())

        var scripts: [String] { state.value.scripts }

        func fail(status: OSStatus, message: String? = nil) {
            state.mutate { $0.outcome = .failure(NowPlayingScriptError(status: status, message: message)) }
        }

        func succeed() {
            state.mutate { $0.outcome = .success(()) }
        }

        var executor: NowPlayingController.Executor {
            let state = self.state
            return { script in
                state.mutate { current in
                    current.scripts.append(script)
                    return current.outcome
                }
            }
        }
    }

    /// Same shape as `Recorder`, for the read path.
    private struct QueryRecorder: Sendable {
        struct State: Sendable {
            var scripts: [String] = []
            var outcome: Result<NowPlayingScriptValue, NowPlayingScriptError> = .success(.number(0))
        }
        let state = Locked(State())
        var scripts: [String] { state.value.scripts }

        func answer(_ value: NowPlayingScriptValue) {
            state.mutate { $0.outcome = .success(value) }
        }
        func fail(status: OSStatus) {
            state.mutate { $0.outcome = .failure(NowPlayingScriptError(status: status, message: nil)) }
        }
        var executor: NowPlayingController.QueryExecutor {
            let state = self.state
            return { script in
                state.mutate { current in
                    current.scripts.append(script)
                    return current.outcome
                }
            }
        }
    }

    private func makeController(
        _ recorder: Recorder,
        queries: QueryRecorder = QueryRecorder(),
        probe: @escaping NowPlayingController.PermissionProbe = { _ in noErr }
    ) -> NowPlayingController {
        NowPlayingController(executor: recorder.executor, queryExecutor: queries.executor, probe: probe)
    }

    // MARK: - Queries

    func testQueryScriptTextPerPlayer() {
        XCTAssertEqual(
            NowPlayingController.script(for: .playerPosition, bundleID: Self.music),
            "tell application \"Music\" to get player position"
        )
        XCTAssertEqual(
            NowPlayingController.script(for: .artworkURL, bundleID: Self.spotify),
            "tell application \"Spotify\" to get artwork url of current track"
        )
        // Music exposes artwork as image data, not a URL — no vocabulary, no script.
        XCTAssertNil(NowPlayingController.script(for: .artworkURL, bundleID: Self.music))
        XCTAssertNil(NowPlayingController.script(for: .playerPosition, bundleID: "com.example.player"))
        XCTAssertNil(NowPlayingController.script(for: .playerPosition, bundleID: nil))
    }

    /// The hard rule for the read path: a query is never the result of the user
    /// clicking anything, so it must not be what first provokes the Automation
    /// dialog. `-1744` is macOS saying "I would have to ask" — nothing may be
    /// sent while that is the answer.
    func testQueryStaysSilentWhileConsentWouldHaveToBeAsked() async {
        let queries = QueryRecorder()
        let controller = makeController(
            Recorder(), queries: queries,
            probe: { _ in NowPlayingController.Status.wouldRequireUserConsent }
        )
        queries.answer(.number(12.5))

        let value = await controller.value(for: .playerPosition, from: Self.music)
        XCTAssertNil(value)
        XCTAssertTrue(queries.scripts.isEmpty)
        XCTAssertEqual(controller.authorization(for: Self.music), .notDetermined)
    }

    /// Consent lives in System Settings and survives relaunches, while this
    /// map starts empty every launch. Reading the existing answer (which never
    /// prompts) is what lets a playhead appear for someone who granted
    /// Automation months ago and has not touched a transport button today.
    func testQueryUsesConsentGrantedInAnEarlierLaunch() async {
        let queries = QueryRecorder()
        let controller = makeController(Recorder(), queries: queries, probe: { _ in noErr })
        queries.answer(.number(12.5))

        let value = await controller.value(for: .playerPosition, from: Self.music)
        XCTAssertEqual(value?.doubleValue, 12.5)
        XCTAssertEqual(queries.scripts.count, 1)
        XCTAssertEqual(controller.authorization(for: Self.music), .authorized)
    }

    /// A target the user has refused stays refused without a round trip.
    func testQueryStaysSilentForARefusedTarget() async {
        let queries = QueryRecorder()
        let controller = makeController(
            Recorder(), queries: queries,
            probe: { _ in NowPlayingController.Status.notPermitted }
        )
        let value = await controller.value(for: .playerPosition, from: Self.music)
        XCTAssertNil(value)
        XCTAssertTrue(queries.scripts.isEmpty)
        XCTAssertEqual(controller.authorization(for: Self.music), .denied)
    }

    func testQueryDeniedMarksTheTargetDenied() async {
        let queries = QueryRecorder()
        let controller = makeController(Recorder(), queries: queries)
        _ = await controller.send(.playPause, to: Self.music)
        queries.fail(status: NowPlayingController.Status.notPermitted)

        let value = await controller.value(for: .playerPosition, from: Self.music)
        XCTAssertNil(value)
        XCTAssertEqual(controller.authorization(for: Self.music), .denied)
    }

    /// A real is read out of the descriptor, never off `stringValue`:
    /// AppleScript formats reals for the current locale, so `12,5` would parse
    /// to nil wherever the decimal separator is a comma.
    func testNumericValuesDoNotGoThroughLocaleFormatting() {
        XCTAssertEqual(NowPlayingScriptValue.number(12.5).doubleValue, 12.5)
        XCTAssertNil(NowPlayingScriptValue.text("12,5").doubleValue)
        XCTAssertEqual(NowPlayingScriptValue.text("https://i.scdn.co/image/a").stringValue,
                       "https://i.scdn.co/image/a")
        XCTAssertNil(NowPlayingScriptValue.text("").stringValue)
    }

    /// `Result<Void, _>` is not Equatable (Void is not), so outcomes are read
    /// out rather than compared whole.
    private func failure(
        _ result: Result<Void, NowPlayingControlFailure>
    ) -> NowPlayingControlFailure? {
        guard case let .failure(failure) = result else { return nil }
        return failure
    }

    private func succeeded(_ result: Result<Void, NowPlayingControlFailure>) -> Bool {
        guard case .success = result else { return false }
        return true
    }

    // MARK: Script text (verbatim, per player)

    func testEveryCommandGeneratesTheDocumentedScriptForEveryPlayer() {
        let expected: [String: [(NowPlayingCommand, String)]] = [
            Self.spotify: [
                (.playPause, "tell application \"Spotify\" to playpause"),
                (.next, "tell application \"Spotify\" to next track"),
                (.previous, "tell application \"Spotify\" to previous track"),
                (.seek(seconds: 42.5), "tell application \"Spotify\" to set player position to 42.500"),
            ],
            Self.music: [
                (.playPause, "tell application \"Music\" to playpause"),
                (.next, "tell application \"Music\" to next track"),
                (.previous, "tell application \"Music\" to previous track"),
                (.seek(seconds: 42.5), "tell application \"Music\" to set player position to 42.500"),
            ],
        ]
        for (bundleID, cases) in expected {
            for (command, script) in cases {
                XCTAssertEqual(
                    NowPlayingController.script(for: command, bundleID: bundleID, duration: 300),
                    script
                )
            }
        }
    }

    /// `"\(1e14)"` renders `1e+14`, which is not an AppleScript number literal.
    func testSeekSecondsNeverUseScientificNotation() {
        let cases: [(Double, String)] = [
            (0, "0.000"),
            (100, "100.000"),
            (1e14, "100000000000000.000"),
            (7.5, "7.500"),
        ]
        for (seconds, literal) in cases {
            XCTAssertEqual(NowPlayingController.secondsLiteral(seconds), literal)
            let script = NowPlayingController.script(
                for: .seek(seconds: seconds), bundleID: Self.spotify, duration: 1e18
            )
            XCTAssertEqual(script, "tell application \"Spotify\" to set player position to \(literal)")
            XCTAssertEqual(script?.lowercased().contains("e+"), false)
        }
    }

    func testSeekSecondsClampToTheReportedDuration() {
        XCTAssertEqual(NowPlayingController.clampedSeek(seconds: -12, duration: 245), 0)
        XCTAssertEqual(NowPlayingController.clampedSeek(seconds: 900, duration: 245), 245)
        XCTAssertEqual(NowPlayingController.clampedSeek(seconds: 61.5, duration: 245), 61.5)
        XCTAssertEqual(NowPlayingController.clampedSeek(seconds: .nan, duration: 245), 0)
        XCTAssertEqual(NowPlayingController.clampedSeek(seconds: .infinity, duration: 245), 0)
        // No usable duration: the floor still applies, the ceiling cannot.
        XCTAssertEqual(NowPlayingController.clampedSeek(seconds: -1, duration: nil), 0)
        XCTAssertEqual(NowPlayingController.clampedSeek(seconds: 900, duration: nil), 900)
        XCTAssertEqual(NowPlayingController.clampedSeek(seconds: 900, duration: 0), 900)

        XCTAssertEqual(
            NowPlayingController.script(for: .seek(seconds: 900), bundleID: Self.spotify, duration: 245),
            "tell application \"Spotify\" to set player position to 245.000"
        )
    }

    // MARK: Unknown targets never produce a script or a call

    func testUnknownAndMissingBundleIDsProduceNoScript() {
        for bundleID in [nil, "", "com.example.NotAPlayer", "com.apple.music"] {
            XCTAssertNil(
                NowPlayingController.script(for: .playPause, bundleID: bundleID),
                "\(bundleID ?? "nil") produced a script"
            )
        }
    }

    func testUnknownAndMissingBundleIDsNeverReachTheExecutor() async {
        let recorder = Recorder()
        let controller = makeController(recorder)

        let noPlayer = await controller.send(.playPause, to: nil)
        XCTAssertEqual(failure(noPlayer), .noPlayer)

        let unknown = await controller.send(.next, to: "com.example.NotAPlayer")
        XCTAssertEqual(failure(unknown), .unsupportedPlayer)

        XCTAssertTrue(recorder.scripts.isEmpty, "a command escaped for an uncontrollable player")
    }

    // MARK: Throttle

    func testRepeatedCommandInsideTheWindowIsSentOnce() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let first = await controller.send(.next, to: Self.spotify, now: start)
        let second = await controller.send(.next, to: Self.spotify, now: start.addingTimeInterval(0.29))
        XCTAssertTrue(succeeded(first))
        XCTAssertEqual(failure(second), .throttled)
        XCTAssertEqual(recorder.scripts.count, 1)

        let third = await controller.send(.next, to: Self.spotify, now: start.addingTimeInterval(0.31))
        XCTAssertTrue(succeeded(third))
        XCTAssertEqual(recorder.scripts.count, 2)
    }

    /// The window is per command, not global: a play/pause right after a skip
    /// is a different intent and must still land.
    func testThrottleIsPerCommandAndPerPlayer() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await controller.send(.next, to: Self.spotify, now: start)
        _ = await controller.send(.playPause, to: Self.spotify, now: start.addingTimeInterval(0.01))
        _ = await controller.send(.next, to: Self.music, now: start.addingTimeInterval(0.02))
        _ = await controller.send(.seek(seconds: 10), to: Self.spotify, now: start.addingTimeInterval(0.03))
        _ = await controller.send(.seek(seconds: 20), to: Self.spotify, now: start.addingTimeInterval(0.04))

        XCTAssertEqual(recorder.scripts.count, 5, "\(recorder.scripts)")
    }

    // MARK: Authorization

    func testDenialIsRememberedAndStopsFurtherSendsToThatTarget() async {
        let recorder = Recorder()
        recorder.fail(status: NowPlayingController.Status.notPermitted, message: "Not authorized")
        let controller = makeController(recorder)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let first = await controller.send(.playPause, to: Self.spotify, now: start)
        XCTAssertEqual(failure(first), .notAuthorized)
        XCTAssertEqual(controller.authorization(for: Self.spotify), .denied)
        XCTAssertEqual(recorder.scripts.count, 1, "the first attempt is what surfaces the denial")

        // Well outside the throttle window, a different command, same player:
        // only the remembered denial can keep this from being sent.
        let second = await controller.send(.next, to: Self.spotify, now: start.addingTimeInterval(60))
        XCTAssertEqual(failure(second), .notAuthorized)
        XCTAssertEqual(recorder.scripts.count, 1, "a denied target kept sending Apple Events")
    }

    /// Automation consent is granted per target app, so a Spotify denial must
    /// not mute Music: one shared flag made every player inert after the first
    /// refusal, with no way back short of a relaunch.
    func testDenialForOnePlayerDoesNotMuteTheOther() async {
        let recorder = Recorder()
        recorder.fail(status: NowPlayingController.Status.notPermitted, message: "Not authorized")
        let controller = makeController(recorder)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        _ = await controller.send(.playPause, to: Self.spotify, now: start)
        XCTAssertEqual(controller.authorization(for: Self.spotify), .denied)
        XCTAssertEqual(controller.authorization(for: Self.music), .notDetermined)

        recorder.succeed()
        let toMusic = await controller.send(.next, to: Self.music, now: start.addingTimeInterval(60))
        XCTAssertNil(failure(toMusic), "Music was never denied and must still be sent to")
        XCTAssertEqual(recorder.scripts.count, 2)
        XCTAssertTrue(recorder.scripts[1].contains("Music"), "\(recorder.scripts)")
        XCTAssertEqual(controller.authorization(for: Self.music), .authorized)

        // Spotify stays denied and stays silent.
        let toSpotify = await controller.send(
            .previous, to: Self.spotify, now: start.addingTimeInterval(120)
        )
        XCTAssertEqual(failure(toSpotify), .notAuthorized)
        XCTAssertEqual(recorder.scripts.count, 2, "\(recorder.scripts)")
    }

    /// A script that will not compile is our bug, not the user refusing
    /// consent: latching it as a denial made the buttons dead until relaunch.
    func testScriptCompileFailureDoesNotLatchAsDenial() async {
        let recorder = Recorder()
        recorder.fail(status: NowPlayingController.Status.scriptCompileFailed, message: nil)
        let controller = makeController(recorder)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let first = await controller.send(.playPause, to: Self.spotify, now: start)
        XCTAssertEqual(failure(first), .scriptFailed(NowPlayingController.Status.scriptCompileFailed))
        XCTAssertNotEqual(controller.authorization(for: Self.spotify), .denied)

        recorder.succeed()
        let second = await controller.send(.next, to: Self.spotify, now: start.addingTimeInterval(60))
        XCTAssertNil(failure(second), "a compile failure must not stop later commands")
        XCTAssertEqual(recorder.scripts.count, 2)
    }

    func testOtherScriptErrorsDoNotLatchAsDenial() async {
        let recorder = Recorder()
        recorder.fail(status: -1728, message: "no track")
        let controller = makeController(recorder)

        let result = await controller.send(.next, to: Self.spotify)
        XCTAssertEqual(failure(result), .scriptFailed(-1728))
        XCTAssertNotEqual(controller.authorization(for: Self.spotify), .denied)

        let again = await controller.send(.previous, to: Self.spotify)
        XCTAssertEqual(failure(again), .scriptFailed(-1728))
        XCTAssertEqual(recorder.scripts.count, 2, "a transient failure must not latch")
    }

    func testProbeMapsEveryStatusToAuthorizationState() async {
        let cases: [(OSStatus, NowPlayingController.Authorization)] = [
            (noErr, .authorized),
            (NowPlayingController.Status.notPermitted, .denied),
            (NowPlayingController.Status.wouldRequireUserConsent, .notDetermined),
        ]
        for (status, expected) in cases {
            let controller = makeController(Recorder(), probe: { _ in status })
            await controller.refreshAuthorization(for: Self.spotify)
            XCTAssertEqual(controller.authorization(for: Self.spotify), expected, "status \(status)")
            XCTAssertEqual(
                controller.authorization(for: Self.music), .notDetermined,
                "probing one target must not answer for the other"
            )
        }
    }

    /// A player that is not running cannot be probed; reading that as a denial
    /// would silently disable the buttons for the rest of the session.
    func testNotRunningPlayerDoesNotReadAsDenied() async {
        let controller = makeController(
            Recorder(), probe: { _ in NowPlayingController.Status.procNotFound }
        )
        await controller.refreshAuthorization(for: Self.spotify)
        XCTAssertEqual(controller.authorization(for: Self.spotify), .notDetermined)
    }

    /// Seek keys carry their seconds, so an unbounded map would grow for the
    /// life of the process.
    func testThrottleMapStaysBounded() async {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for step in 0 ..< 200 {
            _ = await controller.send(
                .seek(seconds: Double(step)), to: Self.spotify,
                now: start.addingTimeInterval(Double(step))
            )
        }
        XCTAssertLessThanOrEqual(controller.debugThrottleKeyCount, 32)
        XCTAssertEqual(recorder.scripts.count, 200, "capping must not drop a legitimate command")
    }

    func testProbeIsNotRunForAnUncontrollablePlayer() async {
        let probed = Locked<[String]>([])
        let controller = NowPlayingController(
            executor: Recorder().executor,
            probe: { bundleID in
                probed.mutate { $0.append(bundleID) }
                return noErr
            }
        )
        await controller.refreshAuthorization(for: nil)
        await controller.refreshAuthorization(for: "com.example.NotAPlayer")
        XCTAssertTrue(probed.value.isEmpty)
    }

    // MARK: Control mapping table

    func testControlMappingCoversExactlyTheIngestedPlayers() {
        XCTAssertEqual(
            Set(NowPlayingControlMapping.all.map(\.bundleID)),
            Set(NowPlayingMonitor.mappings.map(\.bundleID)),
            "a player we read but cannot control (or the reverse) is a silent dead button"
        )
    }
}
