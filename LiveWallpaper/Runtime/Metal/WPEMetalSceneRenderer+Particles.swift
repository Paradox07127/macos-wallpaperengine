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

    private func makeParticleSceneTransform(for object: WPESceneParticleObject) -> WPEParticleSceneTransform {
        WPEParticleSceneTransform(
            sceneSize: SIMD2<Float>(Float(sceneRenderSize.width), Float(sceneRenderSize.height)),
            objectOrigin: SIMD3<Float>(Float(object.origin.x), Float(object.origin.y), Float(object.origin.z)),
            objectScale: SIMD3<Float>(Float(object.scale.x), Float(object.scale.y), Float(object.scale.z)),
            objectAngleZ: Float(object.angles.z)
        )
    }
    func particleTextureResource(
        relativePath: String,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB,
        on actor: isolated WPEDisplayRenderActor
    ) async throws -> WPELoadedTextureResource {
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
        // Only static atlases are cached. Particles read frame 0 plus the
        // sprite-sheet rects and never tick a dynamic source, so holding one for
        // the scene lifetime would pin a lazy `.tex`'s compressed payload — or an
        // AVFoundation decoder — that nothing will ever read again, and none of
        // them are in `dynamicTextureSources` for the suspend-time release.
        if case .staticTexture = loaded {
            particleTextureLoadCache[key] = loaded
        }
        return loaded
    }

    /// Missing sprite texture would leave fragment-texture(0) stale and paint the 3725117707 black+red-grid overlay.
    func loadParticleSystems(
        from document: WPESceneDocument,
        on actor: isolated WPEDisplayRenderActor
    ) async {
        particleSystems.removeAll(keepingCapacity: true)
        particleTextures.removeAll(keepingCapacity: true)
        particleNormalTextures.removeAll(keepingCapacity: true)
        particleTextureLoadCache.removeAll(keepingCapacity: true)
        let imageObjectsByID = Dictionary(
            document.imageObjects.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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
                originAccum: SIMD3<Double>(0, 0, 0),
                ancestry: [],
                parentSystem: nil,
                followFromParent: false,
                object: object,
                sortIndex: document.objectPaintOrder[object.id] ?? 0,
                groupEffect: groupEffect,
                on: actor
            )
        }
        prewarmParticleSystems()
    }

    /// `starttime` is a simulation offset (star fields with 200 load already full). The developer flag only prewarms authored-0 emitters.
    /// `followParent` chains must prewarm in lockstep with the frame-loop injection rule; independent prewarm empties `eventfollow` children (3226487183: 136 `matrix_trail` systems at 0 particles).
    private func prewarmParticleSystems() {
        guard !particleSystems.isEmpty else { return }
        let oracleReplaySeconds = WPEOracleMode.isEnabled
            ? WPEOracleMode.loadFrameOverride()?.baseTime
            : nil
        let presimulateDelay = true
        let seconds = particleSystems.map {
            Self.particlePrewarmSeconds(
                for: $0.definition,
                manualPrewarmEnabled: Self.particlePrewarmEnabled,
                oracleReplaySeconds: oracleReplaySeconds
            )
        }
        // DFS registration: a parent precedes its children, so the chain index is already assigned.
        var chains: [[Int]] = []
        var chainIndexBySystem: [ObjectIdentifier: Int] = [:]
        for (index, system) in particleSystems.enumerated() {
            let chainIndex: Int
            if let parent = system.followParent,
               let parentChain = chainIndexBySystem[ObjectIdentifier(parent)] {
                chainIndex = parentChain
                chains[parentChain].append(index)
            } else {
                chainIndex = chains.count
                chains.append([index])
            }
            chainIndexBySystem[ObjectIdentifier(system)] = chainIndex
        }
        for chain in chains {
            let eligible = chain.compactMap { index in
                seconds[index].map { (system: particleSystems[index], seconds: $0) }
            }
            // One live member keeps the prior spawn sequence (scenes without an eventfollow pair).
            if eligible.count > 1 {
                Self.prewarmFollowChain(eligible, presimulateDelay: presimulateDelay)
            } else if let only = eligible.first {
                only.system.prewarm(simulatedSeconds: only.seconds,
                                    presimulateDelay: presimulateDelay)
            }
        }
    }

    /// Shared clock, parents first, so a child spawns at the position its parent reached on the same substep. Windows align by their end (longer `starttime` started earlier).
    nonisolated static func prewarmFollowChain(
        _ chain: [(system: WPEParticleSystem, seconds: Double)],
        presimulateDelay: Bool,
        step: Double = 1.0 / 60
    ) {
        guard step > 0, let longest = chain.map(\.seconds).max(), longest > 0 else { return }
        // One chain-wide window: a short-lived child must not start before the parent it rides.
        let convergence = chain.map(\.system.definition.lifetimeMax)
            .filter(\.isFinite)
            .max()
        var members: [(system: WPEParticleSystem, offset: Double, span: ClosedRange<Double>)] = []
        for member in chain {
            guard let span = member.system.beginPrewarm(simulatedSeconds: member.seconds,
                                                        presimulateDelay: presimulateDelay,
                                                        convergenceSeconds: convergence)
            else { continue }
            members.append((member.system, longest - member.seconds, span))
        }
        for substep in 0..<Int((longest / step).rounded(.up)) {
            let wall = min(longest, Double(substep + 1) * step)
            for member in members {
                let local = wall - member.offset
                guard local > member.span.lowerBound else { continue }
                injectFollowControlPoint(into: member.system)
                member.system.prewarmStep(to: min(local, member.span.upperBound))
            }
        }
        for member in members { member.system.endPrewarm() }
    }

    /// A `composelayer` ancestor's tint + opacity mask must be baked on (particles draw to scene). 3462491575 matrix rain is cyan-tinted and masked.
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

    /// Dedup per ancestry chain so same-path siblings with different `origin` (matrix-rain columns) each instantiate. `renderer: []` expands but does not register.
    private func expandParticleTree(
        path: String,
        parentPath: String?,
        originAccum: SIMD3<Double>,
        ancestry: [String],
        parentSystem: WPEParticleSystem?,
        followFromParent: Bool,
        object: WPESceneParticleObject,
        sortIndex: Int,
        groupEffect: (mask: MTLTexture?, tint: SIMD3<Float>)? = nil,
        childReference: WPEParticleChildReference? = nil,
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
        let definition = parsedDefinition
            .offsettingOrigin(by: originAccum)
            .applying(instanceOverride: object.instanceOverride)
        let registered: WPEParticleSystem?
        if definition.rendersSprite {
            registered = await registerParticleSystem(
                definition: definition,
                object: object,
                particlePath: particlePath,
                followParent: followFromParent ? parentSystem : nil,
                requiresFollowParent: followFromParent,
                sortIndex: sortIndex,
                isNestedChild: !ancestry.isEmpty,
                groupEffect: groupEffect,
                on: actor
            )
            // Event-driven children re-roll per parent event; only the system sees those events.
            if let registered, let childReference, childReference.rollsProbabilityPerEvent {
                registered.spawnProbability = childReference.probability
            }
        } else {
            registered = nil
            debugStage("particle", "expand-only \(object.name) — renderer disabled: \(particlePath)")
        }
        // `renderer:[]` forwards its own parent. A failed rendering parent forwards nil so children stay gated, not silently following the grandparent.
        let childParentSystem = definition.rendersSprite ? registered : parentSystem
        let childAncestry = ancestry + [particlePath]
        for child in parsedDefinition.childReferences {
            // Event-driven probability belongs in `WPEParticleSystem` (per parent event). Rolling here would freeze the effect for the whole session.
            // A `static` child's condition is "the system starts", so this is its once-only roll. 0 and 1 are decided outright (corpus is all 1.0).
            if !child.rollsProbabilityPerEvent {
                if child.probability <= 0 { continue }
                if child.probability < 1, Double.random(in: 0..<1) >= child.probability { continue }
            }
            await expandParticleTree(
                path: child.relativePath,
                parentPath: particlePath,
                originAccum: originAccum + child.originOffset,
                ancestry: childAncestry,
                parentSystem: childParentSystem,
                followFromParent: child.isEventFollow,
                object: object,
                sortIndex: sortIndex,
                groupEffect: groupEffect,
                childReference: child,
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
        followParent: WPEParticleSystem? = nil,
        requiresFollowParent: Bool = false,
        sortIndex: Int = 0,
        isNestedChild: Bool = false,
        groupEffect: (mask: MTLTexture?, tint: SIMD3<Float>)? = nil,
        on actor: isolated WPEDisplayRenderActor
    ) async -> WPEParticleSystem? {
        let material = definition.materialRelativePath
            .flatMap(parseParticleMaterial(at:))
        let blendMode = material?.blendMode ?? .translucent
        let sceneTransform = makeParticleSceneTransform(for: object)
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
        // Repacked sequence atlas can lose TEXS (3462491575: 450×400 logical, gcd 50 → 72 frames). Only when `animationmode` opted into sequence; a default must not slice single-image sprites.
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
            spriteSheet: spriteSheet,
            seed: oracleSeed
        ) else { return nil }
        #if !LITE_BUILD && DEBUG
        system.traceObjectID = object.id
        system.traceParticlePath = object.particleRelativePath
        #endif
        // Rigid-subtree: topmost ancestor's depth/origin drive the assembly. 3448877775 meteor authors no depth; the group chain carries -0.92.
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
        system.sortIndex = sortIndex
        system.overbright = Self.particleOverbright(
            material: material?.overbright,
            objectBrightness: object.brightness
        )
        system.isNestedChildSystem = isNestedChild
        if let groupEffect {
            system.groupOpacityMask = groupEffect.mask
            system.groupTint = groupEffect.tint
        }
        // REFRACT needs the normal map; load fail → flat sprite. Frame 0 of a dynamic source is the whole atlas (TEXS sub-rects). Demanding `.staticTexture` dropped refraction on 3713073223 rain.
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
        if requiresFollowParent {
            system.followParent = followParent
            system.requiresFollowParent = true
        }
        particleSystems.append(system)
        particleTextures[ObjectIdentifier(system)] = resolved
        // Same pin as the normal map: this binding outlives every suspend, and a
        // released-then-restored slot would leave two copies of the atlas alive.
        animatedTextureSource?.pinSlotHoldingExternally(textureFor: 0)
        if WPESceneDebugArtifacts.shared.isEnabled {
            // Motion-driving params: split parse errors from simulation errors.
            let idx = particleSystems.count - 1
            let d = definition
            var s = "particle[\(idx)] name=\(object.name)\n"
            // def index ≠ particle-state-N traceIndex (sorted+filtered). This line pairs the two dumps.
            s += "object=\(object.id) particle=\(object.particleRelativePath)\n"
            s += "material=\(d.materialRelativePath ?? "-") blend=\(blendMode.rawValue) animationMode=\(d.animationMode)\n"
            // Record the REFRACT chain so the dump distinguishes "combo not parsed" from "normal not loaded".
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
#endif
