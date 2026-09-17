import AppKit
@preconcurrency import AVFoundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Public video color composition")
@MainActor
struct VideoColorCompositionTests {
    @Test("sRGB and Display P3 choose explicit primaries and sRGB transfer without mutating FPS geometry")
    func colorOverridesPreserveBase() {
        let base = makeBase(transfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        for preference in [VideoColorSpace.sRGB, .displayP3] {
            let result = VideoColorCompositionController.applying(preference, to: base)
            #expect(result !== base)
            #expect(result.colorPrimaries == (preference == .sRGB ? AVVideoColorPrimaries_ITU_R_709_2 : AVVideoColorPrimaries_P3_D65))
            if #available(macOS 15, *) {
                #expect(result.colorTransferFunction == AVVideoTransferFunction_IEC_sRGB)
            } else {
                #expect(result.colorTransferFunction == AVVideoTransferFunction_ITU_R_709_2)
            }
            #expect(result.colorYCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_709_2)
            #expect(result.frameDuration == base.frameDuration)
            #expect(result.renderSize == base.renderSize)
            #expect(result.renderScale == base.renderScale)
            #expect(result.sourceTrackIDForFrameTiming == base.sourceTrackIDForFrameTiming)
            #expect(result.instructions.count == base.instructions.count)
        }
        #expect(base.colorTransferFunction == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        #expect(base.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
    }

    @Test("Rec.2020 preserves nil, SDR, PQ and HLG transfers instead of manufacturing HDR", arguments: [
        String?.none,
        AVVideoTransferFunction_ITU_R_709_2,
        AVVideoTransferFunction_SMPTE_ST_2084_PQ,
        AVVideoTransferFunction_ITU_R_2100_HLG,
    ])
    func rec2020PreservesTransfer(transfer: String?) {
        let result = VideoColorCompositionController.applying(.rec2020HDR, to: makeBase(transfer: transfer))
        #expect(result.colorPrimaries == AVVideoColorPrimaries_ITU_R_2020)
        #expect(result.colorYCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_2020)
        #expect(result.colorTransferFunction == transfer)
    }

    @Test("Auto and Force SDR preserve their existing composition verbatim")
    func nativeAndForceSDRRemainUnchanged() {
        let base = makeBase(transfer: AVVideoTransferFunction_ITU_R_709_2)
        #expect(VideoColorCompositionController.applying(.auto, to: base) === base)
        #expect(VideoColorCompositionController.applying(.forceSDR, to: base) === base)
    }

    @Test("color override retains a custom effects compositor and its instructions")
    func customCompositorRemainsInstalled() throws {
        let base = try #require(makeBase(transfer: nil).mutableCopy() as? AVMutableVideoComposition)
        base.customVideoCompositorClass = ColorTestVideoCompositor.self
        let result = VideoColorCompositionController.applying(.displayP3, to: base)
        #expect(result.customVideoCompositorClass.map { ObjectIdentifier($0) } == ObjectIdentifier(ColorTestVideoCompositor.self))
        #expect(result.instructions.count == base.instructions.count)
        #expect(result.instructions.first?.timeRange == base.instructions.first?.timeRange)
        #expect(result.sourceTrackIDForFrameTiming == base.sourceTrackIDForFrameTiming)
    }

    @Test("a failed color build keeps source playback available and can be retried")
    func failedBuildCanRetry() async {
        var attempts = 0
        let base = makeBase(transfer: nil)
        let controller = VideoColorCompositionController { _ in
            attempts += 1
            if attempts == 1 {
                throw ColorBuildFailure.failed
            }
            return base
        }
        var publications = 0
        await controller.update(base: nil, asset: AVMutableComposition(), preference: .sRGB) {
            publications += 1
        }?.value
        #expect(controller.composition == nil)
        #expect(publications == 0)
        await controller.update(base: nil, asset: AVMutableComposition(), preference: .sRGB) {
            publications += 1
        }?.value
        #expect(controller.composition != nil)
        #expect(publications == 1)
        #expect(attempts == 2)
    }

    @Test("a cancelled late base build cannot restore a superseded color preference")
    func staleBuildDoesNotPublish() async {
        let gate = CompositionGate()
        let controller = VideoColorCompositionController { _ in try await gate.wait() }
        var publications = 0
        let oldTask = controller.update(
            base: nil,
            asset: AVMutableComposition(),
            preference: .displayP3
        ) { publications += 1 }
        while gate.continuation == nil {
            await Task.yield()
        }
        controller.update(base: nil, asset: nil, preference: .auto) { publications += 1 }
        gate.continuation?.resume(returning: makeBase(transfer: nil))
        await oldTask?.value
        #expect(controller.composition == nil)
        #expect(publications == 0)
    }

    @Test("completed output is retained once, and reset releases it")
    func publicationAndReset() async {
        let base = makeBase(transfer: AVVideoTransferFunction_ITU_R_2100_HLG)
        let controller = VideoColorCompositionController { _ in base }
        var publications = 0
        await controller.update(base: nil, asset: AVMutableComposition(), preference: .rec2020HDR) {
            publications += 1
        }?.value
        #expect(publications == 1)
        #expect(controller.composition?.colorTransferFunction == AVVideoTransferFunction_ITU_R_2100_HLG)
        controller.reset()
        #expect(controller.composition == nil)
    }

    @Test("player color changes preserve effects ownership and auto restores the original composition")
    func playerPreservesCompositionOwner() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/color-policy-test.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }
        let base = makeBase(transfer: nil)
        player.setVideoComposition(base, owner: .effects)
        player.setVideoColorSpace(.displayP3)
        #expect(player.videoCompositionOwner == .effects)
        #expect(player.currentVideoComposition === base)
        #expect(player.effectiveVideoComposition?.colorPrimaries == AVVideoColorPrimaries_P3_D65)
        player.setVideoColorSpace(.auto)
        #expect(player.videoCompositionOwner == .effects)
        #expect(player.effectiveVideoComposition === base)
    }

    @Test("player host dynamic range uses public typed layer properties")
    func hostUsesPublicDynamicRange() {
        let host = PlayerHostView(frame: .zero)
        host.setExtendedDynamicRangeEnabled(true)
        if #available(macOS 26, *) {
            #expect(host.playerLayer?.preferredDynamicRange == .high)
        } else {
            #expect(host.playerLayer?.wantsExtendedDynamicRangeContent == true)
        }
        host.setExtendedDynamicRangeEnabled(false)
        if #available(macOS 26, *) {
            #expect(host.playerLayer?.preferredDynamicRange == .standard)
        } else {
            #expect(host.playerLayer?.wantsExtendedDynamicRangeContent == false)
        }
    }

    private func makeBase(transfer: String?) -> AVVideoComposition {
        let base = AVMutableVideoComposition()
        base.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        base.colorTransferFunction = transfer
        base.frameDuration = CMTime(value: 1, timescale: 24)
        base.renderSize = CGSize(width: 320, height: 180)
        base.renderScale = 0.5
        base.sourceTrackIDForFrameTiming = 7
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        base.instructions = [instruction]
        return base
    }
}

@MainActor
private final class CompositionGate {
    var continuation: CheckedContinuation<AVVideoComposition, Error>?

    func wait() async throws -> AVVideoComposition {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

private enum ColorBuildFailure: Error { case failed }

private final class ColorTestVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_: AVVideoCompositionRenderContext) {}
    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        asyncVideoCompositionRequest.finishCancelledRequest()
    }
}
