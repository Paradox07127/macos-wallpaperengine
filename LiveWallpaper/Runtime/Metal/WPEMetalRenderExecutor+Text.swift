#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal
import simd

extension WPEMetalRenderExecutor {
    @discardableResult
    func encodeTextMesh(
        payload: WPETextRenderPayload?,
        effectCarrier: Bool = false,
        sceneSize: CGSize,
        output: MTLTexture,
        clearsOutput: Bool,
        cameraClipTransform: SIMD4<Float> = SIMD4(1, 1, 0, 0),
        cameraOrientation: simd_float4x4 = matrix_identity_float4x4,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        try encodeTextMeshes(
            payloads: payload?.mesh.map { [$0] } ?? [],
            effectCarrier: effectCarrier,
            backgroundColor: payload?.backgroundColor,
            sceneSize: sceneSize,
            output: output,
            clearsOutput: clearsOutput,
            cameraClipTransform: cameraClipTransform,
            cameraOrientation: cameraOrientation,
            commandBuffer: commandBuffer
        )
    }

    @discardableResult
    private func encodeTextMeshes(
        payloads: [WPETextMeshPayload],
        effectCarrier: Bool = false,
        backgroundColor: SIMD4<Float>?,
        sceneSize: CGSize,
        output: MTLTexture,
        clearsOutput: Bool,
        cameraClipTransform: SIMD4<Float> = SIMD4(1, 1, 0, 0),
        cameraOrientation: simd_float4x4 = matrix_identity_float4x4,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        guard !payloads.isEmpty || clearsOutput else { return false }
        // Resolve before opening the encoder so a failure never leaks it.
        let state = try textGlyphPipelineState(colorPixelFormat: output.pixelFormat, effectCarrier: effectCarrier)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = clearsOutput ? .clear : .load
        let background = backgroundColor ?? SIMD4<Float>(0, 0, 0, 0)
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(background.x), Double(background.y), Double(background.z), Double(background.w)
        )
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "textGlyphs")
        closeSharedSceneEncoderForHelperEncoder()
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.applyTraceLabel("textGlyphs")
        WPEFrameOccupancyMeter.count(.textEncoder)
        encoder.setRenderPipelineState(state)
        var sceneSizeValue = SIMD2<Float>(
            Float(max(sceneSize.width, 1)),
            Float(max(sceneSize.height, 1))
        )
        encoder.setVertexBytes(&sceneSizeValue, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        var clipTransform = cameraClipTransform
        encoder.setVertexBytes(&clipTransform, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        var orientation = cameraOrientation
        encoder.setVertexBytes(&orientation, length: MemoryLayout<simd_float4x4>.stride, index: 3)
        for payload in payloads {
            var color = payload.color
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            for page in payload.pages {
                encoder.setVertexBuffer(page.vertexBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(page.texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: page.vertexCount)
            }
        }
        encoder.endEncoding()
        return true
    }

    func encodeTextBackground(
        source: MTLTexture,
        uniforms: WPEObjectQuadUniforms,
        output: MTLTexture,
        effectCarrier: Bool = false,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let state = try textBackgroundPipelineState(colorPixelFormat: output.pixelFormat, effectCarrier: effectCarrier)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "textBackground")
        closeSharedSceneEncoderForHelperEncoder()
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.applyTraceLabel("textBackground")
        WPEFrameOccupancyMeter.count(.textEncoder)
        encoder.setRenderPipelineState(state)
        encoder.setFragmentTexture(source, index: 0)
        var values = uniforms
        encoder.setFragmentBytes(&values, length: MemoryLayout<WPEObjectQuadUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func textBackgroundPipelineState(
        colorPixelFormat: MTLPixelFormat, effectCarrier: Bool
    ) throws -> MTLRenderPipelineState {
        let key = "\(colorPixelFormat.rawValue)|\(effectCarrier)"
        if let cached = textBackgroundPipelineCache[key] { return cached }
        let fragmentName = effectCarrier ? "wpe_text_effect_background_fragment" : "wpe_text_background_fragment"
        guard let vertex = defaultLibrary.makeFunction(name: "wpe_fullscreen_vertex"),
              let fragment = try WPEMetalColorOutput.fragment(library: defaultLibrary, name: fragmentName, format: colorPixelFormat) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_text_background_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        textBackgroundPipelineCache[key] = state
        return state
    }

    private func textGlyphPipelineState(colorPixelFormat: MTLPixelFormat, effectCarrier: Bool) throws -> MTLRenderPipelineState {
        let key = "\(colorPixelFormat.rawValue)|\(effectCarrier)"
        if let cached = textGlyphPipelineCache[key] {
            return cached
        }
        guard let vertex = defaultLibrary.makeFunction(name: "wpe_text_glyph_vertex"),
              let fragment = try WPEMetalColorOutput.fragment(library: defaultLibrary, name: "wpe_text_glyph_fragment", format: colorPixelFormat) else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_text_glyph_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        guard let attachment = descriptor.colorAttachments[0] else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_text_glyph_fragment")
        }
        attachment.pixelFormat = colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // The fragment premultiplies RGB, so `.one` is SRC_ALPHA-equivalent there. Alpha
        // takes `.one` for the same reason: this target is composited later as a
        // premultiplied image, and squaring its alpha would break `rgb <= alpha` and let
        // the background through a second time — thin glyphs wash out.
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        // Native effected text uses SrcAlpha for alpha too (coverage squared).
        // RGB is already multiplied by the glyph fragment, equivalent to native straight RGB/SrcAlpha.
        attachment.sourceAlphaBlendFactor = effectCarrier ? .sourceAlpha : .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        textGlyphPipelineCache[key] = state
        return state
    }
}
#endif
