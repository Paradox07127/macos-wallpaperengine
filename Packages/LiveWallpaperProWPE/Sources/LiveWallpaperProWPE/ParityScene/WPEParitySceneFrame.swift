public struct WPEParitySceneDraw: Hashable, Sendable {
    public enum Geometry: Hashable, Sendable {
        case fullscreenQuad
        /// The layer's own mesh transformed by the layer MVP.
        case layerMesh
        /// The layer's `WPEParitySceneObject.puppet` mesh transformed by the layer MVP.
        case puppetMesh
        /// The meshes of the object's `.mdl` file.
        case modelMesh
        /// The vertices a particle renderer entry writes this frame.
        case particles(WPEParityParticleDrawKey)
        /// A text layer's quad from (0, 0) to its FBO size (+0x2d8), moved by `WPEParityTextMatrices`.
        case textBackground
        /// One glyph list of the text layer's mesh. Drawn with `fillsComposite` it lands in the text FBO.
        case textGlyphs(WPEParityGlyphAtlasInstance.Atlas)
    }

    public let pass: WPEPassIdentity
    public let objectID: String
    public let effectID: String?
    public let passIndex: Int?
    public let shader: String
    /// Nil when the scene description did not say which material the draw uses.
    public let source: WPEParitySceneMaterialSource?
    public let reads: [WPEResourceID]
    public let target: WPEResourceID
    public let blend: WPEParitySceneBlend
    /// Alpha blend op MAX (RD+0xe8) while drawing into a parent composite that did not copy the background.
    public let alphaMax: Bool
    /// The layer whose composite the draw lands in, rather than the scene; the draw uses that layer's composite
    /// camera. A grandchild drawn through a parent without a composite names the grandparent.
    public let compositeOwnerID: String?
    public let writeMask: WPEParitySceneWriteMask
    public let geometry: Geometry
    /// The albedo filling the layer's own first composite: composite-size mesh and camera instead of the 2×2 quad.
    public let fillsComposite: Bool
    /// Set by model, particle, bit4 composite and `_depth` text draws only; every other scene draw runs with depth off.
    public let depthTest: Bool
    public let depthWrite: Bool
    public let cullsBackFaces: Bool

    public init(pass: WPEPassIdentity, objectID: String, effectID: String? = nil, passIndex: Int? = nil,
                shader: String, source: WPEParitySceneMaterialSource? = nil, reads: [WPEResourceID],
                target: WPEResourceID, blend: WPEParitySceneBlend, alphaMax: Bool = false,
                compositeOwnerID: String? = nil, writeMask: WPEParitySceneWriteMask, geometry: Geometry,
                fillsComposite: Bool = false, depthTest: Bool = false, depthWrite: Bool = false,
                cullsBackFaces: Bool = false) {
        self.pass = pass
        self.objectID = objectID
        self.effectID = effectID
        self.passIndex = passIndex
        self.shader = shader
        self.source = source
        self.reads = reads
        self.target = target
        self.blend = blend
        self.alphaMax = alphaMax
        self.compositeOwnerID = compositeOwnerID
        self.writeMask = writeMask
        self.geometry = geometry
        self.fillsComposite = fillsComposite
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.cullsBackFaces = cullsBackFaces
    }
}

/// Sampler WPE creates with a layer composite (FUN_140099980).
public struct WPEParitySceneSampler: Hashable, Sendable {
    public enum Filter: Hashable, Sendable {
        case linear
        case point
    }

    public enum Address: Hashable, Sendable {
        case clamp
        case wrap
    }

    public let filter: Filter
    public let address: Address

    public init(filter: Filter, address: Address) {
        self.filter = filter
        self.address = address
    }
}

public struct WPEParitySceneFrame: Hashable, Sendable {
    public let operations: [WPERenderOperation]
    /// Sorted by id.
    public let resources: [WPELogicalResource]
    /// Keyed by the `pass` of the draw operation they describe.
    public let draws: [WPEPassIdentity: WPEParitySceneDraw]
    /// Sampler a draw binds when it reads one of the layer composites.
    public let samplers: [WPEResourceID: WPEParitySceneSampler]
    public let diagnostics: [WPEParitySceneDiagnostic]
    /// The object each pass renders; scene-wide passes are absent.
    public let owners: [WPEPassIdentity: String]
}

public enum WPEParitySceneResource {
    public static let backbuffer: WPEResourceID = "backbuffer"
    public static let backbufferDepth: WPEResourceID = "backbufferDepth"
    public static let fullFrameBuffer: WPEResourceID = "_rt_FullFrameBuffer"
    public static let multisampled: WPEResourceID = "_rt_FullFrameBufferMultiSampled"
    public static let multisampledDepth: WPEResourceID = "_rt_FullFrameBufferMultiSampledDepth"
    public static let colorFormat = "rgba8unorm"
    public static let depthFormat = "depth32float"

    /// 1401ea500.c:137-446: `sc.<w>.<h>.<n|b><c|r><index>`, then the number of `ancestors` (the composites the
    /// enclosing layers draw their children into) whose name starts with that, when above 0.
    public static func pooledComposite(width: Int, height: Int, sampler: WPEParitySceneSampler, index: Int,
                                       ancestors: [WPEResourceID] = []) -> WPEResourceID {
        let filter = sampler.filter == .point ? "n" : "b"
        let address = sampler.address == .clamp ? "c" : "r"
        let name = "sc.\(width).\(height).\(filter)\(address)\(index)"
        let count = ancestors.count { $0.rawValue.hasPrefix(name) }
        return WPEResourceID(count > 0 ? "\(name)\(count)" : name)
    }

    public static func layerCompositeA(_ objectID: String) -> WPEResourceID {
        WPEResourceID("_rt_imageLayerComposite_\(objectID)_a")
    }

    public static func layerImage(_ objectID: String) -> WPEResourceID {
        WPEResourceID("\(objectID)/image")
    }

    public static func effectFBO(objectID: String, effectID: String, name: String) -> WPEResourceID {
        WPEResourceID("\(objectID)/\(effectID)/\(name)")
    }

    /// An effect FBO that more than one layer touches keeps its pool name.
    public static func sharedFBO(_ name: String) -> WPEResourceID {
        WPEResourceID(name)
    }
}
