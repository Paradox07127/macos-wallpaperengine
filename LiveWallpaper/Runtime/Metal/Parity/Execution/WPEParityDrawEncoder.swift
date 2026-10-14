#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// One draw, indexed with 16-bit indices when `indexBuffer` is set. Constants are keyed by stage, then HLSL name, since the stages can map one name to different
/// material keys; textures and samplers are shared. Each stage packs only the names its own reflection declares.
/// With a geometry-emulation pipeline the draw is a non-indexed point list, one vertex per particle.
struct WPEParityDraw {
    var pipeline: WPEParityPipeline
    var depthStencil: WPEParityDepthStencilState
    var rasterizer: WPEParityRasterizerState
    var constants: [WPEHLSLStage: [String: WPECBufferValue]] = [:]
    var textures: [String: MTLTexture] = [:]
    var samplers: [String: WPEParitySamplerState] = [:]
    var vertexBuffer: MTLBuffer
    var vertexBufferOffset = 0
    var primitiveType: MTLPrimitiveType
    var vertexStart = 0
    var vertexCount: Int
    var indexBuffer: MTLBuffer?
    var indexCount = 0
    /// The executor skips and counts this draw when the frame arena cannot hold its arguments, instead of failing
    /// the frame.
    var dropsWhenArenaIsFull = false
}

struct WPEParityDrawEncoder {
    let factory: WPEParityPipelineFactory

    static func validateDimension(_ resource: WPEStageReflection.Resource, textureType: MTLTextureType) throws {
        let expected: MTLTextureType? = switch resource.dimension {
        case .texture2D: .type2D
        case .texture2DMS: .type2DMultisample
        case .texture3D: .type3D
        case .texture2DArray: .type2DArray
        case .cube: .typeCube
        case .none: nil
        }
        guard textureType == expected else {
            throw WPEParityExecutionError.textureDimensionMismatch(resource.name,
                                                                   expected: resource.dimension.rawValue, actual: textureType.rawValue)
        }
    }

    /// Called once when a draw plan is built, before the graph promises its writes. Sampler and depth creation
    /// can fail too; discovering that on the first encoded frame is too late for load/store and alias decisions.
    func prepare(pipeline: WPEParityPipeline, depthStencil: WPEParityDepthStencilState,
                 textureNames: Set<String>, samplers: [String: WPEParitySamplerState]) throws {
        _ = try factory.depthStencilState(depthStencil)
        for stage in [pipeline.vertex, pipeline.geometry?.geometry, pipeline.fragment].compactMap(\.self) {
            for resource in stage.reflection.resources {
                guard resource.count == 1 else {
                    throw WPEParityExecutionError.resourceArrayUnsupported(resource.name)
                }
                switch resource.kind {
                case .texture:
                    guard textureNames.contains(resource.name) else {
                        throw WPEParityExecutionError.missingTexture(resource.name)
                    }
                case .sampler:
                    guard let sampler = samplers[resource.name] else {
                        throw WPEParityExecutionError.missingSampler(resource.name)
                    }
                    _ = try factory.samplerState(sampler)
                }
            }
        }
    }

    /// Arena bytes `encode` takes for `pipeline`'s cbuffers and top-level argument buffers, each 256-byte aligned.
    static func argumentBytes(_ pipeline: WPEParityPipeline) -> Int {
        pipeline.argumentBytes
    }

    static func argumentBytes(stages: [WPEParityPipeline.Stage]) -> Int {
        stages.reduce(0) { total, stage in
            let plan = stage.bindingPlan
            guard plan.totalSize > 0 else { return total }
            let cbuffers = stage.cbuffers.filter {
                plan.cbufferOffset(register: $0.reflection.register, space: $0.reflection.space) != nil
            }
            return cbuffers.reduce(total + WPEParityFrameArena.aligned(plan.totalSize)) {
                $0 + WPEParityFrameArena.aligned($1.size)
            }
        }
    }

    func encode(_ draw: WPEParityDraw, frame: WPEParityFrameArena.Frame,
                on encoder: MTLRenderCommandEncoder) throws {
        let emulation = draw.pipeline.geometry
        if emulation != nil, draw.primitiveType != .point || draw.indexBuffer != nil {
            throw WPEParityExecutionError.geometryDrawUnsupported
        }
        guard frame.canAllocate(length: Self.argumentBytes(draw.pipeline)) else {
            throw WPEParityExecutionError.arenaExhausted
        }
        encoder.setRenderPipelineState(draw.pipeline.state)
        try encoder.setDepthStencilState(factory.depthStencilState(draw.depthStencil))
        let raster = WPEParityMetalStateMapping.rasterSettings(draw.rasterizer)
        encoder.setTriangleFillMode(raster.fillMode)
        encoder.setCullMode(raster.cullMode)
        encoder.setFrontFacing(raster.frontFacing)
        encoder.setDepthBias(raster.depthBias, slopeScale: raster.depthSlopeScale, clamp: raster.depthBiasClamp)
        encoder.setDepthClipMode(raster.depthClipMode)

        var textureStages: [ObjectIdentifier: (MTLTexture, MTLRenderStages)] = [:]
        if let offset = try encodeArguments(draw.pipeline.vertex, stages: emulation == nil ? .vertex : .object,
                                            constants: draw.constants[.vertex], draw: draw, frame: frame,
                                            textureStages: &textureStages) {
            if emulation == nil {
                encoder.setVertexBuffer(frame.buffer, offset: offset, index: WPEParityMSCRuntime.argumentBufferBindPoint)
            } else {
                encoder.setObjectBuffer(frame.buffer, offset: offset, index: WPEParityMSCRuntime.argumentBufferBindPoint)
            }
        }
        if let emulation, let offset = try encodeArguments(emulation.geometry, stages: .mesh,
                                                           constants: draw.constants[.geometry], draw: draw,
                                                           frame: frame, textureStages: &textureStages) {
            encoder.setMeshBuffer(frame.buffer, offset: offset, index: WPEParityMSCRuntime.argumentBufferBindPoint)
        }
        if let offset = try encodeArguments(draw.pipeline.fragment, stages: .fragment,
                                            constants: draw.constants[.fragment], draw: draw, frame: frame,
                                            textureStages: &textureStages) {
            encoder.setFragmentBuffer(frame.buffer, offset: offset, index: WPEParityMSCRuntime.argumentBufferBindPoint)
        }
        // Cbuffers live in the arena buffer bound above, so only textures need explicit residency.
        for (texture, stages) in textureStages.values {
            encoder.useResource(texture, usage: .read, stages: stages)
        }

        if let emulation {
            emulation.drawPoints(on: encoder, vertexBuffer: draw.vertexBuffer, offset: draw.vertexBufferOffset,
                                 vertexStart: draw.vertexStart, vertexCount: draw.vertexCount)
            return
        }
        encoder.setVertexBuffer(draw.vertexBuffer, offset: draw.vertexBufferOffset,
                                index: WPEParityMSCRuntime.vertexBufferBindPoint)
        // IRRuntimeDrawParams is a union of IRRuntimeDrawArgument and the 20-byte IRRuntimeDrawIndexedArgument.
        let drawParams: [UInt32] = if draw.indexBuffer != nil {
            [UInt32(draw.indexCount), 1, 0, 0, 0]
        } else {
            [UInt32(draw.vertexCount), 1, UInt32(draw.vertexStart), 0, 0]
        }
        drawParams.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.drawArgumentsBindPoint)
        }
        // IRMetalIndexToIRIndex: the Metal index type plus one.
        let indexType = draw.indexBuffer == nil
            ? WPEParityMSCRuntime.nonIndexedDraw : UInt16(MTLIndexType.uint16.rawValue + 1)
        withUnsafeBytes(of: indexType) {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.uniformsBindPoint)
        }
        if let indexBuffer = draw.indexBuffer {
            encoder.drawIndexedPrimitives(type: draw.primitiveType, indexCount: draw.indexCount, indexType: .uint16,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0)
        } else {
            encoder.drawPrimitives(type: draw.primitiveType, vertexStart: draw.vertexStart,
                                   vertexCount: draw.vertexCount)
        }
    }

    /// Returns the arena offset of the stage's top-level argument buffer, or `nil` when it has no entries.
    private func encodeArguments(
        _ stage: WPEParityPipeline.Stage,
        stages: MTLRenderStages,
        constants: [String: WPECBufferValue]?,
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
                if let value = constants?[variable.name] {
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
                try Self.validateDimension(resource, textureType: texture.textureType)
                // Texture metadata: min LOD clamp 0.0 in the low 32 bits.
                try plan.writeEntry(at: offset, gpuAddress: 0, resourceID: texture.gpuResourceID._impl,
                                    metadata: 0, into: &table)
                let key = ObjectIdentifier(texture)
                textureStages[key] = (texture, (textureStages[key]?.1 ?? []).union(stages))
            case .sampler:
                guard let state = draw.samplers[resource.name] else {
                    throw WPEParityExecutionError.missingSampler(resource.name)
                }
                let sampler = try factory.samplerState(state)
                frame.retainSampler(sampler)
                // Sampler metadata is the LOD bias; it stays 0 because the sampler descriptor already carries it.
                try plan.writeEntry(at: offset, gpuAddress: sampler.gpuResourceID._impl,
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
