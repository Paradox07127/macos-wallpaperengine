#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

extension WPEParityFrameDrawPlanner {
    // MARK: State and geometry

    static func blend(_ description: WPEParityFrameDraw) -> WPEParityBlendState {
        switch description {
        case let .scene(draw):
            let mode: WPEParityBlendMode = switch draw.blend {
            case .normal: .normal
            case .translucent: .translucent
            case .additive: .additive
            case .alphaToCoverage: .alphaToCoverage
            }
            var modifiers: WPEParityBlendModifiers = draw.writeMask == .rgba ? .writeAlpha : []
            if draw.alphaMax {
                modifiers.insert(.alphaMax)
            }
            if draw.multipliesDestination {
                modifiers.insert(.multiply)
            }
            return .wpe(mode, modifiers: modifiers)
        case let .post(draw):
            switch draw.blend {
            case .normal: return .wpe(.normal, modifiers: .writeAlpha)
            case .translucent: return .wpe(.translucent)
            case .additive: return .wpe(.additive)
            }
        }
    }

    struct Vertex {
        var position: SIMD3<Float>
        var texcoord: SIMD2<Float>
        var blendIndices = SIMD4<UInt32>.zero
        var blendWeights = SIMD4<Float>.zero
        var normal = SIMD3<Float>(0, 0, 1)
    }

    /// One model sub-mesh using the preserved MDLV stream; u32 meshes upload R32 indices (14009a880.c:58-68).
    static func modelGeometry(_ mesh: WPEPuppetMesh, inputs: [WPEStageReflection.StageAttribute],
                              device: MTLDevice) throws(WPEParityFrameSkip)
        -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int, indexType: MTLIndexType)? {
        switch mesh.indexElementWidth {
        case .uint16:
            guard let buffers = try modelGeometry(mesh, indices: WPEParityScenePuppet.indices(of: mesh),
                                                  inputs: inputs, device: device) else { return nil }
            return (buffers.vertices, buffers.indices, buffers.indexCount, .uint16)
        case .uint32:
            guard let buffers = try modelGeometry(mesh, indices: mesh.indices, inputs: inputs, device: device)
            else { return nil }
            return (buffers.vertices, buffers.indices, buffers.indexCount, .uint32)
        }
    }

    private static func modelGeometry(
        _ mesh: WPEPuppetMesh, indices: [some FixedWidthInteger], inputs: [WPEStageReflection.StageAttribute], device: MTLDevice
    ) throws(WPEParityFrameSkip) -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        if let stream = mesh.vertexStream {
            return try rawGeometry(stream, indices: indices, inputs: inputs, uvMax: .one, device: device)
        }
        return geometry(mesh.vertices.map {
            Vertex(position: $0.position, texcoord: $0.uv, blendIndices: SIMD4(truncatingIfNeeded: $0.skinBlendIndices),
                   blendWeights: $0.skinBlendWeights, normal: $0.normal)
        }, indices: indices, inputs: inputs, device: device)
    }

    /// Mesh0 of a puppet layer, or one of its clip segments, with its texcoords scaled by `uvMax`.
    static func puppetGeometry(_ puppet: WPEParityScenePuppet, segment: Int? = nil, uvMax: SIMD2<Float>,
                               inputs: [WPEStageReflection.StageAttribute],
                               device: MTLDevice) throws(WPEParityFrameSkip)
        -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        let indices = segment.map { Array(puppet.clipIndices[puppet.clipSegments[$0]]) } ?? puppet.indices
        if let stream = puppet.vertexStream {
            return try rawGeometry(stream, indices: indices, inputs: inputs, uvMax: uvMax, device: device)
        }
        return geometry(puppet.vertices.map {
            Vertex(position: $0.position, texcoord: $0.uv * uvMax,
                   blendIndices: SIMD4(truncatingIfNeeded: $0.skinBlendIndices), blendWeights: $0.skinBlendWeights)
        }, indices: indices, inputs: inputs, device: device)
    }

    static func rawVertexWordCount(_ stream: WPEPuppetVertexStream,
                                   inputs: [WPEStageReflection.StageAttribute]) throws(WPEParityFrameSkip) -> Int {
        var width = 0
        for input in inputs {
            guard (1 ... 4).contains(input.columns) else { throw .pipeline("invalid vertex input width") }
            let added = width.addingReportingOverflow(input.columns)
            guard !added.overflow else { throw .pipeline("vertex input width exceeds addressable storage") }
            width = added.partialValue
        }
        let count = stream.vertexCount.multipliedReportingOverflow(by: width)
        guard !count.overflow else { throw .pipeline("vertex input stream exceeds addressable storage") }
        return count.partialValue
    }

    /// Maps the native stream straight into its Metal upload in MSC reflection order, preserving uint
    /// BLENDINDICES and float NaN payloads. D3D11 missing components are zero except W=1 in the source type.
    static func writeRawVertexWords(_ stream: WPEPuppetVertexStream, inputs: [WPEStageReflection.StageAttribute],
                                    uvMax: SIMD2<Float> = .one,
                                    to destination: UnsafeMutableBufferPointer<UInt32>) throws(WPEParityFrameSkip) {
        guard !stream.layout.hasSyntheticPosition else {
            throw .pipeline("MDLV vertex format is missing authored POSITION0")
        }
        guard stream.layout.stride > 0, stream.data.count % stream.layout.stride == 0,
              stream.layout.unsupportedFlags == 0 else {
            throw .pipeline("unsupported or malformed MDLV vertex format 0x\(String(stream.layout.format, radix: 16))")
        }
        struct Input {
            let attribute: WPEPuppetVertexAttribute
            let columns: Int
            /// Only the puppet's first UV pair is adjusted for its albedo image; UV.zw/UV1+ survive.
            let scalesUV: Bool
        }
        var resolved: [Input] = []
        for input in inputs.sorted(by: { $0.index < $1.index }) {
            guard (1 ... 4).contains(input.columns),
                  ["float", "int", "sint", "uint", "uint32"].contains(input.elementType.lowercased()) else {
                throw .pipeline("unsupported vertex input \(input.name):\(input.elementType)[\(input.columns)]")
            }
            let name = input.name.uppercased()
            let semantic = String(name.reversed().drop(while: { $0.isNumber }).reversed())
            let suffix = name.dropFirst(semantic.count)
            let index = suffix.isEmpty ? 0 : Int(suffix) ?? -1
            let attributes = stream.layout.attributes(semantic: semantic, index: index)
            guard attributes.count == 1, let attribute = attributes.first else {
                throw .pipeline("MDLV input \(input.name) has \(attributes.count) native elements")
            }
            resolved.append(Input(attribute: attribute, columns: input.columns,
                                  scalesUV: attribute.semantic == "TEXCOORD" && attribute.semanticIndex == 0
                                      && attribute.componentType == .float32))
        }
        let count = try rawVertexWordCount(stream, inputs: inputs)
        guard destination.count >= count else {
            throw .pipeline("vertex upload is shorter than its reflected input stream")
        }
        var output = 0
        stream.data.withUnsafeBytes { bytes in
            for vertex in 0 ..< stream.vertexCount {
                for input in resolved {
                    let attribute = input.attribute
                    for lane in 0 ..< input.columns {
                        var word: UInt32 = lane == 3
                            ? (attribute.componentType == .float32 ? Float(1).bitPattern : 1) : 0
                        if lane < attribute.componentCount {
                            let offset = vertex * stream.layout.stride + attribute.byteOffset + lane * 4
                            word = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                            if input.scalesUV, lane < 2, uvMax[lane] != 1 {
                                word = (Float(bitPattern: word) * uvMax[lane]).bitPattern
                            }
                        }
                        destination[output] = word
                        output += 1
                    }
                }
            }
        }
    }

    private static func rawGeometry<Index: FixedWidthInteger>(_ stream: WPEPuppetVertexStream, indices: [Index],
                                                              inputs: [WPEStageReflection.StageAttribute],
                                                              uvMax: SIMD2<Float>,
                                                              device: MTLDevice) throws(WPEParityFrameSkip)
        -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        let count = try rawVertexWordCount(stream, inputs: inputs)
        guard let vertices = device.makeBuffer(length: max(16, count * 4), options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<Index>.stride,
                                                  options: .storageModeShared) else { return nil }
        try writeRawVertexWords(
            stream, inputs: inputs, uvMax: uvMax,
            to: UnsafeMutableBufferPointer(start: vertices.contents().assumingMemoryBound(to: UInt32.self), count: count)
        )
        return (vertices, indexBuffer, indices.count)
    }

    /// One glyph list of a text layer, or its background quad from (0, 0) to the FBO size with the glyph quads'
    /// corner order and indices.
    static func textMesh(_ text: WPEParitySceneText,
                         _ geometry: WPEParitySceneDraw.Geometry) -> (vertices: [Vertex], indices: [UInt16])? {
        switch geometry {
        case let .textGlyphs(list):
            guard let mesh = text.layout.mesh else { return nil }
            let glyphs = list == .mono ? mesh.mono : mesh.color
            return (glyphs.vertices.map { Vertex(position: SIMD3($0.x, $0.y, $0.z), texcoord: SIMD2($0.u, $0.v)) },
                    glyphs.indices)
        case .textBackground:
            let size = SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y))
            let corners: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)]
            return (corners.map { Vertex(position: SIMD3($0 * size, 0), texcoord: SIMD2($0.x, 1 - $0.y)) },
                    [0, 2, 1, 1, 2, 3])
        default:
            return nil
        }
    }

    static func geometry<Index: FixedWidthInteger>(
        _ vertices: [Vertex], indices: [Index], inputs: [WPEStageReflection.StageAttribute], device: MTLDevice
    ) -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        guard let vertexBuffer = vertexBuffer(vertices, inputs: inputs, device: device),
              let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<Index>.stride,
                                                  options: .storageModeShared)
        else { return nil }
        return (vertexBuffer, indexBuffer, indices.count)
    }

    /// The vertices packed as the vertex reflection lists its inputs; BLENDINDICES stay integers.
    private static func vertexBuffer(_ vertices: [Vertex], inputs: [WPEStageReflection.StageAttribute],
                                     device: MTLDevice) -> MTLBuffer? {
        var words: [UInt32] = []
        for vertex in vertices {
            for input in inputs.sorted(by: { $0.index < $1.index }) {
                let name = input.name.lowercased()
                let floats: [Float] = if name.hasPrefix("position") {
                    [vertex.position.x, vertex.position.y, vertex.position.z, 1]
                } else if name == "texcoord0" {
                    [vertex.texcoord.x, vertex.texcoord.y, 0, 0]
                } else if name.hasPrefix("normal") {
                    [vertex.normal.x, vertex.normal.y, vertex.normal.z, 0]
                } else if name.hasPrefix("blendweight") {
                    (0 ..< 4).map { vertex.blendWeights[$0] }
                } else if name.hasPrefix("color") {
                    [1, 1, 1, 1]
                } else {
                    [0, 0, 0, 0]
                }
                let value = name.hasPrefix("blendindices") ? (0 ..< 4).map { vertex.blendIndices[$0] }
                    : floats.map(\.bitPattern)
                words += value.prefix(input.columns)
            }
        }
        // An input-less vertex stage still gets a buffer at the MSC vertex bind point.
        let length = max(16, words.count * MemoryLayout<UInt32>.stride)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        buffer.contents().copyMemory(from: words, byteCount: words.count * MemoryLayout<UInt32>.stride)
        return buffer
    }
}
#endif
