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
    /// A particle child left out of the draw list: its path repeats an ancestor, it nests deeper than 8 levels, or it
    /// descends from an event child, which `WPEParityParticleDrawKey` cannot address.
    case particleChildOmitted(objectID: String, path: String)
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
    /// Shader the engine draws with instead of the pass JSON's, such as a rope-only particle system's.
    public var shader: String?

    public init(materialPath: String, materialPass: Int = 0, effectFile: String? = nil, effectPass: Int? = nil,
                combos: [String: Int] = [:], shader: String? = nil) {
        self.materialPath = materialPath
        self.materialPass = materialPass
        self.effectFile = effectFile
        self.effectPass = effectPass
        self.combos = combos
        self.shader = shader
    }

    public static let composeLayer = WPEParitySceneMaterialSource(materialPath: "materials/util/composelayer.json")

    /// genericimage4 with the combos FUN_140206ae0 adds; FOG_COMPUTED (and FOG, which the pass JSON never sets) goes
    /// when the layer material's own program (`layerFog`) has no FOG ≠ 0. Material flag 0x18 (LIGHTING/REFLECTION=0)
    /// is not modelled: the document does not carry it.
    public static func layerPassthrough(colorBlendMode: Int, layerFog: Bool,
                                        puppet: WPEParityScenePuppet? = nil) -> WPEParitySceneMaterialSource {
        var combos = ["BLENDMODE": colorBlendMode == 31 ? 0 : colorBlendMode]
        if layerFog {
            combos["FOG_COMPUTED"] = 1
        }
        combos.merge(puppet?.skinningCombos ?? [:]) { _, new in new }
        return WPEParitySceneMaterialSource(materialPath: "materials/util/effectpassthrough_4.json", combos: combos)
    }
}

/// Mesh0 of an image layer's model JSON `"puppet"` (FUN_1401fbae0): positions go straight into the layer MVP.
public struct WPEParityScenePuppet: Hashable, Sendable {
    public var vertices: [WPEPuppetVertex]
    public var indices: [UInt16]
    /// MDLS bone count; BONECOUNT and the length of `g_Bones`.
    public var boneCount: Int
    /// FUN_1402076e0: mesh0's format has bone indices (0x800000) and the model has bones.
    public var skinned: Bool
    /// puppet+0x390, the first mesh with flag & 2; `WPEMdlParser` does not expose mesh flags, so always nil.
    public var blendMeshIndex: Int?

    public init(vertices: [WPEPuppetVertex], indices: [UInt16], boneCount: Int, skinned: Bool,
                blendMeshIndex: Int? = nil) {
        self.vertices = vertices
        self.indices = indices
        self.boneCount = boneCount
        self.skinned = skinned
        self.blendMeshIndex = blendMeshIndex
    }

    /// FUN_140207710.
    public var skinningCombos: [String: Int] {
        skinned ? ["SKINNING": 1, "BONECOUNT": boneCount] : [:]
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
        /// A particle system; it draws only its renderer entries and takes no composite or effects.
        case particle(WPEParitySceneParticle)
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
    /// FUN_14020ae00 set bit4 for the layer's puppet.
    public var puppetForcesComposite: Bool
    public var puppet: WPEParityScenePuppet?
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
                puppet: WPEParityScenePuppet? = nil, noInterpolation: Bool = false, clampUVs: Bool = true,
                parentID: String? = nil, effects: [WPEParitySceneEffect] = []) {
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
        self.puppet = puppet
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

/// One particle renderer-entry draw: `node` indexes the static children (`WPEParityParticleSystem.children`) from the
/// root system; with `eventGroup` the draw covers every instance of that node's `eventChildren[eventGroup]`.
public struct WPEParityParticleDrawKey: Hashable, Sendable {
    public var objectID: String
    public var node: [Int]
    /// Index into the drawn system's `renderers`.
    public var renderer: Int
    public var eventGroup: Int?

    public init(objectID: String, node: [Int] = [], renderer: Int, eventGroup: Int? = nil) {
        self.objectID = objectID
        self.node = node
        self.renderer = renderer
        self.eventGroup = eventGroup
    }
}

/// A particle object's draws in WPE order (R16 Q4): a system's entries in JSON order, then its static children depth
/// first, then one group per event child.
public struct WPEParitySceneParticle: Hashable, Sendable {
    public var draws: [WPEParitySceneParticleDraw]

    public init(draws: [WPEParitySceneParticleDraw]) {
        self.draws = draws
    }
}

public struct WPEParitySceneParticleDraw: Hashable, Sendable {
    public var key: WPEParityParticleDrawKey
    public var shader: String
    /// Pass 0 of the system's `material`, with the entry's combos and the rope-only shader override.
    public var source: WPEParitySceneMaterialSource
    public var blend: WPEParitySceneBlend
    public var materialState: WPEParitySceneMaterialState
    /// REFRACT: the pass samples `_rt_FullFrameBuffer`.
    public var readsFullFrameBuffer: Bool
    /// Particle JSON `flags` bit0 and bit2.
    public var worldSpace: Bool
    public var perspective: Bool

    public init(key: WPEParityParticleDrawKey, shader: String, source: WPEParitySceneMaterialSource,
                blend: WPEParitySceneBlend, materialState: WPEParitySceneMaterialState,
                readsFullFrameBuffer: Bool = false, worldSpace: Bool = false, perspective: Bool = false) {
        self.key = key
        self.shader = shader
        self.source = source
        self.blend = blend
        self.materialState = materialState
        self.readsFullFrameBuffer = readsFullFrameBuffer
        self.worldSpace = worldSpace
        self.perspective = perspective
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
