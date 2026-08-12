import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Runtime model of a Wallpaper Engine `scene.json`; unsupported fields remain available as diagnostics.
public struct WPESceneDocument: Equatable, Sendable {
    public let camera: WPESceneCamera
    public let general: WPESceneGeneral
    /// `var` so the renderer can append the synthetic image layers it derives
    /// from `textObjects` before the render graph is built (WPETextLayerSynthesis);
    /// nothing else mutates a parsed document.
    public var imageObjects: [WPESceneImageObject]
    public let scriptHostObjects: [WPESceneScriptHostObject]
    public let transformHostObjects: [WPESceneTransformHostObject]
    public let particleObjects: [WPESceneParticleObject]
    public let textObjects: [WPESceneTextObject]
    public let soundObjects: [WPESceneSoundObject]
    /// Typed light objects are preserved even while the native light/shadow
    /// renderer is gated behind its uniform and attachment oracles.
    public let lightObjects: [WPESceneLightObject]
    /// WPE objects-array paint order (earlier behind later) for z-interleave.
    public let objectPaintOrder: [String: Int]
    /// User-property key → targets (incremental vs reload without re-parse).
    public let propertyBindings: [String: [WPEScenePropertyBinding]]
    /// Parent chain + own baked visible; runtime ANDs live ancestor visibility
    /// so a script cannot show under a hidden group.
    public let objectParentByID: [String: String]
    public let ownVisibilityByID: [String: Bool]
    public let diagnostics: [WPESceneDiagnostic]

    public init(
        camera: WPESceneCamera,
        general: WPESceneGeneral,
        imageObjects: [WPESceneImageObject],
        scriptHostObjects: [WPESceneScriptHostObject] = [],
        transformHostObjects: [WPESceneTransformHostObject] = [],
        particleObjects: [WPESceneParticleObject] = [],
        textObjects: [WPESceneTextObject] = [],
        soundObjects: [WPESceneSoundObject] = [],
        lightObjects: [WPESceneLightObject] = [],
        objectPaintOrder: [String: Int] = [:],
        propertyBindings: [String: [WPEScenePropertyBinding]] = [:],
        objectParentByID: [String: String] = [:],
        ownVisibilityByID: [String: Bool] = [:],
        diagnostics: [WPESceneDiagnostic]
    ) {
        self.camera = camera
        self.general = general
        self.imageObjects = imageObjects
        self.scriptHostObjects = scriptHostObjects
        self.transformHostObjects = transformHostObjects
        self.particleObjects = particleObjects
        self.textObjects = textObjects
        self.soundObjects = soundObjects
        self.lightObjects = lightObjects
        self.objectPaintOrder = objectPaintOrder
        self.propertyBindings = propertyBindings
        self.objectParentByID = objectParentByID
        self.ownVisibilityByID = ownVisibilityByID
        self.diagnostics = diagnostics
    }
}

/// Non-drawn group that carries transform scripts for descendants.
public struct WPESceneTransformHostObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let parentObjectID: String?
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let localOrigin: SIMD3<Double>
    public let localScale: SIMD3<Double>
    public let localAngles: SIMD3<Double>
    /// Keyframed `origin` (WPE authors emitter sweeps this way). `origin` above
    /// holds only the authored static `value` seed — 3448877775's meteor emitter
    /// parks off-screen and returns to (0,0) for ~18s of a 90s loop, which is
    /// what makes its shooting stars periodic rather than permanent.
    public let originAnimation: WPESceneAnimatedValue?
    public let originScript: WPESceneTransformScript?
    public let scaleScript: WPESceneTransformScript?
    public let anglesScript: WPESceneTransformScript?
    /// Camera-parallax depth authored ON THE GROUP. WPE moves a parented
    /// subtree rigidly by its topmost ancestor's depth, and that ancestor is
    /// usually a group — 3448877775's clock/date/weekday assembly rides its
    /// group's "-0.408" while the leaf texts author -0.7 / 0 / 1.0, all of
    /// which the Windows captures prove are ignored. Dropping the field here
    /// severed that chain.
    public let parallaxDepth: SIMD2<Double>

    public init(
        id: String,
        name: String,
        parentObjectID: String? = nil,
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        localOrigin: SIMD3<Double>? = nil,
        localScale: SIMD3<Double>? = nil,
        localAngles: SIMD3<Double>? = nil,
        originAnimation: WPESceneAnimatedValue? = nil,
        originScript: WPESceneTransformScript? = nil,
        scaleScript: WPESceneTransformScript? = nil,
        anglesScript: WPESceneTransformScript? = nil,
        parallaxDepth: SIMD2<Double> = SIMD2<Double>(0, 0)
    ) {
        self.id = id
        self.name = name
        self.parentObjectID = parentObjectID
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.localOrigin = localOrigin ?? origin
        self.localScale = localScale ?? scale
        self.localAngles = localAngles ?? angles
        self.originAnimation = originAnimation
        self.originScript = originScript
        self.scaleScript = scaleScript
        self.anglesScript = anglesScript
        self.parallaxDepth = parallaxDepth
    }
}

/// A non-rendered SceneScript host: WPE permits objects such as `solid:true`
/// controller layers to carry a `visible.script` whose only job is updating
/// globals like `shared.*`. They must run with the layer scripts but do not
/// produce draw passes.
public struct WPESceneScriptHostObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let visibleScript: String
    public let scriptProperties: [String: WPESceneScriptPropertyValue]

    public init(
        id: String,
        name: String,
        visibleScript: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.visibleScript = visibleScript
        self.scriptProperties = scriptProperties
    }
}

/// `action` decides whether changing the property can be patched in place
/// (`.incremental`) or requires a full pipeline reload (`.reload`).
///
/// `condition` carries the expected literal for *condition-form* bindings —
/// `{"user":{"name":K,"condition":"2"},"value":...}` (WPE style selectors).
/// When non-nil the target is visible only while `userValues[propertyKey]`
/// matches `condition`; when nil the property drives the target directly
/// (simple `{"user":K,"value":...}` form).
public struct WPEScenePropertyBinding: Equatable, Sendable {
    public let propertyKey: String
    public let target: WPEScenePropertyBindingTarget
    public let kind: WPEScenePropertyBindingKind
    public let action: WPEScenePropertyBindingAction
    public let condition: String?

    public init(
        propertyKey: String,
        target: WPEScenePropertyBindingTarget,
        kind: WPEScenePropertyBindingKind,
        action: WPEScenePropertyBindingAction,
        condition: String? = nil
    ) {
        self.propertyKey = propertyKey
        self.target = target
        self.kind = kind
        self.action = action
        self.condition = condition
    }
}

public enum WPEScenePropertyBindingTarget: Equatable, Sendable {
    case generalField(name: String)
    case imageObject(id: String)
    case textObject(id: String)
    case particleObject(id: String)
    case soundObject(id: String)
    case lightObject(id: String)
    case imageEffect(objectID: String, effectID: String)
    case shaderUniform(objectID: String, effectID: String?, passID: Int?, name: String)
    case shaderCombo(objectID: String, effectID: String?, passID: Int?, name: String)
    case textureSlot(objectID: String, effectID: String?, passID: Int?, index: Int)
    case objectResource(objectID: String, field: String)
    /// A user property injected into an authored SceneScript's global
    /// `scriptProperties` object. Keeping the property name and consumer role
    /// prevents a nested script binding from being mistaken for a direct
    /// visible/alpha binding, and gives the renderer an exact live-patch target.
    case scriptProperty(WPESceneScriptPropertyTarget)
}

public struct WPESceneScriptPropertyTarget: Equatable, Sendable {
    public let objectID: String
    public let role: WPESceneScriptPropertyRole
    public let propertyName: String
    /// Effect/pass identity when the script belongs below the object itself.
    public let subresourceID: String?

    public init(
        objectID: String,
        role: WPESceneScriptPropertyRole,
        propertyName: String,
        subresourceID: String? = nil
    ) {
        self.objectID = objectID
        self.role = role
        self.propertyName = propertyName
        self.subresourceID = subresourceID
    }
}

public enum WPESceneScriptPropertyRole: String, Equatable, Hashable, Sendable {
    case origin
    case scale
    case angles
    case color
    case layerVisible
    case layerAlpha
    case textContent
    case textVisible
    case textAlpha
    case effectVisible
    case effectConstant
}

public enum WPEScenePropertyBindingKind: String, Equatable, Sendable {
    case general
    case visible
    case color
    case alpha
    case brightness
    case volume
    case uniform
    case combo
    case texture
    case resource
    case scriptProperty
}

public enum WPEScenePropertyBindingAction: String, Equatable, Sendable {
    case incremental
    case reload
}

/// Consumers ask `requiresReload` first; if false they apply
/// `incrementalBindings` live.
public struct WPEScenePropertyPatch: Equatable, Sendable {
    public let bindingsByProperty: [String: [WPEScenePropertyBinding]]
    public let oldValues: [String: WallpaperEngineProjectPropertyValue]
    public let newValues: [String: WallpaperEngineProjectPropertyValue]
    public let changedKeys: Set<String>

    public init(
        bindingsByProperty: [String: [WPEScenePropertyBinding]],
        oldValues: [String: WallpaperEngineProjectPropertyValue],
        newValues: [String: WallpaperEngineProjectPropertyValue]
    ) {
        self.bindingsByProperty = bindingsByProperty
        self.oldValues = oldValues
        self.newValues = newValues
        let keys = Set(oldValues.keys).union(newValues.keys)
        self.changedKeys = Set(keys.filter { oldValues[$0] != newValues[$0] })
    }

    public var changedBindings: [WPEScenePropertyBinding] {
        changedKeys.sorted().flatMap { bindingsByProperty[$0] ?? [] }
    }

    /// A changed property with no known binding is treated conservatively as
    /// reload, so an unmapped key never silently no-ops.
    public var requiresReload: Bool {
        for key in changedKeys {
            let bindings = bindingsByProperty[key] ?? []
            if bindings.isEmpty { return true }
            if bindings.contains(where: { $0.action == .reload }) { return true }
        }
        return false
    }

    public var incrementalBindings: [WPEScenePropertyBinding] {
        changedBindings.filter { $0.action == .incremental }
    }
}

public struct WPESceneSoundObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let soundRelativePaths: [String]
    public let volume: Double
    public let playbackMode: String
    public let startSilent: Bool
    /// Effective initial visibility after folding the object's own authored or
    /// user-bound value with its ancestor groups. WPE only auto-starts while
    /// this is true; later user-property visibility changes address the sound
    /// control directly.
    public let visible: Bool
    /// Lossless typed views of the authored envelopes. The scalar properties
    /// above remain the resolved runtime values for source compatibility.
    public let volumeField: WPESceneAuthoredField<Double>
    public let visibleField: WPESceneAuthoredField<Bool>

    public init(
        id: String,
        name: String,
        soundRelativePaths: [String],
        volume: Double,
        playbackMode: String,
        startSilent: Bool,
        visible: Bool = true,
        volumeField: WPESceneAuthoredField<Double>? = nil,
        visibleField: WPESceneAuthoredField<Bool>? = nil
    ) {
        self.id = id
        self.name = name
        self.soundRelativePaths = soundRelativePaths
        self.volume = volume
        self.playbackMode = playbackMode
        self.startSilent = startSilent
        self.visible = visible
        self.volumeField = volumeField ?? .init(seed: volume, resolvedValue: volume)
        self.visibleField = visibleField ?? .init(seed: visible, resolvedValue: visible)
    }
}

/// WPE light type values used by the global four-light shader arrays.
/// Keep the authored spelling separately because older scenes use both the
/// short (`lpoint`) and canonical (`point`) forms.
public enum WPESceneLightType: Int, Equatable, Sendable {
    case point = 0
    case spot = 1
    case directional = 2
}

/// `general.lightconfig` declares the authored maximum counts by light/shadow
/// class. It is capacity metadata, not permission to fabricate missing lights.
public struct WPESceneLightConfiguration: Equatable, Sendable {
    public let directional: Int
    public let directionalShadow: Int
    public let point: Int
    public let pointShadow: Int
    public let spot: Int
    public let spotShadow: Int

    public init(
        directional: Int = 0,
        directionalShadow: Int = 0,
        point: Int = 0,
        pointShadow: Int = 0,
        spot: Int = 0,
        spotShadow: Int = 0
    ) {
        self.directional = max(0, directional)
        self.directionalShadow = max(0, directionalShadow)
        self.point = max(0, point)
        self.pointShadow = max(0, pointShadow)
        self.spot = max(0, spot)
        self.spotShadow = max(0, spotShadow)
    }

    public static let empty = WPESceneLightConfiguration()
}

/// Provenance for a light field that may carry animation, a user-property
/// envelope, or SceneScript. Runtime consumers may use `resolvedValue`, while
/// `seed` and the authored binding metadata remain available for reloads and
/// future per-frame light evaluation.
public struct WPESceneLightFieldBinding: Equatable, Sendable {
    public let seed: WPESceneShaderConstantValue?
    public let resolvedValue: WPESceneShaderConstantValue?
    public let userBindings: [WPESceneAuthoredUserBinding]
    public let script: String?
    public let scriptProperties: [String: WPESceneScriptPropertyValue]

    public init(
        seed: WPESceneShaderConstantValue?,
        resolvedValue: WPESceneShaderConstantValue?,
        userBindings: [WPESceneAuthoredUserBinding] = [],
        script: String? = nil,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:]
    ) {
        self.seed = seed
        self.resolvedValue = resolvedValue
        self.userBindings = userBindings
        self.script = script
        self.scriptProperties = scriptProperties
    }
}

/// Typed preservation of a WPE light object. These values intentionally do not
/// imply that lighting or shadows are already rendered: uniform packing and
/// shadow-atlas consumption have separate L1 gates.
public struct WPESceneLightObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let type: WPESceneLightType
    public let authoredType: String
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let localOrigin: SIMD3<Double>
    public let localScale: SIMD3<Double>
    public let localAngles: SIMD3<Double>
    public let parentObjectID: String?
    public let parallaxDepth: SIMD2<Double>
    public let color: SIMD3<Double>
    public let radius: Double
    public let intensity: Double
    public let visible: Bool
    public let shape: String?
    public let ledSource: Bool
    public let castShadow: Bool
    public let castVolumetrics: Bool
    public let innerConeDegrees: Double
    public let outerConeDegrees: Double
    public let attenuation: Double
    public let exponent: Double
    public let density: Double
    public let volumetricsExponent: Double
    public let lightSourceSize: Double
    public let minimumDistance: Double
    public let cascadeDistances: SIMD3<Double>
    public let lockTransforms: Bool
    public let muteInEditor: Bool
    public let noInterpolation: Bool
    public let disablePropagation: Bool
    public let solid: Bool
    public let dependencies: [String]
    /// Every authored light field with its seed/resolved/dynamic provenance.
    public let fieldBindings: [String: WPESceneLightFieldBinding]

    public init(
        id: String,
        name: String,
        type: WPESceneLightType,
        authoredType: String,
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        localOrigin: SIMD3<Double>? = nil,
        localScale: SIMD3<Double>? = nil,
        localAngles: SIMD3<Double>? = nil,
        parentObjectID: String? = nil,
        parallaxDepth: SIMD2<Double> = .zero,
        color: SIMD3<Double> = SIMD3<Double>(repeating: 1),
        radius: Double = 1_000,
        intensity: Double = 1,
        visible: Bool = true,
        shape: String? = nil,
        ledSource: Bool = false,
        castShadow: Bool = false,
        castVolumetrics: Bool = false,
        innerConeDegrees: Double = 0,
        outerConeDegrees: Double = 0,
        attenuation: Double = 0,
        exponent: Double = 1,
        density: Double = 1,
        volumetricsExponent: Double = 1,
        lightSourceSize: Double = 0,
        minimumDistance: Double = 0,
        cascadeDistances: SIMD3<Double> = .zero,
        lockTransforms: Bool = false,
        muteInEditor: Bool = false,
        noInterpolation: Bool = false,
        disablePropagation: Bool = false,
        solid: Bool = false,
        dependencies: [String] = [],
        fieldBindings: [String: WPESceneLightFieldBinding] = [:]
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.authoredType = authoredType
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.localOrigin = localOrigin ?? origin
        self.localScale = localScale ?? scale
        self.localAngles = localAngles ?? angles
        self.parentObjectID = parentObjectID
        self.parallaxDepth = parallaxDepth
        self.color = color
        self.radius = radius
        self.intensity = intensity
        self.visible = visible
        self.shape = shape
        self.ledSource = ledSource
        self.castShadow = castShadow
        self.castVolumetrics = castVolumetrics
        self.innerConeDegrees = innerConeDegrees
        self.outerConeDegrees = outerConeDegrees
        self.attenuation = attenuation
        self.exponent = exponent
        self.density = density
        self.volumetricsExponent = volumetricsExponent
        self.lightSourceSize = lightSourceSize
        self.minimumDistance = minimumDistance
        self.cascadeDistances = cascadeDistances
        self.lockTransforms = lockTransforms
        self.muteInEditor = muteInEditor
        self.noInterpolation = noInterpolation
        self.disablePropagation = disablePropagation
        self.solid = solid
        self.dependencies = dependencies
        self.fieldBindings = fieldBindings
    }
}

/// One resolved scriptProperty binding (a WPE SceneScript editor property the
/// scene configures per object — e.g. a clock's `dayFormat`/`showDay`). WPE
/// sliders are numeric, but checkboxes are bools and combos/text are strings.
public enum WPESceneScriptPropertyValue: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
}

/// WPE SceneScript attached to a transform field such as `origin`.
/// Static scripts are evaluated once by the parser; dynamic scripts are retained
/// here so the renderer can tick them with live inputs such as the cursor.
public struct WPESceneTransformScript: Equatable, Sendable {
    public let script: String
    public let scriptProperties: [String: WPESceneScriptPropertyValue]
    public let seed: SIMD3<Double>

    public init(
        script: String,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        seed: SIMD3<Double>
    ) {
        self.script = script
        self.scriptProperties = scriptProperties
        self.seed = seed
    }
}

public struct WPESceneTextObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let text: String
    public let textScript: String?
    /// The scene's per-object scriptProperty overrides (e.g. `dayFormat`,
    /// `showDay`), so the text script renders with the scene's configuration
    /// instead of the script's own declared defaults.
    public let scriptProperties: [String: WPESceneScriptPropertyValue]
    public let fontRelativePath: String?
    public let pointSize: Double
    public let color: SIMD3<Double>
    /// Object-level `brightness` colour multiplier — the same generic field
    /// image objects carry (3460973721's Clock/Date/Day author 2.39/1.98/1.4).
    /// Multiplied into the text colour by both draw paths; 1 = unchanged.
    public let brightness: Double
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    /// Static author-space rotation (radians, `angles` in scene.json). Text
    /// objects rotate like image layers — 2986828130's Clock/Date carry a
    /// standalone z of 0.5236 (30°) with no parent chain.
    public let angles: SIMD3<Double>
    public let visible: Bool
    public let horizontalAlignment: String
    public let verticalAlignment: String
    public let maxWidth: Double?
    /// WPE "Limit rows" + "Max rows". `maxRows` is nil when the toggle is off,
    /// mirroring how `maxWidth` is gated by `limitWidth` — without a cap the
    /// CoreText path wraps until every character fits, so a long song title
    /// grows downward without bound instead of clipping to one line.
    public let maxRows: Int?
    /// WPE "Use ellipsis": append "…" when the text was clipped by `maxRows`.
    public let limitUseEllipsis: Bool
    /// Per-axis camera-parallax depth (WPE stores this as a Vec2 "x y"). Each
    /// axis scales independently, so "1 0" parallaxes horizontally only and
    /// "0 1" vertically only. `.zero` pins the layer (no parallax).
    public let parallaxDepth: SIMD2<Double>
    /// WPE's `size`: the text FBO dimensions the EDITOR last measured, written
    /// back into scene.json — layout OUTPUT, not input, and stale the moment a
    /// scripted clock/date changes length. **Nothing in the render path may read
    /// it** (glyphs are laid out at pointsize×300/72 anchored on `origin`; see
    /// `WPETextLayoutEngine`). Kept only because SceneScript's `layer.size`
    /// reports it.
    public let boxSize: SIMD2<Double>?
    /// Transparent margin (scene pixels) the runtime adds AROUND the glyph
    /// block when rendering text effects into an intermediate target (official
    /// docs: "increases the geometry around the font characters"). It does NOT
    /// shift the text anchor; the authored `size` box is an editor artifact and
    /// is deliberately not parsed (oracle-verified, memory wpe-text-windows-model).
    public let padding: Double
    /// Copies the scene region behind the text into the offscreen surface before
    /// glyph drawing. This is also an offscreen-rendering discriminator in WPE.
    public let copyBackground: Bool
    /// Fills the text surface with `backgroundColor × backgroundBrightness`
    /// before glyph drawing. Opaque-background text can never use Direct mode.
    public let opaqueBackground: Bool
    public let backgroundColor: SIMD3<Double>
    public let backgroundBrightness: Double
    /// Effect chain on the text object. WPE renders a text layer's glyphs into
    /// an intermediate target and then runs it through the SAME chain as an
    /// image layer (blurprecise / opacity / pulse dominate the corpus).
    public let effects: [WPESceneImageEffect]
    public let letterSpacing: Double
    /// Parent object id + this object's LOCAL origin (pre-composition). `origin`
    /// above is the parse-time WORLD origin; when the parent chain moves at
    /// runtime (script-driven menu panels), the renderer re-composes
    /// `localOrigin` through the live parent transforms instead.
    public let parentObjectID: String?
    public let localOrigin: SIMD3<Double>?
    /// This object's OWN authored scale, before the parent chain folds in.
    /// `scale` above is the parse-time WORLD scale; a `scale` SceneScript
    /// returns a LOCAL value (WPE scripts read/write the object's own
    /// property), so the renderer needs both to swap one out for the other.
    public let localScale: SIMD3<Double>?
    /// Script-driven alpha/visible on TEXT objects (3509243656's login-intro
    /// texts fade themselves out via alpha scripts; the clock gates visibility).
    /// Ticked by the renderer through the same layer-script machinery as image
    /// layers — the baked `alpha`/`visible` above are only the load-time seeds.
    public let alphaScript: String?
    public let alphaScriptProperties: [String: WPESceneScriptPropertyValue]
    public let visibleScript: String?
    public let visibleScriptProperties: [String: WPESceneScriptPropertyValue]
    /// Dynamic `origin` SceneScript (reads `shared`/`input`/time), ticked live by
    /// the renderer — 3509243656's star-coordinate tooltip labels track their
    /// body via `shared.xxN`. Nil when the origin is static (resolved at parse).
    public let originScript: WPESceneTransformScript?
    /// WPE SceneScript attached to `color`. Returns a Vec3 in 0…1 linear RGB, so
    /// the renderer ticks it through the same Vec3 machinery as scale/angles.
    public let colorScript: WPESceneTransformScript?
    /// WPE SceneScript attached to `scale` / `angles`. Text objects never became
    /// transform hosts (the parse loop excludes them), so these are their only
    /// route to a scripted scale — the corpus binds 259 of them, almost all the
    /// audio-response template.
    public let scaleScript: WPESceneTransformScript?
    public let anglesScript: WPESceneTransformScript?
    public init(
        id: String,
        name: String,
        text: String,
        textScript: String? = nil,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        fontRelativePath: String?,
        pointSize: Double,
        color: SIMD3<Double>,
        brightness: Double = 1,
        alpha: Double,
        alphaAnimation: WPESceneAnimatedValue? = nil,
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        visible: Bool,
        horizontalAlignment: String,
        verticalAlignment: String,
        maxWidth: Double?,
        maxRows: Int? = nil,
        limitUseEllipsis: Bool = false,
        parallaxDepth: SIMD2<Double>,
        boxSize: SIMD2<Double>? = nil,
        padding: Double = 0,
        copyBackground: Bool = false,
        opaqueBackground: Bool = false,
        backgroundColor: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        backgroundBrightness: Double = 1,
        effects: [WPESceneImageEffect] = [],
        letterSpacing: Double = 0,
        parentObjectID: String? = nil,
        localOrigin: SIMD3<Double>? = nil,
        localScale: SIMD3<Double>? = nil,
        alphaScript: String? = nil,
        alphaScriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        visibleScript: String? = nil,
        visibleScriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        originScript: WPESceneTransformScript? = nil,
        colorScript: WPESceneTransformScript? = nil,
        scaleScript: WPESceneTransformScript? = nil,
        anglesScript: WPESceneTransformScript? = nil
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.textScript = textScript
        self.scriptProperties = scriptProperties
        self.fontRelativePath = fontRelativePath
        self.pointSize = pointSize
        self.color = color
        self.brightness = brightness
        self.alpha = alpha
        self.alphaAnimation = alphaAnimation
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.visible = visible
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.maxWidth = maxWidth
        self.maxRows = maxRows
        self.limitUseEllipsis = limitUseEllipsis
        self.parallaxDepth = parallaxDepth
        self.boxSize = boxSize
        self.padding = padding
        self.copyBackground = copyBackground
        self.opaqueBackground = opaqueBackground
        self.backgroundColor = backgroundColor
        self.backgroundBrightness = backgroundBrightness
        self.effects = effects
        self.letterSpacing = letterSpacing
        self.parentObjectID = parentObjectID
        self.localOrigin = localOrigin
        self.localScale = localScale
        self.alphaScript = alphaScript
        self.alphaScriptProperties = alphaScriptProperties
        self.visibleScript = visibleScript
        self.visibleScriptProperties = visibleScriptProperties
        self.originScript = originScript
        self.colorScript = colorScript
        self.scaleScript = scaleScript
        self.anglesScript = anglesScript
    }

    public func resolvedAlpha(at time: Double) -> Double {
        alphaAnimation?.scalar(at: time) ?? alpha
    }

    /// Returns a copy carrying the live (scripted) text + resolved alpha while
    /// preserving every other field. `liveColor` is the `color` SceneScript's
    /// output; nil keeps the authored tint.
    public func withLiveText(
        _ liveText: String,
        alpha liveAlpha: Double,
        color liveColor: SIMD3<Double>? = nil
    ) -> WPESceneTextObject {
        WPESceneTextObject(
            id: id,
            name: name,
            text: liveText,
            textScript: textScript,
            scriptProperties: scriptProperties,
            fontRelativePath: fontRelativePath,
            pointSize: pointSize,
            color: liveColor ?? color,
            brightness: brightness,
            alpha: liveAlpha,
            alphaAnimation: alphaAnimation,
            origin: origin,
            scale: scale,
            angles: angles,
            visible: visible,
            horizontalAlignment: horizontalAlignment,
            verticalAlignment: verticalAlignment,
            maxWidth: maxWidth,
            maxRows: maxRows,
            limitUseEllipsis: limitUseEllipsis,
            parallaxDepth: parallaxDepth,
            boxSize: boxSize,
            padding: padding,
            copyBackground: copyBackground,
            opaqueBackground: opaqueBackground,
            backgroundColor: backgroundColor,
            backgroundBrightness: backgroundBrightness,
            effects: effects,
            letterSpacing: letterSpacing,
            parentObjectID: parentObjectID,
            localOrigin: localOrigin,
            localScale: localScale,
            alphaScript: alphaScript,
            alphaScriptProperties: alphaScriptProperties,
            visibleScript: visibleScript,
            visibleScriptProperties: visibleScriptProperties,
            originScript: originScript,
            colorScript: colorScript,
            scaleScript: scaleScript,
            anglesScript: anglesScript
        )
    }
}

public struct WPESceneParticleObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Parent object, so a transform host with a keyframed `origin` can move this
    /// emitter. Image layers get that through the render graph's parent→child
    /// composition; particles are not render layers, so without this the meteor's
    /// emitter stayed frozen at its parse-time origin and rained shooting stars
    /// non-stop instead of only while its host sweeps on-screen.
    public let parentObjectID: String?
    public let particleRelativePath: String
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let visible: Bool
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let color: SIMD3<Double>
    /// Object-level `brightness` colour multiplier — the same generic field
    /// image objects carry (WPE applies it to any renderable object). Rendered
    /// by folding into the particle overbright uniform; 1 = unchanged.
    public let brightness: Double
    /// Per-axis camera-parallax depth (WPE stores this as a Vec2 "x y"). Each
    /// axis scales independently, so "1 0" parallaxes horizontally only and
    /// "0 1" vertically only. `.zero` pins the layer (no parallax).
    public let parallaxDepth: SIMD2<Double>
    public let instanceOverride: WPESceneParticleInstanceOverride?

    public init(id: String, name: String, parentObjectID: String? = nil, particleRelativePath: String, origin: SIMD3<Double>, scale: SIMD3<Double>, angles: SIMD3<Double>, visible: Bool, alpha: Double, alphaAnimation: WPESceneAnimatedValue? = nil, color: SIMD3<Double>, brightness: Double = 1, parallaxDepth: SIMD2<Double>, instanceOverride: WPESceneParticleInstanceOverride? = nil) {
        self.id = id
        self.name = name
        self.parentObjectID = parentObjectID
        self.particleRelativePath = particleRelativePath
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.visible = visible
        self.alpha = alpha
        self.alphaAnimation = alphaAnimation
        self.color = color
        self.brightness = brightness
        self.parallaxDepth = parallaxDepth
        self.instanceOverride = instanceOverride
    }

    public func resolvedAlpha(at time: Double) -> Double {
        alphaAnimation?.scalar(at: time) ?? alpha
    }
}

public struct WPESceneParticleInstanceOverride: Equatable, Sendable {
    public let count: Double?
    public let rate: Double?
    public let lifetime: Double?
    public let size: Double?
    public let speed: Double?
    public let alpha: Double?
    /// HDR multiplier applied to the generated particle vertex RGB. Windows
    /// WPE keeps the material `g_Overbright` unchanged and bakes this value
    /// into COLOR.rgb instead (3509243656: sibling systems author 2 and 4).
    public let brightness: Double?
    /// Override color in the same 0...255 space as particle definitions.
    public let color: SIMD3<Double>?
    /// Keyframed `alpha` override. WPE authors these as the usual four-key
    /// `{animation, script, scriptproperties, value}` dict; `alpha` above is only
    /// the static seed, so a scene that ramps its particles in over a loop
    /// (3448877775's star field: 0.01 → 1.0) sat at full brightness without this.
    public let alphaAnimation: WPESceneAnimatedValue?
    /// `controlpointN`: per-instance replacement for the particle definition's own
    /// control-point offsets, keyed by N. One particle file is reused across
    /// objects and each object moves the control points from here. Dropping them
    /// left `controlpointattract` pulling toward the emitter itself (an authored
    /// control point with no `offset` defaults to 0,0,0), which pins the whole
    /// system in place — scene 3596044309's two `31.json` instances sit in a
    /// ~15px clump because of it, with attract `scale` 1000 against a ~223 gravity.
    public let controlPointOffsets: [Int: SIMD3<Double>]

    public init(
        count: Double? = nil,
        rate: Double? = nil,
        lifetime: Double? = nil,
        size: Double? = nil,
        speed: Double? = nil,
        alpha: Double? = nil,
        brightness: Double? = nil,
        color: SIMD3<Double>? = nil,
        alphaAnimation: WPESceneAnimatedValue? = nil,
        controlPointOffsets: [Int: SIMD3<Double>] = [:]
    ) {
        self.count = count
        self.rate = rate
        self.lifetime = lifetime
        self.size = size
        self.speed = speed
        self.alpha = alpha
        self.brightness = brightness
        self.color = color
        self.alphaAnimation = alphaAnimation
        self.controlPointOffsets = controlPointOffsets
    }
}

public struct WPESceneCamera: Equatable, Sendable {
    public let center: SIMD3<Double>
    public let eye: SIMD3<Double>
    public let up: SIMD3<Double>
    public let nearZ: Double
    public let farZ: Double
    public let fov: Double

    public init(center: SIMD3<Double>, eye: SIMD3<Double>, up: SIMD3<Double>, nearZ: Double, farZ: Double, fov: Double) {
        self.center = center
        self.eye = eye
        self.up = up
        self.nearZ = nearZ
        self.farZ = farZ
        self.fov = fov
    }

    public static let defaultCamera = WPESceneCamera(
        center: SIMD3<Double>(0, 0, 0),
        eye: SIMD3<Double>(0, 0, 1),
        up: SIMD3<Double>(0, 1, 0),
        nearZ: 0.01,
        farZ: 10000,
        fov: 50
    )
}

/// WPE HDR scene bloom (`general.bloom` + `bloomhdr*`). Values are the raw
/// scene.json numbers; the executor derives the cbuffer forms RenderDoc-verified
/// on 3509243656 (g_BloomStrength = strength/17, knee curve from
/// threshold/feather, per-level texel offsets, scatter-weighted additive upsample).
public struct WPESceneBloomSettings: Equatable, Sendable {
    public let strength: Double
    public let threshold: Double
    public let feather: Double
    public let scatter: Double
    public let iterations: Int
    public let tint: SIMD3<Double>

    public init(
        strength: Double,
        threshold: Double,
        feather: Double,
        scatter: Double,
        iterations: Int,
        tint: SIMD3<Double>
    ) {
        self.strength = strength
        self.threshold = threshold
        self.feather = feather
        self.scatter = scatter
        self.iterations = iterations
        self.tint = tint
    }
}

/// A user-property dependency preserved from an authored WPE field envelope.
/// `condition` is non-nil for selector-form bindings such as
/// `{ "user": { "name": "style", "condition": "2" }, "value": ... }`.
public struct WPESceneAuthoredUserBinding: Equatable, Sendable {
    public let propertyKey: String
    public let condition: String?

    public init(propertyKey: String, condition: String? = nil) {
        self.propertyKey = propertyKey
        self.condition = condition
    }
}

/// Typed preservation view of a WPE field that may be a literal, user-property
/// envelope, or SceneScript envelope. `seed` is the serialized fallback while
/// `resolvedValue` reflects the user values supplied to this parse. Runtime
/// consumers remain separate and must pass their own L1 behavior gate.
public struct WPESceneAuthoredField<Value: Equatable & Sendable>: Equatable, Sendable {
    public let seed: Value
    public let resolvedValue: Value
    public let isAuthored: Bool
    public let userBindings: [WPESceneAuthoredUserBinding]
    public let script: String?
    public let scriptProperties: [String: WPESceneScriptPropertyValue]

    public init(
        seed: Value,
        resolvedValue: Value? = nil,
        isAuthored: Bool = false,
        userBindings: [WPESceneAuthoredUserBinding] = [],
        script: String? = nil,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:]
    ) {
        self.seed = seed
        self.resolvedValue = resolvedValue ?? seed
        self.isAuthored = isAuthored
        self.userBindings = userBindings
        self.script = script
        self.scriptProperties = scriptProperties
    }

    public var hasDynamicBinding: Bool {
        !userBindings.isEmpty || script != nil
    }
}

public struct WPESceneCameraShakeSettings: Equatable, Sendable {
    public let enabled: WPESceneAuthoredField<Bool>
    public let amplitude: WPESceneAuthoredField<Double>
    public let speed: WPESceneAuthoredField<Double>
    public let roughness: WPESceneAuthoredField<Double>

    public init(
        enabled: WPESceneAuthoredField<Bool> = .init(seed: false),
        amplitude: WPESceneAuthoredField<Double> = .init(seed: 0),
        speed: WPESceneAuthoredField<Double> = .init(seed: 0),
        roughness: WPESceneAuthoredField<Double> = .init(seed: 0)
    ) {
        self.enabled = enabled
        self.amplitude = amplitude
        self.speed = speed
        self.roughness = roughness
    }
}

public struct WPESceneWindSettings: Equatable, Sendable {
    public let enabled: WPESceneAuthoredField<Bool>
    public let direction: WPESceneAuthoredField<SIMD3<Double>>
    public let strength: WPESceneAuthoredField<Double>

    public init(
        enabled: WPESceneAuthoredField<Bool> = .init(seed: false),
        direction: WPESceneAuthoredField<SIMD3<Double>> = .init(seed: SIMD3<Double>(0, 0, 1)),
        strength: WPESceneAuthoredField<Double> = .init(seed: 0)
    ) {
        self.enabled = enabled
        self.direction = direction
        self.strength = strength
    }
}

public struct WPESceneGravitySettings: Equatable, Sendable {
    public let direction: WPESceneAuthoredField<SIMD3<Double>>
    public let strength: WPESceneAuthoredField<Double>

    public init(
        direction: WPESceneAuthoredField<SIMD3<Double>> = .init(seed: SIMD3<Double>(0, -1, 0)),
        strength: WPESceneAuthoredField<Double> = .init(seed: 0)
    ) {
        self.direction = direction
        self.strength = strength
    }
}

public struct WPESceneGeneral: Equatable, Sendable {
    public let clearColor: SIMD3<Double>
    public let orthogonalProjection: WPESceneOrthogonalProjection
    public let usesPerspectiveProjection: Bool
    /// Authored WPE `general.zoom` value. Retained as scene metadata only: the
    /// projection/camera consumption rule still needs an L1 oracle before the
    /// renderer may use it.
    public let zoom: Double
    /// Full authored wrapper for `general.zoom`; `zoom` remains the compatible
    /// resolved scalar API while this retains user/SceneScript provenance.
    public let zoomField: WPESceneAuthoredField<Double>
    /// Metadata-only until the per-object perspective camera domain has L1.
    public let perspectiveOverrideFOV: WPESceneAuthoredField<Double>
    /// Metadata-only; no camera jitter is generated from this state yet.
    public let cameraShake: WPESceneCameraShakeSettings
    /// Metadata-only; the render-pass clear policy does not consume it yet.
    public let clearEnabled: WPESceneAuthoredField<Bool>
    /// Metadata-only scene environment fields; particle/render algorithms do
    /// not consume these values without an independent behavior oracle.
    public let wind: WPESceneWindSettings
    public let gravity: WPESceneGravitySettings
    public let cameraParallax: WPESceneCameraParallaxSettings
    /// WPE `general.supportsaudioprocessing`: the scene declares audio-reactive
    /// content (a shader/effect samples `g_AudioSpectrum*`). Used by the renderer
    /// to keep the view on the continuous-frame path so the visualizer animates
    /// with audio instead of freezing on the static/on-demand path.
    public let supportsAudioProcessing: Bool
    /// WPE `general.ambientcolor` / `general.skylightcolor` — the scene light
    /// uniforms (`g_LightAmbientColor` / `g_LightSkylightColor`), uploaded RAW
    /// (no sRGB conversion; RenderDoc-verified on 3509243656). Default WHITE so
    /// scenes that never author them keep the pre-lighting model look.
    public let lightAmbientColor: SIMD3<Double>
    public let lightSkylightColor: SIMD3<Double>
    /// Authored light/shadow capacity declarations. Preserved independently
    /// from the renderer so a missing uniform/shadow implementation cannot
    /// silently erase the scene's lighting contract.
    public let lightConfiguration: WPESceneLightConfiguration
    /// WPE `general.hdr`: gates the HDR branches of model materials
    /// (brightness multiply + emissive overbright in generic4).
    public let hdr: Bool
    /// Non-nil when the scene enables HDR bloom (`bloom:true` + `hdr:true`).
    public let bloom: WPESceneBloomSettings?

    public init(
        clearColor: SIMD3<Double>,
        orthogonalProjection: WPESceneOrthogonalProjection,
        usesPerspectiveProjection: Bool = false,
        zoom: Double = 1,
        zoomField: WPESceneAuthoredField<Double>? = nil,
        perspectiveOverrideFOV: WPESceneAuthoredField<Double> = .init(seed: 0),
        cameraShake: WPESceneCameraShakeSettings = .init(),
        clearEnabled: WPESceneAuthoredField<Bool> = .init(seed: true),
        wind: WPESceneWindSettings = .init(),
        gravity: WPESceneGravitySettings = .init(),
        cameraParallax: WPESceneCameraParallaxSettings = .disabled,
        supportsAudioProcessing: Bool = false,
        lightAmbientColor: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        lightSkylightColor: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        lightConfiguration: WPESceneLightConfiguration = .empty,
        hdr: Bool = false,
        bloom: WPESceneBloomSettings? = nil
    ) {
        self.clearColor = clearColor
        self.orthogonalProjection = orthogonalProjection
        self.usesPerspectiveProjection = usesPerspectiveProjection
        self.zoom = zoom
        self.zoomField = zoomField ?? WPESceneAuthoredField(seed: zoom)
        self.perspectiveOverrideFOV = perspectiveOverrideFOV
        self.cameraShake = cameraShake
        self.clearEnabled = clearEnabled
        self.wind = wind
        self.gravity = gravity
        self.cameraParallax = cameraParallax
        self.supportsAudioProcessing = supportsAudioProcessing
        self.lightAmbientColor = lightAmbientColor
        self.lightSkylightColor = lightSkylightColor
        self.lightConfiguration = lightConfiguration
        self.hdr = hdr
        self.bloom = bloom
    }

    public static let defaultGeneral = WPESceneGeneral(
        clearColor: SIMD3<Double>(0, 0, 0),
        orthogonalProjection: WPESceneOrthogonalProjection(width: 1920, height: 1080, auto: true)
    )
}

/// WPE scene-level camera parallax: the whole scene follows the cursor, each
/// layer shifting by its `parallaxDepth`. `amount`/`delay`/`mouseInfluence`
/// mirror the WPE general settings; defaults match WPE so an enabled scene that
/// omits them behaves like Wallpaper Engine. Disabled by default (no-op).
public struct WPESceneCameraParallaxSettings: Equatable, Sendable {
    public let enabled: Bool
    public let amount: Double
    public let delay: Double
    public let mouseInfluence: Double

    public init(
        enabled: Bool = false,
        amount: Double = 0.5,
        delay: Double = 0.1,
        mouseInfluence: Double = 0.5
    ) {
        self.enabled = enabled
        self.amount = amount
        self.delay = delay
        self.mouseInfluence = mouseInfluence
    }

    public static let disabled = WPESceneCameraParallaxSettings(
        enabled: false, amount: 0.5, delay: 0.1, mouseInfluence: 0.5
    )
}

public struct WPESceneOrthogonalProjection: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let auto: Bool

    public init(width: Double, height: Double, auto: Bool) {
        self.width = width
        self.height = height
        self.auto = auto
    }
}

/// WPE `objects[].instance.usertextures` binding. A missing `type` represents
/// the older bare-string form; typed entries name system media or user-shortcut
/// texture providers that the native renderer may resolve separately.
public struct WPESceneUserTextureBinding: Equatable, Sendable {
    public let name: String
    public let type: String?

    public init(name: String, type: String? = nil) {
        self.name = name
        self.type = type
    }
}

/// Per-object material binding overrides serialized in WPE
/// `objects[].instance`. These are merged over the image asset's base material
/// after it loads; empty texture slots intentionally do not replace the base.
public struct WPESceneMaterialInstance: Equatable, Sendable {
    public let id: Int?
    public let combos: [String: Int]
    public let textures: [Int: String]
    public let userTextures: [WPESceneUserTextureBinding]

    public init(
        id: Int? = nil,
        combos: [String: Int] = [:],
        textures: [Int: String] = [:],
        userTextures: [WPESceneUserTextureBinding] = []
    ) {
        self.id = id
        self.combos = combos
        self.textures = textures
        self.userTextures = userTextures
    }
}

/// WPE `objects[].config` metadata for image layers. `passthrough` is kept
/// typed for diagnostics and future render-graph planning, but is deliberately
/// not interpreted until its topology semantics have L1 evidence.
public struct WPESceneImageConfig: Equatable, Sendable {
    public let passthrough: Bool

    public init(passthrough: Bool = false) {
        self.passthrough = passthrough
    }
}

public struct WPESceneImageObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let imageRelativePath: String
    public let materialRelativePath: String?
    /// Per-object compiled-material binding overrides (`objects[].instance`).
    public let materialInstance: WPESceneMaterialInstance?
    /// Authored `objects[].config`, retained without changing pass topology.
    public let config: WPESceneImageConfig
    /// Authored WPE `disablepropagation` flag. Retained for a future hierarchy
    /// planner, but deliberately not applied to parallax propagation until the
    /// native behavior has an L1 mutation capture.
    public let disablePropagation: Bool
    /// Whether this image participates in WPE cursor hit-testing. Preserved as
    /// authored input; the renderer does not change dispatch policy until the
    /// overlapping-layer order has an L1 oracle.
    public let solid: Bool
    /// Whether utility composition layers should seed their pass chain from the current scene.
    public let copyBackground: Bool
    /// Scene object this layer attaches to (the parent puppet for body-split rigs). `nil` for roots.
    public let parentObjectID: String?
    /// Named MDAT anchor on the parent puppet, or `nil` when unattached.
    public let attachment: String?
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    /// The object's own (pre-inheritance) transform. `origin`/`scale`/`angles` are parent-baked;
    /// these retain the local values so attachment-following can re-derive the child placement.
    public let localOrigin: SIMD3<Double>
    public let localScale: SIMD3<Double>
    public let localAngles: SIMD3<Double>
    public let visible: Bool
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let color: SIMD3<Double>
    /// Keyframed color track; `color` remains the authored static seed.
    public let colorAnimation: WPESceneAnimatedValue?
    public let brightness: Double
    /// A blend that reads the destination, so it cannot ride a Metal blend
    /// descriptor and must go through the programmable composite. `blendMode`
    /// is `.normal` for these — drawing them with it paints an opaque rectangle
    /// over the scene (3448877775's full-screen Overlay tint erased the whole
    /// wallpaper this way).
    public var usesProgrammableBlend: Bool {
        WPESceneBlendMode.fixedFunction(forWPEBlendMode: colorBlendMode) == nil
    }
    public let blendMode: WPESceneBlendMode
    /// Raw WPE `common_blending.h` BLENDMODE index. `blendMode` above is only the
    /// fixed-function-expressible approximation; modes outside that subset (11
    /// Overlay, 12 Soft Light, …) read the destination and must run the
    /// programmable `ApplyBlending` path keyed on this number.
    public let colorBlendMode: Int
    public let alignment: WPESceneAlignment
    public let size: CGSize?
    public let dependencies: [String]
    public let effects: [WPESceneImageEffect]
    public let animationLayers: [WPESceneAnimationLayer]
    /// Per-axis camera-parallax depth (WPE stores this as a Vec2 "x y"). Each
    /// axis scales independently, so "1 0" parallaxes horizontally only and
    /// "0 1" vertically only. `.zero` pins the layer (no parallax).
    public let parallaxDepth: SIMD2<Double>
    /// WPE SceneScript attached to this layer's `visible` field (a JS program
    /// with `init()`/`update()` that drives the layer's visibility/alpha and any
    /// video texture). `nil` for the common static-visibility case.
    public let visibleScript: String?
    /// WPE SceneScript attached to this layer's `alpha` field. These scripts
    /// return the live alpha value from `update(value)` and must not change
    /// layer visibility.
    public let alphaScript: String?
    public let alphaScriptProperties: [String: WPESceneScriptPropertyValue]
    /// Dynamic WPE SceneScript attached to this layer's `origin` field. Static
    /// origin scripts are resolved at parse time and leave this nil.
    public let originScript: WPESceneTransformScript?
    /// WPE SceneScript attached to this layer's `scale` field. Scale scripts are
    /// evaluated at runtime because authored scenes often use shared state or
    /// frame-local state even when the serialized fallback value looks static.
    public let scaleScript: WPESceneTransformScript?
    /// WPE SceneScript attached to this layer's `angles` field. Runtime
    /// evaluation drives scene-control rigs such as mouse drag rotation.
    public let anglesScript: WPESceneTransformScript?
    /// WPE SceneScript attached to this layer's `color` field. Returns a Vec3 in
    /// 0…1 linear RGB, ticked by the same runtime as scale/angles.
    public let colorScript: WPESceneTransformScript?
    /// Resolved scriptProperty overrides for `visibleScript` (user-bound values
    /// like `ruchang` overlaid on the script's declared defaults).
    public let scriptProperties: [String: WPESceneScriptPropertyValue]
    /// Perspective-quad corners for a `shape: "quad"` layer that has no image and
    /// draws a DIRECTDRAW effect (e.g. lightshafts light beams). Each entry is a
    /// normalized `point0..3` from the effect's `EffectPerspectiveUV` gizmo. When
    /// present the renderer synthesizes a 4-corner quad from these instead of the
    /// axis-aligned object quad. `nil` for ordinary image/model layers.
    public let shapePoints: [SIMD2<Double>]?

    public init(
        id: String,
        name: String,
        imageRelativePath: String,
        materialRelativePath: String?,
        materialInstance: WPESceneMaterialInstance? = nil,
        config: WPESceneImageConfig = WPESceneImageConfig(),
        disablePropagation: Bool = false,
        solid: Bool = false,
        copyBackground: Bool = true,
        parentObjectID: String? = nil,
        attachment: String? = nil,
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        localOrigin: SIMD3<Double>? = nil,
        localScale: SIMD3<Double>? = nil,
        localAngles: SIMD3<Double>? = nil,
        visible: Bool,
        alpha: Double,
        alphaAnimation: WPESceneAnimatedValue? = nil,
        color: SIMD3<Double>,
        colorAnimation: WPESceneAnimatedValue? = nil,
        brightness: Double,
        blendMode: WPESceneBlendMode,
        colorBlendMode: Int = 0,
        alignment: WPESceneAlignment,
        size: CGSize?,
        dependencies: [String] = [],
        effects: [WPESceneImageEffect],
        animationLayers: [WPESceneAnimationLayer],
        parallaxDepth: SIMD2<Double> = SIMD2<Double>(0, 0),
        visibleScript: String? = nil,
        alphaScript: String? = nil,
        alphaScriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        originScript: WPESceneTransformScript? = nil,
        scaleScript: WPESceneTransformScript? = nil,
        anglesScript: WPESceneTransformScript? = nil,
        colorScript: WPESceneTransformScript? = nil,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        shapePoints: [SIMD2<Double>]? = nil
    ) {
        self.id = id
        self.name = name
        self.imageRelativePath = imageRelativePath
        self.materialRelativePath = materialRelativePath
        self.materialInstance = materialInstance
        self.config = config
        self.disablePropagation = disablePropagation
        self.solid = solid
        self.copyBackground = copyBackground
        self.parentObjectID = parentObjectID
        self.attachment = attachment
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.localOrigin = localOrigin ?? origin
        self.localScale = localScale ?? scale
        self.localAngles = localAngles ?? angles
        self.visible = visible
        self.alpha = alpha
        self.alphaAnimation = alphaAnimation
        self.color = color
        self.colorAnimation = colorAnimation
        self.brightness = brightness
        self.blendMode = blendMode
        self.colorBlendMode = colorBlendMode
        self.alignment = alignment
        self.size = size
        self.dependencies = dependencies
        self.effects = effects
        self.animationLayers = animationLayers
        self.parallaxDepth = parallaxDepth
        self.visibleScript = visibleScript
        self.alphaScript = alphaScript
        self.alphaScriptProperties = alphaScriptProperties
        self.originScript = originScript
        self.scaleScript = scaleScript
        self.anglesScript = anglesScript
        self.colorScript = colorScript
        self.scriptProperties = scriptProperties
        self.shapePoints = shapePoints
    }

    public func resolvedAlpha(at time: Double) -> Double {
        alphaAnimation?.scalar(at: time) ?? alpha
    }
}

public struct WPESceneImageEffect: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let fileRelativePath: String
    public let visible: Bool
    public let passOverrides: [WPESceneEffectPassOverride]
    /// SceneScript bound to this effect's visibility. Parsed and preserved; the
    /// renderer does NOT yet re-gate on its live value, because the graph bakes
    /// the composite ping-pong from the visible set at build time — skipping an
    /// effect's passes mid-chain leaves the next pass sampling an FBO nothing
    /// wrote. `visible` above is the authored seed and IS honoured.
    public let visibleScript: WPESceneTransformScript?

    public init(
        id: String,
        name: String,
        fileRelativePath: String,
        visible: Bool,
        passOverrides: [WPESceneEffectPassOverride],
        visibleScript: WPESceneTransformScript? = nil
    ) {
        self.id = id
        self.name = name
        self.fileRelativePath = fileRelativePath
        self.visible = visible
        self.passOverrides = passOverrides
        self.visibleScript = visibleScript
    }

    public var isShakeEffect: Bool {
        let normalizedFile = fileRelativePath.lowercased()
        let normalizedName = name.lowercased()
        return normalizedFile.contains("/shake/")
            || normalizedFile.hasSuffix("shake/effect.json")
            || normalizedName == "shake"
    }
}

public struct WPESceneEffectPassOverride: Equatable, Sendable {
    public let id: Int?
    public let combos: [String: Int]
    public let constants: [String: WPESceneShaderConstantValue]
    public let textures: [Int: String]
    /// Dynamic texture-provider declarations at the object/effect override
    /// locus. Kept separate from static texture slots until provider precedence
    /// and lifetime have an L1 contract.
    public let userTextures: [WPESceneUserTextureBinding]
    /// SceneScripts bound to individual shader constants ("bind a script to any
    /// shader property"). `constants` still carries the authored seed, so a
    /// script that fails to load leaves the pass exactly as authored.
    public let constantScripts: [String: WPESceneTransformScript]

    public init(
        id: Int?,
        combos: [String: Int],
        constants: [String: WPESceneShaderConstantValue],
        textures: [Int: String],
        userTextures: [WPESceneUserTextureBinding] = [],
        constantScripts: [String: WPESceneTransformScript] = [:]
    ) {
        self.id = id
        self.combos = combos
        self.constants = constants
        self.textures = textures
        self.userTextures = userTextures
        self.constantScripts = constantScripts
    }
}

public struct WPESceneAnimationKeyframe: Equatable, Sendable {
    public let frame: Double
    public let value: Double

    public init(frame: Double, value: Double) {
        self.frame = frame
        self.value = value
    }
}

public struct WPESceneNumericAnimation: Equatable, Sendable {
    public let tracks: [[WPESceneAnimationKeyframe]]
    public let fps: Double
    public let length: Double
    public let mode: String
    public let wrapLoop: Bool

    public init(
        tracks: [[WPESceneAnimationKeyframe]],
        fps: Double,
        length: Double,
        mode: String,
        wrapLoop: Bool
    ) {
        self.tracks = tracks.map { $0.sorted { $0.frame < $1.frame } }
        self.fps = fps > 0 ? fps : 30
        self.length = max(0, length)
        self.mode = mode.lowercased()
        self.wrapLoop = wrapLoop
    }

    public func values(at time: Double, fallbacks: [Double]) -> [Double] {
        guard !tracks.isEmpty else { return fallbacks }
        let frame = effectiveFrame(at: time)
        return tracks.enumerated().map { index, track in
            value(in: track, atFrame: frame, fallback: fallbacks[safe: index] ?? fallbacks.first ?? 0)
        }
    }

    private func effectiveFrame(at time: Double) -> Double {
        let rawFrame = max(0, time) * fps
        if shouldLoop, length > 0 {
            let wrapped = rawFrame.truncatingRemainder(dividingBy: length)
            return wrapped >= 0 ? wrapped : wrapped + length
        }
        let lastTrackFrame = tracks
            .compactMap(\.last?.frame)
            .max() ?? 0
        let clampFrame = length > 0 ? max(length, lastTrackFrame) : lastTrackFrame
        return min(max(rawFrame, 0), clampFrame)
    }

    private var shouldLoop: Bool {
        wrapLoop || mode == "loop" || mode == "mirror"
    }

    private func value(
        in track: [WPESceneAnimationKeyframe],
        atFrame frame: Double,
        fallback: Double
    ) -> Double {
        guard let first = track.first else { return fallback }
        if frame <= first.frame { return first.value }
        guard let last = track.last else { return first.value }
        if frame >= last.frame { return last.value }

        for index in 0..<(track.count - 1) {
            let start = track[index]
            let end = track[index + 1]
            guard frame >= start.frame && frame <= end.frame else { continue }
            let span = max(end.frame - start.frame, 0.0001)
            let t = min(max((frame - start.frame) / span, 0), 1)
            return start.value + (end.value - start.value) * t
        }
        return last.value
    }
}

public struct WPESceneAnimatedValue: Equatable, Sendable {
    public let animation: WPESceneNumericAnimation
    public let scalarFallback: Double?
    public let vectorFallback: [Double]?

    public init(
        animation: WPESceneNumericAnimation,
        scalarFallback: Double?,
        vectorFallback: [Double]?
    ) {
        self.animation = animation
        self.scalarFallback = scalarFallback
        self.vectorFallback = vectorFallback
    }

    public func resolvedValue(at time: Double) -> WPESceneShaderConstantValue {
        if let vectorFallback, animation.tracks.count > 1 {
            return .vector(animation.values(at: time, fallbacks: vectorFallback))
        }
        return .number(scalar(at: time) ?? scalarFallback ?? 0)
    }

    public func scalar(at time: Double) -> Double? {
        let fallback = scalarFallback ?? vectorFallback?.first ?? 0
        return animation.values(at: time, fallbacks: [fallback]).first
    }

    public func vector(at time: Double) -> [Double]? {
        guard let vectorFallback else {
            return scalar(at: time).map { [$0] }
        }
        return animation.values(at: time, fallbacks: vectorFallback)
    }
}

public enum WPESceneShaderConstantValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case vector([Double])
    case animated(WPESceneAnimatedValue)

    public var numberValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .animated(let value):
            return value.scalar(at: 0)
        default:
            return nil
        }
    }

    public var vectorValue: [Double]? {
        switch self {
        case .vector(let value):
            return value
        case .animated(let value):
            return value.vector(at: 0)
        default:
            return nil
        }
    }

    public func resolved(at time: Double) -> WPESceneShaderConstantValue {
        if case .animated(let value) = self {
            return value.resolvedValue(at: time)
        }
        return self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public struct WPESceneAnimationLayer: Equatable, Sendable, Identifiable {
    public let id: Int
    public let rate: Double
    public let visible: Bool
    public let blend: Double
    public let animation: Int
    /// Composed ADDITIVELY on top of the base (non-additive) layer — e.g. a
    /// blink/face layer over an idle-sway base. Drives multi-layer palette blending.
    public let additive: Bool

    public init(id: Int, rate: Double, visible: Bool, blend: Double, animation: Int, additive: Bool = false) {
        self.id = id
        self.rate = rate
        self.visible = visible
        self.blend = blend
        self.animation = animation
        self.additive = additive
    }
}

public enum WPESceneAlignment: String, Equatable, Sendable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case top
    case bottom
    case left
    case right

    public init(rawWPEValue raw: String?) {
        switch raw?.lowercased() {
        case "topleft", "top left":         self = .topLeft
        case "topright", "top right":       self = .topRight
        case "bottomleft", "bottom left":   self = .bottomLeft
        case "bottomright", "bottom right": self = .bottomRight
        case "top":                         self = .top
        case "bottom":                      self = .bottom
        case "left":                        self = .left
        case "right":                       self = .right
        default:                            self = .center
        }
    }
}

public enum WPESceneBlendMode: String, Equatable, Sendable {
    case normal
    case translucent
    case additive
    case multiply
    case screen

    public init(rawWPEValue raw: String?) {
        switch raw?.lowercased() {
        case "translucent": self = .translucent
        case "additive":    self = .additive
        case "multiply":    self = .multiply
        case "screen":      self = .screen
        default:            self = .normal
        }
    }

    /// The subset of WPE's `common_blending.h` BLENDMODE enum that a Metal
    /// fixed-function blend descriptor can express exactly. `nil` means the mode
    /// is a *function of the destination* (Overlay, Soft Light, Color Burn, …)
    /// and can only be reproduced by sampling the scene and running
    /// `ApplyBlending` in the fragment shader, exactly as WPE itself does
    /// (`genericimage4.frag` binds `_rt_FullFrameBuffer` to `g_Texture4` under
    /// `#if BLENDMODE` — RenderDoc-confirmed on 3448877775 pass 41).
    ///
    /// Returning `.normal` for an unmapped mode is NOT a safe default: a
    /// full-screen tint layer then paints opaque over the whole wallpaper.
    public static func fixedFunction(forWPEBlendMode raw: Int) -> WPESceneBlendMode? {
        switch raw {
        case 0:     return .normal
        case 2:     return .multiply
        case 7:     return .screen
        // 9 = Add `min(A+B,1)`; 31 = `A + B*opacity` — both are the premultiplied
        // one/one add once the source carries its own alpha.
        case 9, 31: return .additive
        default:    return nil
        }
    }
}
