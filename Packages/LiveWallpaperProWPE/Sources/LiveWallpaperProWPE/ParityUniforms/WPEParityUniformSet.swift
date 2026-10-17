import simd

/// Per-frame engine state shared by every draw.
public struct WPEParityUniformFrame: Sendable {
    public var clock: WPEParityClock {
        didSet { refreshSharedValues() }
    }

    public var daytime: Float {
        didSet { refreshSharedValues() }
    }

    public var screen: WPEParityUniformScreen {
        didSet { refreshSharedValues() }
    }

    public var pointer: WPEParityUniformPointer {
        didSet { refreshSharedValues() }
    }

    public var parallax: WPEParityUniformParallax {
        didSet { refreshSharedValues() }
    }

    public var eyePosition: SIMD3<Float> {
        didSet { refreshSharedValues() }
    }

    public var view: simd_float4x4 {
        didSet { refreshSharedValues() }
    }

    public var audio: WPEParityAudioSpectrum {
        didSet { refreshSharedValues() }
    }

    /// Live scene terms after script writes; nil leaves them to whatever the binding supplies.
    public var lights: WPEParityUniformLights? {
        didSet { lightValues = lights?.values ?? [:] }
    }

    /// The draw-independent g_* values (time, screen, pointer, parallax, eye, view vectors, audio spectrum).
    public private(set) var sharedValues: [String: WPECBufferValue] = [:]
    /// `lights.values`, built once per change for every draw of the frame.
    public private(set) var lightValues: [String: WPECBufferValue]

    public init(clock: WPEParityClock, daytime: Float, screen: WPEParityUniformScreen,
                pointer: WPEParityUniformPointer, parallax: WPEParityUniformParallax, eyePosition: SIMD3<Float>,
                view: simd_float4x4, audio: WPEParityAudioSpectrum = WPEParityAudioSpectrum(),
                lights: WPEParityUniformLights? = nil) {
        self.clock = clock
        self.daytime = daytime
        self.screen = screen
        self.pointer = pointer
        self.parallax = parallax
        self.eyePosition = eyePosition
        self.view = view
        self.audio = audio
        self.lights = lights
        lightValues = lights?.values ?? [:]
        refreshSharedValues()
    }

    private mutating func refreshSharedValues() {
        func vector(_ value: SIMD2<Float>) -> WPECBufferValue {
            .vector([value.x, value.y])
        }
        func vector(_ value: SIMD3<Float>) -> WPECBufferValue {
            .vector([value.x, value.y, value.z])
        }
        let viewVectors = WPEParityUniformParallax.viewVectors(view: view)
        let state = pointer.state
        var values: [String: WPECBufferValue] = [
            "g_Time": .float(clock.timeUniform),
            "g_Frametime": .float(clock.frametime),
            "g_Daytime": .float(daytime),
            "g_Screen": vector(screen.screen),
            "g_TexelSize": vector(screen.texelSize),
            "g_TexelSizeHalf": vector(screen.texelSizeHalf),
            "g_PointerPosition": vector(pointer.position),
            "g_PointerPositionLast": vector(pointer.lastPosition),
            "g_PointerState": .vector([state.x, state.y, state.z, state.w]),
            "g_ParallaxPosition": vector(parallax.position),
            "g_EyePosition": vector(eyePosition),
            "g_ViewForward": vector(viewVectors.forward),
            "g_ViewRight": vector(viewVectors.right),
            "g_ViewUp": vector(viewVectors.up),
        ]
        values.merge(audio.uniforms()) { $1 }
        sharedValues = values
    }
}

public struct WPEParityUniformDraw: Sendable {
    public var matrices: WPEParityUniformMatrices
    public var effectPass: WPEParityUniformEffectPass?
    /// Indexed by slot; missing or nil entries are unbound.
    public var textures: [WPEParityUniformTexture?]

    public init(matrices: WPEParityUniformMatrices, effectPass: WPEParityUniformEffectPass? = nil,
                textures: [WPEParityUniformTexture?] = []) {
        self.matrices = matrices
        self.effectPass = effectPass
        self.textures = textures
    }
}

/// Engine-owned g_* values for one draw, keyed by HLSL name; callers write only names their layout declares.
public enum WPEParityUniformSet {
    public static func values(frame: WPEParityUniformFrame, draw: WPEParityUniformDraw) -> [String: WPECBufferValue] {
        var values = frame.sharedValues
        values.merge(draw.matrices.values) { $1 }
        if let effectPass = draw.effectPass {
            values.merge(effectPass.values) { $1 }
        }
        if let lights = frame.lights {
            values.merge(lights.values) { $1 }
        }
        for slot in 0 ..< WPEParityUniformTextures.slotCount {
            let texture = slot < draw.textures.count ? draw.textures[slot] : nil
            values.merge(WPEParityUniformTextures.values(slot: slot, texture: texture)) { $1 }
        }
        return values
    }

    /// Writes `variable`'s engine value into its zeroed cbuffer at `base`, the bytes packing `values(frame:draw:)`
    /// gives it; writes nothing for a name that set lacks.
    public static func write(_ uniform: WPEParityEngineUniform, to variable: WPEStageReflection.CBuffer.Variable,
                             frame: WPEParityUniformFrame, draw: WPEParityUniformDraw,
                             at base: UnsafeMutableRawPointer) throws {
        func matrix(_ value: simd_float4x4) throws {
            let rows = value.transpose
            try WPECBufferWriter.writeTransposed(size: 4, to: variable, at: base) { rows[$0][$1] }
        }
        func effect(_ value: (WPEParityUniformEffectPass) -> simd_float4x4) throws {
            if let pass = draw.effectPass {
                try matrix(value(pass))
            }
        }
        func lanes(_ value: SIMD4<Float>, _ count: Int, vector: Bool = true) throws {
            try WPECBufferWriter.write(value, count: count, vector: vector, to: variable, at: base)
        }
        func texture(_ slot: Int) -> WPEParityUniformTexture? {
            slot < draw.textures.count ? draw.textures[slot] : nil
        }
        let matrices = draw.matrices
        switch uniform {
        case .frame:
            if let value = frame.lightValues[variable.name] ?? frame.sharedValues[variable.name] {
                try WPECBufferWriter.write(value, to: variable, at: base)
            }
        case .model: try matrix(matrices.model)
        case .modelInverse: try matrix(matrices.model.inverse)
        case .viewProjection: try matrix(matrices.viewProjection)
        case .modelViewProjection: try matrix(matrices.modelViewProjection)
        case .modelViewProjectionInverse: try matrix(matrices.modelViewProjection.inverse)
        case .normalModel:
            let rows = matrices.normalModel.transpose
            try WPECBufferWriter.writeTransposed(size: 3, to: variable, at: base) { rows[$0][$1] }
        case .effectModel: try effect(\.effectModel)
        case .effectModelViewProjection: try effect(\.effectModelViewProjection)
        case .effectModelViewProjectionInverse: try effect { $0.effectModelViewProjection.inverse }
        case .effectTextureProjection: try effect(\.effectTextureProjection)
        case .effectTextureProjectionInverse: try effect { $0.effectTextureProjection.inverse }
        case .layerModel: try effect(\.layerModel)
        case let .textureResolution(slot):
            guard let texture = texture(slot) else { return try lanes(SIMD4(repeating: 2), 4) }
            try lanes(SIMD4(Float(texture.textureWidth), Float(texture.textureHeight), Float(texture.imageWidth),
                            Float(texture.imageHeight)), 4)
        case let .textureTexel(slot):
            guard let texture = texture(slot) else { return try lanes(SIMD4(0.5, 0.5, 2, 2), 4) }
            let width = Float(texture.textureWidth), height = Float(texture.textureHeight)
            try lanes(SIMD4(1 / width, 1 / height, width, height), 4)
        case let .textureMipMapInfo(slot):
            let info = texture(slot).map { max(0, Float($0.mipMapInfo)) } ?? 1
            try lanes(SIMD4(info, 0, 0, 0), 1, vector: false)
        case let .textureRotation(slot):
            if let frame = texture(slot)?.spriteFrame {
                try lanes(frame.rotation, 4)
            }
        case let .textureTranslation(slot):
            if let frame = texture(slot)?.spriteFrame {
                let translation = frame.translation
                try lanes(SIMD4(translation.x, translation.y, 0, 0), 2)
            }
        }
    }
}

/// An engine g_* name, resolved once per reflected variable so a draw evaluates only the names its stages declare.
public enum WPEParityEngineUniform: Sendable, Equatable {
    /// Looked up by name in the frame's light, then shared, values.
    case frame
    case model, modelInverse, viewProjection, modelViewProjection, modelViewProjectionInverse, normalModel
    case effectModel, effectModelViewProjection, effectModelViewProjectionInverse
    case effectTextureProjection, effectTextureProjectionInverse, layerModel
    case textureResolution(Int), textureTexel(Int), textureMipMapInfo(Int), textureRotation(Int), textureTranslation(Int)

    public init(name: String) {
        self = Self.byName[name] ?? .frame
    }

    private static let byName: [String: Self] = {
        var names: [String: Self] = [
            "g_ModelMatrix": .model, "g_ModelMatrixInverse": .modelInverse,
            "g_ViewProjectionMatrix": .viewProjection, "g_ModelViewProjectionMatrix": .modelViewProjection,
            "g_ModelViewProjectionMatrixInverse": .modelViewProjectionInverse, "g_NormalModelMatrix": .normalModel,
            "g_EffectModelMatrix": .effectModel, "g_EffectModelViewProjectionMatrix": .effectModelViewProjection,
            "g_EffectModelViewProjectionMatrixInverse": .effectModelViewProjectionInverse,
            "g_EffectTextureProjectionMatrix": .effectTextureProjection,
            "g_EffectTextureProjectionMatrixInverse": .effectTextureProjectionInverse,
            "g_LayerModelMatrix": .layerModel,
        ]
        for slot in 0 ..< WPEParityUniformTextures.slotCount {
            names["g_Texture\(slot)Resolution"] = .textureResolution(slot)
            names["g_Texture\(slot)Texel"] = .textureTexel(slot)
            names["g_Texture\(slot)MipMapInfo"] = .textureMipMapInfo(slot)
            names[WPEParityUniformTextures.rotationNames[slot]] = .textureRotation(slot)
            names[WPEParityUniformTextures.translationNames[slot]] = .textureTranslation(slot)
        }
        return names
    }()
}
