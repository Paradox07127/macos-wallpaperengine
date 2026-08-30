import Foundation
@testable import LiveWallpaper
import Testing

/// GitHub issue #133: 120 copies of `ReferenceError: Can't find variable:
/// MediaPlaybackEvent` — scenes read the global from module top level, so the
/// whole module (including `update()`) dies and WPEScriptFaultPolicy eventually
/// quarantines the entry point for good.
@Suite(.serialized)
@MainActor
struct WPESceneScriptMediaPlaybackEventTests {
    private let isolatedGovernor = WPESceneScriptExecutionGovernor(limit: 4)

    private func instance(script: String) throws -> LiveWallpaper.WPESceneScriptInstance {
        try LiveWallpaper.WPESceneScriptInstance(
            script: script,
            initialValue: "module-died",
            setupBudget: 2,
            tickBudget: 0.5,
            governor: isolatedGovernor
        )
    }

    @Test("A module whose top level reads MediaPlaybackEvent still evaluates")
    func topLevelReferenceSurvives() throws {
        let script = """
        var stopped = MediaPlaybackEvent.PLAYBACK_STOPPED;
        export function update(value) { return 'top-level-ok:' + stopped; }
        """
        #expect(try instance(script: script).tickString() == "top-level-ok:0")
    }

    @Test("The three playback constants are 0, 1 and 2")
    func constantValues() throws {
        let script = """
        export function update(value) {
            return [
                MediaPlaybackEvent.PLAYBACK_STOPPED,
                MediaPlaybackEvent.PLAYBACK_PLAYING,
                MediaPlaybackEvent.PLAYBACK_PAUSED
            ].join(',');
        }
        """
        #expect(try instance(script: script).tickString() == "0,1,2")
    }

    /// Workshop scenes branch on `event.state == 1`, so the constants have to be
    /// genuine Numbers, not opaque objects that merely stringify.
    @Test("The constants are JS Numbers, not objects that stringify to digits")
    func constantsAreNumbers() throws {
        let script = """
        export function update(value) {
            var ok = typeof MediaPlaybackEvent.PLAYBACK_PLAYING === 'number'
                && MediaPlaybackEvent.PLAYBACK_STOPPED === 0
                && MediaPlaybackEvent.PLAYBACK_PLAYING === 1
                && MediaPlaybackEvent.PLAYBACK_PAUSED === 2;
            return ok ? 'numbers' : 'not-numbers';
        }
        """
        #expect(try instance(script: script).tickString() == "numbers")
    }

    /// The authored script from workshop scene 3713073223, which is one of the
    /// four that were throwing. Verbatim shape: the global is read at module
    /// top level, and `mediaPlaybackChanged` is exported but never called here —
    /// exactly the case where the ReferenceError used to take `update()` down.
    @Test("The real authored script from a scene that was throwing now evaluates")
    func authoredSceneScriptSurvives() throws {
        let script = """
        var mediaState = MediaPlaybackEvent.PLAYBACK_STOPPED;

        export function mediaPlaybackChanged(event) {
            mediaState = event.state;
        }

        export function update() {
            if (mediaState === MediaPlaybackEvent.PLAYBACK_PLAYING
                || mediaState === MediaPlaybackEvent.PLAYBACK_PAUSED) {
                thisLayer.visible = true;
                return 'shown';
            }
            thisLayer.visible = false;
            return 'hidden';
        }
        """
        // The authored original returns the assignment itself, i.e. a Boolean;
        // this harness is a string-valued property script, so the returns are
        // spelled as strings. Everything that made the scene die — the module
        // top-level read and the exported callback — is verbatim.
        #expect(try instance(script: script).tickString() == "hidden")
    }

    @Test("One scene cannot clobber a constant for the scripts that read it later")
    func constantsResistMutation() throws {
        let script = """
        export function update(value) {
            try { MediaPlaybackEvent.PLAYBACK_PLAYING = 99; } catch (e) {}
            return String(MediaPlaybackEvent.PLAYBACK_PLAYING);
        }
        """
        #expect(try instance(script: script).tickString() == "1")
    }
}
