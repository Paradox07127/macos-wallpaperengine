import Foundation

/// The canonical value owned by SceneState. Submitted GPU work retains its exact Data/resource versions separately.
public struct WPEParitySceneModelData: Sendable {
    public struct Shape: Equatable, Sendable {
        public internal(set) var vertices: WPEPuppetVertexStream
        public internal(set) var indices: WPEParityModelDataIndices?
        public internal(set) var material: Data
        public internal(set) var isVertexBufferDynamic: Bool
        public internal(set) var isIndexBufferDynamic: Bool
    }

    public internal(set) var shapes: [Shape]
    public let bounds: WPEPuppetMeshBounds
    public internal(set) var references: UInt32 = 1
}

public enum WPEParityModelDataMutation: Sendable {
    case create(token: UInt32, shape: Int)
    case rebuild(token: UInt32, shape: Int)
    case vertices(token: UInt32, shape: Int)
    case indices(token: UInt32, shape: Int)
}

public enum WPEParityModelDataFailure: Error, Equatable {
    case native(Int)
    /// Explicit macOS safety admission, never presented as an original native error.
    case safety(String)

    public var message: String {
        switch self {
        case .native(1): "Invalid material"
        case .native(2): "Shader expecting more vertex data."
        case .native(3): "Inconsistent vertex buffer size"
        case .native(4): "Invalid model data token"
        case .native(5): "Vertex buffer size cannot increase"
        case .native(6): "Index buffer size cannot increase"
        case .native(7): "Model data not created as dynamic"
        case .native(8): "Buffer lock failed"
        case .native(9): "Incorrect index buffer type"
        case .native(10): "Cannot add shapes in IModelData.update"
        case .native(11): "Cannot delete shape or buffers in IModelData.update"
        case .native(12): "Material cannot be changed in IModelData.update"
        case .native(13): "Vertex format cannot be changed in IModelData.update"
        case let .native(code): "Unknown model data error \(code)"
        case let .safety(reason): "ModelData safety admission: \(reason)"
        }
    }
}

public extension WPEParitySceneState {
    var modelDataGeneration: Int {
        modelDataRevision
    }

    func modelData(_ token: UInt32) -> WPEParitySceneModelData? {
        modelDataValues[token]
    }

    /// All VM shapes have already converted successfully. Creation publishes no model on resource admission failure.
    mutating func createModelData(
        _ patch: WPEParityModelDataPatch,
        admitShape: (WPEParitySceneModelData.Shape, WPEParityModelDataMutation) throws -> Void
    ) throws -> UInt32 {
        guard lastModelDataToken < UInt32.max else { throw WPEParityModelDataFailure.safety("model token space exhausted") }
        let token = lastModelDataToken + 1
        var shapes: [WPEParitySceneModelData.Shape] = []
        var lastFailure: WPEParityModelDataFailure?
        for (index, value) in patch.shapes.enumerated() {
            let shape = try Self.modelShape(value, validateSize: false)
            if shape.vertices.data.count % shape.vertices.layout.stride != 0 {
                lastFailure = .native(3)
            }
            // The constructor continues later material/shape validation; a later native error replaces its code.
            do {
                try admitShape(shape, .create(token: token, shape: index))
            } catch let failure as WPEParityModelDataFailure {
                if case .native = failure {
                    lastFailure = failure
                } else {
                    throw failure
                }
            }
            shapes.append(shape)
        }
        if let lastFailure {
            throw lastFailure
        }
        let bounds = patch.bounds ?? Self.modelBounds(shapes)
        lastModelDataToken += 1
        modelDataValues[lastModelDataToken] = .init(shapes: shapes, bounds: bounds)
        modelDataRevision += 1
        return lastModelDataToken
    }

    /// 1401d6400 mutates in original shape/field order. Earlier writes survive a later native error.
    /// Deferred null-shape compaction happens only after the main loop completes normally.
    mutating func updateModelData(
        _ token: UInt32, patch: WPEParityModelDataPatch, replacing: Bool,
        admitShape: (WPEParitySceneModelData.Shape, WPEParityModelDataMutation) throws -> Void
    ) throws {
        guard var model = modelDataValues[token] else { throw WPEParityModelDataFailure.native(4) }
        if !replacing, patch.shapes.count > model.shapes.count {
            throw WPEParityModelDataFailure.native(10)
        }
        var changed = false
        defer {
            modelDataValues[token] = model
            if changed {
                modelDataRevision += 1
            }
        }
        var lastLockFailure: WPEParityModelDataFailure?
        var removals: [Int] = []
        for (index, value) in patch.shapes.enumerated() {
            if value.remove || value.indices == .remove {
                if !replacing {
                    throw WPEParityModelDataFailure.native(11)
                }
                if value.remove {
                    guard index < model.shapes.count else { throw WPEParityModelDataFailure.safety("null shape exceeds existing shape range") }
                    removals.append(index)
                    continue
                }
            }
            if index == model.shapes.count {
                let shape = try Self.modelShape(value)
                try admitShape(shape, .rebuild(token: token, shape: index))
                model.shapes.append(shape)
                changed = true
                continue
            }
            if let material = value.material, !material.isEmpty, material != model.shapes[index].material {
                if !replacing {
                    throw WPEParityModelDataFailure.native(12)
                }
                model.shapes[index].material = material
                changed = true
            }
            var shape = model.shapes[index]
            let formatChanged = value.vertexFormat != 0 && value.vertexFormat != shape.vertices.layout.format
            if formatChanged, !replacing {
                throw WPEParityModelDataFailure.native(13)
            }
            let incomingIndices: WPEParityModelDataIndices? = if case let .buffer(buffer) = value.indices {
                buffer
            } else {
                nil
            }
            let rebuild = formatChanged
                || value.vertices.map { $0.count > shape.vertices.data.count || !shape.isVertexBufferDynamic } == true
                || incomingIndices.map { $0.count > (shape.indices?.count ?? 0) || !shape.isIndexBufferDynamic } == true
                || (value.indices == .remove && shape.indices != nil)
            if rebuild {
                if !replacing {
                    throw WPEParityModelDataFailure.native(7)
                }
                // The original rebuild reads the new descriptor directly. Do not invent omitted old bytes/format.
                shape = try Self.modelShape(value, material: shape.material)
                model.shapes[index] = shape
                changed = true
                try admitShape(shape, .rebuild(token: token, shape: index))
                continue
            }
            if let vertices = value.vertices {
                guard vertices.count >= shape.vertices.data.count else {
                    throw WPEParityModelDataFailure.safety("vertex view is shorter than the original copy length")
                }
                shape.vertices = WPEPuppetVertexStream(data: vertices, layout: shape.vertices.layout)
                do {
                    try admitShape(shape, .vertices(token: token, shape: index))
                    model.shapes[index].vertices = shape.vertices
                    changed = true
                } catch WPEParityModelDataFailure.native(8) { lastLockFailure = .native(8) }
            }
            if let indices = incomingIndices {
                guard indices.elementWidth == model.shapes[index].indices?.elementWidth else {
                    throw WPEParityModelDataFailure.native(9)
                }
                guard indices.data.count >= (model.shapes[index].indices?.data.count ?? 0) else {
                    throw WPEParityModelDataFailure.safety("index view is shorter than the original copy length")
                }
                shape = model.shapes[index]
                shape.indices = indices
                do {
                    try admitShape(shape, .indices(token: token, shape: index))
                    model.shapes[index].indices = indices
                    changed = true
                } catch WPEParityModelDataFailure.native(8) { lastLockFailure = .native(8) }
            }
        }
        for index in removals.reversed() {
            model.shapes.remove(at: index)
            changed = true
        }
        if let lastLockFailure {
            throw lastLockFailure
        }
    }

    /// Numeric host release and the actual referencing-layer destructor share this one reference owner.
    mutating func releaseModelData(_ token: UInt32) {
        guard var model = modelDataValues[token] else { return }
        if model.references > 1 {
            model.references -= 1
            modelDataValues[token] = model
        } else {
            modelDataValues[token] = nil
            modelDataRevision += 1
        }
    }

    private static func modelShape(_ patch: WPEParityModelDataShapePatch, material: Data? = nil,
                                   validateSize: Bool = true) throws -> WPEParitySceneModelData.Shape {
        guard !patch.remove, let stream = patch.vertexStream, let name = material ?? patch.material,
              stream.layout.stride > 0 else {
            throw WPEParityModelDataFailure.safety("incomplete descriptor cannot rebuild a native model buffer safely")
        }
        if validateSize, stream.data.count % stream.layout.stride != 0 {
            throw WPEParityModelDataFailure.native(3)
        }
        let indices: WPEParityModelDataIndices? = if case let .buffer(buffer) = patch.indices {
            buffer
        } else {
            nil
        }
        return .init(vertices: stream, indices: indices, material: name,
                     isVertexBufferDynamic: patch.isVertexBufferDynamic ?? false,
                     isIndexBufferDynamic: patch.isIndexBufferDynamic ?? false)
    }

    private static func modelBounds(_ shapes: [WPEParitySceneModelData.Shape]) -> WPEPuppetMeshBounds {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for shape in shapes {
            // Native initial bounds scan consecutive xyz triples, independent of the vertex format stride.
            shape.vertices.data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, through: bytes.count - 12, by: 12) {
                    for lane in 0 ..< 3 {
                        let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + lane * 4, as: UInt32.self))
                        let value = Float(bitPattern: bits)
                        minimum[lane] = minimum[lane] <= value ? minimum[lane] : value
                        maximum[lane] = value <= maximum[lane] ? maximum[lane] : value
                    }
                }
            }
        }
        return .init(minimum: minimum, maximum: maximum)
    }
}
