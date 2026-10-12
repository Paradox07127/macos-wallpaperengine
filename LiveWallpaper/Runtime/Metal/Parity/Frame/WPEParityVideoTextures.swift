#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Metal
import MetalPerformanceShaders

/// Plays each video .tex of a scene into the fixed texture its draws sample.
final class WPEParityVideoTextures {
    /// A video .tex as planned: the texture draws sample and the MP4 stream from its first mip.
    struct Stream {
        let texture: MTLTexture
        let bytes: Data
    }

    private let videos: [(source: WPEVideoTextureSource, texture: MTLTexture)]
    private let scaler: MPSImageBilinearScale
    /// Indices of the sources whose staged frame went into the current frame's command buffer.
    private var encoded: Set<Int> = []

    var textures: [MTLTexture] {
        videos.map(\.texture)
    }

    /// Stores each stream in the video disk cache and starts looping wall-clock playback.
    init(streams: [Stream], workshopID: String, device: MTLDevice, queue: MTLCommandQueue) async throws {
        var videos: [(source: WPEVideoTextureSource, texture: MTLTexture)] = []
        for stream in streams {
            let url = try await WPEVideoTextureDiskCache.shared.store(stream.bytes, workshopID: workshopID)
            let source: WPEVideoTextureSource
            do {
                source = try WPEVideoTextureSource(device: device, videoURL: url, commandQueue: queue,
                                                   onInvalidate: { url in
                                                       Task.detached(priority: .utility) {
                                                           await WPEVideoTextureDiskCache.shared.release(url)
                                                       }
                                                   })
            } catch {
                await WPEVideoTextureDiskCache.shared.release(url)
                throw error
            }
            source.applyPerformanceProfile(.quality)
            videos.append((source, stream.texture))
        }
        self.videos = videos
        scaler = Self.scaler(device: device)
    }

    /// The default zero edge mode blends the border texels with transparent black.
    static func scaler(device: MTLDevice) -> MPSImageBilinearScale {
        let scaler = MPSImageBilinearScale(device: device)
        scaler.edgeMode = .clamp
        return scaler
    }

    deinit {
        for video in videos {
            video.source.invalidate()
        }
    }

    /// Stages each decoder's new frame into `commandBuffer` ahead of the scene and stretches it over its texture; a
    /// source without a new frame leaves its texture as it was.
    func encode(into commandBuffer: MTLCommandBuffer) throws {
        for (index, video) in videos.enumerated() {
            // The decoder paces by AVPlayer's wall clock and ignores the time argument.
            guard let frame = video.source.texture(at: 0), video.source.hasStagedFrameWork else { continue }
            video.source.encodeStagedFrameWork(into: commandBuffer)
            guard !video.source.stagedFrameWorkEncodingFailed else { continue }
            encoded.insert(index)
            try Self.stretch(frame, into: video.texture, scaler: scaler, commandBuffer: commandBuffer)
        }
    }

    /// Call after every frame: `encode` only runs on a command buffer that is then committed, so the sources it
    /// encoded publish their frame and every other source drops what it armed.
    func finishFrame() {
        for (index, video) in videos.enumerated() {
            if encoded.contains(index) {
                video.source.commitStagedFrameWork()
            } else {
                video.source.rollbackStagedFrameWork()
            }
        }
        encoded.removeAll()
    }

    /// Fills `texture` with `frame`, as WPE's TransferVideoFrame stretches into the fixed texture (1400f3480.c:18-52).
    static func stretch(_ frame: MTLTexture, into texture: MTLTexture, scaler: MPSImageBilinearScale,
                        commandBuffer: MTLCommandBuffer) throws {
        if frame.width == texture.width, frame.height == texture.height, frame.pixelFormat == texture.pixelFormat {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw WPEParityFrameRenderError.encoderUnavailable
            }
            blit.copy(from: frame, to: texture)
            blit.endEncoding()
        } else {
            scaler.encode(commandBuffer: commandBuffer, sourceTexture: frame, destinationTexture: texture)
        }
    }
}
#endif
