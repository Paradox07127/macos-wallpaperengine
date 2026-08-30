import CoreGraphics
import Foundation

/// Renderer-neutral WPE IR (material/effect/pass/FBO — not named effects).
public struct WPERenderGraph: Equatable, Sendable {
    public let layers: [WPERenderLayer]

    public init(layers: [WPERenderLayer]) {
        self.layers = layers
    }
}

/// Complete authored JSON that contributed to one render layer.
///
/// `sceneObjects` is ordered from the outermost authored ancestor to the
/// rendered object itself. `imageDescriptor` is the root dictionary loaded
/// from the object's JSON image/model path (typically `models/*.json`). These
/// values are preservation-only metadata: their presence does not imply that
/// unknown fields have a native runtime consumer.
public struct WPERenderLayerAuthoredJSON: Equatable, Sendable {
    public let sceneObjects: [WPESceneJSONValue]
    public let imageDescriptor: WPESceneJSONValue?

    public init(
        sceneObjects: [WPESceneJSONValue] = [],
        imageDescriptor: WPESceneJSONValue? = nil
    ) {
        self.sceneObjects = sceneObjects
        self.imageDescriptor = imageDescriptor
    }

    public static let empty = WPERenderLayerAuthoredJSON()
}

public struct WPERenderLayer: Equatable, Sendable, Identifiable {
    public var id: String { objectID }

    public let objectID: String
    public let objectName: String
    /// Keep hidden layers in the graph (composites/dependents); executor skips draw.
    public let visible: Bool
    public let imagePath: String
    public let materialPath: String?
    public let puppetPath: String?
    /// Object this layer attaches to (the parent puppet for body-split rigs). `nil` for roots.
    public let parentObjectID: String?
    /// Named MDAT anchor on the parent puppet this layer follows. `nil` when unattached.
    public let attachment: String?
    /// Scene `animationlayers` for this object, selecting which puppet MDLA animation(s) play.
    public let animationLayers: [WPESceneAnimationLayer]
    /// Lossless authored object ancestry and image/model descriptor. Metadata
    /// only; typed fields below remain the renderer's consumed representation.
    public let authoredJSON: WPERenderLayerAuthoredJSON
    public let geometry: WPERenderLayerGeometry
    /// Pre-inheritance geometry retained so an attached child can re-derive its placement from the
    /// parent puppet's animated anchor bone. `nil` for layers that need no attachment-following.
    public let localGeometry: WPERenderLayerGeometry?
    public let compositeA: String
    public let compositeB: String
    public let localFBOs: [WPERenderFBO]
    public let passes: [WPERenderPass]
    /// Offscreen group target this layer's final scene pass is redirected into. The executor uses
    /// `groupLocalGeometry` when drawing to this target, so child layers are placed inside the
    /// composelayer-local render target instead of the global scene.
    public let groupRenderTarget: String?
    public let groupLocalGeometry: WPERenderLayerGeometry?
    /// For a composelayer that owns a child group, this names the group target sampled by its
    /// material pass before the composelayer's own effects and final scene composite.
    public let groupCompositeSource: String?
    /// Per-axis camera-parallax depth (WPE Vec2). Each axis scales independently;
    /// `.zero` pins the layer. Inherited from the root attachment ancestor by the
    /// graph builder so a rigid puppet subtree shifts as one unit.
    public let parallaxDepth: SIMD2<Double>
    /// Original scene-object paint index. Earlier indices paint behind later
    /// ones; particles interleave against this in the executor.
    public let sortIndex: Int
    /// Derived from `imagePath` in `init`, not an init parameter — copies cannot drop it.
    public let utilityModelKind: WPEUtilityModelKind?

    public init(
        objectID: String,
        objectName: String,
        visible: Bool = true,
        imagePath: String,
        materialPath: String?,
        puppetPath: String? = nil,
        parentObjectID: String? = nil,
        attachment: String? = nil,
        animationLayers: [WPESceneAnimationLayer] = [],
        authoredJSON: WPERenderLayerAuthoredJSON = .empty,
        geometry: WPERenderLayerGeometry,
        localGeometry: WPERenderLayerGeometry? = nil,
        compositeA: String,
        compositeB: String,
        localFBOs: [WPERenderFBO],
        passes: [WPERenderPass],
        groupRenderTarget: String? = nil,
        groupLocalGeometry: WPERenderLayerGeometry? = nil,
        groupCompositeSource: String? = nil,
        parallaxDepth: SIMD2<Double> = SIMD2<Double>(0, 0),
        sortIndex: Int = 0
    ) {
        self.objectID = objectID
        self.objectName = objectName
        self.visible = visible
        self.imagePath = imagePath
        self.materialPath = materialPath
        self.puppetPath = puppetPath
        self.parentObjectID = parentObjectID
        self.attachment = attachment
        self.animationLayers = animationLayers
        self.authoredJSON = authoredJSON
        self.geometry = geometry
        self.localGeometry = localGeometry
        self.compositeA = compositeA
        self.compositeB = compositeB
        self.localFBOs = localFBOs
        self.passes = passes
        self.groupRenderTarget = groupRenderTarget
        self.groupLocalGeometry = groupLocalGeometry
        self.groupCompositeSource = groupCompositeSource
        self.parallaxDepth = parallaxDepth
        self.sortIndex = sortIndex
        utilityModelKind = WPEUtilityModelKind.classify(imagePath)
    }

    /// True for `composelayer` / `projectlayer` / `fullscreenlayer`.
    public var isUtilityModelLayer: Bool { utilityModelKind != nil }
}

public struct WPERenderLayerGeometry: Equatable, Sendable {
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let alignment: WPESceneAlignment
    public let size: CGSize?
    /// Raw MDLV mesh-bbox center (puppet model coordinates) subtracted in the
    /// puppet vertex shader so the mesh is centered in its mesh-bbox-sized local
    /// composite. Zero for non-puppet layers and puppets that fit `size`.
    public let puppetMeshCenter: SIMD2<Double>
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let color: SIMD3<Double>
    public let colorAnimation: WPESceneAnimatedValue?
    public let brightness: Double
    /// Normalized perspective-quad corners (`point0..3`) for a `shape: "quad"`
    /// DIRECTDRAW effect layer. Non-nil routes the pass through the 4-corner
    /// `wpe_shape_quad_vertex` geometry instead of the axis-aligned object quad.
    public let shapePoints: [SIMD2<Double>]?

    public init(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        alignment: WPESceneAlignment,
        size: CGSize?,
        puppetMeshCenter: SIMD2<Double> = SIMD2<Double>(0, 0),
        alpha: Double,
        alphaAnimation: WPESceneAnimatedValue? = nil,
        color: SIMD3<Double>,
        colorAnimation: WPESceneAnimatedValue? = nil,
        brightness: Double,
        shapePoints: [SIMD2<Double>]? = nil
    ) {
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.alignment = alignment
        self.size = size
        self.puppetMeshCenter = puppetMeshCenter
        self.alpha = alpha
        self.alphaAnimation = alphaAnimation
        self.color = color
        self.colorAnimation = colorAnimation
        self.brightness = brightness
        self.shapePoints = shapePoints
    }

    /// Whether `resolved(at:)` can return anything but `self`. Both slots nil
    /// makes it a field-by-field copy, so a caller rebuilding a tree per frame
    /// can skip the layer entirely.
    public var isTimeVarying: Bool {
        alphaAnimation != nil || colorAnimation != nil
    }

    public func resolved(at time: Double) -> WPERenderLayerGeometry {
        guard isTimeVarying else { return self }
        return WPERenderLayerGeometry(
            origin: origin,
            scale: scale,
            angles: angles,
            alignment: alignment,
            size: size,
            puppetMeshCenter: puppetMeshCenter,
            alpha: alphaAnimation?.scalar(at: time) ?? alpha,
            alphaAnimation: alphaAnimation,
            color: Self.resolvedColor(colorAnimation, at: time) ?? color,
            colorAnimation: colorAnimation,
            brightness: brightness,
            shapePoints: shapePoints
        )
    }

    private static func resolvedColor(
        _ animation: WPESceneAnimatedValue?,
        at time: Double
    ) -> SIMD3<Double>? {
        guard let values = animation?.vector(at: time), values.count >= 3 else { return nil }
        return SIMD3<Double>(values[0], values[1], values[2])
    }

    public static let identity = WPERenderLayerGeometry(
        origin: SIMD3<Double>(0, 0, 0),
        scale: SIMD3<Double>(1, 1, 1),
        angles: SIMD3<Double>(0, 0, 0),
        alignment: .center,
        size: nil,
        puppetMeshCenter: SIMD2<Double>(0, 0),
        alpha: 1,
        alphaAnimation: nil,
        color: SIMD3<Double>(1, 1, 1),
        brightness: 1
    )
}

public struct WPERenderFBO: Equatable, Sendable {
    public let name: String
    public let scale: Double
    /// Optional longest-edge target in pixels. WPE effect FBOs use this instead
    /// of `scale`: preserve aspect ratio and round both resolved dimensions.
    public let fit: Double?
    public let format: String
    public let unique: Bool
    public let pixelSize: CGSize?

    public init(
        name: String,
        scale: Double,
        fit: Double? = nil,
        format: String,
        unique: Bool = false,
        pixelSize: CGSize? = nil
    ) {
        self.name = name
        self.scale = scale
        self.fit = fit
        self.format = format
        self.unique = unique
        self.pixelSize = pixelSize
    }
}

/// Marks passes contributed by an effect whose `visible` field is a SceneScript.
/// Such an effect is baked into the graph even when authored hidden, because the
/// script that decides its visibility routinely lives on the effect's OWN pass
/// constants — scene 3151551777's day/night cycle computes `shared.shownight`
/// from a constant script on the very effect that reads `shared.shownight` to
/// decide whether to show. Dropping the hidden effect at build time drops that
/// producer too, so the gate can never open. The executor runs the pass only
/// while the gate resolves true; otherwise it passes the layer composite
/// through unchanged, so a closed gate draws nothing visible.
public struct WPEPassVisibilityGate: Equatable, Sendable {
    /// Script-instance key. Authored source + seed, so the dozen clones of one
    /// effect that WPE scenes spread across objects share a single JS instance.
    public let id: String
    public let script: WPESceneTransformScript
    /// Authored `visible` seed; the gate value until the script first ticks.
    public let initialVisible: Bool

    public init(script: WPESceneTransformScript, initialVisible: Bool) {
        id = "\(initialVisible ? 1 : 0)\u{1}\(script.script)"
        self.script = script
        self.initialVisible = initialVisible
    }
}

/// Authored dynamic texture declarations remain separated by their JSON locus.
/// This deliberately does not guess merge precedence or bind a runtime provider.
public struct WPERenderUserTextureBindings: Equatable, Sendable {
    public let material: [WPESceneUserTextureBinding]
    public let pass: [WPESceneUserTextureBinding]
    public let override: [WPESceneUserTextureBinding]

    public init(
        material: [WPESceneUserTextureBinding] = [],
        pass: [WPESceneUserTextureBinding] = [],
        override: [WPESceneUserTextureBinding] = []
    ) {
        self.material = material
        self.pass = pass
        self.override = override
    }

    public static let empty = WPERenderUserTextureBindings()

    public var isEmpty: Bool {
        material.isEmpty && pass.isEmpty && override.isEmpty
    }
}

/// Stable authored identity for a pass contributed by an image effect.
///
/// `stablePassID` names the effect asset's pass/override locus and remains
/// stable even when one effect pass expands into multiple renderer passes.
/// `WPERenderPass.id` remains the concrete render-pass identity.
public struct WPERenderEffectPassIdentity: Equatable, Sendable {
    public let stableEffectID: String
    public let stablePassID: String
    public let objectID: String
    public let authoredEffectID: String
    public let authoredEffectPath: String
    public let effectPassIndex: Int
    public let authoredOverrideID: Int?

    public init(
        objectID: String,
        authoredEffectID: String,
        authoredEffectPath: String,
        effectPassIndex: Int,
        authoredOverrideID: Int?
    ) {
        self.objectID = objectID
        self.authoredEffectID = authoredEffectID
        self.authoredEffectPath = authoredEffectPath
        self.effectPassIndex = effectPassIndex
        self.authoredOverrideID = authoredOverrideID
        stableEffectID = "\(objectID):effect:\(authoredEffectID)"
        stablePassID = "\(objectID):effect:\(authoredEffectID):pass:\(effectPassIndex)"
    }
}

/// Complete authored JSON documents that contributed a render pass.
///
/// The typed fields on `WPERenderPass` remain the executor's fast path. These
/// trees preserve every material/effect key and array entry through graph and
/// prepared-pipeline construction so a future consumer can be added without
/// first changing the package reader. Presence here is metadata, not proof that
/// an unsupported field already has equivalent runtime behavior.
public struct WPERenderPassAuthoredJSON: Equatable, Sendable {
    public let materialDocument: WPESceneJSONValue?
    public let materialPass: WPESceneJSONValue?
    public let effectDocument: WPESceneJSONValue?
    public let effectPass: WPESceneJSONValue?
    /// Stable effect/pass identity for diagnostics. Nil for material, command,
    /// text, and other independently dispatched paths.
    public let effectIdentity: WPERenderEffectPassIdentity?

    public init(
        materialDocument: WPESceneJSONValue? = nil,
        materialPass: WPESceneJSONValue? = nil,
        effectDocument: WPESceneJSONValue? = nil,
        effectPass: WPESceneJSONValue? = nil,
        effectIdentity: WPERenderEffectPassIdentity? = nil
    ) {
        self.materialDocument = materialDocument
        self.materialPass = materialPass
        self.effectDocument = effectDocument
        self.effectPass = effectPass
        self.effectIdentity = effectIdentity
    }

    public static let empty = WPERenderPassAuthoredJSON()
}

public struct WPERenderPass: Equatable, Sendable, Identifiable {
    public let id: String
    public let phase: WPERenderPassPhase
    public let shader: String
    public let source: WPETextureReference
    public let target: WPERenderTarget
    public let textures: [Int: WPETextureReference]
    public let binds: [Int: WPETextureReference]
    public let constants: [String: WPESceneShaderConstantValue]
    public let combos: [String: Int]
    /// Metadata-only preservation for material/pass/instance dynamic texture
    /// declarations. Runtime texture-provider consumption is a separate gate.
    public let userTextureBindings: WPERenderUserTextureBindings
    /// Lossless material/effect documents and pass dictionaries that produced
    /// this pass. Consumers must still opt into individual fields explicitly.
    public let authoredJSON: WPERenderPassAuthoredJSON
    public let blending: String
    public let cullMode: String
    public let depthTest: String
    public let depthWrite: String
    /// SceneScripts bound to individual shader constants on this pass. The
    /// renderer builds one script instance per entry and overrides the authored
    /// `constants` value each frame; empty for every pass without one.
    public let constantScripts: [String: WPESceneTransformScript]
    /// Non-nil only for passes contributed by a script-gated hidden effect.
    public let visibilityGate: WPEPassVisibilityGate?

    public init(
        id: String,
        phase: WPERenderPassPhase,
        shader: String,
        source: WPETextureReference,
        target: WPERenderTarget,
        textures: [Int: WPETextureReference],
        binds: [Int: WPETextureReference],
        constants: [String: WPESceneShaderConstantValue],
        combos: [String: Int],
        userTextureBindings: WPERenderUserTextureBindings = .empty,
        authoredJSON: WPERenderPassAuthoredJSON = .empty,
        blending: String,
        cullMode: String,
        depthTest: String,
        depthWrite: String,
        constantScripts: [String: WPESceneTransformScript] = [:],
        visibilityGate: WPEPassVisibilityGate? = nil
    ) {
        self.id = id
        self.phase = phase
        self.shader = shader
        self.source = source
        self.target = target
        self.textures = textures
        self.binds = binds
        self.constants = constants
        self.combos = combos
        self.userTextureBindings = userTextureBindings
        self.authoredJSON = authoredJSON
        self.blending = blending
        self.cullMode = cullMode
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.constantScripts = constantScripts
        self.visibilityGate = visibilityGate
    }

    public func replacingTarget(_ target: WPERenderTarget) -> WPERenderPass {
        WPERenderPass(
            id: id,
            phase: phase,
            shader: shader,
            source: source,
            target: target,
            textures: textures,
            binds: binds,
            constants: constants,
            combos: combos,
            userTextureBindings: userTextureBindings,
            authoredJSON: authoredJSON,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite,
            constantScripts: constantScripts,
            visibilityGate: visibilityGate
        )
    }

    public func replacingBlending(_ blending: String) -> WPERenderPass {
        WPERenderPass(
            id: id,
            phase: phase,
            shader: shader,
            source: source,
            target: target,
            textures: textures,
            binds: binds,
            constants: constants,
            combos: combos,
            userTextureBindings: userTextureBindings,
            authoredJSON: authoredJSON,
            blending: blending,
            cullMode: cullMode,
            depthTest: depthTest,
            depthWrite: depthWrite,
            constantScripts: constantScripts,
            visibilityGate: visibilityGate
        )
    }
}

public enum WPERenderPassPhase: Equatable, Sendable {
    case material
    case effect(file: String)
    case command(file: String)

    /// Exact built-in copy asset shared by graph construction and effect-chain classification.
    public static let sceneCopyCommandFile = "materials/util/copy.json"
}

/// WPE render-target aliases that refer to the scene composed so far.
public enum WPESceneAliasName {
    public static let fullFrameBuffer = "_rt_FullFrameBuffer"
}

public enum WPETextureReference: Equatable, Sendable {
    case image(String)
    case asset(String)
    case fbo(String)
    case previous

    /// Classifies `_rt_*` aliases that refer to the live scene texture rather than a discrete FBO.
    /// This shared list must stay authoritative for both graph construction and shader input binding.
    public static func isSceneAliasName(_ name: String) -> Bool {
        switch name {
        case WPESceneAliasName.fullFrameBuffer,
             "_rt_HalfFrameBuffer",
             "_rt_QuarterFrameBuffer",
             "_rt_imageLayerComposite":
            return true
        default:
            return name.hasPrefix("_rt_Mip")
                || name.hasPrefix("_rt_downscaled")
        }
    }
}

public enum WPERenderTarget: Equatable, Sendable {
    case layerComposite(name: String)
    case fbo(name: String)
    case scene
}

public enum WPERenderGraphError: Error, Equatable, LocalizedError, Sendable {
    case fileMissing(String)
    case invalidJSON(String)
    case malformedMaterial(String)
    case malformedEffect(String)
    case materialUnresolved(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let path):
            return String(localized: "error.render.graph.file_missing", defaultValue: "WPE graph asset missing: \(path)", comment: "Error shown when a Wallpaper Engine render graph asset is missing.")
        case .invalidJSON(let path):
            return String(localized: "error.render.graph.invalid_json", defaultValue: "WPE graph asset is not valid JSON: \(path)", comment: "Error shown when a Wallpaper Engine render graph asset is invalid JSON.")
        case .malformedMaterial(let path):
            return String(localized: "error.render.graph.malformed_material", defaultValue: "WPE material has no renderable passes: \(path)", comment: "Error shown when a Wallpaper Engine material has no renderable passes.")
        case .malformedEffect(let path):
            return String(localized: "error.render.graph.malformed_effect", defaultValue: "WPE effect has no renderable passes: \(path)", comment: "Error shown when a Wallpaper Engine effect has no renderable passes.")
        case .materialUnresolved(let imagePath):
            return String(localized: "error.render.graph.material_unresolved", defaultValue: "Could not resolve WPE material for image reference: \(imagePath)", comment: "Error shown when a Wallpaper Engine material cannot be resolved for an image reference.")
        }
    }
}
