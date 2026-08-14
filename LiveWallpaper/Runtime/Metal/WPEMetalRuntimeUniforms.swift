#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import QuartzCore
import simd

/// Per-frame camera-parallax state. Smoothing is the delay ramp (`t = idle/delay`), not exponential.
struct WPECameraParallaxFrame: Equatable, Sendable {
    /// `pointer - 0.5` before amount/influence: influence scales only the mouse term.
    var smoothed: SIMD2<Float>
    var amount: Double = 0.5
    var influence: Double = 0.5
    /// Shared magnitude. Override: `defaults write com.loomscreen.pro WPEParallaxGain <n>` (reload after).
    var gain: Double = WPECameraParallaxFrame.defaultGain

    static let defaultGain: Double = 1
    static let maxGain: Double = 20

    /// `nil`/non-finite → `defaultGain`; `0` is off; negatives clamp to 0.
    static func clampedGain(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return defaultGain }
        return min(max(raw, 0), maxGain)
    }

    static let neutral = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0, 0), amount: 0, influence: 0)

    /// Cursor y flipped 2026-08-08: unflipped y chased the cursor vertically while
    /// opposing it horizontally. `objectCenter` is `nodePos−camPos` — 2780710296
    /// parks its clock at x=2732 so the character hides it; without this term the
    /// clock sat on top of her.
    func pixelOffset(
        objectCenter: SIMD2<Double>,
        depth: SIMD2<Double>,
        sceneSize: CGSize
    ) -> SIMD2<Float> {
        let dx = Float(depth.x)
        let dy = Float(depth.y)
        let width = Float(max(sceneSize.width, 1))
        let height = Float(max(sceneSize.height, 1))
        guard dx.isFinite, dy.isFinite, width.isFinite, height.isFinite,
              dx != 0 || dy != 0 else {
            return SIMD2<Float>(0, 0)
        }
        let influenceF = Float(influence)
        let mouseX = -smoothed.x * width * influenceF
        let mouseY = -smoothed.y * height * influenceF
        let scale = Float(amount) * Float(gain)
        return SIMD2<Float>(
            (Float(objectCenter.x) + mouseX) * dx * scale,
            (Float(objectCenter.y) + mouseY) * dy * scale
        )
    }
}

/// Cursor smoother. Tracks even when parallax is disabled: only the per-layer
/// translation is gated (`amount`); `g_ParallaxPosition` still feeds `depthparallax`.
///
/// `cameraparallaxdelay` is a RAMP (`t = idle / delay`), not `1 - exp(-dt/delay)`.
/// A moving cursor holds `t` near zero; a settled one lands exactly on target.
/// The exp form was still ~37% short after one `delay` and never arrived, so
/// on a 2 s scene every parallaxed layer visibly trailed.
struct WPECameraParallaxSmoother: Equatable, Sendable {
    private(set) var smoothed = SIMD2<Float>(0, 0)
    private var lastTime: Double?
    private var target = SIMD2<Float>(0, 0)
    private var lastTargetChange: Double = 0
    private var idle: Double = 0

    mutating func reset() {
        smoothed = SIMD2<Float>(0, 0)
        lastTime = nil
        target = SIMD2<Float>(0, 0)
        lastTargetChange = 0
        idle = 0
    }

    mutating func frame(
        settings: WPESceneCameraParallaxSettings,
        pointerPosition: SIMD2<Double>,
        time: Double,
        gain: Double = WPECameraParallaxFrame.defaultGain
    ) -> WPECameraParallaxFrame {
        // Signs are authored: negative `mouseinfluence` INVERTS parallax. Clamping
        // to 0 read "inverted" as "off" — 3448877775 (−0.3) sat still.
        let amount = settings.enabled ? settings.amount : 0
        let influence = settings.mouseInfluence
        let pointer = pointerPosition.clampedToUnitSquare
        let sampled = SIMD2<Float>(Float(pointer.x - 0.5), Float(pointer.y - 0.5))
        let rawDt = lastTime.map { max(time - $0, 0) }
        lastTime = time
        // First frame / long gap snaps; else dt is floored at 10 FPS so a hitch cannot over-step.
        guard let rawDt, rawDt <= 0.5 else {
            target = sampled
            smoothed = sampled
            lastTargetChange = time
            idle = max(settings.delay, 0)
            return WPECameraParallaxFrame(
                smoothed: smoothed, amount: amount, influence: influence, gain: gain
            )
        }
        if sampled != target {
            idle = max(idle - (time - lastTargetChange), 0)
            lastTargetChange = time
            target = sampled
        }
        let delay = max(settings.delay, 0)
        idle = min(idle + min(rawDt, 1.0 / 10.0), delay)
        let t: Float = delay > 0 ? Float(idle / delay) : 1
        smoothed += (target - smoothed) * t
        return WPECameraParallaxFrame(
            smoothed: smoothed, amount: amount, influence: influence, gain: gain
        )
    }
}

struct WPEMetalRuntimeUniforms: Equatable, Sendable {
    let time: Double
    let daytime: Double
    let brightness: Double
    let pointerPosition: SIMD2<Double>
    /// Defaults to current so a fresh frame reports zero motion.
    var pointerPositionLast: SIMD2<Double>
    var pointerClick: WPEPointerFrame = .neutral
    var cameraParallax: WPECameraParallaxFrame = .neutral
    let audioSpectrumLeft: [Double]
    let audioSpectrumRight: [Double]

    static let zero = WPEMetalRuntimeUniforms(
        time: 0,
        daytime: 0,
        brightness: 1,
        pointerPosition: SIMD2<Double>(0.5, 0.5)
    )

    init(
        time: Double,
        daytime: Double,
        brightness: Double,
        pointerPosition: SIMD2<Double>,
        audioSpectrum: [Double] = [Double](repeating: 0, count: 64)
    ) {
        let mono = Self.normalized(audioSpectrum)
        self.init(
            time: time,
            daytime: daytime,
            brightness: brightness,
            pointerPosition: pointerPosition,
            audioSpectrumLeft: mono,
            audioSpectrumRight: mono
        )
    }

    init(
        time: Double,
        daytime: Double,
        brightness: Double,
        pointerPosition: SIMD2<Double>,
        audioSpectrumLeft: [Double],
        audioSpectrumRight: [Double]
    ) {
        self.time = time
        self.daytime = daytime
        self.brightness = brightness
        self.pointerPosition = pointerPosition
        self.pointerPositionLast = pointerPosition
        self.audioSpectrumLeft = Self.normalized(audioSpectrumLeft)
        self.audioSpectrumRight = Self.normalized(audioSpectrumRight)
    }

    private static func normalized(_ bins: [Double]) -> [Double] {
        if bins.count >= 64 { return Array(bins.prefix(64)) }
        return bins + [Double](repeating: 0, count: 64 - bins.count)
    }

    /// Raw pointer warped 3.2× on 3462279189 (unscaled, y inverted). Must use
    /// the SMOOTHED cursor so `depthparallax` does not snap while neighbours trail.
    var parallaxPosition: SIMD2<Double> {
        let influence = cameraParallax.influence
        return SIMD2<Double>(
            0.5 + Double(cameraParallax.smoothed.x) * influence,
            0.5 - Double(cameraParallax.smoothed.y) * influence
        )
    }

    var uniformValues: [String: WPESceneShaderConstantValue] {
        let s64L = audioSpectrumLeft
        let s64R = audioSpectrumRight
        let s32L = Self.halve(s64L)
        let s32R = Self.halve(s64R)
        let s16L = Self.halve(s32L)
        let s16R = Self.halve(s32R)
        return [
            "g_Time": .number(time),
            "g_Daytime": .number(daytime),
            "g_Brightness": .number(brightness),
            "g_PointerPosition": .vector([pointerPosition.x, pointerPosition.y]),
            "g_ParallaxPosition": .vector([parallaxPosition.x, parallaxPosition.y]),
            // `g_PointerClick*` are internal aliases, not official WPE names.
            "g_PointerPositionLast": .vector([pointerPositionLast.x, pointerPositionLast.y]),
            "g_PointerClickPosition": .vector([pointerClick.clickPosition.x, pointerClick.clickPosition.y]),
            "g_PointerDown": .number(pointerClick.isDown ? 1 : 0),
            "g_PointerRightDown": .number(pointerClick.isRightDown ? 1 : 0),
            "g_AudioSpectrum16Left": .vector(s16L),
            "g_AudioSpectrum16Right": .vector(s16R),
            "g_AudioSpectrum32Left": .vector(s32L),
            "g_AudioSpectrum32Right": .vector(s32R),
            "g_AudioSpectrum64Left": .vector(s64L),
            "g_AudioSpectrum64Right": .vector(s64R),
            // Zero disables optional 2.8 font effects (outline/blur/shadow).
            "g_RenderVar0": .vector([0, 0, 0, 0]),
            "g_RenderVar1": .vector([0, 0, 0, 0]),
            "g_RenderVar2": .vector([0, 0, 0, 0]),
            "g_RenderVar3": .vector([0, 0, 0, 0]),
            // `.y = 0.5` ⇒ maxHDR = 1 (pass-through); `.y = 0` divides by zero → NaN/black.
            "g_HDRParams": .vector([1, 0.5])
        ]
    }

    /// Max-pool adjacent bins (64→32→16). Mean-pool misses WPE: oracle error
    /// 0.0 vs 0.10–0.43 on same-frame 32/16-band uniforms (3448877775).
    private static func halve(_ bins: [Double]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(bins.count / 2)
        var index = 0
        while index + 1 < bins.count {
            result.append(max(bins[index], bins[index + 1]))
            index += 2
        }
        return result
    }
}

struct WPEMetalFrameClock: Sendable {
    let loadTime: CFTimeInterval

    private let currentMediaTime: @Sendable () -> CFTimeInterval
    private let currentDate: @Sendable () -> Date
    private let calendar: Calendar

    init(
        loadTime: CFTimeInterval = CACurrentMediaTime(),
        currentMediaTime: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() },
        currentDate: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.loadTime = loadTime
        self.currentMediaTime = currentMediaTime
        self.currentDate = currentDate
        self.calendar = calendar
    }

    func runtimeUniforms(
        profile: WallpaperPerformanceProfile,
        pointerPosition: SIMD2<Double>
    ) -> WPEMetalRuntimeUniforms {
        let elapsed = max(currentMediaTime() - loadTime, 0)
        let date = currentDate()
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0))
        let daytime = min(max(seconds / 86_400, 0), 1)

        return WPEMetalRuntimeUniforms(
            time: elapsed,
            daytime: daytime,
            brightness: profile.metalBrightnessUniformValue,
            pointerPosition: pointerPosition.clampedToUnitSquare
        )
    }
}

struct WPEMetalPointerSample: Equatable, Sendable {
    let position: SIMD2<Double>
    let isInsideView: Bool

    static let inactive = WPEMetalPointerSample(
        position: SIMD2<Double>(0.5, 0.5),
        isInsideView: false
    )

    static func inside(_ position: SIMD2<Double>) -> WPEMetalPointerSample {
        WPEMetalPointerSample(
            position: position.clampedToUnitSquare,
            isInsideView: true
        )
    }
}

// Not `@MainActor`: sampled on the renderer's actor from a non-blocking mailbox.
struct WPEMetalPointerSampler {
    let sample: @Sendable () -> WPEMetalPointerSample

    static func mailbox(_ mailbox: WPEPointerMailbox) -> WPEMetalPointerSampler {
        WPEMetalPointerSampler { mailbox.read().pointerSample }
    }

    static func fixed(_ uv: SIMD2<Double>) -> WPEMetalPointerSampler {
        WPEMetalPointerSampler { WPEMetalPointerSample.inside(uv) }
    }

    static func fixedOutside() -> WPEMetalPointerSampler {
        WPEMetalPointerSampler { .inactive }
    }

    // @MainActor on the method only: remaining callers are tests already on the main actor.
    @MainActor
    static func normalizedSceneUV(mouseLocation: CGPoint, in view: NSView) -> SIMD2<Double> {
        sampleSceneUV(mouseLocation: mouseLocation, in: view).position
    }

    @MainActor
    static func sampleSceneUV(mouseLocation: CGPoint, in view: NSView) -> WPEMetalPointerSample {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return .inactive
        }

        let localPoint: CGPoint
        if let window = view.window {
            let windowPoint = window.convertPoint(fromScreen: mouseLocation)
            localPoint = view.convert(windowPoint, from: nil)
        } else {
            localPoint = view.convert(mouseLocation, from: nil)
        }

        guard view.bounds.contains(localPoint) else {
            return .inactive
        }

        let x = Double(localPoint.x / view.bounds.width)
        let y = 1.0 - Double(localPoint.y / view.bounds.height)
        return .inside(SIMD2<Double>(x, y))
    }
}

struct WPEMetalCameraUniforms: Equatable, Sendable {
    let renderSize: CGSize
    let viewProjectionMatrix: [Double]
    let usesPerspectiveProjection: Bool
    let sceneCamera: WPESceneCamera
    /// Raw `general.ambientcolor`/`skylightcolor` (no sRGB conversion).
    let lightAmbientColor: SIMD3<Double>
    let lightSkylightColor: SIMD3<Double>
    let sceneHDR: Bool
    let bloom: WPESceneBloomSettings?

    static let identity = WPEMetalCameraUniforms(
        renderSize: CGSize(width: 1, height: 1),
        viewProjectionMatrix: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ],
        usesPerspectiveProjection: false,
        sceneCamera: .defaultCamera
    )

    init(
        orthogonalProjection: WPESceneOrthogonalProjection,
        sceneCamera: WPESceneCamera,
        usesPerspectiveProjection: Bool = false,
        lightAmbientColor: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        lightSkylightColor: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        sceneHDR: Bool = false,
        bloom: WPESceneBloomSettings? = nil
    ) {
        let width = max(orthogonalProjection.width, 1)
        let height = max(orthogonalProjection.height, 1)
        renderSize = CGSize(width: width, height: height)
        self.usesPerspectiveProjection = usesPerspectiveProjection
        self.sceneCamera = sceneCamera
        self.lightAmbientColor = lightAmbientColor
        self.lightSkylightColor = lightSkylightColor
        self.sceneHDR = sceneHDR
        self.bloom = bloom
        viewProjectionMatrix = usesPerspectiveProjection
            ? Self.perspectiveViewProjectionMatrix(
                sceneCamera: sceneCamera,
                aspect: Double(width) / Double(height)
            )
            : Self.topLeftOrthographicMatrix(
                width: Double(width),
                height: Double(height),
                nearZ: sceneCamera.nearZ,
                farZ: sceneCamera.farZ
            )
    }

    private init(
        renderSize: CGSize,
        viewProjectionMatrix: [Double],
        usesPerspectiveProjection: Bool,
        sceneCamera: WPESceneCamera,
        lightAmbientColor: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        lightSkylightColor: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        sceneHDR: Bool = false,
        bloom: WPESceneBloomSettings? = nil
    ) {
        self.renderSize = renderSize
        self.viewProjectionMatrix = viewProjectionMatrix
        self.usesPerspectiveProjection = usesPerspectiveProjection
        self.sceneCamera = sceneCamera
        self.lightAmbientColor = lightAmbientColor
        self.lightSkylightColor = lightSkylightColor
        self.sceneHDR = sceneHDR
        self.bloom = bloom
    }

    var uniformValues: [String: WPESceneShaderConstantValue] {
        [
            "g_ViewProjectionMatrix": .vector(viewProjectionMatrix),
            "g_LightAmbientColor": .vector([lightAmbientColor.x, lightAmbientColor.y, lightAmbientColor.z]),
            "g_LightSkylightColor": .vector([lightSkylightColor.x, lightSkylightColor.y, lightSkylightColor.z]),
            // Internal `general.hdr` carrier — not a WPE uniform name.
            "g_SceneHDREnabled": .number(sceneHDR ? 1 : 0)
        ]
    }

    /// Shared by image-quad and text-mesh so both land at the same scene-centered (+Y up) origin.
    func projectedCenterInScenePixels(
        worldPoint: SIMD3<Double>,
        sceneSize: CGSize
    ) -> (center: SIMD2<Float>, depthScale: Float)? {
        // Identity orientation (forward −Z, up +Y); fov is vertical. RenderDoc 3509243656.
        let eye = sceneCamera.eye
        let relative = worldPoint - eye
        let depth = -relative.z
        guard depth.isFinite, depth > 0.0001 else { return nil }
        let sceneHeight = Double(max(sceneSize.height, 1))
        let fov = max(min(sceneCamera.fov, 179), 1) * .pi / 180
        let focal = sceneHeight / max(2 * tan(fov * 0.5), 0.0001)
        let depthScale = focal / depth
        return (
            SIMD2<Float>(Float(relative.x * depthScale), Float(relative.y * depthScale)),
            Float(depthScale)
        )
    }

    private static func topLeftOrthographicMatrix(
        width: Double,
        height: Double,
        nearZ: Double,
        farZ: Double
    ) -> [Double] {
        let left = 0.0
        let right = width
        let top = 0.0
        let bottom = height
        let near = nearZ
        let far = farZ == nearZ ? nearZ + 1 : farZ

        return [
            2.0 / (right - left), 0, 0, 0,
            0, 2.0 / (top - bottom), 0, 0,
            0, 0, 1.0 / (near - far), 0,
            (left + right) / (left - right),
            (top + bottom) / (bottom - top),
            near / (near - far),
            1
        ]
    }

    private static func perspectiveViewProjectionMatrix(
        sceneCamera: WPESceneCamera,
        aspect: Double
    ) -> [Double] {
        let eye = sceneCamera.eye
        let fovRadians = max(min(sceneCamera.fov, 179), 1) * .pi / 180
        let f = 1.0 / tan(fovRadians * 0.5)
        let zNear = max(sceneCamera.nearZ, 0.0001)
        let zFar = max(sceneCamera.farZ, zNear + 0.0001)

        let projection = [
            f / max(aspect, 0.0001), 0, 0, 0,
            0, f, 0, 0,
            0, 0, zNear / (zFar - zNear), -1,
            0, 0, (zNear * zFar) / (zFar - zNear), 0
        ]
        let view = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            -eye.x, -eye.y, -eye.z, 1
        ]
        return multiply4x4(projection, view)
    }

    private static func multiply4x4(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        guard lhs.count == 16, rhs.count == 16 else { return lhs }
        var out = [Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 {
                    sum += lhs[k * 4 + row] * rhs[column * 4 + k]
                }
                out[column * 4 + row] = sum
            }
        }
        return out
    }
}

extension WallpaperPerformanceProfile {
    /// `g_Brightness` MUST stay 1 when paused: 0 painted every `genericimage*`
    /// layer as a black silhouette (alpha still drew the shape).
    var metalBrightnessUniformValue: Double {
        switch self {
        case .quality, .suspended:
            return 1
        }
    }
}

private extension SIMD2 where Scalar == Double {
    var clampedToUnitSquare: SIMD2<Double> {
        SIMD2<Double>(
            Swift.min(Swift.max(x, 0), 1),
            Swift.min(Swift.max(y, 0), 1)
        )
    }
}
#endif
