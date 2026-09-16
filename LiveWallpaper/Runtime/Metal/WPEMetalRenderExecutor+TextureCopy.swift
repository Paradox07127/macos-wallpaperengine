#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Metal

enum WPEMetalTextureCopyError: Error, Equatable {
    case unsupportedLayout
    case unsupportedSampledFormat
    case missingSampledUsage
    case overlappingViews
}

extension WPEMetalRenderExecutor {
    /// Copies mip zero across the full image. Identical extents/format retain the
    /// byte-exact blit path. Other supported color inputs use bilinear sampling:
    /// Metal applies pixel-format conversion (including sRGB transfer), without
    /// premultiplication, alpha clamping, tone mapping or color-primary conversion.
    /// This is not a subregion copy, an MSAA resolve, or an array/volume transfer.
    func copyTexture(
        _ source: MTLTexture,
        to destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        traceLabel: @autoclosure () -> String = "copy",
        generateMipmaps: Bool = false
    ) throws {
        guard source.textureType == .type2D, destination.textureType == .type2D,
              source.sampleCount == 1, destination.sampleCount == 1 else {
            throw WPEMetalTextureCopyError.unsupportedLayout
        }
        let needsMipmaps = generateMipmaps && destination.mipmapLevelCount > 1
        if source === destination, !needsMipmaps {
            return
        }
        closeSharedSceneEncoderForHelperEncoder()
        let exactCopy = source.pixelFormat == destination.pixelFormat
            && source.width == destination.width && source.height == destination.height

        if exactCopy {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw WPEMetalRenderExecutorError.commandBufferFailed
            }
            blit.applyTraceLabel(traceLabel())
            WPEFrameOccupancyMeter.count(.helperEncoder)
            if source !== destination {
                blit.copy(
                    from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                    sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                    to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin()
                )
            }
            if needsMipmaps {
                blit.generateMipmaps(for: destination)
                WPEFrameOccupancyMeter.count(.reflectionMipGeneration)
            }
            blit.endEncoding()
            return
        }

        try encodeSampledTextureCopy(source, to: destination, commandBuffer: commandBuffer, traceLabel: traceLabel())
        if needsMipmaps {
            // Render must end before blit generates the new destination chain.
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw WPEMetalRenderExecutorError.commandBufferFailed
            }
            blit.applyTraceLabel("copy-mipmaps")
            WPEFrameOccupancyMeter.count(.helperEncoder)
            blit.generateMipmaps(for: destination)
            WPEFrameOccupancyMeter.count(.reflectionMipGeneration)
            blit.endEncoding()
        }
    }

    private func encodeSampledTextureCopy(
        _ source: MTLTexture,
        to destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        traceLabel: String
    ) throws {
        guard Self.supportsSampledCopyFormat(source.pixelFormat, destination: false),
              Self.supportsSampledCopyFormat(destination.pixelFormat, destination: true) else {
            throw WPEMetalTextureCopyError.unsupportedSampledFormat
        }
        guard !source.isFramebufferOnly,
              source.usage.isEmpty || source.usage.contains(.shaderRead),
              destination.usage.isEmpty || destination.usage.contains(.renderTarget) else {
            throw WPEMetalTextureCopyError.missingSampledUsage
        }
        func root(_ texture: MTLTexture) -> MTLTexture {
            var result = texture
            while let parent = result.parent {
                result = parent
            }
            return result
        }
        guard root(source) !== root(destination) else {
            throw WPEMetalTextureCopyError.overlappingViews
        }
        // Resolve the PSO before opening a dontCare pass: a failure must not
        // leave an encoded store of undefined destination contents.
        let pipeline = try renderPipeline(
            fragmentName: "wpe_copy_fragment", blendMode: "disabled",
            alphaWritePolicy: .all, colorPixelFormat: destination.pixelFormat
        )
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: traceLabel)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.applyTraceLabel(traceLabel)
        WPEFrameOccupancyMeter.count(.helperEncoder)
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private static func supportsSampledCopyFormat(_ format: MTLPixelFormat, destination: Bool) -> Bool {
        switch format {
        case .r8Unorm, .rg8Unorm, .rgba8Unorm, .rgba8Unorm_srgb,
             .bgra8Unorm, .bgra8Unorm_srgb, .r16Float, .rg16Float, .rgba16Float:
            true
        case .bc1_rgba, .bc1_rgba_srgb, .bc2_rgba, .bc2_rgba_srgb,
             .bc3_rgba, .bc3_rgba_srgb, .bc4_rUnorm, .bc5_rgUnorm,
             .bc6H_rgbFloat, .bc6H_rgbuFloat, .bc7_rgbaUnorm, .bc7_rgbaUnorm_srgb:
            !destination
        default:
            false
        }
    }
}
#endif
