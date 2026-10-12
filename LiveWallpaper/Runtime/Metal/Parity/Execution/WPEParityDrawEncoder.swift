#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// One non-indexed draw. Constants, textures and samplers are keyed by HLSL name and shared by
/// both stages; each stage packs only the names its own reflection declares.
struct WPEParityDraw {
    var pipeline: WPEParityPipeline
    var depthStencil: WPEParityDepthStencilState
    var rasterizer: WPEParityRasterizerState
    var constants: [String: WPECBufferValue] = [:]
    var textures: [String: MTLTexture] = [:]
    var samplers: [String: WPEParitySamplerState] = [:]
    var vertexBuffer: MTLBuffer
    var vertexBufferOffset = 0
    var primitiveType: MTLPrimitiveType
    var vertexStart = 0
    var vertexCount: Int
}

struct WPEParityDrawEncoder {
    let factory: WPEParityPipelineFactory

    func encode(_ draw: WPEParityDraw, frame: WPEParityFrameArena.Frame,
                on encoder: MTLRenderCommandEncoder) throws {
        encoder.setRenderPipelineState(draw.pipeline.state)
        try encoder.setDepthStencilState(factory.depthStencilState(draw.depthStencil))
        let raster = WPEParityMetalStateMapping.rasterSettings(draw.rasterizer)
        encoder.setTriangleFillMode(raster.fillMode)
        encoder.setCullMode(raster.cullMode)
        encoder.setFrontFacing(raster.frontFacing)
        encoder.setDepthBias(raster.depthBias, slopeScale: raster.depthSlopeScale, clamp: raster.depthBiasClamp)
        encoder.setDepthClipMode(raster.depthClipMode)

        var textureStages: [ObjectIdentifier: (MTLTexture, MTLRenderStages)] = [:]
        if let offset = try encodeArguments(draw.pipeline.vertex, stages: .vertex, draw: draw, frame: frame,
                                            textureStages: &textureStages) {
            encoder.setVertexBuffer(frame.buffer, offset: offset, index: WPEParityMSCRuntime.argumentBufferBindPoint)
        }
        if let offset = try encodeArguments(draw.pipeline.fragment, stages: .fragment, draw: draw, frame: frame,
                                            textureStages: &textureStages) {
            encoder.setFragmentBuffer(frame.buffer, offset: offset, index: WPEParityMSCRuntime.argumentBufferBindPoint)
        }
        // Cbuffers live in the arena buffer bound above, so only textures need explicit residency.
        for (texture, stages) in textureStages.values {
            encoder.useResource(texture, usage: .read, stages: stages)
        }

        encoder.setVertexBuffer(draw.vertexBuffer, offset: draw.vertexBufferOffset,
                                index: WPEParityMSCRuntime.vertexBufferBindPoint)
        // IRRuntimeDrawParams is a union of IRRuntimeDrawArgument and the 20-byte indexed variant.
        let drawParams: [UInt32] = [UInt32(draw.vertexCount), 1, UInt32(draw.vertexStart), 0, 0]
        drawParams.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.drawArgumentsBindPoint)
        }
        withUnsafeBytes(of: WPEParityMSCRuntime.nonIndexedDraw) {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.uniformsBindPoint)
        }
        encoder.drawPrimitives(type: draw.primitiveType, vertexStart: draw.vertexStart, vertexCount: draw.vertexCount)
    }

    /// Returns the arena offset of the stage's top-level argument buffer, or `nil` when it has no entries.
    private func encodeArguments(
        _ stage: WPEParityPipeline.Stage,
        stages: MTLRenderStages,
        draw: WPEParityDraw,
        frame: WPEParityFrameArena.Frame,
        textureStages: inout [ObjectIdentifier: (MTLTexture, MTLRenderStages)]
    ) throws -> Int? {
        let plan = stage.bindingPlan
        guard plan.totalSize > 0 else { return nil }
        var table = [UInt8](repeating: 0, count: plan.totalSize)

        for layout in stage.cbuffers {
            guard let entry = plan.cbufferOffset(register: layout.reflection.register,
                                                 space: layout.reflection.space) else { continue }
            var packer = WPECBufferPacker(layout: layout)
            for variable in layout.reflection.variables {
                if let value = draw.constants[variable.name] {
                    try packer.write(value, to: variable.name)
                }
            }
            let allocation = try allocate(frame, packer.bytes)
            // Buffer metadata: byte length in the low 32 bits (MSC bounds checks read it).
            try plan.writeEntry(at: entry, gpuAddress: allocation.gpuAddress, resourceID: 0,
                                metadata: UInt64(UInt32(layout.size)), into: &table)
        }

        for resource in stage.reflection.resources {
            let offset = resource.kind == .texture
                ? plan.textureOffset(named: resource.name) : plan.samplerOffset(named: resource.name)
            guard let offset else { continue }
            guard resource.count == 1 else { throw WPEParityExecutionError.resourceArrayUnsupported(resource.name) }
            switch resource.kind {
            case .texture:
                guard let texture = draw.textures[resource.name] else {
                    throw WPEParityExecutionError.missingTexture(resource.name)
                }
                // Texture metadata: min LOD clamp 0.0 in the low 32 bits.
                try plan.writeEntry(at: offset, gpuAddress: 0, resourceID: texture.gpuResourceID._impl,
                                    metadata: 0, into: &table)
                let key = ObjectIdentifier(texture)
                textureStages[key] = (texture, (textureStages[key]?.1 ?? []).union(stages))
            case .sampler:
                guard let state = draw.samplers[resource.name] else {
                    throw WPEParityExecutionError.missingSampler(resource.name)
                }
                // Sampler metadata is the LOD bias; it stays 0 because the sampler descriptor already carries it.
                try plan.writeEntry(at: offset, gpuAddress: factory.samplerState(state).gpuResourceID._impl,
                                    resourceID: 0, metadata: 0, into: &table)
            }
        }
        return try allocate(frame, table).offset
    }

    private func allocate(_ frame: WPEParityFrameArena.Frame, _ bytes: [UInt8]) throws -> WPEParityFrameArena.Allocation {
        guard let allocation = frame.allocate(length: bytes.count) else {
            throw WPEParityExecutionError.arenaExhausted
        }
        allocation.contents.copyMemory(from: bytes, byteCount: bytes.count)
        return allocation
    }
}
#endif
