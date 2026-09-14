import CoreGraphics
import Foundation
import LiveWallpaperCore

public struct WPESceneDocument: Equatable, Sendable {
    public let sourceJSON: WPESceneJSONValue
    public let camera: WPESceneCamera
    public let authoredCamera: WPESceneAuthoredCamera
    public let authoredCameraObjects: [WPESceneAuthoredCameraObject]
    public let general: WPESceneGeneral
    /// `var` so the renderer can append synthetic image layers from `textObjects` before the graph is built; nothing else mutates a parsed document.
    public var imageObjects: [WPESceneImageObject]
    public let scriptHostObjects: [WPESceneScriptHostObject]
    public let transformHostObjects: [WPESceneTransformHostObject]
    public let particleObjects: [WPESceneParticleObject]
    public let textObjects: [WPESceneTextObject]
    public let soundObjects: [WPESceneSoundObject]
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
        sourceJSON: WPESceneJSONValue = .object([:]),
        camera: WPESceneCamera,
        authoredCamera: WPESceneAuthoredCamera = .empty,
        authoredCameraObjects: [WPESceneAuthoredCameraObject] = [],
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
        self.sourceJSON = sourceJSON
        self.camera = camera
        self.authoredCamera = authoredCamera
        self.authoredCameraObjects = authoredCameraObjects
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
    /// Keyframed `origin`; the `origin` field is only the authored static `value` seed.
    public let originAnimation: WPESceneAnimatedValue?
    public let originScript: WPESceneTransformScript?
    public let scaleScript: WPESceneTransformScript?
    public let anglesScript: WPESceneTransformScript?
    /// Camera-parallax depth authored on the group: WPE moves a parented subtree by its topmost ancestor's depth, usually a group.
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

/// Non-rendered SceneScript host (`solid:true` controllers). Must run with layer scripts but produces no draw passes.
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

/// `action` is `.incremental` (in-place patch) or `.reload`. `condition` non-nil ⇒ visible only while `userValues[propertyKey]` matches; nil ⇒ the property drives the target directly.
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
    /// Reloads the scene so the parser can re-fold the group through every descendant; there is no duplicate incremental planner.
    case groupObject(id: String)
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
    /// User property injected into a SceneScript's `scriptProperties`. Keeping name + role prevents mistaking it for a direct visible/alpha binding.
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
    /// Effective initial visibility after folding own value with ancestor groups. WPE only auto-starts while this is true.
    public let visible: Bool
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

/// Unknown authored values stay explicit so a future renderer cannot silently pack them as point lights.
public enum WPESceneLightType: Equatable, Sendable {
    case point
    case spot
    case directional
    case unknown(String)

    public var knownShaderArrayValue: Int? {
        switch self {
        case .point: 0
        case .spot: 1
        case .directional: 2
        case .unknown: nil
        }
    }
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

/// WPE sliders are numeric; checkboxes are bools and combos/text are strings.
public enum WPESceneScriptPropertyValue: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
}

/// Static scripts are evaluated once by the parser; dynamic scripts are retained for the renderer to tick with live inputs.
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
    /// Per-object scriptProperty overrides so the text script uses the scene's configuration, not the script's declared defaults.
    public let scriptProperties: [String: WPESceneScriptPropertyValue]
    public let fontRelativePath: String?
    public let pointSize: Double
    public let color: SIMD3<Double>
    /// Object-level `brightness` colour multiplier; 1 = unchanged. Multiplied into the text colour by both draw paths.
    public let brightness: Double
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    /// Static author-space rotation in radians (`angles` in scene.json). Text objects rotate like image layers.
    public let angles: SIMD3<Double>
    public let visible: Bool
    public let horizontalAlignment: String
    public let verticalAlignment: String
    public let maxWidth: Double?
    /// `maxRows` is nil when the Limit-rows toggle is off. Without a cap CoreText wraps until every character fits.
    public let maxRows: Int?
    /// WPE "Use ellipsis": append "…" when the text was clipped by `maxRows`.
    public let limitUseEllipsis: Bool
    /// Per-axis camera-parallax depth (Vec2 "x y"). "1 0" horizontal only, "0 1" vertical only. `.zero` pins the layer.
    public let parallaxDepth: SIMD2<Double>
    /// Editor-measured text FBO size: layout OUTPUT, not input. Nothing in the render path may read it (glyphs at pointsize×300/72 on `origin`; see `WPETextLayoutEngine`). Kept only because SceneScript `layer.size` reports it.
    public let boxSize: SIMD2<Double>?
    /// Transparent margin in scene pixels around the glyph block. Does not shift the text anchor; the authored `size` box is an editor artifact and is not parsed.
    public let padding: Double
    /// Copies the scene region behind the text into the offscreen surface before
    /// glyph drawing. This is also an offscreen-rendering discriminator in WPE.
    public let copyBackground: Bool
    /// Fills the text surface with `backgroundColor × backgroundBrightness`
    /// before glyph drawing. Opaque-background text can never use Direct mode.
    public let opaqueBackground: Bool
    public let backgroundColor: SIMD3<Double>
    public let backgroundBrightness: Double
    public let effects: [WPESceneImageEffect]
    public let letterSpacing: Double
    /// `origin` is parse-time WORLD; `localOrigin` is pre-composition LOCAL. When the parent chain moves, re-compose `localOrigin` through live parent transforms.
    public let parentObjectID: String?
    public let localOrigin: SIMD3<Double>?
    /// `scale` is parse-time WORLD; `localScale` is this object's own authored scale. A `scale` SceneScript returns LOCAL, so the renderer needs both.
    public let localScale: SIMD3<Double>?
    /// Script-driven alpha/visible on text. The baked `alpha`/`visible` fields are only load-time seeds.
    public let alphaScript: String?
    public let alphaScriptProperties: [String: WPESceneScriptPropertyValue]
    public let visibleScript: String?
    public let visibleScriptProperties: [String: WPESceneScriptPropertyValue]
    /// Dynamic `origin` SceneScript; nil when the origin is static (resolved at parse).
    public let originScript: WPESceneTransformScript?
    /// WPE SceneScript attached to `color`. Returns a Vec3 in 0…1 linear RGB, so
    /// the renderer ticks it through the same Vec3 machinery as scale/angles.
    public let colorScript: WPESceneTransformScript?
    /// Text objects are not transform hosts; these scripts are their only route to a scripted scale.
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

    /// `liveColor` is the `color` SceneScript output; nil keeps the authored tint.
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
    /// Parent object so a transform host with keyframed `origin` can move this emitter. Particles are not render layers, so without this the emitter stays at parse-time origin.
    public let parentObjectID: String?
    public let particleRelativePath: String
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let visible: Bool
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let color: SIMD3<Double>
    /// Object-level `brightness` colour multiplier; 1 = unchanged. Folded into the particle overbright uniform.
    public let brightness: Double
    /// Per-axis camera-parallax depth (Vec2 "x y"). "1 0" horizontal only, "0 1" vertical only. `.zero` pins the layer.
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

}

public struct WPESceneParticleInstanceOverride: Equatable, Sendable {
    public let count: Double?
    public let rate: Double?
    public let lifetime: Double?
    public let size: Double?
    public let speed: Double?
    public let alpha: Double?
    /// HDR multiplier on generated particle vertex RGB. Windows keeps material `g_Overbright` unchanged and bakes this into COLOR.rgb instead.
    public let brightness: Double?
    /// Override color in the same 0...255 space as particle definitions.
    public let color: SIMD3<Double>?
    /// Keyframed `alpha` override; `alpha` above is only the static seed.
    public let alphaAnimation: WPESceneAnimatedValue?
    /// `controlpointN`: per-instance replacement of the definition's control-point offsets, keyed by N. An authored control point with no `offset` defaults to 0,0,0.
    public let controlPointOffsets: [Int: SIMD3<Double>]
    /// Script-driven `alpha` override; `alpha` above is only the seed.
    public let alphaScript: String?
    public let alphaScriptProperties: [String: WPESceneScriptPropertyValue]

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
        controlPointOffsets: [Int: SIMD3<Double>] = [:],
        alphaScript: String? = nil,
        alphaScriptProperties: [String: WPESceneScriptPropertyValue] = [:]
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
        self.alphaScript = alphaScript
        self.alphaScriptProperties = alphaScriptProperties
    }
}

public struct WPESceneAuthoredCamera: Equatable, Sendable {
    public let sourceJSON: WPESceneJSONValue
    /// Ordered camera-path asset references. No default is inferred: nil means
    /// the key was absent, while `.value([])` means the author wrote an empty list.
    public let paths: WPESceneAuthoredJSONField<[String]>?

    public init(
        sourceJSON: WPESceneJSONValue = .object([:]),
        paths: WPESceneAuthoredJSONField<[String]>? = nil
    ) {
        self.sourceJSON = sourceJSON
        self.paths = paths
    }

    public static let empty = WPESceneAuthoredCamera()
}

public struct WPESceneAuthoredCameraObject: Equatable, Sendable {
    public let sourceObjectIndex: Int
    public let sourceJSON: WPESceneJSONValue
    public let camera: WPESceneAuthoredJSONField<String>?
    public let path: WPESceneAuthoredJSONField<String>?
    public let queueMode: WPESceneAuthoredJSONField<String>?
    public let origin: WPESceneAuthoredJSONField<SIMD3<Double>>?
    public let angles: WPESceneAuthoredJSONField<SIMD3<Double>>?
    public let fov: WPESceneAuthoredJSONField<Double>?
    public let zoom: WPESceneAuthoredJSONField<Double>?

    public init(
        sourceObjectIndex: Int,
        sourceJSON: WPESceneJSONValue,
        camera: WPESceneAuthoredJSONField<String>? = nil,
        path: WPESceneAuthoredJSONField<String>? = nil,
        queueMode: WPESceneAuthoredJSONField<String>? = nil,
        origin: WPESceneAuthoredJSONField<SIMD3<Double>>? = nil,
        angles: WPESceneAuthoredJSONField<SIMD3<Double>>? = nil,
        fov: WPESceneAuthoredJSONField<Double>? = nil,
        zoom: WPESceneAuthoredJSONField<Double>? = nil
    ) {
        self.sourceObjectIndex = sourceObjectIndex
        self.sourceJSON = sourceJSON
        self.camera = camera
        self.path = path
        self.queueMode = queueMode
        self.origin = origin
        self.angles = angles
        self.fov = fov
        self.zoom = zoom
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

/// Raw scene.json bloom numbers. Executor derives cbuffer forms: `g_BloomStrength = strength/17`, knee from threshold/feather.
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

/// `condition` is non-nil for selector-form `{ user: { name, condition }, value }`.
public struct WPESceneAuthoredUserBinding: Equatable, Sendable {
    public let propertyKey: String
    public let condition: String?

    public init(propertyKey: String, condition: String? = nil) {
        self.propertyKey = propertyKey
        self.condition = condition
    }
}

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
    public let zoom: Double
    public let zoomField: WPESceneAuthoredField<Double>
    public let perspectiveOverrideFOV: WPESceneAuthoredField<Double>
    public let cameraShake: WPESceneCameraShakeSettings
    public let clearEnabled: WPESceneAuthoredField<Bool>
    public let wind: WPESceneWindSettings
    public let gravity: WPESceneGravitySettings
    public let cameraParallax: WPESceneCameraParallaxSettings
    /// `general.supportsaudioprocessing`: a shader/effect samples `g_AudioSpectrum*`. Keeps the view on the continuous-frame path so the visualizer does not freeze on the static/on-demand path.
    public let supportsAudioProcessing: Bool
    /// `g_LightAmbientColor` / `g_LightSkylightColor`, uploaded raw (no sRGB). Default white so unauthored scenes keep the pre-lighting look.
    public let lightAmbientColor: SIMD3<Double>
    public let lightSkylightColor: SIMD3<Double>
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

/// Scene-level camera parallax: the scene follows the cursor; each layer shifts by its `parallaxDepth`. Defaults match WPE. Disabled (no-op) by default.
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

/// Missing `type` is the older bare-string form; typed entries name system media or user-shortcut providers.
public struct WPESceneUserTextureBinding: Equatable, Sendable {
    public let name: String
    public let type: String?
    /// `slot` IS the texture slot: the array is positional against sibling `textures`, and authors leave `null` in slots they do not override. nil only for bindings constructed outside a parsed array.
    public let slot: Int?

    public init(name: String, type: String? = nil, slot: Int? = nil) {
        self.name = name
        self.type = type
        self.slot = slot
    }
}

/// Merged over the image asset's base material after load; empty texture slots do not replace the base.
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
    public let materialInstance: WPESceneMaterialInstance?
    public let config: WPESceneImageConfig
    public let disablePropagation: Bool
    public let solid: Bool
    /// In an otherwise orthographic scene this object is projected through the scene's perspective camera instead of the ortho canvas matrix.
    public let usesPerspectiveProjection: Bool
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
    /// A blend that reads the destination cannot ride a Metal blend descriptor. `blendMode` is `.normal` for these — drawing with it paints an opaque rectangle over the scene.
    public var usesProgrammableBlend: Bool {
        WPESceneBlendMode.fixedFunction(forWPEBlendMode: colorBlendMode) == nil
    }
    public let blendMode: WPESceneBlendMode
    /// Raw `common_blending.h` BLENDMODE index. `blendMode` is only the fixed-function subset; modes 11 Overlay, 12 Soft Light, … must run programmable `ApplyBlending` keyed on this number.
    public let colorBlendMode: Int
    public let alignment: WPESceneAlignment
    public let size: CGSize?
    public let dependencies: [String]
    public let effects: [WPESceneImageEffect]
    public let animationLayers: [WPESceneAnimationLayer]
    /// Per-axis camera-parallax depth (Vec2 "x y"). "1 0" horizontal only, "0 1" vertical only. `.zero` pins the layer.
    public let parallaxDepth: SIMD2<Double>
    /// SceneScript on `visible`; `nil` for static visibility. May drive visibility/alpha and any video texture.
    public let visibleScript: String?
    /// Alpha scripts return the live alpha from `update(value)` and must not change layer visibility.
    public let alphaScript: String?
    public let alphaScriptProperties: [String: WPESceneScriptPropertyValue]
    /// Dynamic WPE SceneScript attached to this layer's `origin` field. Static
    /// origin scripts are resolved at parse time and leave this nil.
    public let originScript: WPESceneTransformScript?
    /// Scale scripts are evaluated at runtime even when the serialized fallback looks static.
    public let scaleScript: WPESceneTransformScript?
    public let anglesScript: WPESceneTransformScript?
    /// WPE SceneScript attached to this layer's `color` field. Returns a Vec3 in
    /// 0…1 linear RGB, ticked by the same runtime as scale/angles.
    public let colorScript: WPESceneTransformScript?
    public let scriptProperties: [String: WPESceneScriptPropertyValue]
    /// Normalized `point0..3` for a `shape: "quad"` DIRECTDRAW layer. When present the renderer synthesizes a 4-corner quad instead of the axis-aligned object quad. `nil` for ordinary image/model layers.
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
        usesPerspectiveProjection: Bool = false,
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
        self.usesPerspectiveProjection = usesPerspectiveProjection
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
}

public struct WPESceneImageEffect: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let fileRelativePath: String
    public let visible: Bool
    public let passOverrides: [WPESceneEffectPassOverride]
    /// Parsed and preserved; the renderer does not yet re-gate on the live value, because skipping an effect mid-chain leaves the next pass sampling an FBO nothing wrote. Authored `visible` seed IS honoured.
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
}

public struct WPESceneEffectPassOverride: Equatable, Sendable {
    public let id: Int?
    public let combos: [String: Int]
    public let constants: [String: WPESceneShaderConstantValue]
    public let textures: [Int: String]
    public let userTextures: [WPESceneUserTextureBinding]
    /// `constants` still carries the authored seed, so a script that fails to load leaves the pass exactly as authored.
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

/// Absent dictionary key ⇒ absent (`nil`) field; authored JSON null, a decoded value, and an unexpected shape remain distinct.
public enum WPESceneAuthoredJSONField<Value: Equatable & Sendable>: Equatable, Sendable {
    case null
    case value(Value)
    case unparsed(WPESceneJSONValue)
}

public struct WPESceneAnimationTangent: Equatable, Sendable {
    public let enabled: WPESceneAuthoredJSONField<Bool>?
    public let x: WPESceneAuthoredJSONField<Double>?
    public let y: WPESceneAuthoredJSONField<Double>?
    /// Opaque editor marker. Corpus authors JSON booleans while another parser models an integer, so retaining the JSON type is the lossless representation.
    public let magic: WPESceneJSONValue?

    public init(
        enabled: WPESceneAuthoredJSONField<Bool>? = nil,
        x: WPESceneAuthoredJSONField<Double>? = nil,
        y: WPESceneAuthoredJSONField<Double>? = nil,
        magic: WPESceneJSONValue? = nil
    ) {
        self.enabled = enabled
        self.x = x
        self.y = y
        self.magic = magic
    }
}

public struct WPESceneAnimationEvent: Equatable, Sendable {
    public let name: WPESceneAuthoredJSONField<String>?
    public let frame: WPESceneAuthoredJSONField<Double>?

    public init(
        name: WPESceneAuthoredJSONField<String>? = nil,
        frame: WPESceneAuthoredJSONField<Double>? = nil
    ) {
        self.name = name
        self.frame = frame
    }
}

public struct WPESceneAnimationKeyframe: Equatable, Sendable {
    public let frame: Double
    public let value: Double
    public let lockAngle: WPESceneAuthoredJSONField<Bool>?
    public let lockLength: WPESceneAuthoredJSONField<Bool>?
    public let front: WPESceneAuthoredJSONField<WPESceneAnimationTangent>?
    public let back: WPESceneAuthoredJSONField<WPESceneAnimationTangent>?

    public init(
        frame: Double,
        value: Double,
        lockAngle: WPESceneAuthoredJSONField<Bool>? = nil,
        lockLength: WPESceneAuthoredJSONField<Bool>? = nil,
        front: WPESceneAuthoredJSONField<WPESceneAnimationTangent>? = nil,
        back: WPESceneAuthoredJSONField<WPESceneAnimationTangent>? = nil
    ) {
        self.frame = frame
        self.value = value
        self.lockAngle = lockAngle
        self.lockLength = lockLength
        self.front = front
        self.back = back
    }
}

public struct WPESceneNumericAnimation: Equatable, Sendable {
    public let tracks: [[WPESceneAnimationKeyframe]]
    public let fps: Double
    public let length: Double
    public let mode: String
    public let wrapLoop: Bool
    public let name: WPESceneAuthoredJSONField<String>?
    public let startPaused: WPESceneAuthoredJSONField<Bool>?
    public let events: WPESceneAuthoredJSONField<[WPESceneAnimationEvent]>?

    public init(
        tracks: [[WPESceneAnimationKeyframe]],
        fps: Double,
        length: Double,
        mode: String,
        wrapLoop: Bool,
        name: WPESceneAuthoredJSONField<String>? = nil,
        startPaused: WPESceneAuthoredJSONField<Bool>? = nil,
        events: WPESceneAuthoredJSONField<[WPESceneAnimationEvent]>? = nil
    ) {
        self.tracks = tracks.map { $0.sorted { $0.frame < $1.frame } }
        self.fps = fps > 0 ? fps : 30
        self.length = max(0, length)
        self.mode = mode.lowercased()
        self.wrapLoop = wrapLoop
        self.name = name
        self.startPaused = startPaused
        self.events = events
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
        // Mirror is one full forward traversal then an equally long reverse, repeating. Keep both turn-around endpoints: at `length` sample the last frame; at `2 * length` sample the first before the next forward leg. Zero-length/single-frame bypasses the remainder and uses the clamped sampler.
        if mode == "mirror", length > 0 {
            let period = 2 * length
            let phase = rawFrame.truncatingRemainder(dividingBy: period)
            return phase <= length ? phase : period - phase
        }
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
        wrapLoop || mode == "loop"
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

    /// `nil` means the mode is a function of the destination and can only be reproduced by sampling the scene and running `ApplyBlending`. Returning `.normal` for an unmapped mode is not a safe default: a full-screen tint then paints opaque over the wallpaper.
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
