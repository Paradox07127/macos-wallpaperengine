#if !LITE_BUILD
import Foundation
import JavaScriptCore
@testable import LiveWallpaper
import Testing

/// Stands in for `window.webkit.messageHandlers`, which JavaScriptCore has no notion of.
private func makeAudioSpectrumContext() throws -> JSContext {
    let context = try #require(JSContext())
    context.evaluateScript(
        """
        var window = this;
        var hostMessages = [];
        window.webkit = {
            messageHandlers: {
                lwAudioSpectrum: {
                    postMessage: function (payload) { hostMessages.push(payload); }
                }
            }
        };
        """
    )
    context.evaluateScript(
        HTMLWallpaperRuntimeScript.audioSpectrumBridge(
            messageName: HTMLWallpaperView.audioSpectrumMessageName
        )
    )
    return context
}

@Suite("HTML audio spectrum bridge")
struct HTMLAudioSpectrumBridgeTests {
    @Test("Registering a listener defines the global and tells the host")
    func registeringAListenerNotifiesTheHost() throws {
        let context = try makeAudioSpectrumContext()

        #expect(context.evaluateScript("typeof window.wallpaperRegisterAudioListener")?.toString() == "function")
        #expect(context.evaluateScript("hostMessages.length")?.toInt32() == 0)

        context.evaluateScript("window.wallpaperRegisterAudioListener(function (a) { window.seen = a; });")

        #expect(context.evaluateScript("hostMessages.length")?.toInt32() == 1)
        #expect(context.exception == nil)
    }

    @Test("A non-function registration is ignored and does not wake the host")
    func nonFunctionRegistrationIsIgnored() throws {
        let context = try makeAudioSpectrumContext()

        context.evaluateScript("window.wallpaperRegisterAudioListener('not a function');")

        #expect(context.evaluateScript("hostMessages.length")?.toInt32() == 0)
        #expect(context.exception == nil)
    }

    @Test("A pushed frame reaches every registered listener")
    func pushedFrameReachesEveryListener() throws {
        let context = try makeAudioSpectrumContext()
        context.evaluateScript(
            """
            window.firstSeen = null;
            window.secondSeen = null;
            window.wallpaperRegisterAudioListener(function (a) { window.firstSeen = a; });
            window.wallpaperRegisterAudioListener(function (a) { window.secondSeen = a; });
            window.__lwPushAudioSpectrum__([0.25, 0.5, 0.75]);
            """
        )

        #expect(context.evaluateScript("window.firstSeen.length")?.toInt32() == 3)
        #expect(context.evaluateScript("window.secondSeen[2]")?.toDouble() == 0.75)
        #expect(context.exception == nil)
    }

    @Test("A throwing listener does not stop the others")
    func throwingListenerDoesNotStopTheOthers() throws {
        let context = try makeAudioSpectrumContext()
        context.evaluateScript(
            """
            window.survivorSeen = null;
            window.wallpaperRegisterAudioListener(function () { throw new Error('boom'); });
            window.wallpaperRegisterAudioListener(function (a) { window.survivorSeen = a; });
            window.__lwPushAudioSpectrum__([1]);
            """
        )

        #expect(context.evaluateScript("window.survivorSeen[0]")?.toDouble() == 1)
        #expect(context.exception == nil)
    }

    @Test("Reinstalling on an already-bridged document keeps the existing listeners")
    func reinstallKeepsExistingListeners() throws {
        let context = try makeAudioSpectrumContext()
        context.evaluateScript(
            """
            window.seen = null;
            window.wallpaperRegisterAudioListener(function (a) { window.seen = a; });
            """
        )
        context.evaluateScript(
            HTMLWallpaperRuntimeScript.audioSpectrumBridge(
                messageName: HTMLWallpaperView.audioSpectrumMessageName
            )
        )
        context.evaluateScript("window.__lwPushAudioSpectrum__([0.5]);")

        #expect(context.evaluateScript("window.seen[0]")?.toDouble() == 0.5)
    }

    @Test("A frame serializes to 64 left bins followed by 64 right bins")
    func frameSerializesLeftThenRight() {
        let left = (0 ..< AudioSpectrumFrame.binCount).map { Float($0) / Float(AudioSpectrumFrame.binCount) }
        let right = Array(left.reversed())
        let frame = AudioSpectrumFrame(left: left, right: right, timestampNanos: 1)

        let values = HTMLWallpaperView.audioSpectrumValues(for: frame)

        #expect(values.count == 128)
        #expect(values[0] == Double(left[0]))
        #expect(values[63] == Double(left[63]))
        #expect(values[64] == Double(right[0]))
        #expect(values[127] == Double(right[63]))
    }
}
#endif
