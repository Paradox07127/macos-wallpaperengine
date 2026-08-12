#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import QuartzCore
import simd

/// Per-frame, smoothed camera-parallax state. `smoothed` is the cursor offset
/// from screen center (−0.5…0.5 per axis) after exponential smoothing and the
/// scene's amount/mouse-influence calibration. `pixelOffset` turns it into a
/// per-layer scene-pixel translation scaled by that layer's `parallaxDepth`.
struct WPECameraParallaxFrame: Equatable, Sendable {
    /// Smoothed `pointer - 0.5`, raw. The scene's `amount` / `mouseinfluence`
    /// are applied in `pixelOffset` because the reference weights the mouse and
    /// the static terms differently (influence hits only the mouse term).
    var smoothed: SIMD2<Float>
    /// Scene `cameraparallaxamount`; scales BOTH terms.
    var amount: Double = 0.5
    /// Scene `cameraparallaxmouseinfluence`; scales the mouse term only.
    var influence: Double = 0.5
    /// Magnitude multiplier for the per-layer shift, carried on the frame so
    /// every consumer (image layers, particles, text) uses one value. Override
    /// per machine: `defaults write com.loomscreen.pro WPEParallaxGain <n>`;
    /// read at load, so reload the wallpaper after changing it.
    var gain: Double = WPECameraParallaxFrame.defaultGain

    /// Neutral by default: the magnitude now comes entirely from the scene's
    /// own `amount` x `mouseinfluence` x per-object depth, exactly as the
    /// reference engine computes it, so a gain of 1 IS Wallpaper Engine.
    static let defaultGain: Double = 1
    /// Upper bound for a `WPEParallaxGain` override.
    static let maxGain: Double = 20

    /// `nil` (key absent) or non-finite falls back to `defaultGain`; `0` is
    /// honored (parallax off); negatives clamp to 0; magnitude capped at `maxGain`.
    static func clampedGain(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return defaultGain }
        return min(max(raw, 0), maxGain)
    }

    static let neutral = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0, 0), amount: 0, influence: 0)

    /// Each axis is scaled by its own depth so WPE's per-axis limiting works
    /// ("1 0" → horizontal only, "0 1" → vertical only). The reference builds the
    /// cursor term in the scene's +y-up world while the object quad lives in
    /// top-left y-down scene pixels, so BOTH the cursor term and `objectCenter`
    /// flip on the way in — and the two flips cancel for `objectCenter`, which we
    /// already receive y-down. Keeping the cursor y unflipped (we did until
    /// 2026-08-08) made every parallaxed layer chase the cursor vertically while
    /// opposing it horizontally.
    ///
    /// A static `(nodePos−camPos)·depth·amount` term (reference `WPShaderValueUpdater.cpp`)
    /// was tried 2026-07-17 and reverted: our nodePos/camPos coordinate space did
    /// not match the reference, so scenes shifted while static (multi-layer
    /// misalignment, full-frame layers pushed off-canvas). Redo it only after using
    /// the oracle to pin down the nodePos/camPos space convention.
    /// Reference (`WPShaderValueUpdater.cpp`), verbatim and unclamped:
    ///   `mouseVec = (0.5 - mouse) flip-y, * ortho * mouseinfluence`
    ///   `paraVec  = (nodePos - camPos + mouseVec) * depth * amount`
    ///
    /// `objectCenter` is that `nodePos - camPos`: the object's authored origin
    /// relative to the scene centre, in scene pixels, +y up. Dropping it (we
    /// did until 2026-08-07) leaves every parallaxed object sitting at its
    /// authored origin at rest — 2780710296 parks its clock at x=2732 in a
    /// 2560-wide scene so the character hides it, and without the term the
    /// clock sat on top of her instead. Solved from two RenderDoc captures:
    /// three objects agree on the cursor position to within 12 px, and the
    /// "cursor at the right edge" capture solves to 0.999.
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
        // `smoothed` is `pointer - 0.5`, so `-smoothed` is the reference's
        // `0.5 - mouse` on both axes once the world→render y flip is folded in.
        let mouseX = -smoothed.x * width * influenceF
        let mouseY = -smoothed.y * height * influenceF
        let scale = Float(amount) * Float(gain)
        return SIMD2<Float>(
            (Float(objectCenter.x) + mouseX) * dx * scale,
            (Float(objectCenter.y) + mouseY) * dy * scale
        )
    }
}

/// Cursor smoother for camera parallax. Holds the smoothed cursor offset across
/// frames, and keeps tracking even when the scene disables parallax: only the
/// per-layer translation is gated (`amount`), while `g_ParallaxPosition` feeds
/// `depthparallax` regardless.
///
/// `cameraparallaxdelay` is a RAMP on the lerp factor, not an exponential time
/// constant. `WPShaderValueUpdater.cpp` accumulates idle time toward `delay`
/// each frame, lerps by `t = idle / delay`, and knocks the accumulator back by
/// the gap since the previous cursor event on every new one. A moving cursor
/// therefore holds `t` near zero; a settled one ramps to 1 and lands EXACTLY on
/// target. Our old `1 - exp(-dt/delay)` was still ~37% short after one `delay`
/// and never arrived, so on a 2 s scene every parallaxed layer visibly trailed.
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

    /// `time` is monotonic scene-elapsed seconds.
    mutating func frame(
        settings: WPESceneCameraParallaxSettings,
        pointerPosition: SIMD2<Double>,
        time: Double,
        gain: Double = WPECameraParallaxFrame.defaultGain
    ) -> WPECameraParallaxFrame {
        // Signs are authored, not mistakes to clamp away: WPE multiplies
        // `mouseinfluence` straight into the parallax vector
        // (WPShaderValueUpdater.cpp `mouseVec * m_parallax.mouseinfluence`),
        // and `enable` is the only gate. A negative value INVERTS the parallax —
        // clamping it to 0 read "inverted" as "off", which is why 3448877775
        // (mouseinfluence −0.3) sat perfectly still while every positive-influence
        // scene parallaxed fine. `mouseinfluence == 0` likewise silences only the
        // cursor term; the static `(nodePos − camPos)` half still applies.
        let amount = settings.enabled ? settings.amount : 0
        let influence = settings.mouseInfluence
        // Raw cursor offset only — `amount` / `mouseinfluence` ride on the frame
        // and are applied per-term in `pixelOffset`, as the reference does.
        let pointer = pointerPosition.clampedToUnitSquare
        let sampled = SIMD2<Float>(Float(pointer.x - 0.5), Float(pointer.y - 0.5))
        let rawDt = lastTime.map { max(time - $0, 0) }
        lastTime = time
        // First frame or a long gap (resume from suspend/idle) snaps to the
        // cursor instead of slow catch-up. Otherwise `dt` is clamped to a 10 FPS
        // floor: one heavy frame can't over-step, yet low frame rates stay
        // frame-rate independent.
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

/// Per-frame WPE runtime uniforms produced by `WPEMetalFrameClock`, merged into
/// prepared pass uniforms before the Metal executor runs. Built-in shaders
/// ignore entries they don't bind.
struct WPEMetalRuntimeUniforms: Equatable, Sendable {
    let time: Double
    let daytime: Double
    let brightness: Double
    let pointerPosition: SIMD2<Double>
    /// Previous frame's pointer position (WPE's official `g_PointerPositionLast`,
    /// for motion-aware pointer shaders). Defaults to the current position so a
    /// fresh frame reports zero motion. Tracked by the renderer across frames —
    /// works with cursor-follow alone, no click capture needed.
    var pointerPositionLast: SIMD2<Double>
    /// Click state from the interactive view, meaningful only while the scene's
    /// per-screen "Interaction" (click capture) toggle is on; neutral otherwise.
    var pointerClick: WPEPointerFrame = .neutral
    var cameraParallax: WPECameraParallaxFrame = .neutral
    /// Per-channel spectrum, 64 bins each, normalized 0…1, low frequency → high.
    /// Fed from the shared system-audio broker. Audio-reactive shaders consume
    /// 16/32/64-element slices per channel via the resolution combo. Mono
    /// sources duplicate into both channels.
    let audioSpectrumLeft: [Double]
    let audioSpectrumRight: [Double]

    static let zero = WPEMetalRuntimeUniforms(
        time: 0,
        daytime: 0,
        brightness: 1,
        pointerPosition: SIMD2<Double>(0.5, 0.5)
    )

    /// Duplicates one 64-bin spectrum into both channels. For the frame-clock
    /// default path and fixtures.
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
        // Default "no motion" — the renderer overwrites this with the actual
        // previous-frame pointer each frame.
        self.pointerPositionLast = pointerPosition
        self.audioSpectrumLeft = Self.normalized(audioSpectrumLeft)
        self.audioSpectrumRight = Self.normalized(audioSpectrumRight)
    }

    /// Clamps a spectrum to exactly 64 bins (truncate or zero-pad).
    private static func normalized(_ bins: [Double]) -> [Double] {
        if bins.count >= 64 { return Array(bins.prefix(64)) }
        return bins + [Double](repeating: 0, count: 64 - bins.count)
    }

    /// `depthparallax.vert` reads `g_ParallaxPosition * 2 - 1`, so 0.5 is the
    /// neutral centre and 0 is a FULL negative offset. The reference
    /// (`WPShaderValueUpdater.cpp`, `has_PARALLAXPOSITION`) is the cursor offset
    /// about that centre, y-flipped into the shader's +y-up axis and scaled by
    /// `cameraparallaxmouseinfluence`. Feeding the raw pointer instead drove the
    /// warp at 1/influence times WPE's amplitude — 3.2x on 3462279189 — with the
    /// vertical axis inverted.
    ///
    /// (The reference's own line reads `0.5 + (Scaling(1,-1) * mouse - 0.5) *
    /// influence`, which is not neutral at the screen centre; that grouping
    /// cannot be what the shader wants, so the flip is applied to the offset.)
    /// Built from the SMOOTHED cursor, not the raw pointer: the reference feeds
    /// `m_mousePos` to both this uniform and the per-layer translation, so a raw
    /// pointer here snapped the `depthparallax` layer to full deflection while
    /// its neighbours trailed behind `cameraparallaxdelay`.
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
            // Official WPE motion uniform + our internal click aliases (non-
            // official; documented in WPEInteractiveMTKView). Shaders that don't
            // declare these ignore them, so they're zero-cost.
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
            // WPE 2.8 neutral frame defaults. Shaders ignore entries they do not
            // declare, so these are zero-cost for non-2.8 passes and only matter
            // when a 2.8 shader binds them. `g_RenderVar0…3` default to zero,
            // which disables every optional font effect (outline/blur/shadow).
            "g_RenderVar0": .vector([0, 0, 0, 0]),
            "g_RenderVar1": .vector([0, 0, 0, 0]),
            "g_RenderVar2": .vector([0, 0, 0, 0]),
            "g_RenderVar3": .vector([0, 0, 0, 0]),
            // SDR pass-through identity for combine_video_hdr.frag, whose math is
            // `maxHDR = g_HDRParams.y * 2; rgb = saturate(rgb / maxHDR) * maxHDR`.
            // `.y = 0.5` ⇒ maxHDR = 1.0 ⇒ exact pass-through for [0,1] input
            // (`.y = 0` would divide by zero → NaN/black). `.x` is unused here.
            "g_HDRParams": .vector([1, 0.5])
        ]
    }

    /// Max over adjacent bins to halve resolution (64→32→16). WPE keeps the
    /// louder neighbour, not the average: Windows RenderDoc captures with
    /// same-frame 32/16-band uniforms (9 captures, 18 array pairs, e.g.
    /// tools/wpe-oracle/captures/3448877775) reproduce under max-pool with
    /// error 0.0 while mean-pool is off by 0.10–0.43.
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

/// Deterministic clock for Metal frame uniforms. The closure-based
/// `currentMediaTime` and `currentDate` make the type trivial to drive from
/// fixtures while the default initializer falls back to `CACurrentMediaTime`
/// and `Date()` for production.
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

/// Pointer position plus ownership state for one renderer view. `position` is
/// always safe for uniforms; `isInsideView` tells cursor-reactive systems
/// whether the mouse actually belongs to this wallpaper surface.
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

/// Pointer position sampler (the renderer's frame-path pointer source). `mailbox`
/// reads the non-blocking pointer mailbox the surface feeds; `fixed` is for
/// fixtures that need a known active position regardless of the cursor. The
/// closure is view-free — the surface, not the renderer, owns the `NSView`.
// Not `@MainActor`: sampled on the renderer's actor. The closure
// reads the non-blocking pointer mailbox, which is safe off the main thread.
struct WPEMetalPointerSampler {
    let sample: @Sendable () -> WPEMetalPointerSample

    /// Production default: the mailbox's NSView-free `pointerSample`, which is
    /// bit-equal to `sampleSceneUV` (see `WPEPointerMailboxTests`).
    static func mailbox(_ mailbox: WPEPointerMailbox) -> WPEMetalPointerSampler {
        WPEMetalPointerSampler { mailbox.read().pointerSample }
    }

    static func fixed(_ uv: SIMD2<Double>) -> WPEMetalPointerSampler {
        WPEMetalPointerSampler { WPEMetalPointerSample.inside(uv) }
    }

    static func fixedOutside() -> WPEMetalPointerSampler {
        WPEMetalPointerSampler { .inactive }
    }

    // @MainActor (not the enclosing struct): only test callers remain (grep-verified,
    // WPEPointerMailboxTests/WPEMetalRuntimeUniformsTests), both already on the main actor —
    // this reads NSView.bounds/.window, which are themselves main-actor-isolated.
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

/// Camera/projection uniforms produced from `general.orthogonalprojection` +
/// the scene camera. Mirrors the WPE convention of a top-left origin so UV
/// math stays consistent across Metal scene passes.
struct WPEMetalCameraUniforms: Equatable, Sendable {
    let renderSize: CGSize
    let viewProjectionMatrix: [Double]
    let usesPerspectiveProjection: Bool
    let sceneCamera: WPESceneCamera
    /// Scene light uniforms from `general.ambientcolor`/`skylightcolor` (raw,
    /// no sRGB conversion — matches WPE's cbuffer upload) + `general.hdr`.
    /// Consumed by the scene-model generic4 fragment and any transpiled shader
    /// binding `g_Light*`.
    let lightAmbientColor: SIMD3<Double>
    let lightSkylightColor: SIMD3<Double>
    let sceneHDR: Bool
    /// Scene HDR bloom settings (nil = off) — consumed by the executor's
    /// post-scene bloom pyramid.
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
            // Internal carrier for `general.hdr` (not a WPE uniform name, so no
            // transpiled shader ever binds it): the scene-model generic4 path
            // reads it from merged pass uniforms — no extra executor plumbing.
            "g_SceneHDREnabled": .number(sceneHDR ? 1 : 0)
        ]
    }

    /// Project a world-space point through the scene camera into scene-centered
    /// pixel space (origin = screen center, +Y up) — the convention the
    /// object-quad perspective path (`perspectiveObjectQuadUniforms`) produces
    /// and both object-quad and text-mesh placement consume as their `center`.
    /// Returns the projected center plus `depthScale` (focal ÷ depth, the factor
    /// distant content shrinks by), or nil when the point is at/behind the eye
    /// plane. This is the single source of truth shared by the image quad and
    /// text mesh paths so perspective text lands exactly where an image at the
    /// same world origin would.
    func projectedCenterInScenePixels(
        worldPoint: SIMD3<Double>,
        sceneSize: CGSize
    ) -> (center: SIMD2<Float>, depthScale: Float)? {
        // WPE's runtime perspective camera has a FIXED identity orientation
        // (forward −Z, up +Y); the eye comes from the scene's camera OBJECT (see
        // WPESceneDocumentParser.runtimeCameraObjectOverride). Ground truth
        // (RenderDoc capture of 3509243656): g_ViewProjectionMatrix is a pure
        // translation view (clip.w = eye.z − z, no rotation) and fov is VERTICAL
        // (y-scale = 1/tan(fov/2), x = y/aspect).
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
        // Identity orientation (forward −Z, up +Y) from the runtime camera eye —
        // matches `projectedCenterInScenePixels`; see the ground-truth note there.
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
    /// `g_Brightness` fed to image shaders, which compute
    /// `rgb = sampled.rgb * color.rgb * g_Brightness`. This MUST stay 1 in
    /// both states: returning 0 for `.suspended` rendered every `genericimage*`
    /// layer as a pure-black silhouette (alpha is a separate term, so the shape
    /// survived) whenever a frame was produced while suspended — most visibly
    /// the first frame during load and any not-fully-occluded paused wallpaper.
    /// Suspension saves power via `mtkView.isPaused`, not by dimming content to
    /// black; a paused wallpaper should show its scene frozen, not blanked.
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
