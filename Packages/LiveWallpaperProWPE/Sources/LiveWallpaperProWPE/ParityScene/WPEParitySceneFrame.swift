public struct WPEParitySceneDraw: Hashable, Sendable {
    /// Engine colour is assigned by the pass's purpose, independently of shader/material identity. In particular,
    /// the bit4 publish and its clipped targets use white after the composite already consumed the layer colour.
    public enum ColorRole: Hashable, Sendable {
        case none
        case albedo
        case compositeFill
        case compositePublish
        case mask

        public var usesLayerColor: Bool {
            self == .albedo || self == .compositeFill
        }
    }

    public enum Geometry: Hashable, Sendable {
        case fullscreenQuad
        /// The layer's own mesh transformed by the layer MVP.
        case layerMesh
        /// The layer's `WPEParitySceneObject.puppet` mesh transformed by the layer MVP.
        case puppetMesh
        /// One `WPEParityScenePuppet.clipSegments` entry of the layer's puppet, transformed by the layer MVP.
        case puppetSegment(Int)
        /// The meshes of the object's `.mdl` file.
        case modelMesh
        /// The vertices a particle renderer entry writes this frame.
        case particles(WPEParityParticleDrawKey)
        /// A text layer's quad from (0, 0) to its FBO size (+0x2d8), moved by `WPEParityTextMatrices`.
        case textBackground
        /// One glyph list of the text layer's mesh. Drawn with `fillsComposite` it lands in the text FBO.
        case textGlyphs(WPEParityGlyphAtlasInstance.Atlas)
        /// A shape quad's `WPEParitySceneShape` mesh transformed by the layer MVP.
        case shapeQuad
    }

    public let pass: WPEPassIdentity
    public let objectID: String
    public let effectID: String?
    public let passIndex: Int?
    public let shader: String
    /// Nil when the scene description did not say which material the draw uses.
    public let source: WPEParitySceneMaterialSource?
    public let colorRole: ColorRole
    /// The mask draw's flags2 value, also written to native RenderVar+0xa8 (14020d6a0:19–42).
    public let clipMaskInverted: Bool
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
    /// Original logical composite extent. Geometry/camera keep this size when the attachment is scaled on Mac.
    public let logicalCompositeSize: SIMD2<Int>?
    /// Effective state after the native layer override and blend-dependent write restriction.
    public let depthTest: Bool
    public let depthWrite: Bool
    public let cullsBackFaces: Bool
    /// A `fullscreenQuad` pass of the last effect after its last flip: WPE draws the 2×2 quad with the layer's
    /// matrices instead of the effect ortho (1401e8aa0.c:951-997, 1052-1075).
    public let layerMatrices: Bool
    /// A last-segment pass or bit4 publish of a fullscreen layer: the 2×2 quad with M = V = I and P = ortho(±1)
    /// (1401e8aa0.c:1004-1050).
    public let fullscreenLayer: Bool
    /// RD flag 0x100 (SrcBlend DEST_COLOR), set around the clip mask merge (14020d6a0.c:150-169).
    public let multipliesDestination: Bool

    public init(pass: WPEPassIdentity, objectID: String, effectID: String? = nil, passIndex: Int? = nil,
                shader: String, source: WPEParitySceneMaterialSource? = nil, reads: [WPEResourceID],
                target: WPEResourceID, blend: WPEParitySceneBlend, alphaMax: Bool = false,
                compositeOwnerID: String? = nil, writeMask: WPEParitySceneWriteMask, geometry: Geometry,
                fillsComposite: Bool = false, depthTest: Bool = false, depthWrite: Bool = false,
                cullsBackFaces: Bool = false, layerMatrices: Bool = false, fullscreenLayer: Bool = false,
                multipliesDestination: Bool = false,
                colorRole: ColorRole = .none, clipMaskInverted: Bool = false,
                logicalCompositeSize: SIMD2<Int>? = nil) {
        self.pass = pass
        self.objectID = objectID
        self.effectID = effectID
        self.passIndex = passIndex
        self.shader = shader
        self.source = source
        self.colorRole = colorRole
        self.clipMaskInverted = clipMaskInverted
        self.reads = reads
        self.target = target
        self.blend = blend
        self.alphaMax = alphaMax
        self.compositeOwnerID = compositeOwnerID
        self.writeMask = writeMask
        self.geometry = geometry
        self.fillsComposite = fillsComposite
        self.logicalCompositeSize = logicalCompositeSize
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.cullsBackFaces = cullsBackFaces
        self.layerMatrices = layerMatrices
        self.fullscreenLayer = fullscreenLayer
        self.multipliesDestination = multipliesDestination
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

/// One particle object's authored position and targets. The runtime projects its live instance stream here.
public struct WPEParityParticleBlock: Hashable, Sendable {
    public let objectID: String
    /// The draw context whose model inverse is the native world-space stack C; nil at scene level.
    public let compositeOwnerID: String?
    public let operations: Range<Int>
    public let color: WPEResourceID
    public let depth: WPEResourceID?
    /// Current render-target stack top: a parent's composite while drawing its children.
    public let snapshotSource: WPEResourceID
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
    /// The object each pass renders. Scene-wide passes are absent, and so are the passes filling a
    /// `dependencyTarget` layer's composites, which run while the layer is hidden.
    public let owners: [WPEPassIdentity: String]
    public let particleBlocks: [WPEParityParticleBlock]
}

public enum WPEParitySceneResource {
    public static let backbuffer: WPEResourceID = "backbuffer"
    public static let backbufferDepth: WPEResourceID = "backbufferDepth"
    public static let fullFrameBuffer: WPEResourceID = "_rt_FullFrameBuffer"
    public static let multisampled: WPEResourceID = "_rt_FullFrameBufferMultiSampled"
    public static let multisampledDepth: WPEResourceID = "_rt_FullFrameBufferMultiSampledDepth"
    public static let colorFormat = "rgba8unorm"
    public static let depthFormat = "depth32float"
    /// Puppet clip masks, R8 at the scene size (140208670.c:90-138).
    public static let fullAlphaMask: WPEResourceID = "_rt_FullAlphaMask"
    public static let fullAlphaMaskIntermediate: WPEResourceID = "_rt_FullAlphaMaskIntermediate"
    /// Depth-only R32 shadow atlas (140190c80.c:1533-1541).
    public static let shadowAtlas: WPEResourceID = "_rt_shadowAtlas"

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

    /// A name no effect of the layer declares.
    public static func effectFBO(objectID: String, effectID: String, name: String) -> WPEResourceID {
        WPEResourceID("\(objectID)/\(effectID)/\(name)")
    }

    /// 1401ea500.c:576-831: `<name>_<effect id>` for a unique FBO; otherwise `<name>_<w>_<h>_<scale>`, or the bare
    /// name on a fullscreen layer (0x304 bit1), so equal declarations on different layers share one pool texture.
    public static func effectFBO(_ fbo: WPEParitySceneFBO, effectID: String, fullscreen: Bool) -> WPEResourceID {
        if fbo.unique {
            return WPEResourceID("\(fbo.name)_\(effectID)")
        }
        let size = fbo.unscaledSize
        return WPEResourceID(fullscreen ? fbo.name : "\(fbo.name)_\(size.x)_\(size.y)_\(fbo.scale)")
    }

    /// An effect FBO that more than one layer touches keeps its pool name.
    public static func sharedFBO(_ name: String) -> WPEResourceID {
        WPEResourceID(name)
    }
}
