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
    /// Positional declarations and their original loci; they do not replace authored texture fallbacks.
    public var userTextures: WPEParityProgramUserTextures
    /// Merged `constantshadervalues`: material key (the uniform annotation's `material`) → components.
    public var constants: [String: [Double]]
    /// `cullmode` other than `nocull`.
    public var cullsBackFaces: Bool

    public init(shader: String, path: String? = nil, blending: WPEParityBlendMode = .normal,
                combos: [String: Int32] = [:], textures: [Int32: String] = [:], constants: [String: [Double]] = [:],
                cullsBackFaces: Bool = true, userTextures: WPEParityProgramUserTextures = .init()) {
        self.shader = shader
        self.path = path
        self.blending = blending
        self.combos = combos
        self.textures = textures
        self.userTextures = userTextures
        self.constants = constants
        self.cullsBackFaces = cullsBackFaces
    }
}

/// The three authored `usertextures` fields before an unproven array-merge policy can discard a declaration.
/// The typed views are built once with the material, never by the per-frame texture consumer.
public struct WPEParityProgramUserTextures: Sendable, Equatable {
    public let material: WPESceneJSONValue?
    public let pass: WPESceneJSONValue?
    public let override: WPESceneJSONValue?
    public let bindings: WPERenderUserTextureBindings
    /// Single-locus or identical declarations only. Different arrays retain their loci and diagnose the unknown merge.
    public let slots: [Int32: WPESceneUserTextureBinding]
    /// Native reads a Boolean; missing or other shapes do not enable the flag. Its aspect transform is still unverified.
    public let keepAspect: [Int32: Bool]
    public let diagnostics: [String]

    public init(material: WPESceneJSONValue? = nil, pass: WPESceneJSONValue? = nil,
                override: WPESceneJSONValue? = nil,
                overrideBindings: [WPESceneUserTextureBinding]? = nil) {
        self.material = material
        self.pass = pass
        self.override = override
        let materialEntries = Self.entries(material)
        let passEntries = Self.entries(pass)
        let overrideEntries = Self.entries(override)
        bindings = WPERenderUserTextureBindings(material: materialEntries.map(\.binding),
                                                pass: passEntries.map(\.binding),
                                                override: override == nil ? overrideBindings ?? []
                                                    : overrideEntries.map(\.binding))
        let authored = [("material", material, materialEntries), ("pass", pass, passEntries),
                        ("override", override, overrideEntries)].filter { $0.1 != nil }
        var diagnostics: [String] = []
        var slots: [Int32: WPESceneUserTextureBinding] = [:]
        var keepAspect: [Int32: Bool] = [:]
        if override == nil, let overrideBindings, !overrideBindings.isEmpty {
            diagnostics.append("usertextures override has typed bindings without raw array/keepaspect provenance")
        } else if let first = authored.first, authored.allSatisfy({ $0.1 == first.1 }) {
            for entry in first.2 {
                guard let slot = entry.binding.slot, let key = Int32(exactly: slot) else { continue }
                slots[key] = entry.binding
                keepAspect[key] = entry.keepAspect
                if entry.keepAspect {
                    diagnostics.append("usertextures keepaspect transform is unverified at slot \(slot)")
                }
            }
        } else if !authored.isEmpty {
            diagnostics.append("usertextures array merge is unverified across \(authored.map(\.0).joined(separator: "/")); authored fallback retained")
        }
        for (locus, raw, _) in authored {
            if case .array? = raw {
                continue
            }
            if case .null? = raw {
                continue
            }
            diagnostics.append("usertextures \(locus) has an unsupported non-array declaration")
        }
        self.slots = slots
        self.keepAspect = keepAspect
        self.diagnostics = diagnostics
    }

    private struct Entry {
        let binding: WPESceneUserTextureBinding
        let keepAspect: Bool
    }

    /// 140154480:148–156,270: the original array ordinal is the texture slot; null never shifts later entries.
    private static func entries(_ raw: WPESceneJSONValue?) -> [Entry] {
        guard case let .array(values)? = raw else { return [] }
        return values.enumerated().compactMap { slot, value in
            if case let .string(name) = value, !name.isEmpty {
                return Entry(binding: .init(name: name, slot: slot), keepAspect: false)
            }
            guard case let .string(name)? = value["name"], !name.isEmpty else { return nil }
            let type: String? = if case let .string(type)? = value["type"], !type.isEmpty {
                type
            } else {
                nil
            }
            return Entry(binding: .init(name: name, type: type, slot: slot), keepAspect: value["keepaspect"] == .bool(true))
        }
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
