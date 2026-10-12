/// One material pass as WPE loads it: the pass JSON after scene overrides are merged in (FUN_1401e7170).
public struct WPEParityProgramMaterial: Sendable, Equatable {
    /// Shader name without `shaders/` and extension, e.g. `effects/waterripple`.
    public var shader: String
    /// File the pass came from; nil for an engine draw whose shader has no `materials/util` file.
    public var path: String?
    public var blending: WPEParityBlendMode
    /// Raw keys and values of the merged `combos` object (segment J).
    public var combos: [String: Int32]
    /// Texture slot → texture, FBO or `previous` name; only bound slots are present.
    public var textures: [Int32: String]

    public init(shader: String, path: String? = nil, blending: WPEParityBlendMode = .normal,
                combos: [String: Int32] = [:], textures: [Int32: String] = [:]) {
        self.shader = shader
        self.path = path
        self.blending = blending
        self.combos = combos
        self.textures = textures
    }
}

/// Everything `WPEComboResolver` and `WPEHLSLRewriter` need for one draw.
public struct WPEParityProgramDescription: Sendable, Equatable {
    public var material: WPEParityProgramMaterial
    public var engineFlags: WPEEngineComboFlags
    /// TEXnFORMAT and component flags of each bound slot; WPE writes texture combos only for bound slots.
    public var boundTextures: [Int32: WPEBoundComboTexture]

    public init(material: WPEParityProgramMaterial, engineFlags: WPEEngineComboFlags,
                boundTextures: [Int32: WPEBoundComboTexture]) {
        self.material = material
        self.engineFlags = engineFlags
        self.boundTextures = boundTextures
    }

    public var passJSONCombos: [WPEPassJSONCombo] {
        material.combos.map { WPEPassJSONCombo(key: $0.key, value: $0.value) }
    }
}

/// One frame draw and the program it needs.
public struct WPEParityProgramDraw: Sendable, Equatable {
    /// Index of the draw operation in `WPEParityFrame.operations`.
    public let operationIndex: Int
    public let pass: WPEPassIdentity
    /// Nil when the draw's material file is missing.
    public let description: WPEParityProgramDescription?
}
