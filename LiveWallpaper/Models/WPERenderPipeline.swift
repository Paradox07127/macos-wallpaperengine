#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Render graph IR: passes preserved; shader passes carry expanded GLSL.
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

    let pass: WPERenderPass
    let shader: WPEShaderProgram?
    let textureBindings: [Int: WPETextureReference]
    let comboValues: [String: Int]
    let uniformValues: [String: WPESceneShaderConstantValue]
    /// Authored (`material`) name → shader uniform name, from the shader's own
    /// `// {"material":"…"}` annotations. `uniformValues` is keyed by the SHADER
    /// name, while scene JSON and SceneScript both speak the authored name.
    let materialUniformNames: [String: String]
    /// Whether any value is `.animated` — the only case where
    /// `resolved(at:)` is not the identity. Computed once at construction so
    /// the per-frame prepare can reuse a fully static pass without cloning
    /// its dictionaries.
    let hasAnimatedUniformValues: Bool
    /// Set when a script overrode the layer tint of a pass whose `g_Color` is
    /// itself animated. Writing the override straight into the value would
    /// sample the animation at frame 0 and store it back as a static vector,
    /// freezing the components the script never claimed.
    let layerTintOverride: WPELayerTintOverride?

    init(
        pass: WPERenderPass,
        shader: WPEShaderProgram?,
        textureBindings: [Int: WPETextureReference],
        comboValues: [String: Int],
        uniformValues: [String: WPESceneShaderConstantValue],
        materialUniformNames: [String: String] = [:],
        layerTintOverride: WPELayerTintOverride? = nil
    ) {
        self.pass = pass
        self.shader = shader
        self.textureBindings = textureBindings
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
        let scaled = SIMD3<Double>(
            child.origin.x * scale.x,
            child.origin.y * scale.y,
            child.origin.z * scale.z
        )
        let rotated = Self.rotate(scaled, by: angles)

        return WPERenderObjectTransform(
            origin: SIMD3<Double>(
                origin.x + rotated.x,
                origin.y + rotated.y,
                origin.z + rotated.z
            ),
            scale: SIMD3<Double>(
                scale.x * child.scale.x,
                scale.y * child.scale.y,
                scale.z * child.scale.z
            ),
            angles: angles + child.angles
        )
    }

    private static func rotate(_ value: SIMD3<Double>, by angles: SIMD3<Double>) -> SIMD3<Double> {
        var result = value

        if angles.x != 0 {
            let c = cos(angles.x)
            let s = sin(angles.x)
            result = SIMD3<Double>(
                result.x,
                result.y * c - result.z * s,
                result.y * s + result.z * c
            )
        }
        if angles.y != 0 {
            let c = cos(angles.y)
            let s = sin(angles.y)
            result = SIMD3<Double>(
                result.x * c + result.z * s,
                result.y,
                -result.x * s + result.z * c
            )
        }
        if angles.z != 0 {
            let c = cos(angles.z)
            let s = sin(angles.z)
            result = SIMD3<Double>(
                result.x * c - result.y * s,
                result.x * s + result.y * c,
                result.z
            )
        }

        return result
    }
}

struct WPEShaderProgram: Equatable, Sendable {
    let name: String
    let vertexSource: String
    let fragmentSource: String
    let isBuiltin: Bool
}

extension WPEPreparedRenderPipeline {
    /// Applies a live scene-visibility toggle without rebuilding the pipeline;
    /// the executor reads `graphLayer.visible` to gate the scene draw.
    func applyingLayerVisibility(_ visibility: [String: Bool]) -> WPEPreparedRenderPipeline {
        guard !visibility.isEmpty else { return self }
        var didChange = false
        let newLayers = layers.map { layer -> WPEPreparedRenderLayer in
            let resolved = visibility[layer.graphLayer.objectID] ?? layer.graphLayer.visible
            guard resolved != layer.graphLayer.visible else { return layer }
            didChange = true
            return WPEPreparedRenderLayer(
                graphLayer: layer.graphLayer.applyingVisible(resolved),
                puppetModel: layer.puppetModel,
                passes: layer.passes
            )
        }
        guard didChange else { return self }
        return WPEPreparedRenderPipeline(layers: newLayers)
    }

    /// Script layer alpha override (clears authored alpha animation).
    func applyingLayerAlpha(_ alpha: [String: Double]) -> WPEPreparedRenderPipeline {
        guard !alpha.isEmpty else { return self }
        var didChange = false
        let newLayers = layers.map { layer -> WPEPreparedRenderLayer in
            guard let value = alpha[layer.graphLayer.objectID] else { return layer }
            let geometry = layer.graphLayer.geometry
            guard geometry.alpha != value || geometry.alphaAnimation != nil else { return layer }
            didChange = true
            let graphLayer = layer.graphLayer.applyingAlpha(value)
            return WPEPreparedRenderLayer(
                graphLayer: graphLayer,
                puppetModel: layer.puppetModel,
                passes: Self.passesApplyingLayerTint(
                    layer.passes, geometry: graphLayer.geometry,
                    updateColor: false, updateAlpha: true
                )
            )
        }
        guard didChange else { return self }
        return WPEPreparedRenderPipeline(layers: newLayers)
    }

    /// Script layer color override (clears authored color animation).
    func applyingLayerColor(_ color: [String: SIMD3<Double>]) -> WPEPreparedRenderPipeline {
        guard !color.isEmpty else { return self }
        var didChange = false
        let newLayers = layers.map { layer -> WPEPreparedRenderLayer in
            guard let value = color[layer.graphLayer.objectID] else { return layer }
            let geometry = layer.graphLayer.geometry
            guard geometry.color != value || geometry.colorAnimation != nil else { return layer }
            didChange = true
            let graphLayer = layer.graphLayer.applyingColor(value)
            return WPEPreparedRenderLayer(
                graphLayer: graphLayer,
                puppetModel: layer.puppetModel,
                passes: Self.passesApplyingLayerTint(
                    layer.passes, geometry: graphLayer.geometry,
                    updateColor: true, updateAlpha: false
                )
            )
        }
        guard didChange else { return self }
        return WPEPreparedRenderPipeline(layers: newLayers)
    }

    /// Solid passes bind `g_Color` from `uniformValues`, never from geometry —
    /// and a script override clears the authored animation, which also removes
    /// the layer from `addingMetalRuntimeUniforms`' rebuild condition. Without
    /// writing the tint through here, an overridden solid layer stays frozen at
    /// its load-time color. Component-wise on purpose: an alpha override must
    /// not clobber an authored rgb that differs from the layer tint (and vice
    /// versa).
    private static func passesApplyingLayerTint(
        _ passes: [WPEPreparedRenderPass],
        geometry: WPERenderLayerGeometry,
        updateColor: Bool,
        updateAlpha: Bool
    ) -> [WPEPreparedRenderPass] {
        passes.map { pass in
            guard pass.pass.constants["g_Color"] != nil,
                  Self.consumesLayerColor(pass.pass.shader) else { return pass }
            let tint = updateColor ? geometry.color * geometry.brightness : nil
            let alpha = updateAlpha ? geometry.alpha : nil
            let existing = pass.uniformValues["g_Color"] ?? pass.pass.constants["g_Color"]
            // An animated g_Color must stay animated: record the claim and let
            // the per-frame resolve apply it on top of the sampled value.
            if case .animated = existing {
                return WPEPreparedRenderPass(
                    pass: pass.pass,
                    shader: pass.shader,
                    textureBindings: pass.textureBindings,
                    comboValues: pass.comboValues,
                    uniformValues: pass.uniformValues,
                    materialUniformNames: pass.materialUniformNames,
                    layerTintOverride: WPELayerTintOverride(
                        color: tint ?? pass.layerTintOverride?.color,
                        alpha: alpha ?? pass.layerTintOverride?.alpha
                    )
                )
            }
            var vector = existing?.vectorValue ?? [1, 1, 1, 1]
            while vector.count < 4 { vector.append(1) }
            if let tint {
                vector[0] = tint.x
                vector[1] = tint.y
                vector[2] = tint.z
            }
            if let alpha {
                vector[3] = alpha
            }
            var values = pass.uniformValues
            values["g_Color"] = .vector(vector)
            return WPEPreparedRenderPass(
                pass: pass.pass,
                shader: pass.shader,
                textureBindings: pass.textureBindings,
                comboValues: pass.comboValues,
                uniformValues: values,
                materialUniformNames: pass.materialUniformNames,
                layerTintOverride: pass.layerTintOverride
            )
        }
    }

    /// Applies per-frame transform-script overrides before object-scoped uniforms
    /// are derived. The maps are keyed by WPE object id and can be sparse.
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
    private static func consumesLayerColor(_ shader: String) -> Bool {
        switch WPEBuiltinShaderName.normalized(shader) {
        case WPEBuiltinShaderKind.solidLayer.rawValue, WPEBuiltinShaderKind.solidColor.rawValue:
            return true
        default:
            return false
        }
    }

    /// - Parameter objectUniformCache: caller-owned memo for the per-layer
    ///   object matrices. Nil recomputes them all, which is what every call
    ///   site did before the cache existed; the render loop passes its
    ///   executor-owned instance so a static scene pays nothing per frame.
    func addingMetalRuntimeUniforms(
        _ runtimeUniforms: WPEMetalRuntimeUniforms,
        camera: WPEMetalCameraUniforms,
        scriptedConstants: [String: [String: WPESceneShaderConstantValue]] = [:],
        objectUniformCache: WPEObjectUniformCache? = nil
    ) -> (pipeline: WPEPreparedRenderPipeline, frameUniforms: WPEFrameUniformContext) {
        // Computed properties: resolve once per frame. Frame/object uniforms stay
        // in `WPEFrameUniformContext` (old merge inserted them last, so they win).
        let runtimeUniformValues = runtimeUniforms.uniformValues
        let cameraUniformValues = camera.uniformValues
        // g_ModelMatrix is object-scoped (one per layer, shared by its passes)
        // and depends only on origin/scale/angles — `resolved(at:)` moves alpha
        // and color, so the pre-resolve geometry read here is the same one the
        // resolve would produce. The cache turns that into per-layer work only
        // when a layer actually moved.
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
        // Nothing below can change a value: the rebuild would copy the tree field
        // for field. Hand back the load-time one instead of allocating an array
        // per layer and a struct per pass on every frame.
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
                    // Resolve animated tints each frame; otherwise the graph-build seed
                    // freezes the layer while Wallpaper Engine advances its color animation.
                    // Alpha-only animation counts too: solid alpha rides in g_Color.w.
                    let overridesLayerColor = (geometry.colorAnimation != nil || geometry.alphaAnimation != nil)
                        && pass.pass.constants["g_Color"] != nil
                        && Self.consumesLayerColor(pass.pass.shader)
                    // Static pass: reuse the load-time struct (CoW dictionaries).
                    if !pass.hasAnimatedUniformValues, scripted == nil, !overridesLayerColor {
                        return pass
                    }
                    var values = pass.uniformValues.mapValues {
                        $0.resolved(at: runtimeUniforms.time)
                    }
                    // The animated tint is a recomputed SEED, so it goes in
                    // before the script merge — scripted constants override
                    // seed values, including a g_Color a script sets directly.
                    if overridesLayerColor {
                        let tint = geometry.color * geometry.brightness
                        values["g_Color"] = .vector([tint.x, tint.y, tint.z, geometry.alpha])
                    }
                    // A script claim on an animated g_Color lands after the
                    // resolve, component-wise: the animation still owns
                    // whatever the script did not take.
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
                            // Scripts address a constant by its AUTHORED name
                            // (`multiply1`); the pass is keyed by the SHADER name
                            // (`g_Multiply`), same translation the static
                            // `pass.constants` seed already does. Without it the
                            // value lands in a slot no shader reads.
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
                        layerTintOverride: pass.layerTintOverride
                    )
                }
            )
        }
        return (WPEPreparedRenderPipeline(layers: preparedLayers), frameUniforms)
    }

    /// A pass rebuild is driven by animated authored values or a script write.
    /// The layer-tint case is NOT here: it needs `graphLayer.isTimeVarying`,
    /// which every caller already tests alongside this.
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
            blending: p.blending,
            cullMode: p.cullMode,
            depthTest: p.depthTest,
            depthWrite: p.depthWrite
        )
        let dynamicPass = WPEPreparedRenderPass(
            pass: renderPass,
            shader: preparedPass.shader,
            textureBindings: preparedPass.textureBindings,
            comboValues: preparedPass.comboValues,
                uniformValues: preparedPass.uniformValues,
                materialUniformNames: preparedPass.materialUniformNames,
                layerTintOverride: preparedPass.layerTintOverride
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

    func applyingVisible(_ visible: Bool) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            geometry: geometry,
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

    /// Overrides the layer's alpha (clearing the authored alpha animation so a
    /// later `resolved(at:)` keeps the script-driven value).
    func applyingAlpha(_ alpha: Double) -> WPERenderLayer {
        let g = geometry
        let overridden = WPERenderLayerGeometry(
            origin: g.origin,
            scale: g.scale,
            angles: g.angles,
            alignment: g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: alpha,
            alphaAnimation: nil,
            color: g.color,
            colorAnimation: g.colorAnimation,
            brightness: g.brightness,
            shapePoints: g.shapePoints
        )
        // Live alpha must update groupLocalGeometry (group-buffer draw source).
        let overriddenGroupLocal = groupLocalGeometry.map { gl in
            WPERenderLayerGeometry(
                origin: gl.origin,
                scale: gl.scale,
                angles: gl.angles,
                alignment: gl.alignment,
                size: gl.size,
                puppetMeshCenter: gl.puppetMeshCenter,
                alpha: alpha,
                alphaAnimation: nil,
                color: gl.color,
                colorAnimation: gl.colorAnimation,
                brightness: gl.brightness,
                shapePoints: gl.shapePoints
            )
        }
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
            geometry: overridden,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: overriddenGroupLocal,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    /// Script tint override; mirrors applyingAlpha including group-buffer copy.
    func applyingColor(_ color: SIMD3<Double>) -> WPERenderLayer {
        let g = geometry
        let overridden = WPERenderLayerGeometry(
            origin: g.origin,
            scale: g.scale,
            angles: g.angles,
            alignment: g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: g.alpha,
            alphaAnimation: g.alphaAnimation,
            color: color,
            colorAnimation: nil,
            brightness: g.brightness,
            shapePoints: g.shapePoints
        )
        let overriddenGroupLocal = groupLocalGeometry.map { gl in
            WPERenderLayerGeometry(
                origin: gl.origin,
                scale: gl.scale,
                angles: gl.angles,
                alignment: gl.alignment,
                size: gl.size,
                puppetMeshCenter: gl.puppetMeshCenter,
                alpha: gl.alpha,
                alphaAnimation: gl.alphaAnimation,
                color: color,
                colorAnimation: nil,
                brightness: gl.brightness,
                shapePoints: gl.shapePoints
            )
        }
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
            geometry: overridden,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: overriddenGroupLocal,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    /// Whether `resolved(at:)` can change anything on this layer.
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
            // Must carry colorAnimation (was dropped → freeze on first transform).
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
                comment: "Error shown when a Wallpaper Engine shader source file is missing."
            )
        case .includeMissing(let path, let requestedBy):
            return String(
                localized: "error.render.pipeline.include_missing",
                defaultValue: "WPE shader include \(path) requested by \(requestedBy) is missing",
                comment: "Error shown when a Wallpaper Engine shader include file is missing."
            )
        case .includeCycle(let path):
            return String(
                localized: "error.render.pipeline.include_cycle",
                defaultValue: "WPE shader include cycle detected at \(path)",
                comment: "Error shown when a Wallpaper Engine shader include cycle is detected."
            )
        case .invalidSourceEncoding(let path):
            return String(
                localized: "error.render.pipeline.invalid_source_encoding",
                defaultValue: "WPE shader source is not UTF-8: \(path)",
                comment: "Error shown when a Wallpaper Engine shader source file is not UTF-8."
            )
        }
    }

}
#endif
