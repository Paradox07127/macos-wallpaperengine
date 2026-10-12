// Ported from metal_irconverter_runtime.h (Metal Shader Converter), Copyright 2023-2025 Apple Inc., Apache License 2.0.
#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// A WPE geometry shader run as a mesh pipeline: VS as the object stage (fed by MSC's stage-in function), GS as the
/// mesh stage. Only the non-indexed point-list path of the runtime header is ported.
struct WPEParityGeometryEmulation {
    let geometry: WPEParityPipeline.Stage
    /// IRRuntimeGeometryPipelineConfig.gsMaxInputPrimitivesPerMeshThreadgroup, from the GS reflection.
    let maxInputPrimitivesPerMeshThreadgroup: Int
    /// Points one object threadgroup takes (IRRuntimeDrawInfo.objectThreadgroupVertexStride).
    let objectThreadgroupVertexStride: Int
    /// The stage-in function reads one interleaved buffer packed tightly in VS input order.
    let vertexStride: Int

    /// IRRuntimeNewGeometryEmulationPipeline. `descriptor` arrives with its attachments configured.
    static func makePipeline(
        device: MTLDevice,
        vertex: WPEParityShaderArtifact.Stage,
        geometry: WPEParityShaderArtifact.Stage,
        fragment: MTLFunction,
        descriptor: MTLMeshRenderPipelineDescriptor
    ) throws -> (MTLRenderPipelineState, Self) {
        guard let stageIn = vertex.stageIn else { throw WPEParityExecutionError.missingFunction("stage-in") }
        let vertexOutputSize = try stateInteger("vertex_output_size_in_bytes", in: vertex.reflection)
        let maxInputPrimitives = try stateInteger("max_input_primitives_per_mesh_threadgroup", in: geometry.reflection)
        let stageInLibrary = try library(stageIn, device: device)
        guard let stageInName = stageInLibrary.functionNames.first,
              let stageInFunction = stageInLibrary.makeFunction(name: stageInName) else {
            throw WPEParityExecutionError.missingFunction("stage-in")
        }

        let constants = MTLFunctionConstantValues()
        var tessellationEnabled = false
        constants.setConstantValue(&tessellationEnabled, type: .bool, withName: "tessellationEnabled")
        descriptor.objectFunction = try library(vertex.metallib, device: device).makeFunction(
            name: vertex.functionName + ".dxil_irconverter_object_shader", constantValues: constants
        )
        var vertexOutputSizeConstant = Int32(vertexOutputSize)
        constants.setConstantValue(&vertexOutputSizeConstant, type: .int, withName: "vertex_shader_output_size_fc")
        descriptor.meshFunction = try library(geometry.metallib, device: device).makeFunction(
            name: geometry.functionName, constantValues: constants
        )
        descriptor.fragmentFunction = fragment
        let linked = MTLLinkedFunctions()
        linked.functions = [stageInFunction]
        descriptor.objectLinkedFunctions = linked
        let (state, _) = try device.makeRenderPipelineState(descriptor: descriptor, options: [])

        // IRRuntimeCalculateDrawInfoForGSEmulation for points: one vertex per primitive, so no alignment or overlap.
        let payloadBytesForVertexData = 16384 - 32
        let maxPointsPerObjectThreadgroup = min(payloadBytesForVertexData / vertexOutputSize,
                                                1024 * maxInputPrimitives, 256)
        let vertexStride = vertex.reflection.vertexInputs.reduce(0) { $0 + $1.columns * 4 }
        return try (state, Self(geometry: WPEParityPipeline.Stage(geometry.reflection),
                                maxInputPrimitivesPerMeshThreadgroup: maxInputPrimitives,
                                objectThreadgroupVertexStride: maxPointsPerObjectThreadgroup,
                                vertexStride: vertexStride))
    }

    /// IRRuntimeDrawPrimitivesGeometryEmulation with a point list, one instance, plus the IRRuntimeVertexBuffers table
    /// the stage-in function reads at kIRVertexBufferBindPoint.
    func drawPoints(on encoder: MTLRenderCommandEncoder, vertexBuffer: MTLBuffer, offset: Int,
                    vertexStart: Int, vertexCount: Int) {
        // IRRuntimeVertexBuffer[31]: { uint64 addr; uint32 length; uint32 stride }, slot 0 only.
        var vertexBuffers = [UInt64](repeating: 0, count: 31 * 2)
        vertexBuffers[0] = vertexBuffer.gpuAddress + UInt64(offset)
        vertexBuffers[1] = UInt64(UInt32(vertexBuffer.length - offset)) | UInt64(UInt32(vertexStride)) << 32
        vertexBuffers.withUnsafeBytes {
            encoder.setObjectBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.vertexBufferBindPoint)
        }
        encoder.useResource(vertexBuffer, usage: .read, stages: .object)

        // IRRuntimeDrawInfo (24 bytes): indexType, topology | threadsPerPatch << 8, maxInputPrimitivesPerMeshThreadgroup,
        // objectThreadgroupVertexStride, meshThreadgroupPrimitiveStride, gsInstanceCount, patchesPerObjectThreadgroup,
        // inputControlPointsPerPatch, then a zero index buffer address.
        let drawInfo: [UInt16] = [
            WPEParityMSCRuntime.nonIndexedDraw, 1 << 8, UInt16(maxInputPrimitivesPerMeshThreadgroup),
            UInt16(objectThreadgroupVertexStride), UInt16(maxInputPrimitivesPerMeshThreadgroup), 1,
            UInt16(objectThreadgroupVertexStride), 1, 0, 0, 0, 0,
        ]
        // IRRuntimeDrawParams: the 20-byte union of IRRuntimeDrawArgument and IRRuntimeDrawIndexedArgument.
        let drawParams: [UInt32] = [UInt32(vertexCount), 1, UInt32(vertexStart), 0, 0]
        drawInfo.withUnsafeBytes {
            encoder.setObjectBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.uniformsBindPoint)
            encoder.setMeshBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.uniformsBindPoint)
        }
        drawParams.withUnsafeBytes {
            encoder.setObjectBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.drawArgumentsBindPoint)
            encoder.setMeshBytes($0.baseAddress!, length: $0.count, index: WPEParityMSCRuntime.drawArgumentsBindPoint)
        }
        let threadgroups = (vertexCount + objectThreadgroupVertexStride - 1) / objectThreadgroupVertexStride
        encoder.drawMeshThreadgroups(MTLSize(width: threadgroups, height: 1, depth: 1),
                                     threadsPerObjectThreadgroup: MTLSize(width: objectThreadgroupVertexStride,
                                                                          height: 1, depth: 1),
                                     threadsPerMeshThreadgroup: MTLSize(width: maxInputPrimitivesPerMeshThreadgroup,
                                                                        height: 1, depth: 1))
    }

    private static func library(_ metallib: Data, device: MTLDevice) throws -> MTLLibrary {
        try device.makeLibrary(data: metallib.withUnsafeBytes { DispatchData(bytes: $0) })
    }

    private static func stateInteger(_ key: String, in reflection: WPEStageReflection) throws -> Int {
        guard case let .object(state)? = reflection.mscReflection["state"] else {
            throw WPEParityExecutionError.geometryReflectionMissing(key)
        }
        switch state[key] {
        case let .integer(value) where value > 0: return Int(value)
        case let .unsignedInteger(value) where value > 0: return Int(value)
        default: throw WPEParityExecutionError.geometryReflectionMissing(key)
        }
    }
}
#endif
