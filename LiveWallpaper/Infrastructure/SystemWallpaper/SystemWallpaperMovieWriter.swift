import AVFoundation
import CoreVideo
import Foundation
import Metal

/// One frame in flight: the GPU finishes before the encoder receives its pooled buffer.
@available(macOS 26.0, *)
@MainActor
final class SystemWallpaperMovieWriter {
    enum Failure: Error { case bufferUnavailable, encoderFailed }

    let size: CGSize
    private let writer: AVAssetWriter
    private let receiver: AVAssetWriterInput.PixelBufferReceiver
    private let pool: SystemWallpaperFramePool

    init(url: URL, size: CGSize, framesPerSecond: Int, device: any MTLDevice) throws {
        self.size = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 6),
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond,
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        pool = try SystemWallpaperFramePool(size: size, device: device)
        guard writer.startWriting() else { throw writer.error ?? Failure.encoderFailed }
        writer.startSession(atSourceTime: .zero)
    }

    /// The cache wrapper stays alive until `render` has completed all GPU writes.
    func append(at time: CMTime, render: @MainActor (any MTLTexture) async throws -> Void) async throws {
        try Task.checkCancellation()
        let frame = try await pool.nextFrame()
        try await render(frame.texture)
        try Task.checkCancellation()
        // Ownership transfers only after GPU completion; this buffer is never mutated again.
        nonisolated(unsafe) let completedBuffer = frame.buffer
        try await withTaskCancellationHandler(operation: {
            try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: completedBuffer), with: time)
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
        withExtendedLifetime(frame.cachedTexture) {}
    }

    func finish(at time: CMTime) async throws {
        try Task.checkCancellation()
        writer.endSession(atSourceTime: time)
        receiver.finish()
        await withTaskCancellationHandler(operation: { await writer.finishWriting() },
                                          onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? Failure.encoderFailed }
    }

    func cancel() {
        writer.cancelWriting()
    }
}
