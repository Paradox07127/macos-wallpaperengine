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
    public var lights: WPEParityUniformLights?
    /// The draw-independent g_* values (time, screen, pointer, parallax, eye, view vectors, audio spectrum).
    public private(set) var sharedValues: [String: WPECBufferValue] = [:]

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
}
