import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Lite HTML audio bridge is absent")
@MainActor
struct HTMLAudioSpectrumLiteTests {
    @Test("Lite installs no audio listener bridge or pump")
    func liteHasNoAudioBridge() {
        let view = HTMLWallpaperView(frame: .zero, initialEphemeral: true)
        defer { view.cleanup() }
        #expect(view.audioSpectrumBridgeScript == nil)
        view.noteAudioSpectrumListenerRegistered()
        view.reconcileAudioSpectrumPump()
        #expect(!view.audioSpectrumListenerActive && view.audioSpectrumPumpTask == nil && !view.audioSpectrumCaptureRetained)
    }
}
