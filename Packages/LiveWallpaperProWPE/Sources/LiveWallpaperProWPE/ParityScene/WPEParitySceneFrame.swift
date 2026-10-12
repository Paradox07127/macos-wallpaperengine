public struct WPEParitySceneDraw: Hashable, Sendable {
    public enum Geometry: Hashable, Sendable {
        case fullscreenQuad
        /// The layer's own mesh transformed by the layer MVP.
        case layerMesh
    }

    public let pass: WPEPassIdentity
    public let objectID: String
    public let effectID: String?
    public let passIndex: Int?
    public let shader: String
    public let reads: [WPEResourceID]
    public let target: WPEResourceID
    public let blend: WPEParitySceneBlend
    /// Alpha blend op MAX (RD+0xe8) while drawing into a parent composite that did not copy the background.
    public let alphaMax: Bool
    public let writeMask: WPEParitySceneWriteMask
    public let geometry: Geometry

    public init(pass: WPEPassIdentity, objectID: String, effectID: String? = nil, passIndex: Int? = nil,
                shader: String, reads: [WPEResourceID], target: WPEResourceID, blend: WPEParitySceneBlend,
                alphaMax: Bool = false, writeMask: WPEParitySceneWriteMask, geometry: Geometry) {
        self.pass = pass
        self.objectID = objectID
        self.effectID = effectID
        self.passIndex = passIndex
        self.shader = shader
        self.reads = reads
        self.target = target
        self.blend = blend
        self.alphaMax = alphaMax
        self.writeMask = writeMask
        self.geometry = geometry
    }
}

public struct WPEParitySceneFrame: Hashable, Sendable {
    public let operations: [WPERenderOperation]
    /// Sorted by id.
    public let resources: [WPELogicalResource]
    /// Keyed by the `pass` of the draw operation they describe.
    public let draws: [WPEPassIdentity: WPEParitySceneDraw]
}

public enum WPEParitySceneResource {
    public static let backbuffer: WPEResourceID = "backbuffer"
    public static let backbufferDepth: WPEResourceID = "backbufferDepth"
    public static let fullFrameBuffer: WPEResourceID = "_rt_FullFrameBuffer"
    public static let multisampled: WPEResourceID = "_rt_FullFrameBufferMultiSampled"
    public static let multisampledDepth: WPEResourceID = "_rt_FullFrameBufferMultiSampledDepth"
    public static let colorFormat = "rgba8unorm"
    public static let depthFormat = "depth32float"

    /// `<b|n><r|c>` meanings are unknown (U1); every pooled target uses `br`.
    public static func pooledComposite(width: Int, height: Int, index: Int) -> WPEResourceID {
        WPEResourceID("sc.\(width).\(height).br\(index)")
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
}
