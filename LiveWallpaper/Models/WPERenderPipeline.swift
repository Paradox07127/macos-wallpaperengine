#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

struct WPEPreparedRenderPipeline: Equatable, Sendable {
    let layers: [WPEPreparedRenderLayer]
}

struct WPEPreparedRenderLayer: Equatable, Sendable, Identifiable {
    var id: String { graphLayer.id }

    let graphLayer: WPERenderLayer
    let puppetModel: WPEPuppetModel?
    let passes: [WPEPreparedRenderPass]

    init(
        graphLayer: WPERenderLayer,
        puppetModel: WPEPuppetModel? = nil,
        passes: [WPEPreparedRenderPass]
    ) {
        self.graphLayer = graphLayer
        self.puppetModel = puppetModel
        self.passes = passes
    }
}

/// Scripted constant key: (pass id, uniform name).
struct WPEEffectConstantScriptKey: Hashable, Sendable {
    let passID: String
    let uniform: String
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
    /// True when any value is .animated — the only case where resolved(at:) is not the identity.
    let hasAnimatedUniformValues: Bool
    /// Set when a script overrode tint of a pass whose g_Color is animated; writing the override into the value would freeze unclaimed components at frame 0.
    let layerTintOverride: WPELayerTintOverride?

    init(
        pass: WPERenderPass,
        shader: WPEShaderProgram?,
        textureBindings: [Int: WPETextureReference],
        comboValues: [String: Int],
        uniformValues: [String: WPESceneShaderConstantValue],
        materialUniformNames: [String: String] = [:],
        layerTintOverride: WPELayerTintOverride? = nil,
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
        self.layerTintOverride = layerTintOverride
        hasAnimatedUniformValues = uniformValues.values.contains {
            if case .animated = $0 { return true }
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
                    passes: layer.passes
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
        var memo: [String: WPERenderObjectTransform] = [:]

        func localTransform(for id: String) -> WPERenderObjectTransform? {
            let base = layerLocalTransforms[id] ?? hostTransforms[id]
            return base?.applying(
                origin: origins[id],
                scale: scales[id],
                angles: angles[id]
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
                passes: layer.passes
            )
        }
        guard didChange else { return self }
        return WPEPreparedRenderPipeline(layers: newLayers)
    }

    /// Runtime createLayer: single-pass non-puppet templates only.
    func addingCreatedLayers(
        _ createdLayers: [String: WPECreatedLayerScriptState],
        templatesByImagePath: [String: WPEPreparedRenderLayer]
    ) -> WPEPreparedRenderPipeline {
        guard !createdLayers.isEmpty, !templatesByImagePath.isEmpty else { return self }

        let dynamicLayers = createdLayers.values
            .sorted { $0.key < $1.key }
            .compactMap { state -> WPEPreparedRenderLayer? in
                guard state.visible,
                      state.alpha > 0.001,
                      let template = templatesByImagePath[state.imagePath],
                      template.puppetModel == nil,
                      template.passes.count == 1 else {
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
        let frameUniforms = WPEFrameUniformContext(
            runtimeUniformValues: runtimeUniformValues,
            cameraUniformValues: cameraUniformValues,
            objectUniformValuesByPassID: objectUniformValuesByPassID
        )
        // Nothing below can change a value. Hand back the load-time pipeline instead of copying the tree every frame.
        guard needsRebuild else { return (self, frameUniforms) }
        let preparedLayers = layers.map { layer -> WPEPreparedRenderLayer in
            guard layer.graphLayer.isTimeVarying
                || Self.needsPassRebuild(layer, scriptedConstants: scriptedConstants) else {
                return layer
            }
            let resolvedGraphLayer = layer.graphLayer.resolved(at: runtimeUniforms.time)
            let geometry = resolvedGraphLayer.geometry
            return WPEPreparedRenderLayer(
                graphLayer: resolvedGraphLayer,
                puppetModel: layer.puppetModel,
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
                        layerTintOverride: pass.layerTintOverride,
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

private extension WPEPreparedRenderLayer {
    func createdLayerCopy(state: WPECreatedLayerScriptState) -> WPEPreparedRenderLayer? {
        guard let preparedPass = passes.first else { return nil }
        let p = preparedPass.pass
        let renderPass = WPERenderPass(
            id: "\(state.key).0",
            phase: p.phase,
            shader: p.shader,
            source: p.source,
            target: .scene,
            textures: p.textures,
            binds: p.binds,
            constants: p.constants,
            combos: p.combos,
            userTextureBindings: p.userTextureBindings,
            authoredJSON: p.authoredJSON,
            blending: p.blending,
            cullMode: p.cullMode,
            depthTest: p.depthTest,
            depthWrite: p.depthWrite,
            constantScripts: p.constantScripts,
            visibilityGate: p.visibilityGate
        )
        let dynamicPass = WPEPreparedRenderPass(
            pass: renderPass,
            shader: preparedPass.shader,
            textureBindings: preparedPass.textureBindings,
            comboValues: preparedPass.comboValues,
            uniformValues: preparedPass.uniformValues,
            materialUniformNames: preparedPass.materialUniformNames,
            layerTintOverride: preparedPass.layerTintOverride,
            reusingAccess: preparedPass.access
        )
        return WPEPreparedRenderLayer(
            graphLayer: graphLayer.createdLayerCopy(state: state, pass: renderPass),
            puppetModel: nil,
            passes: [dynamicPass]
        )
    }
}

private extension WPERenderLayer {
    func createdLayerCopy(
        state: WPECreatedLayerScriptState,
        pass: WPERenderPass
    ) -> WPERenderLayer {
        let g = geometry
        let dynamicGeometry = WPERenderLayerGeometry(
            origin: state.origin,
            scale: state.scale,
            angles: g.angles,
            alignment: g.alignment,
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
            localFBOs: [],
            passes: [pass],
            groupRenderTarget: nil,
            groupLocalGeometry: nil,
            groupCompositeSource: nil,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
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
            animationLayers: animationLayers,
            authoredJSON: authoredJSON,
            geometry: adjustedGeometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
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
            animationLayers: animationLayers,
            authoredJSON: authoredJSON,
            geometry: geometry.resolved(at: time),
            localGeometry: localGeometry?.resolved(at: time),
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry?.resolved(at: time),
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
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
    case invalidSourceEncoding(path: String)

    var errorDescription: String? {
        switch self {
        case .shaderMissing(let name, let stage, let path):
            return String(
                localized: "error.render.pipeline.shader_missing",
                defaultValue: "WPE shader \(name) is missing \(stage) source at \(path)",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine shader source file is missing."
            )
        case .includeMissing(let path, let requestedBy):
            return String(
                localized: "error.render.pipeline.include_missing",
                defaultValue: "WPE shader include \(path) requested by \(requestedBy) is missing",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine shader include file is missing."
            )
        case .includeCycle(let path):
            return String(
                localized: "error.render.pipeline.include_cycle",
                defaultValue: "WPE shader include cycle detected at \(path)",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine shader include cycle is detected."
            )
        case .invalidSourceEncoding(let path):
            return String(
                localized: "error.render.pipeline.invalid_source_encoding",
                defaultValue: "WPE shader source is not UTF-8: \(path)",
                bundle: .appLanguage, comment: "Error shown when a Wallpaper Engine shader source file is not UTF-8."
            )
        }
    }

}
#endif
