#if !LITE_BUILD
import AppKit
import LiveWallpaperProWPE
import MetalKit

extension WPEMetalSceneRenderer {
    // MARK: - Material parsing

    private struct ParticleMaterialDescriptor {
        let blendMode: WPEParticleBlendMode
        let firstTexturePath: String?
        /// `ui_editor_properties_overbright` HDR colour multiplier (1 = unchanged).
        let overbright: Float
        /// `genericparticle` `REFRACT` combo. Needs `normalTexturePath`.
        let isRefract: Bool
        let normalTexturePath: String?
        /// `g_RefractAmount`. WPE default 0.05.
        let refractAmount: Float
    }

    private func parseParticleMaterial(at relativePath: String) -> ParticleMaterialDescriptor? {
        guard let materialData = try? entryResolver.data(relativePath: relativePath),
              let materialJSON = try? JSONSerialization.jsonObject(with: materialData) as? [String: Any],
              let passes = materialJSON["passes"] as? [[String: Any]],
              let firstPass = passes.first else {
            return nil
        }
        let blendString = firstPass["blending"] as? String
        let textures = firstPass["textures"] as? [Any]
        let firstTexturePath = textures?.first as? String
        let constants = firstPass["constantshadervalues"] as? [String: Any]
        let combos = firstPass["combos"] as? [String: Any]
        let isRefract: Bool = {
            guard let raw = combos?["REFRACT"] else { return false }
            if let n = raw as? NSNumber { return n.intValue != 0 }
            return false
        }()
        let refractAmount: Float = {
            guard let n = constants?["ui_editor_properties_refract_amount"] as? NSNumber,
                  !(constants?["ui_editor_properties_refract_amount"] is Bool) else { return 0.05 }
            return Float(truncating: n)
        }()
        return ParticleMaterialDescriptor(
            blendMode: WPEParticleBlendMode(materialString: blendString),
            firstTexturePath: firstTexturePath,
            overbright: Self.overbright(fromConstants: constants),
            isRefract: isRefract,
            normalTexturePath: (textures?.count ?? 0) >= 2 ? textures?[1] as? String : nil,
            refractAmount: refractAmount
        )
    }

    /// JSON booleans bridge to `NSNumber` 0/1; a stray `false` would black the particle out. Absent/malformed → 1.0.
    nonisolated static func overbright(fromConstants constants: [String: Any]?) -> Float {
        let raw = constants?["ui_editor_properties_overbright"]
        if raw is Bool { return 1.0 }
        guard let number = raw as? NSNumber else { return 1.0 }
        return max(0, Float(truncating: number))
    }

    /// Material overbright × host `brightness`, clamped ≥ 0 so a negative authored brightness cannot invert colours.
    nonisolated static func particleOverbright(
        material: Float?,
        objectBrightness: Double
    ) -> Float {
        max(0, (material ?? 1.0) * Float(objectBrightness))
    }

    // MARK: - Sprite sheets

    /// `<path>.tex-json` sidecar. Nil/malformed → the caller treats the texture as a single-frame sprite.
    private func parseParticleSpriteSheet(
        texturePath: String,
        atlasPixelSize: (width: Int, height: Int)
    ) -> WPEParticleSpriteSheet? {
        let probes = textureCandidates(for: texturePath).map { candidate -> String in
            let stripped = (candidate as NSString).deletingPathExtension
            return "\(stripped).tex-json"
        }
        var seen = Set<String>()
        for probe in probes where seen.insert(probe).inserted {
            guard let data = try? resourceResolver.data(relativePath: probe, optional: true) else {
                continue
            }
            if let sheet = WPEParticleSpriteSheetParser.parse(data: data, atlasPixelSize: atlasPixelSize) {
                return sheet
            }
        }
        return nil
    }

    /// Largest exact square-cell grid over the LOGICAL image (cell = gcd of the sides). Square images stay a static sprite (`nil`). Cell ≥ 16px, ≤ 512 frames.
    static func squareCellGridSpriteSheet(
        logicalWidth: Int,
        logicalHeight: Int,
        atlasWidth: Int,
        atlasHeight: Int,
        isAlphaMask: Bool
    ) -> WPEParticleSpriteSheet? {
        guard logicalWidth > 0, logicalHeight > 0, atlasWidth > 0, atlasHeight > 0 else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int {
            var (a, b) = (a, b)
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        let cell = gcd(logicalWidth, logicalHeight)
        let cols = logicalWidth / cell
        let rows = logicalHeight / cell
        let frames = cols * rows
        guard cell >= 16, frames > 1, frames <= 512 else { return nil }
        var rects: [SIMD4<Float>] = []
        rects.reserveCapacity(frames)
        let w = Float(atlasWidth)
        let h = Float(atlasHeight)
        for row in 0..<rows {
            for col in 0..<cols {
                rects.append(SIMD4<Float>(
                    Float(col * cell) / w,
                    Float(row * cell) / h,
                    Float((col + 1) * cell) / w,
                    Float((row + 1) * cell) / h
                ))
            }
        }
        return WPEParticleSpriteSheet(
            cols: cols,
            rows: rows,
            frameCount: frames,
            baseFrameRate: 0,
            isAlphaMask: isAlphaMask,
            frameRects: rects
        )
    }

    // MARK: - System loading & registration

    private func makeParticleSceneTransform(
        for object: WPESceneParticleObject,
        childTransform: WPEParticleChildTransform = .identity
    ) -> WPEParticleSceneTransform {
        WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(Float(sceneRenderSize.width), Float(sceneRenderSize.height)),
            objectOrigin: SIMD3<Float>(Float(object.origin.x), Float(object.origin.y), Float(object.origin.z)),
            objectScale: SIMD3<Float>(Float(object.scale.x), Float(object.scale.y), Float(object.scale.z)),
            objectAngleZ: Float(object.angles.z),
            childOrigin: SIMD3<Float>(
                Float(childTransform.origin.x),
                Float(childTransform.origin.y),
                Float(childTransform.origin.z)
            ),
            childScale: SIMD3<Float>(
                Float(childTransform.scale.x),
                Float(childTransform.scale.y),
                Float(childTransform.scale.z)
            )
        )
    }
    func particleTextureResource(
        relativePath: String,
        label: String,
        colorSpace: WPEMetalColorSpace? = nil,
        on actor: isolated WPEDisplayRenderActor
    ) async throws -> WPELoadedTextureResource {
        let colorSpace = colorSpace ?? .linear
        let key = ParticleTextureLoadKey(path: relativePath, colorSpace: colorSpace)
        if let cached = particleTextureLoadCache[key] {
            return cached
        }
        let loaded = try await makeTextureResource(
            relativePath: relativePath,
            label: label,
            colorSpace: colorSpace,
            on: actor
        )
        // Only static atlases are cached. Particles never tick a dynamic source, so holding one for the scene lifetime would pin a payload nothing will read again, and none of them are in `dynamicTextureSources` for suspend-time release.
        if case .staticTexture = loaded {
            particleTextureLoadCache[key] = loaded
        }
        return loaded
    }

    /// Missing sprite texture would leave fragment-texture(0) stale and paint the black+red-grid overlay.
    func loadParticleSystems(
        from document: WPESceneDocument,
        on actor: isolated WPEDisplayRenderActor
    ) async {
        particleIndependentSystems.removeAll()
        particleInstanceCoordinator = nil
        particleTemplates.removeAll()
        particleRootTemplates.removeAll()
        particleTemplateTextures.removeAll()
        particleTemplateNormals.removeAll()
        particleSystems.removeAll(keepingCapacity: true)
        particleTextures.removeAll(keepingCapacity: true)
        particleNormalTextures.removeAll(keepingCapacity: true)
        particleTextureLoadCache.removeAll(keepingCapacity: true)
        let imageObjectsByID = Dictionary(
            document.imageObjects.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var expansionBudget = ParticleExpansionBudget()
        for object in document.particleObjects where object.visible {
            let groupEffect = await resolveParticleGroupEffect(
                for: object,
                objectParentByID: document.objectParentByID,
                imageObjectsByID: imageObjectsByID,
                on: actor
            )
            await expandParticleTree(
                path: object.particleRelativePath,
                parentPath: nil,
                childTransform: .identity,
                ancestry: [],
                parentSystem: nil,
                object: object,
                sortIndex: document.objectPaintOrder[object.id] ?? 0,
                groupEffect: groupEffect,
                budget: &expansionBudget,
                on: actor
            )
        }
        debugStage("particles.expand.done", "systems=\(particleSystems.count) roots=\(particleRootTemplates.count)")
        func containsEvent(_ template: WPEParticleTemplate) -> Bool {
            template.children.contains { $0.reference.rollsProbabilityPerEvent || $0.reference.setsParentParticleControlPoints || containsEvent($0.template) }
        }
        let eventRoots = particleRootTemplates.filter(containsEvent)
        var independentIDs: Set<ObjectIdentifier> = []
        func includeIndependent(_ template: WPEParticleTemplate) {
            independentIDs.insert(ObjectIdentifier(template.prototype))
            for child in template.children {
                if child.reference.probability >= 1 || Double.random(in: 0 ..< 1) < child.reference.probability {
                    includeIndependent(child.template)
                }
            }
        }
        for root in particleRootTemplates where !containsEvent(root) {
            includeIndependent(root)
        }
        particleTemplateTextures = particleTextures
        particleTemplateNormals = particleNormalTextures
        particleIndependentSystems = particleSystems.filter { independentIDs.contains(ObjectIdentifier($0)) }
        particleSystems = particleIndependentSystems
        // An event root must not change unrelated roots' existing warm-up/RNG path.
        prewarmParticleSystems()
        debugStage("particles.prewarm.done", "independent=\(particleIndependentSystems.count)")
        if !eventRoots.isEmpty {
            particleInstanceCoordinator = WPEParticleInstanceCoordinator(
                templates: eventRoots, device: executor.textureSourceDevice,
                seed: WPEOracleMode.isEnabled
                    ? WPEParticleSystem.deterministicSeed(workshopID: descriptor.workshopID, objectID: "event-tree", sortIndex: 0)
                    : UInt64.random(in: .min ... .max)
            )
            let oracleReplaySeconds = WPEOracleMode.isEnabled ? WPEOracleMode.loadFrameOverride()?.baseTime : nil
            let seconds = Dictionary(uniqueKeysWithValues: eventRoots.map { template in
                (ObjectIdentifier(template.prototype), Self.particlePrewarmSeconds(
                    for: template.prototype.definition, manualPrewarmEnabled: Self.particlePrewarmEnabled,
                    oracleReplaySeconds: oracleReplaySeconds
                ) ?? 0)
            })
            particleInstanceCoordinator?.prewarm(secondsByRoot: seconds)
            synchronizeParticleInstanceBindings()
            debugStage("particles.eventPrewarm.done", "eventRoots=\(eventRoots.count)")
        }
    }

    /// `starttime` is a simulation offset.
    private func prewarmParticleSystems() {
        guard !particleSystems.isEmpty else { return }
        let oracleReplaySeconds = WPEOracleMode.isEnabled
            ? WPEOracleMode.loadFrameOverride()?.baseTime
            : nil
        for system in particleSystems {
            guard let seconds = Self.particlePrewarmSeconds(
                for: system.definition,
                manualPrewarmEnabled: Self.particlePrewarmEnabled,
                oracleReplaySeconds: oracleReplaySeconds
            ) else { continue }
            system.prewarm(simulatedSeconds: seconds, presimulateDelay: true)
        }
    }

    /// A `composelayer` ancestor's tint + opacity mask must be baked on (particles draw to scene).
    private func resolveParticleGroupEffect(
        for object: WPESceneParticleObject,
        objectParentByID: [String: String],
        imageObjectsByID: [String: WPESceneImageObject],
        on actor: isolated WPEDisplayRenderActor
    ) async -> (mask: MTLTexture?, tint: SIMD3<Float>)? {
        var tint = SIMD3<Float>(1, 1, 1)
        var maskPath: String?
        var current = objectParentByID[object.id]
        var seen: Set<String> = []
        while let id = current, seen.insert(id).inserted {
            if let ancestor = imageObjectsByID[id],
               ancestor.imageRelativePath.lowercased().contains("composelayer") {
                for effect in ancestor.effects where effect.visible {
                    let file = effect.fileRelativePath.lowercased()
                    let pass = effect.passOverrides.first
                    if file.contains("/tint/"),
                       let color = pass?.constants["color"]?.vectorValue, color.count >= 3 {
                        tint = SIMD3<Float>(Float(color[0]), Float(color[1]), Float(color[2]))
                    }
                    if file.contains("/opacity/"),
                       let mask = pass?.textures[1] {
                        maskPath = mask
                    }
                }
            }
            current = objectParentByID[id]
        }
        guard maskPath != nil || tint != SIMD3<Float>(1, 1, 1) else { return nil }
        var maskTexture: MTLTexture?
        if let maskPath,
           let payload = try? await makeTextureResource(
               relativePath: maskPath, label: "particle group mask \(maskPath)", on: actor),
           case .staticTexture(let t) = payload {
            maskTexture = t
        }
        return (maskTexture, tint)
    }

    /// Dedup per ancestry chain so same-path siblings with different `origin` (matrix-rain columns) each instantiate.
    private func expandParticleTree(
        path: String,
        parentPath: String?,
        childTransform: WPEParticleChildTransform,
        ancestry: [String],
        parentSystem: WPEParticleSystem?,
        object: WPESceneParticleObject,
        sortIndex: Int,
        groupEffect: (mask: MTLTexture?, tint: SIMD3<Float>)? = nil,
        childReference: WPEParticleChildReference? = nil,
        budget: inout ParticleExpansionBudget,
        on actor: isolated WPEDisplayRenderActor
    ) async {
        // Reload/cleanup cancels the load task; bail before work or recursion for a dead load.
        guard !Task.isCancelled else { return }
        guard ancestry.count < 16 else {
            debugStage("particle", "skip \(object.name) — particle child depth limit reached at: \(path)")
            return
        }
        let particlePath = resolvedParticleChildPath(path, parentPath: parentPath)
        guard !ancestry.contains(particlePath) else {
            debugStage("particle", "skip \(object.name) — particle child cycle detected: \(particlePath)")
            return
        }
        guard let parsedDefinition = loadParticleDefinition(at: particlePath) else {
            debugStage("particle", "skip \(object.name) — particle definition load failed: \(particlePath)")
            return
        }
        let capacity = max(1, min(parsedDefinition.maxCount, WPEParticleSystem.absoluteCap))
        guard budget.systems < ParticleExpansionBudget.maxSystems,
              budget.particles + capacity <= ParticleExpansionBudget.maxParticles else {
            debugStage("particle", "skip \(object.name) — particle scene budget reached (systems=\(budget.systems) particles=\(budget.particles)): \(particlePath)")
            return
        }
        // Mutable instance properties are sampled on birth. Only immutable brightness
        // and the separately authored animation belong in the shared definition.
        let definition = parsedDefinition.applying(instanceOverride: WPESceneParticleInstanceOverride(
            brightness: object.instanceOverride?.brightness,
            alphaAnimation: object.instanceOverride?.alphaAnimation
        ))
        // Even renderer:[] parents simulate births/deaths for their child templates.
        let registered = await registerParticleSystem(
            definition: definition, object: object, particlePath: particlePath,
            sortIndex: sortIndex, isNestedChild: !ancestry.isEmpty,
            childTransform: childTransform, groupEffect: groupEffect, on: actor
        )
        guard let registered else { return }
        budget.systems += 1
        budget.particles += capacity
        let template = WPEParticleTemplate(registered)
        particleTemplates[ObjectIdentifier(registered)] = template
        if let parentSystem, let childReference,
           let parentTemplate = particleTemplates[ObjectIdentifier(parentSystem)] {
            parentTemplate.children.append(.init(reference: childReference, template: template))
        } else {
            particleRootTemplates.append(template)
        }
        let childParentSystem = registered
        let childAncestry = ancestry + [particlePath]
        for child in parsedDefinition.childReferences {
            if case let .unsupported(type) = child.eventKind {
                debugStage("particle", "skip unsupported child event type \(type): \(child.relativePath)")
                continue
            }
            // Probability is rolled when instances are created (per parent event for event children); only a static 0 is pruned here.
            if !child.rollsProbabilityPerEvent {
                if child.probability <= 0 {
                    continue
                }
            }
            await expandParticleTree(
                path: child.relativePath,
                parentPath: particlePath,
                childTransform: childTransform.appending(child),
                ancestry: childAncestry,
                parentSystem: childParentSystem,
                object: object,
                sortIndex: sortIndex,
                groupEffect: groupEffect,
                childReference: child,
                budget: &budget,
                on: actor
            )
        }
    }

    private func resolvedParticleChildPath(_ childPath: String, parentPath: String?) -> String {
        guard !childPath.contains("/"), let parentPath else {
            return childPath
        }
        let directory = (parentPath as NSString).deletingLastPathComponent
        return directory.isEmpty ? childPath : "\(directory)/\(childPath)"
    }

    private func loadParticleDefinition(at particlePath: String) -> WPEParticleDefinition? {
        guard let data = try? entryResolver.data(relativePath: particlePath) else {
            return nil
        }
        return WPEParticleDefinitionParser.parse(data: data)
    }

    @discardableResult
    /// Same anchor as the layer path, so an emitter and sibling image layers share depth + origin.
    func parallaxRootObjectID(of id: String) -> String {
        WPERenderGraphBuilder.parallaxAnchorNodeID(
            of: id,
            parentByID: objectParentByID,
            depthByID: parallaxAuthoredDepthByObjectID
        )
    }

    private func registerParticleSystem(
        definition: WPEParticleDefinition,
        object: WPESceneParticleObject,
        particlePath: String,
        sortIndex: Int = 0,
        isNestedChild: Bool = false,
        childTransform: WPEParticleChildTransform = .identity,
        groupEffect: (mask: MTLTexture?, tint: SIMD3<Float>)? = nil,
        on actor: isolated WPEDisplayRenderActor
    ) async -> WPEParticleSystem? {
        let material = definition.materialRelativePath
            .flatMap(parseParticleMaterial(at:))
        let blendMode = material?.blendMode ?? .translucent
        let sceneTransform = makeParticleSceneTransform(for: object, childTransform: childTransform)
        if !definition.rendersSprite {
            guard let system = WPEParticleSystem(definition: definition, device: executor.textureSourceDevice,
                                                 blendMode: blendMode, sceneTransform: sceneTransform,
                                                 seed: WPEOracleMode.isEnabled ? WPEParticleSystem.deterministicSeed(
                                                     workshopID: descriptor.workshopID, objectID: object.id, sortIndex: sortIndex
                                                 ) : nil) else { return nil }
            system.instanceValues = WPEParticleInstanceValues(override: object.instanceOverride)
            system.instanceColorBrightnessScale = Float(object.instanceOverride?.brightness ?? 1)
            system.scriptParticleObjectID = object.id
            system.sortIndex = sortIndex
            particleSystems.append(system)
            return system
        }
        guard let texturePath = material?.firstTexturePath else {
            debugStage("particle", "skip \(object.name) — material missing texture binding: \(particlePath)")
            return nil
        }
        guard let texturePayload = try? await particleTextureResource(
            relativePath: texturePath,
            label: "particle texture \(texturePath)",
            on: actor
        ) else {
            debugStage("particle", "skip \(object.name) — texture load failed: \(texturePath)")
            return nil
        }
        // Reload may have reset `particleSystems` during the await; registering now would append a dead load's subtree.
        guard !Task.isCancelled else { return nil }
        let texture: MTLTexture?
        let animatedTextureSource: WPETexAnimatedTextureSource?
        switch texturePayload {
        case .staticTexture(let t):
            texture = t
            animatedTextureSource = nil
        case .dynamicSource(let source):
            texture = source.texture(at: 0)
            animatedTextureSource = source as? WPETexAnimatedTextureSource
        }
        guard let resolved = texture else {
            debugStage("particle", "skip \(object.name) — dynamic source yielded no texture")
            return nil
        }
        var spriteSheet = parseParticleSpriteSheet(
            texturePath: texturePath,
            atlasPixelSize: (width: resolved.width, height: resolved.height)
        )
        // No sidecar (or single-frame) but TEXS has per-frame sub-rects. The uniform-grid path would draw the whole Matrix-glyph atlas as one quad.
        if spriteSheet == nil || (spriteSheet?.frameCount ?? 1) <= 1,
           let animatedTextureSource {
            let frameRects = animatedTextureSource.spriteSheetFrameRectsNormalized()
            if !frameRects.isEmpty {
                spriteSheet = WPEParticleSpriteSheet(
                    cols: 1,
                    rows: 1,
                    frameCount: frameRects.count,
                    baseFrameRate: animatedTextureSource.spriteSheetFrameRate,
                    isAlphaMask: resolved.pixelFormat == .r8Unorm,
                    frameRects: frameRects
                )
            }
        }
        // Repacked sequence atlas can lose TEXS. Only when `animationmode` opted into sequence; a default must not slice single-image sprites.
        if spriteSheet == nil, definition.declaresSequenceAnimation {
            let resolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: resolved)
            spriteSheet = Self.squareCellGridSpriteSheet(
                logicalWidth: resolution.imageWidth,
                logicalHeight: resolution.imageHeight,
                atlasWidth: resolved.width,
                atlasHeight: resolved.height,
                isAlphaMask: resolved.pixelFormat == .r8Unorm
            )
        }
        // R8 without a valid sidecar would sample alpha as 1 → opaque quad. R8 is always an alpha mask.
        if spriteSheet == nil, resolved.pixelFormat == .r8Unorm {
            spriteSheet = WPEParticleSpriteSheet(
                cols: 1, rows: 1, frameCount: 1, baseFrameRate: 0, isAlphaMask: true
            )
        }
        // Oracle: deterministic spawn jitter. `nil` in production ⇒ CSPRNG.
        let oracleSeed: UInt64? = WPEOracleMode.isEnabled
            ? WPEParticleSystem.deterministicSeed(
                workshopID: descriptor.workshopID, objectID: object.id, sortIndex: sortIndex)
            : nil
        guard let system = WPEParticleSystem(
            definition: definition,
            device: executor.textureSourceDevice,
            blendMode: blendMode,
            sceneTransform: sceneTransform,
            childScale: SIMD3<Float>(
                Float(childTransform.scale.x),
                Float(childTransform.scale.y),
                Float(childTransform.scale.z)
            ),
            spriteSheet: spriteSheet,
            seed: oracleSeed
        ) else { return nil }
        #if !LITE_BUILD && DEBUG
        system.traceObjectID = object.id
        system.traceParticlePath = particlePath
        #endif
        let parallaxRoot = parallaxRootObjectID(of: object.id)
        system.parallaxDepth = parallaxAuthoredDepthByObjectID[parallaxRoot] ?? object.parallaxDepth
        let rootOrigin = parallaxAuthoredOriginByObjectID[parallaxRoot]
            ?? SIMD2<Double>(object.origin.x, object.origin.y)
        system.parallaxCenter = SIMD2<Double>(
            rootOrigin.x - Double(sceneRenderSize.width) * 0.5,
            rootOrigin.y - Double(sceneRenderSize.height) * 0.5
        )
        // Particles are not render layers, so they miss graph parent→child composition; walk hosts so a keyframed origin can move this emitter.
        system.hostAncestorIDs = {
            var chain: [String] = []
            var next = object.parentObjectID
            var guardCount = 0
            while let id = next, guardCount < 32 {
                chain.append(id)
                next = objectParentByID[id]
                guardCount += 1
            }
            return chain
        }()
        system.instanceValues = WPEParticleInstanceValues(override: object.instanceOverride)
        system.instanceColorBrightnessScale = Float(object.instanceOverride?.brightness ?? 1)
        system.scriptParticleObjectID = object.id
        system.sortIndex = sortIndex
        system.overbright = Self.particleOverbright(
            material: material?.overbright,
            objectBrightness: object.brightness
        )
        system.isNestedChildSystem = isNestedChild
        if object.instanceOverride?.alphaScript != nil {
            system.instanceAlphaScriptObjectID = object.id
        }
        if let groupEffect {
            system.groupOpacityMask = groupEffect.mask
            system.groupTint = groupEffect.tint
        }
        // REFRACT needs the normal map; load fail → flat sprite. Frame 0 of a dynamic source is the whole atlas (TEXS sub-rects). Demanding `.staticTexture` would drop refraction.
        if material?.isRefract == true, let normalPath = material?.normalTexturePath {
            // a normal map is DATA — sRGB gamma corrupts its vectors
            let normalPayload = try? await particleTextureResource(
                relativePath: normalPath, label: "particle normal \(normalPath)",
                colorSpace: .linear, on: actor)
            let normalTexture: MTLTexture? = switch normalPayload {
            case .staticTexture(let t): t
            case .dynamicSource(let source): source.texture(at: 0)
            case nil: nil
            }
            // `particleNormalTextures` keeps this atlas for the scene's lifetime,
            // so the source must not release (and then re-allocate) that slot.
            if case .dynamicSource(let source) = normalPayload,
               let animated = source as? WPETexAnimatedTextureSource {
                animated.pinSlotHoldingExternally(textureFor: 0)
            }
            if let normalTexture {
                system.isRefract = true
                system.refractAmount = material?.refractAmount ?? 0.05
                particleNormalTextures[ObjectIdentifier(system)] = normalTexture
            }
        }
        particleSystems.append(system)
        particleTextures[ObjectIdentifier(system)] = resolved
        // Same pin as the normal map: this binding outlives every suspend, and a
        // released-then-restored slot would leave two copies of the atlas alive.
        animatedTextureSource?.pinSlotHoldingExternally(textureFor: 0)
        if WPESceneDebugArtifacts.shared.isEnabled {
            let idx = particleSystems.count - 1
            let d = definition
            var s = "particle[\(idx)] name=\(object.name)\n"
            // def index ≠ particle-state-N traceIndex (sorted+filtered). This line pairs the two dumps.
            s += "object=\(object.id) particle=\(object.particleRelativePath)\n"
            s += "material=\(d.materialRelativePath ?? "-") blend=\(blendMode.rawValue) animationMode=\(d.animationMode)\n"
            s += "refract: combo=\(material?.isRefract == true) normal=\(material?.normalTexturePath ?? "-")"
            s += " bound=\(particleNormalTextures[ObjectIdentifier(system)] != nil) amount=\(system.refractAmount)\n"
            s += "maxCount=\(d.maxCount) rate=\(d.rate) startDelay=\(d.startDelay)\n"
            s += "lifetime=[\(d.lifetimeMin),\(d.lifetimeMax)] size=[\(d.sizeMin),\(d.sizeMax)]\n"
            s += "originOffset=\(d.originOffset) dispersal=[\(d.dispersalMin),\(d.dispersalMax)] directionMask=\(d.directionMask)\n"
            s += "velocityMin=\(d.velocityMin) velocityMax=\(d.velocityMax)\n"
            s += "gravity=\(d.gravity) drag=\(d.drag)\n"
            s += "rotation=[\(d.rotationMin),\(d.rotationMax)] angularVel=[\(d.angularVelocityMin),\(d.angularVelocityMax)] angularForceZ=\(d.angularForceZ)\n"
            if let tvi = d.turbulentVelocityInit {
                s += "turbVelInit: speed=[\(tvi.speedMin),\(tvi.speedMax)] scale=\(tvi.scale) offset=\(tvi.offset)\n"
            }
            if let turb = d.turbulence {
                s += "turbulenceOp: speed=[\(turb.speedMin),\(turb.speedMax)] scale=\(turb.scale) timescale=\(turb.timescale) mask=\(turb.mask)\n"
            }
            s += "childTransform: origin=\(childTransform.origin) scale=\(childTransform.scale)\n"
            s += "sceneTransform: renderOrigin=\(sceneTransform.renderOrigin) objectScale=\(sceneTransform.objectScale) objectAngleZ=\(sceneTransform.objectAngleZ)\n"
            WPESceneDebugArtifacts.shared.recordNote(name: "particle-def-\(idx).txt", contents: s)
        }
        let textureLabel = resolved.label ?? "<unlabeled>"
        let sheetDescription: String
        if let sheet = spriteSheet {
            sheetDescription = "sheet=\(sheet.cols)x\(sheet.rows)×\(sheet.frameCount) mask=\(sheet.isAlphaMask)"
        } else {
            sheetDescription = "sheet=none"
        }
        debugStage(
            "particle.binding",
            "\(object.name) particle=\(particlePath) count=\(definition.maxCount) rate=\(definition.rate) blend=\(blendMode.rawValue) texturePath=\(texturePath) texture=\(textureLabel) \(sheetDescription)"
        )
        return system
    }
}

/// Scene-wide load-time totals; shared children referenced by several siblings expand exponentially without it.
private struct ParticleExpansionBudget {
    // ~7x the largest expanded system count per scene in the workshop corpus.
    static let maxSystems = 2048
    // ~4x the largest per-scene sum of capped maxcount in the workshop corpus.
    static let maxParticles = 1_048_576
    var systems = 0
    var particles = 0
}
#endif
