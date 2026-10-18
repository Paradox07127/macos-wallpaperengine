#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// The engine g_* inputs of one draw; encoding evaluates only the names a stage declares.
struct WPEParityDrawUniforms {
    var frame: WPEParityUniformFrame
    var draw: WPEParityUniformDraw
    /// Above the engine set and below `WPEParityDraw.constants`: particle orientation, and the last TEXS transform of
    /// each declared slot this draw's own sprite frames do not write.
    var extras: [String: WPECBufferValue] = [:]
}

/// One draw, with its explicit native index width when `indexBuffer` is set. Constants are keyed by stage, then HLSL name, since the stages can map one name to different
/// material keys; textures and samplers are shared. Each stage packs only the names its own reflection declares.
/// With a geometry-emulation pipeline the draw is a non-indexed point list, one vertex per particle.
struct WPEParityDraw {
    var pipeline: WPEParityPipeline
    var depthStencil: WPEParityDepthStencilState
    var rasterizer: WPEParityRasterizerState
    /// Override every engine value in `uniforms` of the same name.
    var constants: [WPEHLSLStage: [String: WPECBufferValue]] = [:]
    var uniforms: WPEParityDrawUniforms?
    var textures: [String: MTLTexture] = [:]
    var samplers: [String: WPEParitySamplerState] = [:]
    var vertexBuffer: MTLBuffer
    var vertexBufferOffset = 0
    var primitiveType: MTLPrimitiveType
    var vertexStart = 0
    var vertexCount: Int
    var indexBuffer: MTLBuffer?
    var indexCount = 0
    /// Puppet/file MDLV remains R16; script ModelData can independently supply R32.
    var indexType: MTLIndexType = .uint16
    var instanceCount = 1
    /// Indexed by SV_ViewportArrayIndex; empty leaves whatever viewports and scissors the encoder already holds.
    var viewports: [MTLViewport] = []
    /// The executor skips and counts this draw when the frame arena cannot hold its arguments, instead of failing
    /// the frame.
    var dropsWhenArenaIsFull = false

    /// Every value `stage` can pack, merged into one dictionary as `WPEParityUniformSet.values` builds it. Encoding
    /// never builds it; it is the reference the packed bytes are checked against.
    func values(for stage: WPEHLSLStage) -> [String: WPECBufferValue] {
        var values = uniforms.map {
            WPEParityUniformSet.values(frame: $0.frame, draw: $0.draw).merging($0.extras) { $1 }
        } ?? [:]
        values.merge(constants[stage] ?? [:]) { $1 }
        return values
    }
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
        _ = try factory.depthStencilState(.wpe(depthTest: false, depthWrite: false))
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

    /// Arena bytes `encode` takes for the stages' cbuffers and top-level argument buffers, each 256-byte aligned.
    static func argumentBytes(stages: [WPEParityPipeline.Stage]) -> Int {
        stages.reduce(0) { total, stage in
            let plan = stage.bindingPlan
            guard plan.totalSize > 0 else { return total }
            let cbuffers = stage.cbuffers.filter {
                plan.cbufferOffset(register: $0.reflection.register, space: $0.reflection.space) != nil
            }
            return cbuffers.reduce(total + WPEParityFrameArena.aligned(plan.totalSize)) {
                $0 + WPEParityFrameArena.aligned($1.boundLength)
            }
        }
    }

    func encode(_ draw: WPEParityDraw, frame: WPEParityFrameArena.Frame, hasDepthAttachment: Bool,
                on encoder: MTLRenderCommandEncoder) throws {
        let emulation = draw.pipeline.geometry
        if emulation != nil, draw.primitiveType != .point || draw.indexBuffer != nil {
            throw WPEParityExecutionError.geometryDrawUnsupported
        }
        guard frame.canAllocate(length: draw.pipeline.argumentBytes) else {
            throw WPEParityExecutionError.arenaExhausted
        }
        encoder.setRenderPipelineState(draw.pipeline.state)
        // D3D11 tests always pass without a bound depth/stencil buffer. Metal requires the matching disabled state.
        let depthStencil = hasDepthAttachment ? draw.depthStencil : .wpe(depthTest: false, depthWrite: false)
        try encoder.setDepthStencilState(factory.depthStencilState(depthStencil))
        let raster = WPEParityMetalStateMapping.rasterSettings(draw.rasterizer)
        encoder.setTriangleFillMode(raster.fillMode)
        encoder.setCullMode(raster.cullMode)
        encoder.setFrontFacing(raster.frontFacing)
        encoder.setDepthBias(raster.depthBias, slopeScale: raster.depthSlopeScale, clamp: raster.depthBiasClamp)
        encoder.setDepthClipMode(raster.depthClipMode)
        if !draw.viewports.isEmpty {
            encoder.setViewports(draw.viewports)
            // Metal selects the scissor rect by viewport index too; WPE never enables scissor, so each equals its viewport.
            encoder.setScissorRects(draw.viewports.map {
                MTLScissorRect(x: Int($0.originX), y: Int($0.originY), width: Int($0.width), height: Int($0.height))
            })
        }

        var textureStages: [ObjectIdentifier: (MTLTexture, MTLRenderStages)] = [:]
        textureStages.reserveCapacity(draw.textures.count)
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
            [UInt32(draw.indexCount), UInt32(draw.instanceCount), 0, 0, 0]
        } else {
            [UInt32(draw.vertexCount), UInt32(draw.instanceCount), UInt32(draw.vertexStart), 0, 0]
        }
        drawParams.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.drawArgumentsBindPoint)
        }
        // IRMetalIndexToIRIndex: the Metal index type plus one.
        let indexType = draw.indexBuffer == nil
            ? WPEParityMSCRuntime.nonIndexedDraw : UInt16(draw.indexType.rawValue + 1)
        withUnsafeBytes(of: indexType) {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.uniformsBindPoint)
        }
        if let indexBuffer = draw.indexBuffer {
            encoder.drawIndexedPrimitives(type: draw.primitiveType, indexCount: draw.indexCount, indexType: draw.indexType,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0, instanceCount: draw.instanceCount)
        } else {
            encoder.drawPrimitives(type: draw.primitiveType, vertexStart: draw.vertexStart,
                                   vertexCount: draw.vertexCount, instanceCount: draw.instanceCount)
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

        for (index, layout) in stage.cbuffers.enumerated() {
            guard let entry = plan.cbufferOffset(register: layout.reflection.register,
                                                 space: layout.reflection.space) else { continue }
            guard let allocation = frame.allocate(length: layout.boundLength) else {
                throw WPEParityExecutionError.arenaExhausted
            }
            try Self.pack(cbuffer: index, of: stage, constants: constants, uniforms: draw.uniforms,
                          at: allocation.contents)
            // Buffer metadata: byte length in the low 32 bits (MSC bounds checks read it).
            try plan.writeEntry(at: entry, gpuAddress: allocation.gpuAddress, resourceID: 0,
                                metadata: UInt64(UInt32(layout.boundLength)), into: &table)
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

    /// Fills one cbuffer of `stage` at `base`: each declared name takes its `constants` value, else its engine value,
    /// else stays zero.
    static func pack(cbuffer index: Int, of stage: WPEParityPipeline.Stage, constants: [String: WPECBufferValue]?,
                     uniforms: WPEParityDrawUniforms?, at base: UnsafeMutableRawPointer) throws {
        let layout = stage.cbuffers[index]
        // Every frame: the arena's slots rotate, so an unzeroed tail would read an earlier frame's bytes.
        _ = base.initializeMemory(as: UInt8.self, repeating: 0, count: layout.boundLength)
        for (variable, uniform) in zip(layout.reflection.variables, stage.engineUniforms[index]) {
            if let value = constants?[variable.name] {
                try WPECBufferWriter.write(value, to: variable, at: base)
            } else if let uniforms {
                if !uniforms.extras.isEmpty, let value = uniforms.extras[variable.name] {
                    try WPECBufferWriter.write(value, to: variable, at: base)
                } else {
                    try WPEParityUniformSet.write(uniform, to: variable, frame: uniforms.frame, draw: uniforms.draw,
                                                  at: base)
                }
            }
        }
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
