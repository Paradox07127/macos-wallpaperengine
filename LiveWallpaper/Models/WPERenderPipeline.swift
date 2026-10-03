#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import simd

struct WPEPreparedRenderPipeline: Equatable, Sendable {
    let layers: [WPEPreparedRenderLayer]

    /// Upload selection happens after shader prewarm starts and before any target allocation.
    func resolvingSourceMipLevels(_ level: (WPETextureReference) -> Int?) -> Self {
        Self(layers: layers.map { layer in
            guard let extent = layer.effectPublication?.sourceExtent ?? layer.graphLayer.compositeSourceExtent,
                  let source = layer.passes.first,
                  let mip = level(source.textureBindings[0] ?? source.pass.source),
                  (0 ... 14).contains(mip), mip != extent.sourceMipLevel else { return layer }
            let resolved = WPERenderSourceExtent(textureSize: extent.textureSize, imageSize: extent.imageSize,
                                                 sourceMipLevel: mip)
            return layer.replacing(
                graphLayer: layer.effectPublication == nil
                    ? layer.graphLayer.replacingPasses(layer.graphLayer.passes, compositeSourceExtent: resolved) : layer.graphLayer,
                passes: layer.passes,
                effectPublication: layer.effectPublication.map { .some($0.resolvingSourceExtent(resolved)) }
            )
        })
    }
}

struct WPEPreparedRenderLayer: Equatable, Sendable, Identifiable {
    var id: String {
        graphLayer.id
    }

    let graphLayer: WPERenderLayer
    let puppetModel: WPEPuppetModel?
    let passes: [WPEPreparedRenderPass]
    /// Full affine model transform, retained through mesh submission. A rotated
    /// child under non-uniform parent scale cannot be represented by Euler sums.
    let modelMatrix: WPEPreparedModelMatrix?
    let effectPublication: WPEEffectPublicationDescriptor?
    var modelMatrixOverride: [Double]? {
        modelMatrix?.values
    }

    var hasStaticParentModel: Bool {
        if case .staticParent? = modelMatrix {
            return true
        }
        return false
    }

    init(
        graphLayer: WPERenderLayer,
        puppetModel: WPEPuppetModel? = nil,
        passes: [WPEPreparedRenderPass],
        modelMatrixOverride: [Double]? = nil,
        effectPublication: WPEEffectPublicationDescriptor? = nil
    ) {
        self.init(graphLayer: graphLayer, puppetModel: puppetModel, passes: passes,
                  modelMatrix: modelMatrixOverride.map(WPEPreparedModelMatrix.runtime), effectPublication: effectPublication)
    }

    init(graphLayer: WPERenderLayer, puppetModel: WPEPuppetModel? = nil,
         passes: [WPEPreparedRenderPass], modelMatrix: WPEPreparedModelMatrix?,
         effectPublication: WPEEffectPublicationDescriptor? = nil) {
        self.graphLayer = graphLayer
        self.puppetModel = puppetModel
        self.passes = passes
        self.modelMatrix = modelMatrix
        self.effectPublication = effectPublication
    }

    func replacing(graphLayer: WPERenderLayer? = nil, passes: [WPEPreparedRenderPass]? = nil,
                   effectPublication: WPEEffectPublicationDescriptor?? = nil) -> Self {
        Self(graphLayer: graphLayer ?? self.graphLayer, puppetModel: puppetModel,
             passes: passes ?? self.passes, modelMatrix: modelMatrix,
             effectPublication: effectPublication ?? self.effectPublication)
    }
}

enum WPEEffectPublicationScope: Equatable, Sendable {
    case legacyStaticSingleEffect
    case nativeSolidChain
}

/// Stable admission facts only; canonical passes remain owned by the layer.
struct WPEEffectPublicationDescriptor: Equatable, Sendable {
    struct Effect: Equatable, Sendable {
        let passID: String
        let effectID: String
    }

    let basePassID: String
    let effects: [Effect]
    let copyPassID: String
    let sourceExtent: WPERenderSourceExtent?
    let staticParentModel: WPEPreparedModelMatrix?
    let scope: WPEEffectPublicationScope
    let baseSceneBlending: String

    var permitsActiveSubsets: Bool {
        scope == .nativeSolidChain
    }

    func resolvingSourceExtent(_ extent: WPERenderSourceExtent) -> Self {
        Self(basePassID: basePassID, effects: effects, copyPassID: copyPassID, sourceExtent: extent,
             staticParentModel: staticParentModel, scope: scope,
             baseSceneBlending: baseSceneBlending)
    }
}

extension WPEPreparedRenderPipeline {
    func retainingEffectPublication(in readyLayerIDs: Set<String>) -> Self {
        Self(layers: layers.map { layer in
            readyLayerIDs.contains(layer.id) ? layer : layer.replacing(effectPublication: .some(nil))
        })
    }

    /// Derives one transient frame graph; the canonical pipeline is never mutated.
    func resolvingEffectPublication(passVisibility: [String: Bool], camera: WPEMetalCameraUniforms) -> Self {
        Self(layers: layers.map { layer in
            guard let descriptor = layer.effectPublication,
                  let canonical = layer.effectPublicationCanonicalPasses(camera: camera) else { return layer }
            let active = canonical.effects.filter { prepared in
                guard let gate = prepared.pass.visibilityGate else { return true }
                return passVisibility[gate.id] ?? gate.initialVisible
            }
            guard descriptor.permitsActiveSubsets || active.count == canonical.effects.count else { return layer }
            let passes: [WPEPreparedRenderPass]
            if active.isEmpty {
                passes = [layer.effectPublicationPass(canonical.base, source: canonical.base.pass.source,
                                                      target: .scene, terminal: false, baseScene: true)]
            } else {
                var selected = [layer.effectPublicationPass(canonical.base, source: canonical.base.pass.source,
                                                            target: .layerComposite(name: layer.graphLayer.compositeA),
                                                            terminal: false)]
                var predecessor = WPETextureReference.fbo(layer.graphLayer.compositeA)
                for (index, effect) in active.enumerated() {
                    let terminal = index == active.count - 1
                    let target: WPERenderTarget = terminal ? .scene : .layerComposite(
                        name: index.isMultiple(of: 2) ? layer.graphLayer.compositeB : layer.graphLayer.compositeA
                    )
                    selected.append(layer.effectPublicationPass(effect, source: predecessor, target: target, terminal: terminal))
                    predecessor = target.textureReference ?? predecessor
                }
                passes = selected
            }
            return WPEPreparedRenderLayer(
                graphLayer: layer.graphLayer.replacingPasses(passes.map(\.pass), compositeSourceExtent: descriptor.sourceExtent),
                puppetModel: layer.puppetModel, passes: passes,
                modelMatrix: descriptor.staticParentModel ?? layer.modelMatrix
            )
        })
    }
}

extension WPEPreparedRenderLayer {
    /// Bounded role/source enumeration, independent of the number of visibility subsets.
    func effectPublicationPrewarmPasses(camera: WPEMetalCameraUniforms) -> [WPEPreparedRenderPass] {
        guard let canonical = effectPublicationCanonicalPasses(camera: camera) else { return [] }
        let baseRoles: [WPEPreparedRenderPass] = effectPublication?.scope == .nativeSolidChain ? [
            effectPublicationPass(canonical.base, source: canonical.base.pass.source,
                                  target: .layerComposite(name: graphLayer.compositeA), terminal: false),
            effectPublicationPass(canonical.base, source: canonical.base.pass.source,
                                  target: .scene, terminal: false, baseScene: true),
        ] : []
        return baseRoles + canonical.effects.flatMap { effect in
            [graphLayer.compositeA, graphLayer.compositeB].flatMap { source in
                let other = source == graphLayer.compositeA ? graphLayer.compositeB : graphLayer.compositeA
                return [
                    effectPublicationPass(effect, source: .fbo(source), target: .layerComposite(name: other), terminal: false),
                    effectPublicationPass(effect, source: .fbo(source), target: .scene, terminal: true),
                ]
            }
        }
    }

    fileprivate func effectPublicationCanonicalPasses(camera: WPEMetalCameraUniforms)
        -> (base: WPEPreparedRenderPass, effects: [WPEPreparedRenderPass])? {
        guard let descriptor = effectPublication, !camera.sceneHDR,
              !graphLayer.geometry.isTimeVarying, graphLayer.geometry.shapePoints == nil,
              !descriptor.permitsActiveSubsets || graphLayer.parentObjectID == nil,
              Set(passes.map(\.id)).count == passes.count,
              passes.count == descriptor.effects.count + 2,
              graphLayer.passes == passes.map(\.pass),
              passes.first?.id == descriptor.basePassID, passes.last?.id == descriptor.copyPassID else { return nil }
        let effects = Array(passes.dropFirst().dropLast())
        guard effects.map(\.id) == descriptor.effects.map(\.passID),
              effects.map({ $0.pass.authoredJSON.effectIdentity?.stableEffectID }) == descriptor.effects.map({ Optional($0.effectID) }) else { return nil }
        let effectIDs = Set(descriptor.effects.map(\.passID))
        let graph = graphLayer.replacingPasses(passes.map { prepared in
            guard effectIDs.contains(prepared.id) else { return prepared.pass }
            let cull = prepared.pass.authoredJSON.materialPass?["cullmode"] == .string("nocull") ? "nocull" : "back"
            return prepared.pass.replacingCullMode(cull)
        })
        guard WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: graph, camera: camera) else { return nil }
        return (passes[0], effects)
    }

    fileprivate func effectPublicationPass(_ prepared: WPEPreparedRenderPass, source: WPETextureReference,
                                           target: WPERenderTarget, terminal: Bool, baseScene: Bool = false) -> WPEPreparedRenderPass {
        guard let descriptor = effectPublication else { return prepared }
        let pass = prepared.pass
        let isEffect = if case .effect = pass.phase {
            true
        } else {
            false
        }
        let cull = terminal ? (pass.authoredJSON.materialPass?["cullmode"] == .string("nocull") ? "nocull" : "back") : pass.cullMode
        let nativeSolid = descriptor.scope == .nativeSolidChain
        let straight = nativeSolid || descriptor.sourceExtent != nil
        let rewritten = WPERenderPass(
            id: pass.id, phase: pass.phase, shader: pass.shader,
            source: isEffect ? source : pass.source, target: target,
            textures: isEffect ? pass.textures.mapValues { _ in source } : pass.textures,
            binds: isEffect ? pass.binds.mapValues { _ in source } : pass.binds,
            constants: pass.constants, combos: pass.combos, userTextureBindings: pass.userTextureBindings,
            authoredJSON: pass.authoredJSON,
            blending: (baseScene || (nativeSolid && terminal)) ? descriptor.baseSceneBlending
                : ((terminal || straight) ? "disabled" : pass.blending),
            cullMode: cull, depthTest: pass.depthTest, depthWrite: pass.depthWrite,
            constantScripts: pass.constantScripts, visibilityGate: nil
        )
        return WPEPreparedRenderPass(
            pass: rewritten, shader: prepared.shader,
            textureBindings: isEffect ? prepared.textureBindings.mapValues { _ in source } : prepared.textureBindings,
            comboValues: prepared.comboValues, uniformValues: prepared.uniformValues,
            materialUniformNames: prepared.materialUniformNames, stageUniformBindings: prepared.stageUniformBindings,
            layerTintOverride: prepared.layerTintOverride,
            alphaContract: straight ? WPEShaderAlphaContract(unpremultipliedInputSlots: [], premultipliedOutput: false) : prepared.alphaContract,
            publicationVertexRole: nativeSolid && isEffect && !terminal && prepared.shader?.isBuiltin == false ? .localEffect : nil
        )
    }
}

enum WPEPreparedModelMatrix: Equatable, Sendable {
    case runtime([Double])
    /// Created only after static hierarchy and closed-pass publication admission.
    case staticParent([Double])

    var values: [Double] {
        switch self {
        case let .runtime(values), let .staticParent(values): values
        }
    }
}

/// Scripted constant key: (pass id, uniform name).
struct WPEEffectConstantScriptKey: Hashable, Sendable {
    let passID: String
    let uniform: String
}

enum WPEPublicationVertexRole: Equatable, Sendable {
    case localEffect
}

struct WPEPreparedRenderPass: Equatable, Sendable, Identifiable {
    var id: String { pass.id }

    var textureReferences: [WPETextureReference] {
        access.textureReferences
    }

    let access: WPEPreparedPassAccess

    let pass: WPERenderPass
    let shader: WPEShaderProgram?
    let textureBindings: [Int: WPETextureReference]
    let comboValues: [String: Int]
    let uniformValues: [String: WPESceneShaderConstantValue]
    /// Authored (material) name → shader uniform name. uniformValues is keyed by the SHADER name; scene JSON/SceneScript speak the authored name.
    let materialUniformNames: [String: String]
    let stageUniformBindings: [WPEShaderBindingKey: WPEUniformStageBinding]
    let stageUniformBindingKeys: Set<WPEShaderBindingKey>
    /// True when any value is .animated — the only case where resolved(at:) is not the identity.
    let hasAnimatedUniformValues: Bool
    /// Set when a script overrode tint of a pass whose g_Color is animated; writing the override into the value would freeze unclaimed components at frame 0.
    let layerTintOverride: WPELayerTintOverride?
    /// Explicit producer/consumer ABI when graph lowering changes an intermediate
    /// to straight RGBA. Nil retains the existing FBO/PMA convention.
    let alphaContract: WPEShaderAlphaContract?
    let publicationVertexRole: WPEPublicationVertexRole?

    init(
        pass: WPERenderPass,
        shader: WPEShaderProgram?,
        textureBindings: [Int: WPETextureReference],
        comboValues: [String: Int],
        uniformValues: [String: WPESceneShaderConstantValue],
        materialUniformNames: [String: String] = [:],
        stageUniformBindings: [WPEShaderBindingKey: WPEUniformStageBinding] = [:],
        layerTintOverride: WPELayerTintOverride? = nil,
        alphaContract: WPEShaderAlphaContract? = nil,
        publicationVertexRole: WPEPublicationVertexRole? = nil,
        reusingAccess: WPEPreparedPassAccess? = nil
    ) {
        self.pass = pass
        self.shader = shader
        self.textureBindings = textureBindings
        if let reusingAccess, reusingAccess.matches(pass: pass, textureBindings: textureBindings) {
            access = reusingAccess
        } else {
            access = WPEPreparedPassAccess(pass: pass, textureBindings: textureBindings)
        }
        self.comboValues = comboValues
        self.uniformValues = uniformValues
        self.materialUniformNames = materialUniformNames
        self.stageUniformBindings = stageUniformBindings
        stageUniformBindingKeys = Set(stageUniformBindings.keys)
        self.layerTintOverride = layerTintOverride
        self.alphaContract = alphaContract
        self.publicationVertexRole = publicationVertexRole
        hasAnimatedUniformValues = uniformValues.values.contains {
            if case .animated = $0 { return true }
            return false
        } || stageUniformBindings.values.contains {
            if case .animated? = $0.value {
                return true
            }
            return false
        }
    }
}

/// Which components of an animated `g_Color` a script has claimed. Applied
/// after the per-frame resolve so the unclaimed components keep animating.
struct WPELayerTintOverride: Equatable, Sendable {
    let color: SIMD3<Double>?
    let alpha: Double?
}

struct WPERenderObjectTransform: Equatable, Sendable {
    let origin: SIMD3<Double>
    let scale: SIMD3<Double>
    let angles: SIMD3<Double>

    init(origin: SIMD3<Double>, scale: SIMD3<Double>, angles: SIMD3<Double>) {
        self.origin = origin
        self.scale = scale
        self.angles = angles
    }

    init(_ geometry: WPERenderLayerGeometry) {
        self.init(origin: geometry.origin, scale: geometry.scale, angles: geometry.angles)
    }

    func applying(
        origin: SIMD3<Double>?,
        scale: SIMD3<Double>?,
        angles: SIMD3<Double>?
    ) -> WPERenderObjectTransform {
        WPERenderObjectTransform(
            origin: origin ?? self.origin,
            scale: scale ?? self.scale,
            angles: angles ?? self.angles
        )
    }

    func combining(child: WPERenderObjectTransform) -> WPERenderObjectTransform {
        let combined = WPEEulerTransform.combine(
            origin: origin, scale: scale, angles: angles,
            childOrigin: child.origin, childScale: child.scale, childAngles: child.angles
        )
        return WPERenderObjectTransform(origin: combined.origin, scale: combined.scale, angles: combined.angles)
    }
}

/// Shared by build-time parent publication and frame-time model submission.
struct WPEObjectModelMatrixResolver {
    let localTransforms: [String: WPERenderObjectTransform]
    let parentByID: [String: String]
    let attachmentOffsets: [String: SIMD3<Double>]
    let origins: [String: SIMD3<Double>]
    let scales: [String: SIMD3<Double>]
    let angles: [String: SIMD3<Double>]
    private var completeMemo: [String: simd_double4x4] = [:]
    private var legacyMemo: [String: simd_double4x4] = [:]

    init(localTransforms: [String: WPERenderObjectTransform], parentByID: [String: String],
         attachmentOffsets: [String: SIMD3<Double>] = [:], origins: [String: SIMD3<Double>] = [:],
         scales: [String: SIMD3<Double>] = [:], angles: [String: SIMD3<Double>] = [:]) {
        self.localTransforms = localTransforms
        self.parentByID = parentByID
        self.attachmentOffsets = attachmentOffsets
        self.origins = origins
        self.scales = scales
        self.angles = angles
    }

    func completeChain(for id: String) -> [String]? {
        var visited = Set<String>()
        var chain: [String] = []
        var current = id
        while visited.count < 100 {
            guard visited.insert(current).inserted, localTransforms[current] != nil else { return nil }
            chain.append(current)
            guard let parent = parentByID[current] else { return chain }
            current = parent
        }
        return nil
    }

    mutating func resolve(_ id: String, requiringCompleteHierarchy: Bool) -> simd_double4x4? {
        guard !requiringCompleteHierarchy || completeChain(for: id) != nil else { return nil }
        var pending: [(id: String, local: simd_double4x4)] = []
        var visited = Set<String>()
        var current = id
        var world: simd_double4x4?
        // Keep the legacy stop-at-local policy, but store the bounded chain on
        // the heap instead of retaining a large matrix stack frame per parent.
        while true {
            if let cached = (requiringCompleteHierarchy ? completeMemo : legacyMemo)[current] {
                world = cached
                break
            }
            guard let authored = localTransforms[current] else { break }
            let local = WPEMetalObjectUniforms.modelMatrix(
                origin: (origins[current] ?? authored.origin) + (attachmentOffsets[current] ?? .zero),
                scale: scales[current] ?? authored.scale, angles: angles[current] ?? authored.angles
            )
            pending.append((current, local))
            guard let parent = parentByID[current], parent != current,
                  !visited.contains(parent), visited.count < 100 else { break }
            visited.insert(current)
            current = parent
        }
        for entry in pending.reversed() {
            let resolved = world.map { $0 * entry.local } ?? entry.local
            if requiringCompleteHierarchy {
                completeMemo[entry.id] = resolved
            } else {
                legacyMemo[entry.id] = resolved
            }
            world = resolved
        }
        return world
    }
}

struct WPEStaticParentHierarchyContext: Equatable, Sendable {
    let parentByID: [String: String]
    let localTransforms: [String: WPERenderObjectTransform]
    let eligibleAncestorIDs: Set<String>
    let imageObjectIDs: Set<String>

    static func permitsScriptFreePublication(in document: WPESceneDocument) -> Bool {
        WPESceneScriptInstanceInventory(document: document).total == 0
            && document.propertyBindings.isEmpty
            && document.imageObjects.allSatisfy { $0.effects.allSatisfy { $0.visibleScript == nil } }
            && document.particleObjects.allSatisfy { $0.instanceOverride?.alphaScript == nil }
    }

    init?(document: WPESceneDocument, localTransforms: [String: WPERenderObjectTransform]) {
        guard Self.permitsScriptFreePublication(in: document), document.cameraMotion == nil,
              !document.general.cameraParallax.enabled else { return nil }
        parentByID = document.objectParentByID
        self.localTransforms = localTransforms
        imageObjectIDs = Set(document.imageObjects.map(\.id)).subtracting(document.textObjects.map(\.id))
        // Omitted depths parse as (1, 1); they are inert while the scene-wide
        // parallax mechanism is disabled by this context's admission above.
        eligibleAncestorIDs = Set(document.transformHostObjects.filter {
            $0.originAnimation == nil && $0.originScript == nil && $0.scaleScript == nil && $0.anglesScript == nil
                && $0.parallaxDepth.x.isFinite && $0.parallaxDepth.y.isFinite
        }.map(\.id))
    }

    func modelMatrix(for layer: WPERenderLayer) -> [Double]? {
        guard let parent = layer.parentObjectID, parentByID[layer.id] == parent,
              imageObjectIDs.contains(layer.id), let geometry = layer.localGeometry,
              layer.attachment == nil, layer.parallaxDepth.x.isFinite, layer.parallaxDepth.y.isFinite,
              !layer.authoredJSON.sceneObjects.contains(where: { object in
                  object["shape"] != nil || ["origin", "scale", "angles"].contains { key in
                      object[key]?["animation"] != nil || object[key]?["keyframes"] != nil
                  }
              }) else { return nil }
        var transforms = localTransforms
        transforms[layer.id] = WPERenderObjectTransform(geometry)
        var resolver = WPEObjectModelMatrixResolver(localTransforms: transforms, parentByID: parentByID)
        guard let chain = resolver.completeChain(for: layer.id),
              chain.dropFirst().allSatisfy(eligibleAncestorIDs.contains),
              chain.allSatisfy({ id in
                  guard let local = transforms[id] else { return false }
                  return local.origin.z == 0 && local.angles.x == 0 && local.angles.y == 0
                      && [local.origin.x, local.origin.y, local.angles.z].allSatisfy { $0.isFinite && Float($0).isFinite }
                      && [local.scale.x, local.scale.y, local.scale.z].allSatisfy { $0 > 0 && Float($0).isFinite && Float($0) > 0 }
              }), let world = resolver.resolve(layer.id, requiringCompleteHierarchy: true) else { return nil }
        let values = WPEMetalObjectUniforms.flattenedColumnMajor(world)
        guard values.allSatisfy({ $0.isFinite && Float($0).isFinite }),
              let quantized = WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: values.map { Double(Float($0)) }),
              simd_determinant(quantized) > 0,
              WPEMetalObjectUniforms.flattenedColumnMajor(quantized.inverse).allSatisfy({ $0.isFinite && Float($0).isFinite }) else { return nil }
        return values
    }
}

/// Labels describe the selected path, not pixel equivalence with WPE.
enum WPEShaderExecutionClassification: String, Equatable, Sendable {
    case officialSource = "official-source"
    case nativeApproximation = "native-approximation"
    /// A copy program selected specifically because an effect source was absent.
    case copyFallback = "copy-fallback"
    /// Must not infer this from shader == nil: text and other paths also omit it on purpose.
    case unsupportedMetadataOnly = "unsupported-metadata-only"
}

struct WPEShaderProgram: Equatable, Sendable {
    let name: String
    let vertexSource: String
    let fragmentSource: String
    let isBuiltin: Bool
    let executionClassification: WPEShaderExecutionClassification
    /// SHA-256 of (vertex, fragment); nil for builtins. Derived here only — a caller-supplied fingerprint could key the wrong GLSL.
    let sourceFingerprint: String?

    init(
        name: String,
        vertexSource: String,
        fragmentSource: String,
        isBuiltin: Bool,
        executionClassification: WPEShaderExecutionClassification? = nil
    ) {
        self.name = name
        self.vertexSource = vertexSource
        self.fragmentSource = fragmentSource
        self.isBuiltin = isBuiltin
        sourceFingerprint = isBuiltin
            ? nil
            : WPEShaderSourceDigest.pair(vertexSource: vertexSource, fragmentSource: fragmentSource)
        self.executionClassification = executionClassification
            ?? (isBuiltin ? .nativeApproximation : .officialSource)
    }
}

extension WPEPreparedRenderPipeline {
    /// Resolve local transforms before the legacy 2D placement decomposition.
    /// Model meshes and bounded authored 2D scene quads consume this override.
    /// Native 2D placement keeps its existing geometry contract. Resolve static
    /// ancestors as well as scripted hosts.
    func resolvingSceneModelMatrices(
        origins: [String: SIMD3<Double>], scales: [String: SIMD3<Double>], angles: [String: SIMD3<Double>],
        parentByID: [String: String], hostTransforms: [String: WPERenderObjectTransform],
        camera: WPEMetalCameraUniforms = .identity
    ) -> WPEPreparedRenderPipeline {
        let inheritedQuadIDs = Set(layers.filter { layer in
            !layer.hasStaticParentModel && layer.graphLayer.parentObjectID != nil
                && WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer.graphLayer, camera: camera)
                && layer.passes.contains { pass in
                    if case .scene = pass.pass.target {
                        return pass.shader?.isBuiltin == false
                    }
                    return false
                }
        }.map(\.id))
        let models = layers.filter {
            inheritedQuadIDs.contains($0.id)
                || ($0.graphLayer.puppetPath != nil && ($0.graphLayer.imagePath as NSString).pathExtension.lowercased() == "mdl")
        }
        guard !models.isEmpty else { return self }
        var localByID = hostTransforms
        localByID.merge(Dictionary(layers.map {
            ($0.id, WPERenderObjectTransform($0.graphLayer.localGeometry ?? $0.graphLayer.geometry))
        }, uniquingKeysWith: { first, _ in first })) { _, layer in layer }
        let offsets = Dictionary(layers.map { ($0.id, $0.graphLayer.attachmentOriginOffset) }, uniquingKeysWith: { first, _ in first })
        var resolver = WPEObjectModelMatrixResolver(localTransforms: localByID, parentByID: parentByID,
                                                    attachmentOffsets: offsets, origins: origins, scales: scales, angles: angles)
        let modelIDs = Set(models.map(\.id))
        return WPEPreparedRenderPipeline(layers: layers.map { layer in
            guard !layer.hasStaticParentModel, modelIDs.contains(layer.id) else { return layer }
            if inheritedQuadIDs.contains(layer.id) {
                guard parentByID[layer.id] == layer.graphLayer.parentObjectID, resolver.completeChain(for: layer.id) != nil else {
                    return WPEPreparedRenderLayer(graphLayer: layer.graphLayer, puppetModel: layer.puppetModel, passes: layer.passes,
                                                  effectPublication: layer.effectPublication)
                }
            }
            guard let world = resolver.resolve(layer.id, requiringCompleteHierarchy: inheritedQuadIDs.contains(layer.id)) else { return layer }
            return WPEPreparedRenderLayer(graphLayer: layer.graphLayer, puppetModel: layer.puppetModel, passes: layer.passes,
                                          modelMatrixOverride: WPEMetalObjectUniforms.flattenedColumnMajor(world),
                                          effectPublication: layer.effectPublication)
        })
    }

    func applyingLayerTransforms(
        origins: [String: SIMD3<Double>],
        scales: [String: SIMD3<Double>],
        angles: [String: SIMD3<Double>],
        parentByID: [String: String] = [:],
        hostTransforms: [String: WPERenderObjectTransform] = [:]
    ) -> WPEPreparedRenderPipeline {
        guard !origins.isEmpty || !scales.isEmpty || !angles.isEmpty else { return self }
        guard !parentByID.isEmpty || !hostTransforms.isEmpty else {
            var didChange = false
            let newLayers = layers.map { layer -> WPEPreparedRenderLayer in
                guard !layer.hasStaticParentModel else { return layer }
                let objectID = layer.graphLayer.objectID
                let origin = origins[objectID]
                let scale = scales[objectID]
                let angle = angles[objectID]
                guard origin != nil || scale != nil || angle != nil else { return layer }
                let graphLayer = layer.graphLayer.applyingTransform(
                    origin: origin,
                    scale: scale,
                    angles: angle
                )
                let current = layer.graphLayer.geometry
                let next = graphLayer.geometry
                guard current.origin != next.origin
                    || current.scale != next.scale
                    || current.angles != next.angles else {
                    return layer
                }
                didChange = true
                return WPEPreparedRenderLayer(
                    graphLayer: graphLayer,
                    puppetModel: layer.puppetModel,
                    passes: layer.passes,
                    effectPublication: layer.effectPublication
                )
            }
            guard didChange else { return self }
            return WPEPreparedRenderPipeline(layers: newLayers)
        }

        let layerLocalTransforms = Dictionary(
            layers.compactMap { layer -> (String, WPERenderObjectTransform)? in
                guard let localGeometry = layer.graphLayer.localGeometry else { return nil }
                return (layer.graphLayer.objectID, WPERenderObjectTransform(localGeometry))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let attachmentOffsets = Dictionary(
            layers.map { ($0.graphLayer.objectID, $0.graphLayer.attachmentOriginOffset) },
            uniquingKeysWith: { first, _ in first }
        )
        var memo: [String: WPERenderObjectTransform] = [:]

        func localTransform(for id: String) -> WPERenderObjectTransform? {
            let base = layerLocalTransforms[id] ?? hostTransforms[id]
            guard let authored = base?.applying(
                origin: origins[id], scale: scales[id], angles: angles[id]
            ) else { return nil }
            return authored.applying(
                origin: authored.origin + (attachmentOffsets[id] ?? .zero),
                scale: nil, angles: nil
            )
        }

        func resolvedTransform(for id: String, stack: Set<String>) -> WPERenderObjectTransform? {
            if let cached = memo[id] { return cached }
            guard let local = localTransform(for: id) else { return nil }
            guard let parentID = parentByID[id],
                  parentID != id,
                  !stack.contains(parentID),
                  stack.count < 100,
                  let parent = resolvedTransform(for: parentID, stack: stack.union([id])) else {
                memo[id] = local
                return local
            }
            let resolved = parent.combining(child: local)
            memo[id] = resolved
            return resolved
        }

        var didChange = false
        let newLayers = layers.map { layer -> WPEPreparedRenderLayer in
            guard !layer.hasStaticParentModel else { return layer }
            let objectID = layer.graphLayer.objectID
            guard let resolved = resolvedTransform(for: objectID, stack: []) else { return layer }
            let current = layer.graphLayer.geometry
            guard current.origin != resolved.origin
                || current.scale != resolved.scale
                || current.angles != resolved.angles else {
                return layer
            }
            didChange = true
            return WPEPreparedRenderLayer(
                graphLayer: layer.graphLayer.applyingTransform(
                    origin: resolved.origin,
                    scale: resolved.scale,
                    angles: resolved.angles
                ),
                puppetModel: layer.puppetModel,
                passes: layer.passes,
                effectPublication: layer.effectPublication
            )
        }
        guard didChange else { return self }
        return WPEPreparedRenderPipeline(layers: newLayers)
    }

    func applyingScriptLayerPresentation(
        _ mutations: [String: WPELayerScriptPresentationMutation]
    ) -> WPEPreparedRenderPipeline {
        guard !mutations.isEmpty else { return self }
        var result = layers.map { layer -> WPEPreparedRenderLayer in
            guard let mutation = mutations[layer.graphLayer.objectID] else { return layer }
            return layer.replacing(
                graphLayer: layer.graphLayer.applyingScriptPresentation(mutation),
                passes: layer.passes
            )
        }
        if mutations.values.contains(where: { $0.sortIndex != nil }) {
            result = result.enumerated().sorted {
                let a = $0.element.graphLayer.sortIndex, b = $1.element.graphLayer.sortIndex
                return a == b ? $0.offset < $1.offset : a < b
            }.map(\.element)
        }
        return WPEPreparedRenderPipeline(layers: result)
    }

    /// Runtime createLayer: independent material, optionally followed by its canonical scene copy.
    func addingCreatedLayers(
        _ createdLayers: [String: WPECreatedLayerScriptState],
        templatesByImagePath: [String: WPEPreparedRenderLayer]
    ) -> WPEPreparedRenderPipeline {
        guard !createdLayers.isEmpty, !templatesByImagePath.isEmpty else { return self }

        let dynamicLayers = createdLayers.values
            .sorted {
                if let a = $0.sortIndex, let b = $1.sortIndex, a != b {
                    return a < b
                }
                return $0.key < $1.key
            }
            .compactMap { state -> WPEPreparedRenderLayer? in
                guard state.visible,
                      state.alpha > 0.001,
                      let template = templatesByImagePath[state.imagePath],
                      template.createdImagePassLayout != nil else {
                    return nil
                }
                return template.createdLayerCopy(state: state)
            }
        guard !dynamicLayers.isEmpty else { return self }

        var result = layers
        for layer in dynamicLayers {
            let insertionIndex = result.lastIndex {
                $0.graphLayer.sortIndex <= layer.graphLayer.sortIndex
            }.map { result.index(after: $0) } ?? result.startIndex
            result.insert(layer, at: insertionIndex)
        }
        return WPEPreparedRenderPipeline(layers: result)
    }

    /// Builtins where g_Color is object tint (object.color * brightness); never overwrite foreign g_Color.
    static func consumesLayerColor(_ shader: String) -> Bool {
        switch WPEBuiltinShaderName.normalized(shader) {
        case WPEBuiltinShaderKind.solidLayer.rawValue, WPEBuiltinShaderKind.solidColor.rawValue:
            return true
        default:
            return false
        }
    }

    /// objectUniformCache: nil recomputes every layer's object matrices.
    func addingMetalRuntimeUniforms(
        _ runtimeUniforms: WPEMetalRuntimeUniforms,
        camera: WPEMetalCameraUniforms,
        scriptedConstants: [String: [String: WPESceneShaderConstantValue]] = [:],
        objectUniformCache: WPEObjectUniformCache? = nil
    ) -> (pipeline: WPEPreparedRenderPipeline, frameUniforms: WPEFrameUniformContext) {
        // Resolve computed properties once per frame. Frame/object uniforms stay in WPEFrameUniformContext so they win.
        let runtimeUniformValues = runtimeUniforms.uniformValues
        let cameraUniformValues = camera.uniformValues
        // g_ModelMatrix is object-scoped and depends only on origin/scale/angles; pre-resolve geometry is the same one resolved(at:) would produce for those.
        let objectUniformValuesByPassID = (objectUniformCache ?? WPEObjectUniformCache())
            .objectUniformValuesByPassID(for: layers)
        let needsRebuild = layers.contains { layer in
            layer.graphLayer.isTimeVarying
                || Self.needsPassRebuild(layer, scriptedConstants: scriptedConstants)
        }
        var frameUniforms = WPEFrameUniformContext(
            runtimeUniformValues: runtimeUniformValues,
            cameraUniformValues: cameraUniformValues,
            objectUniformValuesByPassID: objectUniformValuesByPassID
        )
        frameUniforms.affineModelMatrixPassIDs = Set(layers.filter {
            $0.modelMatrixOverride.flatMap(WPEMetalObjectUniforms.matrix4x4(fromColumnMajor:)) != nil
        }.flatMap { $0.passes.map(\.id) })
        for layer in layers {
            guard let extent = layer.graphLayer.compositeSourceExtent else { continue }
            for pass in layer.passes {
                frameUniforms.textureReductionScaleByPassID[pass.id] = extent.textureReductionScale
            }
        }
        if camera.hasCapturedFlatDrawProjection {
            for layer in layers where WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer.graphLayer, camera: camera) {
                for pass in layer.passes where pass.shader?.isBuiltin == false {
                    if case .scene = pass.pass.target {
                        frameUniforms.drawViewProjectionMatrixByPassID[pass.id] = .vector(
                            camera.shaderDrawViewProjectionMatrix(objectID: layer.id)
                        )
                    }
                }
            }
        }
        if camera.sceneMotion != .identity || camera.hasCapturedOrthographicShaderGlobals {
            let localCamera = camera.applyingSceneMotion(.identity).legacyCameraUniformValues
            for layer in layers {
                for pass in layer.passes {
                    if case .scene = pass.pass.target {
                        if layer.graphLayer.isUtilityModelLayer, layer.graphLayer.groupCompositeSource == nil {
                            frameUniforms.cameraUniformValuesByPassID[pass.pass.id] = localCamera
                        } else if camera.usesObjectPerspective(objectID: layer.id) {
                            var values = cameraUniformValues
                            values["g_ViewProjectionMatrix"] = .vector(camera.objectViewProjectionMatrix(objectID: layer.id))
                            frameUniforms.cameraUniformValuesByPassID[pass.pass.id] = values
                        }
                    } else {
                        // Camera zoom changes scene placement, never the local
                        // image/text effect surface that will be composited later.
                        frameUniforms.cameraUniformValuesByPassID[pass.pass.id] = localCamera
                    }
                }
            }
        }
        // Nothing below can change a value. Hand back the load-time pipeline instead of copying the tree every frame.
        guard needsRebuild else { return (self, frameUniforms) }
        let preparedLayers = layers.map { layer -> WPEPreparedRenderLayer in
            guard layer.graphLayer.isTimeVarying
                || Self.needsPassRebuild(layer, scriptedConstants: scriptedConstants) else {
                return layer
            }
            let resolvedGraphLayer = layer.graphLayer.resolved(at: runtimeUniforms.time)
            let geometry = resolvedGraphLayer.geometry
            return layer.replacing(
                graphLayer: resolvedGraphLayer,
                passes: layer.passes.map { pass in
                    let scripted = scriptedConstants[pass.pass.id]
                    // Resolve animated tints each frame or the graph-build seed freezes the layer. Alpha-only counts: solid alpha rides in g_Color.w.
                    let overridesLayerColor = (geometry.colorAnimation != nil || geometry.alphaAnimation != nil)
                        && pass.pass.constants["g_Color"] != nil
                        && Self.consumesLayerColor(pass.pass.shader)
                    if !pass.hasAnimatedUniformValues, scripted == nil, !overridesLayerColor {
                        return pass
                    }
                    var values = pass.uniformValues.mapValues {
                        $0.resolved(at: runtimeUniforms.time)
                    }
                    // The animated tint is a recomputed seed: it goes in before the script merge so scripted constants still override.
                    if overridesLayerColor {
                        let tint = geometry.color * geometry.brightness
                        values["g_Color"] = .vector([tint.x, tint.y, tint.z, geometry.alpha])
                    }
                    // A script claim on animated g_Color lands after resolve, component-wise: the animation still owns what the script did not take.
                    if let claim = pass.layerTintOverride, var rgba = values["g_Color"]?.vectorValue {
                        while rgba.count < 4 { rgba.append(1) }
                        if let color = claim.color {
                            rgba[0] = color.x
                            rgba[1] = color.y
                            rgba[2] = color.z
                        }
                        if let alpha = claim.alpha {
                            rgba[3] = alpha
                        }
                        values["g_Color"] = .vector(rgba)
                    }
                    // Script constants override seed; cannot bind g_* frame uniforms
                    // (the frame context wins for frame-global names at read time).
                    if let scripted {
                        for (key, value) in scripted {
                            // Scripts address a constant by its AUTHORED name; the pass is keyed by the SHADER name. Without translation the value lands in a slot no shader reads.
                            let uniformName = pass.materialUniformNames[key] ?? key
                            values[uniformName] = value
                        }
                    }
                    return WPEPreparedRenderPass(
                        pass: pass.pass,
                        shader: pass.shader,
                        textureBindings: pass.textureBindings,
                        comboValues: pass.comboValues,
                        uniformValues: values,
                        materialUniformNames: pass.materialUniformNames,
                        stageUniformBindings: WPEUniformStageBinding.resolved(pass.stageUniformBindings, at: runtimeUniforms.time, authoredUpdates: scripted),
                        layerTintOverride: pass.layerTintOverride,
                        alphaContract: pass.alphaContract,
                        publicationVertexRole: pass.publicationVertexRole,
                        reusingAccess: pass.access
                    )
                }
            )
        }
        return (WPEPreparedRenderPipeline(layers: preparedLayers), frameUniforms)
    }

    /// Layer-tint is NOT here: it needs graphLayer.isTimeVarying, which every caller already tests alongside this.
    private static func needsPassRebuild(
        _ layer: WPEPreparedRenderLayer,
        scriptedConstants: [String: [String: WPESceneShaderConstantValue]]
    ) -> Bool {
        layer.passes.contains { pass in
            pass.hasAnimatedUniformValues || scriptedConstants[pass.pass.id] != nil
        }
    }
}

enum WPECreatedImagePassLayout: Equatable, Sendable {
    case directMaterial
    case isolatedMaterialAndSceneCopy
}

extension WPEPreparedRenderLayer {
    /// Admission for COPYING one layer. A hidden template may write its own
    /// composite rather than the scene; that is safe to promote for a clone.
    /// Arbitrary effects, foreign FBO reads and programmable blending stay out.
    var createdImagePassLayout: WPECreatedImagePassLayout? {
        let graph = graphLayer
        guard puppetModel == nil, graph.parentObjectID == nil, graph.attachment == nil,
              graph.animationLayers.isEmpty, graph.localFBOs.isEmpty,
              graph.groupRenderTarget == nil, graph.groupCompositeSource == nil,
              graph.geometry.shapePoints == nil,
              let material = passes.first, material.pass.phase == .material,
              passes.allSatisfy({ $0.pass.constantScripts.isEmpty && $0.pass.visibilityGate == nil
                      && $0.pass.userTextureBindings.isEmpty }) else { return nil }
        func reads(_ pass: WPEPreparedRenderPass) -> [WPETextureReference] {
            [pass.pass.source] + pass.textureReferences + Array(pass.pass.binds.values)
        }
        guard reads(material).allSatisfy({
            switch $0 {
            case .image, .asset: true
            case .fbo, .previous: false
            }
        }) else { return nil }
        func ownComposite(_ target: WPERenderTarget) -> String? {
            guard case let .layerComposite(name) = target,
                  name == graph.compositeA || name == graph.compositeB else { return nil }
            return name
        }
        if passes.count == 1,
           material.pass.target == .scene || ownComposite(material.pass.target) != nil {
            return .directMaterial
        }
        guard passes.count == 2, let producer = ownComposite(material.pass.target) else { return nil }
        let copy = passes[1]
        guard copy.pass.target == .scene,
              copy.pass.phase == .command(file: WPERenderPassPhase.sceneCopyCommandFile),
              copy.pass.shader == WPERenderPassPhase.sceneCopyCommandFile,
              reads(copy).allSatisfy({ $0 == .fbo(producer) }) else { return nil }
        return .isolatedMaterialAndSceneCopy
    }

    /// Admission for REORDERING the existing graph. Each accepted layer owns
    /// every FBO it reads, so changing the layer order cannot move a consumer
    /// before another layer's producer. Particle/text/group checks are external.
    var permitsIndependentImageReordering: Bool {
        createdImagePassLayout != nil
    }
}

private extension WPEPreparedRenderLayer {
    func createdLayerCopy(state: WPECreatedLayerScriptState) -> WPEPreparedRenderLayer? {
        guard let layout = createdImagePassLayout else { return nil }
        let composite = WPERenderTargetNames.CreatedLayerComposite.make(key: state.key)
        let replacement = [graphLayer.compositeA: composite.a, graphLayer.compositeB: composite.b]
        func reference(_ value: WPETextureReference) -> WPETextureReference {
            guard case let .fbo(name) = value, let fresh = replacement[name] else { return value }
            return .fbo(fresh)
        }
        func target(_ value: WPERenderTarget) -> WPERenderTarget {
            if case .directMaterial = layout {
                return .scene
            }
            guard case let .layerComposite(name) = value, let fresh = replacement[name] else { return value }
            return .layerComposite(name: fresh)
        }
        let dynamicPasses = passes.enumerated().map { index, preparedPass in
            let p = preparedPass.pass
            let renderPass = WPERenderPass(
                id: "\(state.key).\(index)", phase: p.phase, shader: p.shader,
                source: reference(p.source), target: target(p.target),
                textures: p.textures.mapValues(reference), binds: p.binds.mapValues(reference),
                constants: p.constants, combos: p.combos,
                userTextureBindings: p.userTextureBindings, authoredJSON: p.authoredJSON,
                blending: p.blending, cullMode: p.cullMode, depthTest: p.depthTest,
                depthWrite: p.depthWrite, constantScripts: p.constantScripts, visibilityGate: p.visibilityGate
            )
            return WPEPreparedRenderPass(
                pass: renderPass, shader: preparedPass.shader,
                textureBindings: preparedPass.textureBindings.mapValues(reference),
                comboValues: preparedPass.comboValues, uniformValues: preparedPass.uniformValues,
                materialUniformNames: preparedPass.materialUniformNames,
                stageUniformBindings: preparedPass.stageUniformBindings,
                layerTintOverride: preparedPass.layerTintOverride,
                alphaContract: preparedPass.alphaContract,
                publicationVertexRole: preparedPass.publicationVertexRole,
                // The initializer re-derives access when FBO names changed.
                reusingAccess: preparedPass.access
            )
        }
        return WPEPreparedRenderLayer(
            graphLayer: graphLayer.createdLayerCopy(state: state, passes: dynamicPasses.map(\.pass)),
            puppetModel: nil, passes: dynamicPasses
        )
    }
}

private extension WPERenderLayer {
    func applyingScriptPresentation(_ mutation: WPELayerScriptPresentationMutation) -> WPERenderLayer {
        let g = geometry
        let adjusted = WPERenderLayerGeometry(
            origin: g.origin, scale: g.scale, angles: g.angles,
            alignment: mutation.alignment.map { WPESceneAlignment(rawWPEValue: $0) } ?? g.alignment,
            size: g.size, puppetMeshCenter: g.puppetMeshCenter,
            alpha: g.alpha, alphaAnimation: g.alphaAnimation, color: g.color,
            colorAnimation: g.colorAnimation, brightness: g.brightness, shapePoints: g.shapePoints
        )
        return WPERenderLayer(
            objectID: objectID, objectName: objectName, visible: visible,
            imagePath: imagePath, materialPath: materialPath, puppetPath: puppetPath,
            parentObjectID: parentObjectID, attachment: attachment, attachmentOriginOffset: attachmentOriginOffset, animationLayers: animationLayers,
            authoredJSON: authoredJSON, geometry: adjusted, localGeometry: localGeometry,
            compositeA: compositeA, compositeB: compositeB, compositeSourceExtent: compositeSourceExtent, localFBOs: localFBOs,
            passes: passes, groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry, groupCompositeSource: groupCompositeSource,
            parallaxDepth: mutation.parallaxDepth ?? parallaxDepth,
            sortIndex: mutation.sortIndex ?? sortIndex,
            meshMaterialTextures: meshMaterialTextures
        )
    }

    func createdLayerCopy(
        state: WPECreatedLayerScriptState,
        passes: [WPERenderPass]
    ) -> WPERenderLayer {
        let g = geometry
        let dynamicGeometry = WPERenderLayerGeometry(
            origin: state.origin,
            scale: state.scale,
            angles: state.angles.map { $0 * (.pi / 180) } ?? g.angles,
            alignment: state.alignment.map { WPESceneAlignment(rawWPEValue: $0) } ?? g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: state.alpha,
            alphaAnimation: nil,
            color: state.color,
            brightness: g.brightness
        )
        return WPERenderLayer(
            objectID: state.key,
            objectName: state.key,
            visible: state.visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: nil,
            parentObjectID: nil,
            attachment: nil,
            animationLayers: [],
            authoredJSON: authoredJSON,
            geometry: dynamicGeometry,
            localGeometry: dynamicGeometry,
            compositeA: WPERenderTargetNames.CreatedLayerComposite.make(key: state.key).a,
            compositeB: WPERenderTargetNames.CreatedLayerComposite.make(key: state.key).b,
            compositeSourceExtent: compositeSourceExtent,
            localFBOs: [],
            passes: passes,
            groupRenderTarget: nil,
            groupLocalGeometry: nil,
            groupCompositeSource: nil,
            parallaxDepth: state.parallaxDepth ?? parallaxDepth,
            sortIndex: state.sortIndex ?? sortIndex
        )
    }

    func applyingTransform(
        origin: SIMD3<Double>?,
        scale: SIMD3<Double>?,
        angles: SIMD3<Double>?
    ) -> WPERenderLayer {
        let adjustedGeometry = geometry.applyingTransform(
            origin: origin,
            scale: scale,
            angles: angles
        )
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            attachmentOriginOffset: attachmentOriginOffset,
            animationLayers: animationLayers,
            authoredJSON: authoredJSON,
            geometry: adjustedGeometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            compositeSourceExtent: compositeSourceExtent,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex,
            meshMaterialTextures: meshMaterialTextures
        )
    }

    var isTimeVarying: Bool {
        geometry.isTimeVarying
            || localGeometry?.isTimeVarying == true
            || groupLocalGeometry?.isTimeVarying == true
    }

    func resolved(at time: Double) -> WPERenderLayer {
        guard isTimeVarying else { return self }
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            attachmentOriginOffset: attachmentOriginOffset,
            animationLayers: animationLayers,
            authoredJSON: authoredJSON,
            geometry: geometry.resolved(at: time),
            localGeometry: localGeometry?.resolved(at: time),
            compositeA: compositeA,
            compositeB: compositeB,
            compositeSourceExtent: compositeSourceExtent,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry?.resolved(at: time),
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex,
            meshMaterialTextures: meshMaterialTextures
        )
    }
}

private extension WPERenderLayerGeometry {
    func applyingTransform(
        origin: SIMD3<Double>?,
        scale: SIMD3<Double>?,
        angles: SIMD3<Double>?
    ) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: origin ?? self.origin,
            scale: scale ?? self.scale,
            angles: angles ?? self.angles,
            alignment: alignment,
            size: size,
            puppetMeshCenter: puppetMeshCenter,
            alpha: alpha,
            alphaAnimation: alphaAnimation,
            color: color,
            // Must carry colorAnimation; dropping it would freeze color on the first transform.
            colorAnimation: colorAnimation,
            brightness: brightness,
            shapePoints: shapePoints
        )
    }
}

enum WPERenderPipelineError: Error, Equatable, LocalizedError, Sendable {
    case shaderMissing(name: String, stage: String, path: String)
    case includeMissing(path: String, requestedBy: String)
    case includeCycle(path: String)
    case sourceExpansionLimit(path: String, limit: String)
    case invalidSourceEncoding(path: String)

    var errorDescription: String? {
        switch self {
        case let .shaderMissing(name, stage, path):
            String(
                localized: "error.render.pipeline.shader_missing",
                defaultValue: "WPE shader \(name) is missing \(stage) source at \(path)",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine shader source file is missing."
            )
        case let .includeMissing(path, requestedBy):
            String(
                localized: "error.render.pipeline.include_missing",
                defaultValue: "WPE shader include \(path) requested by \(requestedBy) is missing",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine shader include file is missing."
            )
        case let .includeCycle(path):
            String(
                localized: "error.render.pipeline.include_cycle",
                defaultValue: "WPE shader include cycle detected at \(path)",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine shader include cycle is detected."
            )
        case let .sourceExpansionLimit(path, limit):
            "WPE shader source exceeds the \(limit) limit at \(path)"
        case let .invalidSourceEncoding(path):
            String(
                localized: "error.render.pipeline.invalid_source_encoding",
                defaultValue: "WPE shader source is not UTF-8: \(path)",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine shader source file is not UTF-8."
            )
        }
    }

}
#endif
