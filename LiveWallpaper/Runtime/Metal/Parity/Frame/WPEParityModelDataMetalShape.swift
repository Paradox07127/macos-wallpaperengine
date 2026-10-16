#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

/// One immutable resource version owned by the canonical ModelData shape. Draw plans and submitted Metal
/// commands retain this version; updating a live model never writes into a buffer an earlier frame can read.
final class WPEParityModelDataMetalShape: WPEParityModelDataPreparedShape, @unchecked Sendable { // all lets; buffers never written after init
    let vertexFormat: UInt32
    let vertexCount: Int
    let indexElementWidth: WPEPuppetIndexElementWidth?
    let indexCount: Int
    let program: WPEParityProgram
    let mesh: WPEParitySceneModelMesh
    let frameReads: [WPEResourceID]
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer?
    private let vertexLayout: WPEPuppetVertexLayout
    private let engineFlags: WPEEngineComboFlags
    private let vertexInputs: [WPEStageReflection.StageAttribute]

    var indexType: MTLIndexType {
        indexElementWidth == .uint32 ? .uint32 : .uint16
    }

    private init(shape: WPEParitySceneModelData.Shape, program: WPEParityProgram, mesh: WPEParitySceneModelMesh,
                 frameReads: [WPEResourceID], engineFlags: WPEEngineComboFlags,
                 inputs: [WPEStageReflection.StageAttribute],
                 vertices: MTLBuffer, indices: MTLBuffer?) {
        vertexFormat = shape.vertices.layout.format
        vertexCount = shape.vertices.vertexCount
        indexElementWidth = shape.indices?.elementWidth
        indexCount = shape.indices?.count ?? 0
        self.program = program
        self.mesh = mesh
        self.frameReads = frameReads
        self.engineFlags = engineFlags
        vertexLayout = shape.vertices.layout
        vertexInputs = inputs
        vertexBuffer = vertices
        indexBuffer = indices
    }

    /// The existing ProgramScene asset resolver and compiled shader owner qualify material/input admission.
    /// Cold shaders remain an explicit resource prerequisite until the global registration loader supplies them.
    static func program(materialPath path: String, plan: WPEParityFramePlan) throws -> WPEParityProgram {
        let draw = WPEParitySceneDraw(
            pass: WPEPassIdentity("modeldata/material-admission"), objectID: "modeldata/material-admission",
            shader: "", source: .init(materialPath: path), reads: [],
            target: WPEParitySceneResource.backbuffer, blend: .normal, writeMask: .rgba, geometry: .modelMesh
        )
        guard let description = WPEParityProgramBuilder.description(of: .scene(draw), scene: plan.scene) else {
            throw WPEParityModelDataFailure.native(1)
        }
        return try WPEParityProgramResolver.resolve(description, sources: plan.scene.assets)
    }

    static func prepare(
        _ shape: WPEParitySceneModelData.Shape, mutation: WPEParityModelDataMutation,
        plan: WPEParityFramePlan,
        artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>], device: MTLDevice
    ) throws -> WPEParityModelDataMetalShape {
        let previous = shape.prepared as? WPEParityModelDataMetalShape
        let mesh: WPEParitySceneModelMesh
        let program: WPEParityProgram
        let frameReads: [WPEResourceID]
        let engineFlags: WPEEngineComboFlags
        let bufferMutation = switch mutation {
        case .vertices, .indices: true
        case .create, .rebuild, .material: false
        }
        if bufferMutation {
            // 1401d6400 writes material before VB/IB, but notifies its material observer only at the tail.
            // Buffer prefixes must use the program already admitted by the preceding resource version.
            guard let previous else {
                throw WPEParityModelDataFailure.safety("buffer update has no previously admitted material resource")
            }
            mesh = previous.mesh
            program = previous.program
            frameReads = previous.frameReads
            engineFlags = previous.engineFlags
        } else {
            guard let path = String(data: shape.material, encoding: .utf8), !path.isEmpty else {
                throw WPEParityModelDataFailure.native(1)
            }
            if let previous, previous.mesh.material?.materialPath == path,
               previous.engineFlags == plan.scene.engineFlags {
                mesh = previous.mesh
                program = previous.program
                frameReads = previous.frameReads
            } else {
                guard let loaded = plan.scene.modelDataMesh(materialPath: path) else {
                    throw WPEParityModelDataFailure.native(1)
                }
                mesh = loaded
                program = try Self.program(materialPath: path, plan: plan)
                frameReads = plan.scene.modelDataFrameReads(materialPath: path)
            }
            engineFlags = plan.scene.engineFlags
        }
        guard case let .success(artifact)? = artifacts[program.hlsl] else {
            throw WPEParityModelDataFailure.safety("material program was not prepared by the scene asset loader: \(mesh.material?.materialPath ?? program.shader)")
        }
        guard artifact.geometry == nil else {
            throw WPEParityModelDataFailure.safety("model geometry-stage admission requires its original input contract")
        }
        let reuseVertices: Bool
        let reuseIndices: Bool
        switch mutation {
        case .create, .rebuild:
            (reuseVertices, reuseIndices) = (false, false)
        case .vertices:
            (reuseVertices, reuseIndices) = (false, true)
        case .indices:
            (reuseVertices, reuseIndices) = (true, false)
        case .material:
            (reuseVertices, reuseIndices) = (true, true)
        }
        // Only a compatible immutable version may supply the unchanged half of a dynamic update.
        let inputs = artifact.vertex.reflection.vertexInputs.sorted { $0.index < $1.index }
        let compatible = previous.map {
            $0.vertexFormat == shape.vertices.layout.format && Self.sameInputs($0.vertexInputs, inputs)
        } ?? false
        let vertices: MTLBuffer
        if reuseVertices, compatible, let previous {
            vertices = previous.vertexBuffer
        } else {
            let count: Int
            do {
                count = try WPEParityFrameDrawPlanner.rawVertexWordCount(shape.vertices, inputs: inputs)
            } catch {
                throw WPEParityModelDataFailure.safety("material vertex input is unsupported: \(error)")
            }
            guard count <= device.maxBufferLength / MemoryLayout<UInt32>.size,
                  let made = device.makeBuffer(length: max(16, count * MemoryLayout<UInt32>.size),
                                               options: .storageModeShared) else {
                throw WPEParityModelDataFailure.safety("Metal vertex resource allocation failed")
            }
            do {
                try WPEParityFrameDrawPlanner.writeRawVertexWords(
                    shape.vertices, inputs: inputs,
                    to: UnsafeMutableBufferPointer(start: made.contents().assumingMemoryBound(to: UInt32.self), count: count)
                )
            } catch {
                throw WPEParityModelDataFailure.safety("material vertex input is unsupported: \(error)")
            }
            vertices = made
        }
        let indices: MTLBuffer?
        if reuseIndices, let previous, previous.indexElementWidth == shape.indices?.elementWidth,
           previous.indexCount == (shape.indices?.count ?? 0) {
            indices = previous.indexBuffer
        } else if let source = shape.indices {
            guard source.data.count % source.elementWidth.rawValue == 0,
                  source.data.count <= device.maxBufferLength else {
                throw WPEParityModelDataFailure.safety("invalid native index view size")
            }
            let made = device.makeBuffer(length: max(16, source.data.count), options: .storageModeShared)
            guard let made else { throw WPEParityModelDataFailure.safety("Metal index resource allocation failed") }
            source.data.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress, !bytes.isEmpty {
                    made.contents().copyMemory(from: source, byteCount: bytes.count)
                }
            }
            indices = made
        } else {
            indices = nil
        }
        return WPEParityModelDataMetalShape(shape: shape, program: program, mesh: mesh,
                                            frameReads: frameReads, engineFlags: engineFlags, inputs: inputs,
                                            vertices: vertices, indices: indices)
    }

    /// Replacing only an immutable buffer version preserves this draw's already compiled graph and pipeline.
    /// Structural changes return to ordinary planning, including failed admission's explicit no-draw shape.
    func canReplaceDrawVersion(_ previous: WPEParityModelDataMetalShape) -> Bool {
        mesh == previous.mesh && program == previous.program && frameReads == previous.frameReads
            && engineFlags == previous.engineFlags && vertexLayout == previous.vertexLayout
            && vertexCount == previous.vertexCount && indexElementWidth == previous.indexElementWidth
            && indexCount == previous.indexCount && Self.sameInputs(vertexInputs, previous.vertexInputs)
    }

    private static func sameInputs(_ lhs: [WPEStageReflection.StageAttribute],
                                   _ rhs: [WPEStageReflection.StageAttribute]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
            pair.0.name == pair.1.name && pair.0.index == pair.1.index
                && pair.0.columns == pair.1.columns && pair.0.elementType == pair.1.elementType
        }
    }
}
#endif
