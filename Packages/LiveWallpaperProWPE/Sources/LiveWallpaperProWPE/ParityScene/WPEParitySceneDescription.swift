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

/// What one frame of the WPE scene loop needs to know; everything else (uniforms, meshes) stays with the caller.
public struct WPEParitySceneDescription: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var clearColor: SIMD3<Double>
    public var clearEnabled: Bool
    /// 1 renders straight into the backbuffer; more routes through `_rt_FullFrameBufferMultiSampled`.
    public var msaaSamples: Int
    /// Carried but not applied: the report does not name the transparent-sorting comparator (U5).
    public var transparentSorting: Bool
    /// Global flag 0x1800000 that sends every layer through its own `_a` composite.
    public var forcesLayerComposite: Bool
    public var objects: [WPEParitySceneObject]

    public init(width: Int, height: Int, clearColor: SIMD3<Double> = .zero, clearEnabled: Bool = true,
                msaaSamples: Int = 1, transparentSorting: Bool = false, forcesLayerComposite: Bool = false,
                objects: [WPEParitySceneObject]) {
        self.width = width
        self.height = height
        self.clearColor = clearColor
        self.clearEnabled = clearEnabled
        self.msaaSamples = msaaSamples
        self.transparentSorting = transparentSorting
        self.forcesLayerComposite = forcesLayerComposite
        self.objects = objects
    }
}

public struct WPEParitySceneObject: Hashable, Sendable {
    public var id: String
    /// obj+0x124; ties keep input order.
    public var sortKey: Int
    public var visible: Bool
    public var width: Int
    public var height: Int
    public var materialShader: String
    /// Layer material blend used where the layer lands in the scene or its parent composite.
    public var blend: WPEParitySceneBlend
    public var colorBlendMode: Int
    public var passthrough: Bool
    public var copyBackground: Bool
    public var fullscreen: Bool
    public var ledSource: Bool
    public var puppetForcesComposite: Bool
    public var parentID: String?
    public var effects: [WPEParitySceneEffect]

    public init(id: String, sortKey: Int = 0, visible: Bool = true, width: Int, height: Int,
                materialShader: String = "genericimage2", blend: WPEParitySceneBlend = .translucent,
                colorBlendMode: Int = 0, passthrough: Bool = false, copyBackground: Bool = true,
                fullscreen: Bool = false, ledSource: Bool = false, puppetForcesComposite: Bool = false,
                parentID: String? = nil, effects: [WPEParitySceneEffect] = []) {
        self.id = id
        self.sortKey = sortKey
        self.visible = visible
        self.width = width
        self.height = height
        self.materialShader = materialShader
        self.blend = blend
        self.colorBlendMode = colorBlendMode
        self.passthrough = passthrough
        self.copyBackground = copyBackground
        self.fullscreen = fullscreen
        self.ledSource = ledSource
        self.puppetForcesComposite = puppetForcesComposite
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
    public var shader: String
    /// Name of an FBO declared by the effect; `nil` writes the ping-pong composite (or the layer's destination).
    public var target: String?
    /// Effect FBO names sampled besides the previous composite, which every pass samples.
    public var binds: [String]
    public var compose: Bool
    public var readsFullFrameBuffer: Bool
    public var blend: WPEParitySceneBlend

    public init(shader: String, target: String? = nil, binds: [String] = [], compose: Bool = false,
                readsFullFrameBuffer: Bool = false, blend: WPEParitySceneBlend = .normal) {
        self.shader = shader
        self.target = target
        self.binds = binds
        self.compose = compose
        self.readsFullFrameBuffer = readsFullFrameBuffer
        self.blend = blend
    }
}

public struct WPEParitySceneFBO: Hashable, Sendable {
    public var name: String
    public var width: Int
    public var height: Int
    public var format: String

    public init(name: String, width: Int, height: Int, format: String = "rgba8unorm") {
        self.name = name
        self.width = width
        self.height = height
        self.format = format
    }
}
