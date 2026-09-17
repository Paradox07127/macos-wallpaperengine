@preconcurrency import AVFoundation
import LiveWallpaperCore

/// One optional output conversion per player. AVFoundation's compositor converts and tags pixels;
/// AVPlayerLayer itself has no public colorspace override. The FPS/effects composition stays intact.
@MainActor
final class VideoColorCompositionController {
    typealias Builder = @MainActor @Sendable (AVAsset) async throws -> AVVideoComposition

    private let builder: Builder
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var composition: AVVideoComposition?
    var isPreparing: Bool {
        task != nil
    }

    var revision: UInt64 {
        generation
    }

    init(builder: @escaping Builder = VideoColorCompositionController.buildBase) {
        self.builder = builder
    }

    deinit { task?.cancel() }

    func reset() {
        task?.cancel()
        task = nil
        generation &+= 1
        composition = nil
    }

    @discardableResult
    func update(
        base: AVVideoComposition?,
        asset: AVAsset?,
        preference: VideoColorSpace,
        didPublish: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never>? {
        reset()
        guard preference != .auto, preference != .forceSDR else { return nil }
        if let base {
            composition = Self.applying(preference, to: base)
            return nil
        }
        guard let asset else { return nil }
        let expectedGeneration = generation
        let builder = builder
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let base = try await builder(asset)
                guard !Task.isCancelled, let self, generation == expectedGeneration else { return }
                composition = Self.applying(preference, to: base)
                task = nil
                didPublish()
            } catch {
                guard !Task.isCancelled, let self, generation == expectedGeneration else { return }
                task = nil
                Logger.warning("Video color composition unavailable; retaining source color: \(error.localizedDescription)", category: .videoPlayer)
            }
        }
        return task
    }

    static func buildBase(asset: AVAsset) async throws -> AVVideoComposition {
        if #available(macOS 26, *) {
            let configuration = try await AVVideoComposition.Configuration(for: asset)
            return AVVideoComposition(configuration: configuration)
        }
        return try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
    }

    static func applying(_ preference: VideoColorSpace, to base: AVVideoComposition) -> AVVideoComposition {
        let primaries: String
        let transfer: String?
        let matrix: String
        switch preference {
        case .auto, .forceSDR:
            // Auto retains the source/base contract; Force SDR already owns a Rec.709 composition.
            return base
        case .sRGB:
            primaries = AVVideoColorPrimaries_ITU_R_709_2
            transfer = Self.sdrTransferFunction
            matrix = AVVideoYCbCrMatrix_ITU_R_709_2
        case .displayP3:
            primaries = AVVideoColorPrimaries_P3_D65
            transfer = Self.sdrTransferFunction
            matrix = AVVideoYCbCrMatrix_ITU_R_709_2
        case .rec2020HDR:
            primaries = AVVideoColorPrimaries_ITU_R_2020
            // Primaries do not select an HDR transfer function. Preserve an explicit base transfer;
            // nil tells AVFoundation to propagate the source transfer (including PQ/HLG).
            transfer = base.colorTransferFunction
            matrix = AVVideoYCbCrMatrix_ITU_R_2020
        }
        if #available(macOS 26, *) {
            return AVVideoComposition(configuration: AVVideoComposition.Configuration(
                animationTool: base.animationTool,
                colorPrimaries: primaries,
                colorTransferFunction: transfer,
                colorYCbCrMatrix: matrix,
                customVideoCompositorClass: base.customVideoCompositorClass,
                frameDuration: base.frameDuration,
                instructions: base.instructions,
                outputBufferDescription: base.outputBufferDescription,
                perFrameHDRDisplayMetadataPolicy: base.perFrameHDRDisplayMetadataPolicy,
                renderScale: base.renderScale,
                renderSize: base.renderSize,
                sourceSampleDataTrackIDs: base.sourceSampleDataTrackIDs,
                sourceTrackIDForFrameTiming: base.sourceTrackIDForFrameTiming,
                spatialVideoConfigurations: base.spatialVideoConfigurations
            ))
        }
        guard let result = base.mutableCopy() as? AVMutableVideoComposition else {
            Logger.warning("Video composition does not support a mutable color override; retaining base color", category: .videoPlayer)
            return base
        }
        result.colorPrimaries = primaries
        result.colorTransferFunction = transfer
        result.colorYCbCrMatrix = matrix
        return result
    }

    /// IEC sRGB is an AVFoundation output transfer option on macOS 15+. Older systems use the
    /// supported Rec.709 SDR curve, a compatibility approximation rather than an exact sRGB curve.
    static var sdrTransferFunction: String {
        if #available(macOS 15, *) {
            return AVVideoTransferFunction_IEC_sRGB
        }
        return AVVideoTransferFunction_ITU_R_709_2
    }
}
