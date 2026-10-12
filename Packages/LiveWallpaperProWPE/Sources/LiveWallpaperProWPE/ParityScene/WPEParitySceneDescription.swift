/// Material `blending` of a draw; `.normal` is WPE's ONE/ZERO (blending off).
public enum WPEParitySceneBlend: String, Hashable, Sendable {
    case normal
    case translucent
    case additive

    public init(material raw: String?) {
        switch raw?.lowercased() {
        case "translucent": self = .translucent
        case "additive": self = .additive
        default: self = .normal
        }
    }
}

public enum WPEParitySceneWriteMask: Hashable, Sendable {
    case rgba
    case rgb
}

/// What binding a material pass sets besides blending (140155fc0.c:713-738); an absent key keeps WPE's baseline.
public struct WPEParitySceneMaterialState: Hashable, Sendable {
    public enum AlphaWriting: Hashable, Sendable {
        /// `"default"`: the draw keeps the mask of the target it lands in.
        case inherit
        case enabled
        case disabled
    }

    public var depthTest: Bool
    public var depthWrite: Bool
    /// False for `cullmode` `nocull`.
    public var cullsBackFaces: Bool
    public var alphaWriting: AlphaWriting

    public init(depthTest: Bool = true, depthWrite: Bool = true, cullsBackFaces: Bool = true,
                alphaWriting: AlphaWriting = .inherit) {
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.cullsBackFaces = cullsBackFaces
        self.alphaWriting = alphaWriting
    }
}

public enum WPEParitySceneDiagnostic: Hashable, Sendable {
    /// A block-compressed effect FBO format, which cannot be a render target; the FBO is allocated as `rgba8unorm`.
    case compressedFBOFormat(fbo: String, format: String)
}

/// The material JSON pass a draw comes from, and for an effect pass the effect file pass that names it.
public struct WPEParitySceneMaterialSource: Hashable, Sendable {
    public var materialPath: String
    /// Index into the material's `passes`.
    public var materialPass: Int
    public var effectFile: String?
    /// Index into the effect file's `passes`, commands included.
    public var effectPass: Int?
    /// Combos the engine adds to the pass JSON for this draw.
    public var combos: [String: Int]

    public init(materialPath: String, materialPass: Int = 0, effectFile: String? = nil, effectPass: Int? = nil,
                combos: [String: Int] = [:]) {
        self.materialPath = materialPath
        self.materialPass = materialPass
        self.effectFile = effectFile
        self.effectPass = effectPass
        self.combos = combos
    }

    public static let composeLayer = WPEParitySceneMaterialSource(materialPath: "materials/util/composelayer.json")

    /// genericimage4 with the combos FUN_140206ae0 adds; FOG_COMPUTED (and FOG, which the pass JSON never sets) goes
    /// when the layer material's own program (`layerFog`) has no FOG ≠ 0. Material flag 0x18 (LIGHTING/REFLECTION=0)
    /// and puppet combos are not modelled: the document carries neither.
    public static func layerPassthrough(colorBlendMode: Int, layerFog: Bool) -> WPEParitySceneMaterialSource {
        var combos = ["BLENDMODE": colorBlendMode == 31 ? 0 : colorBlendMode]
        if layerFog {
            combos["FOG_COMPUTED"] = 1
        }
        return WPEParitySceneMaterialSource(materialPath: "materials/util/effectpassthrough_4.json", combos: combos)
    }
}

/// What one frame of the WPE scene loop needs to know; everything else (uniforms, meshes) stays with the caller.
public struct WPEParitySceneDescription: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// Backbuffer, `_rt_FullFrameBuffer` and the multisampled scene target; HDR scenes use `rgba16float`.
    public var backbufferFormat: String
    public var clearColor: SIMD3<Double>
    public var clearEnabled: Bool
    /// 1 renders straight into the backbuffer; more routes through `_rt_FullFrameBufferMultiSampled`.
    public var msaaSamples: Int
    /// Carried but not applied: the report does not name the transparent-sorting comparator (U5).
    public var transparentSorting: Bool
    /// Global fog flags 0x1800000 (`general.fogdistance` / `fogheight`) send every layer through its own `_a` composite.
    public var forcesLayerComposite: Bool
    public var objects: [WPEParitySceneObject]
    public var diagnostics: [WPEParitySceneDiagnostic]

    public init(width: Int, height: Int, backbufferFormat: String = WPEParitySceneResource.colorFormat,
                clearColor: SIMD3<Double> = .zero, clearEnabled: Bool = true,
                msaaSamples: Int = 1, transparentSorting: Bool = false, forcesLayerComposite: Bool = false,
                objects: [WPEParitySceneObject], diagnostics: [WPEParitySceneDiagnostic] = []) {
        self.width = width
        self.height = height
        self.backbufferFormat = backbufferFormat
        self.clearColor = clearColor
        self.clearEnabled = clearEnabled
        self.msaaSamples = msaaSamples
        self.transparentSorting = transparentSorting
        self.forcesLayerComposite = forcesLayerComposite
        self.objects = objects
        self.diagnostics = diagnostics
    }
}

public struct WPEParitySceneObject: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case image
        /// A `.mdl` model; its material comes from the model file and it takes no effects.
        case model
    }

    public var id: String
    public var kind: Kind
    /// obj+0x124; ties keep input order.
    public var sortKey: Int
    public var visible: Bool
    public var width: Int
    public var height: Int
    public var materialShader: String
    /// Material pass of the albedo (or model) draw.
    public var material: WPEParitySceneMaterialSource?
    /// Layer material blend used where the layer lands in the scene or its parent composite.
    public var blend: WPEParitySceneBlend
    /// Depth, cull and alpha-write state of the albedo (or model) material pass.
    public var materialState: WPEParitySceneMaterialState
    /// The albedo material's combos, shader defaults included, set FOG ≠ 0.
    public var materialFog: Bool
    public var colorBlendMode: Int
    public var passthrough: Bool
    public var copyBackground: Bool
    public var fullscreen: Bool
    public var ledSource: Bool
    public var puppetForcesComposite: Bool
    /// Layer `nointerpolation` or albedo TEXI flag bit0: the layer's composites sample with point filtering.
    public var noInterpolation: Bool
    /// Layer `clampuvs` (WPE default on): the layer's composites clamp instead of wrap.
    public var clampUVs: Bool
    public var parentID: String?
    public var effects: [WPEParitySceneEffect]

    public init(id: String, kind: Kind = .image, sortKey: Int = 0, visible: Bool = true, width: Int, height: Int,
                materialShader: String = "genericimage2", material: WPEParitySceneMaterialSource? = nil,
                blend: WPEParitySceneBlend = .translucent,
                materialState: WPEParitySceneMaterialState = WPEParitySceneMaterialState(), materialFog: Bool = false,
                colorBlendMode: Int = 0, passthrough: Bool = false, copyBackground: Bool = true,
                fullscreen: Bool = false, ledSource: Bool = false, puppetForcesComposite: Bool = false,
                noInterpolation: Bool = false, clampUVs: Bool = true, parentID: String? = nil,
                effects: [WPEParitySceneEffect] = []) {
        self.id = id
        self.kind = kind
        self.sortKey = sortKey
        self.visible = visible
        self.width = width
        self.height = height
        self.materialShader = materialShader
        self.material = material
        self.blend = blend
        self.materialState = materialState
        self.materialFog = materialFog
        self.colorBlendMode = colorBlendMode
        self.passthrough = passthrough
        self.copyBackground = copyBackground
        self.fullscreen = fullscreen
        self.ledSource = ledSource
        self.puppetForcesComposite = puppetForcesComposite
        self.noInterpolation = noInterpolation
        self.clampUVs = clampUVs
        self.parentID = parentID
        self.effects = effects
    }

    /// Layer bit4 (1401e6f50.c:24-29), without the global 0x1800000 flag.
    public var requiresLayerComposite: Bool {
        ![0, 31].contains(colorBlendMode) || ledSource || puppetForcesComposite
    }
}

public struct WPEParitySceneEffect: Hashable, Sendable {
    public var id: String
    public var enabled: Bool
    public var passes: [WPEParityScenePass]
    public var fbos: [WPEParitySceneFBO]

    public init(id: String, enabled: Bool = true, passes: [WPEParityScenePass], fbos: [WPEParitySceneFBO] = []) {
        self.id = id
        self.enabled = enabled
        self.passes = passes
        self.fbos = fbos
    }
}

public struct WPEParityScenePass: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case draw
        /// Effect `copy` command into `target`; a `nil` source (or target) is the composite the next pass samples.
        case copy(source: String?)
    }

    public var shader: String
    /// Name of an FBO declared by the effect; `nil` writes the ping-pong composite (or the layer's destination).
    public var target: String?
    /// Effect FBO names sampled besides the previous composite, which every pass samples.
    public var binds: [String]
    public var compose: Bool
    public var readsFullFrameBuffer: Bool
    public var blend: WPEParitySceneBlend
    public var kind: Kind
    /// Nil for a command.
    public var source: WPEParitySceneMaterialSource?

    public init(shader: String, target: String? = nil, binds: [String] = [], compose: Bool = false,
                readsFullFrameBuffer: Bool = false, blend: WPEParitySceneBlend = .normal, kind: Kind = .draw,
                source: WPEParitySceneMaterialSource? = nil) {
        self.shader = shader
        self.target = target
        self.binds = binds
        self.compose = compose
        self.readsFullFrameBuffer = readsFullFrameBuffer
        self.blend = blend
        self.kind = kind
        self.source = source
    }
}

public struct WPEParitySceneFBO: Hashable, Sendable {
    public var name: String
    public var width: Int
    public var height: Int
    public var format: String
    /// Another layer reads or declares it: every effect resolves the name to one scene-wide resource.
    public var shared: Bool
    /// The FBO whose binding this one exchanges with after the effect, once per frame; both entries name each other.
    public var swapPartner: String?

    public init(name: String, width: Int, height: Int, format: String = "rgba8unorm", shared: Bool = false,
                swapPartner: String? = nil) {
        self.name = name
        self.width = width
        self.height = height
        self.format = format
        self.shared = shared
        self.swapPartner = swapPartner
    }
}
