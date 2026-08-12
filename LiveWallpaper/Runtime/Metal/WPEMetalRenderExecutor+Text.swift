#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal
import simd

extension WPEMetalRenderExecutor {
    @discardableResult
    func encodeTextMesh(
        payload: WPETextRenderPayload?,
        sceneSize: CGSize,
        output: MTLTexture,
        clearsOutput: Bool,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        try encodeTextMeshes(
            payloads: payload?.mesh.map { [$0] } ?? [],
            backgroundColor: payload?.backgroundColor,
            sceneSize: sceneSize,
            output: output,
            clearsOutput: clearsOutput,
            commandBuffer: commandBuffer
        )
    }

    @discardableResult
    private func encodeTextMeshes(
        payloads: [WPETextMeshPayload],
        backgroundColor: SIMD4<Float>?,
        sceneSize: CGSize,
        output: MTLTexture,
        clearsOutput: Bool,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        guard !payloads.isEmpty || clearsOutput else { return false }
        // Resolve before opening the encoder so a failure never leaks it.
        let state = try textGlyphPipelineState(colorPixelFormat: output.pixelFormat)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = clearsOutput ? .clear : .load
        let background = backgroundColor ?? SIMD4<Float>(0, 0, 0, 0)
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(background.x), Double(background.y), Double(background.z), Double(background.w)
        )
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "textGlyphs")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.setRenderPipelineState(state)
        var sceneSizeValue = SIMD2<Float>(
            Float(max(sceneSize.width, 1)),
            Float(max(sceneSize.height, 1))
        )
        encoder.setVertexBytes(&sceneSizeValue, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
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
        commandBuffer: MTLCommandBuffer
    ) throws {
        let state = try textBackgroundPipelineState(colorPixelFormat: output.pixelFormat)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        descriptor.colorAttachments[0].storeAction = .store
        gpuPassProfiler?.attach(descriptor, to: commandBuffer, label: "textBackground")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        encoder.setRenderPipelineState(state)
        encoder.setFragmentTexture(source, index: 0)
        var values = uniforms
        encoder.setFragmentBytes(&values, length: MemoryLayout<WPEObjectQuadUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func textBackgroundPipelineState(
        colorPixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        if let cached = textBackgroundPipelineCache[colorPixelFormat.rawValue] { return cached }
        guard let vertex = defaultLibrary.makeFunction(name: "wpe_fullscreen_vertex"),
              let fragment = defaultLibrary.makeFunction(name: "wpe_text_background_fragment") else {
            throw WPEMetalRenderExecutorError.pipelineUnavailable("wpe_text_background_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        textBackgroundPipelineCache[colorPixelFormat.rawValue] = state
        return state
    }

    private func textGlyphPipelineState(colorPixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let cached = textGlyphPipelineCache[colorPixelFormat.rawValue] {
            return cached
        }
        guard let vertex = defaultLibrary.makeFunction(name: "wpe_text_glyph_vertex"),
              let fragment = defaultLibrary.makeFunction(name: "wpe_text_glyph_fragment") else {
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
        // WPE blends text with SRC_ALPHA/INV_SRC_ALPHA on RGB *and* alpha
        // (Windows RenderDoc fidelity-2955378002, all five text draws). The
        // fragment premultiplies RGB, so .one is SRC_ALPHA-equivalent there,
        // but the alpha channel must square the source alpha to match.
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        textGlyphPipelineCache[colorPixelFormat.rawValue] = state
        return state
    }
}
#endif
