import simd

/// Per-frame engine state shared by every draw.
public struct WPEParityUniformFrame: Sendable {
    public var clock: WPEParityClock
    public var daytime: Float
    public var screen: WPEParityUniformScreen
    public var pointer: WPEParityUniformPointer
    public var parallax: WPEParityUniformParallax
    public var eyePosition: SIMD3<Float>
    public var view: simd_float4x4
    public var audio: WPEParityAudioSpectrum
    /// Live scene terms after script writes; nil leaves them to whatever the binding supplies.
    public var lights: WPEParityUniformLights?

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
        func vector(_ value: SIMD2<Float>) -> WPECBufferValue {
            .vector([value.x, value.y])
        }
        func vector(_ value: SIMD3<Float>) -> WPECBufferValue {
            .vector([value.x, value.y, value.z])
        }
        let view = WPEParityUniformParallax.viewVectors(view: frame.view)
        let state = frame.pointer.state
        var values: [String: WPECBufferValue] = [
            "g_Time": .float(frame.clock.timeUniform),
            "g_Frametime": .float(frame.clock.frametime),
            "g_Daytime": .float(frame.daytime),
            "g_Screen": vector(frame.screen.screen),
            "g_TexelSize": vector(frame.screen.texelSize),
            "g_TexelSizeHalf": vector(frame.screen.texelSizeHalf),
            "g_PointerPosition": vector(frame.pointer.position),
            "g_PointerPositionLast": vector(frame.pointer.lastPosition),
            "g_PointerState": .vector([state.x, state.y, state.z, state.w]),
            "g_ParallaxPosition": vector(frame.parallax.position),
            "g_EyePosition": vector(frame.eyePosition),
            "g_ViewForward": vector(view.forward),
            "g_ViewRight": vector(view.right),
            "g_ViewUp": vector(view.up),
        ]
        values.merge(frame.audio.uniforms()) { $1 }
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
