#if !LITE_BUILD
import AppKit
import LiveWallpaperProWPE
import MetalKit

extension WPEMetalSceneRenderer {
    // MARK: - Material parsing

    /// Material descriptor extracted from `passes[0]`. Only the fields the
    /// particle path needs — full material parsing lives in the generic
    /// pipeline builder.
    private struct ParticleMaterialDescriptor {
        let blendMode: WPEParticleBlendMode
        let firstTexturePath: String?
        /// `constantshadervalues.ui_editor_properties_overbright` — HDR colour
        /// multiplier on the shader output (1 = unchanged). Drives additive
        /// glow intensity.
        let overbright: Float
        /// `genericparticle` `REFRACT` combo — screen-space refraction (lens
        /// water droplets / heat haze): the particle multiplies its colour by the
        /// scene framebuffer sampled at a normal-map-offset UV, so it shows the
        /// distorted background instead of a flat sprite. Needs `normalTexturePath`.
        let isRefract: Bool
        /// Second pass texture (`g_Texture1`), the refraction normal map.
        let normalTexturePath: String?
        /// `g_RefractAmount` (screen-UV offset scale). WPE default 0.05.
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

    /// Parses `ui_editor_properties_overbright` from a pass's
    /// `constantshadervalues`. A JSON boolean bridges to an `NSNumber` whose
    /// `Float` value is 0/1, so guard it out (a stray `false` would otherwise
    /// black the particle out); clamp to ≥ 0. Absent/malformed → 1.0 (no change).
    nonisolated static func overbright(fromConstants constants: [String: Any]?) -> Float {
        let raw = constants?["ui_editor_properties_overbright"]
        if raw is Bool { return 1.0 }
        guard let number = raw as? NSNumber else { return 1.0 }
        return max(0, Float(truncating: number))
    }

    /// Effective particle colour multiplier: material overbright × the host
    /// object's generic `brightness` (WPE modulates any renderable object with
    /// it; particles fold it into the same overbright uniform, shader unchanged).
    /// Clamped ≥ 0 — a negative authored brightness must not invert colours.
    nonisolated static func particleOverbright(
        material: Float?,
        objectBrightness: Double
    ) -> Float {
        max(0, (material ?? 1.0) * Float(objectBrightness))
    }

    // MARK: - Sprite sheets

    /// Best-effort `.tex-json` sidecar lookup. The atlas slicing
    /// metadata WPE ships next to each `.tex` (cols/rows derived from
    /// the sequence frame size, plus the pixel format) lives in
    /// `<path>.tex-json` — we try the same set of probe paths the main
    /// texture resolver tried (with `.tex` stripped, `materials/`
    /// prefix optional), then read + parse the JSON.
    ///
    /// Returns `nil` when the sidecar is absent or malformed; the
    /// caller then treats the texture as a single-frame static sprite.
    private func parseParticleSpriteSheet(
        texturePath: String,
        atlasPixelSize: (width: Int, height: Int)
    ) -> WPEParticleSpriteSheet? {
        let probes = textureCandidates(for: texturePath).map { candidate -> String in
            // Each candidate already covers ".tex", ".png", etc. — turn
            // them into ".tex-json" siblings.
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

    /// Largest exact square-cell grid over the LOGICAL image (cell = gcd of the
    /// logical sides), emitted as explicit frame rects normalized over the padded
    /// atlas. Square/equal-sided images yield one cell (`nil` — stays a static
    /// sprite), so this only ever slices genuinely rectangular sheets. Bounds
    /// (cell ≥ 16px, ≤ 512 frames) reject degenerate grids from odd image sizes.
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
    /// Spawn one `WPEParticleSystem` per parsed particle object.
    ///
    /// A particle system is only registered if its sprite texture loads
    /// successfully. Missing textures would otherwise leave Metal's
    /// fragment-texture(0) slot stale across systems and produce the
    /// "black background + red grid" overlay seen in workshop 3725117707
    /// before the fix.
    func loadParticleSystems(
        from document: WPESceneDocument,
        on actor: isolated WPEDisplayRenderActor
    ) async {
        particleSystems.removeAll(keepingCapacity: true)
        particleTextures.removeAll(keepingCapacity: true)
        particleNormalTextures.removeAll(keepingCapacity: true)
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

    /// WPE `starttime` is used by workshop authors as an initial simulation
    /// offset: star fields with `starttime: 200` should load already full, not
    /// wait 200 wall-clock seconds. The manual developer flag only adds the same
    /// steady-state prewarm to emitters whose authored starttime is 0.
    ///
    /// Systems linked by `followParent` prewarm in LOCKSTEP, stepping the same
    /// injection rule the frame loop uses. Prewarming them independently — which
    /// is what registration-time prewarm did — drives `advance` directly and so
    /// bypasses parent→child injection: an `eventfollow` child then finds no
    /// injected parent position, `spawn` refuses to place a particle at a stale
    /// origin, and the child prewarms to EMPTY — its passes are then dropped
    /// wholesale by the `liveInstanceCount > 0` filter. Measured on 3226487183,
    /// whose 136 `matrix_trail` systems held 0 particles: the scene went 595 →
    /// 1615 against WPE's 1584, and the 9-scene oracle corpus went 76.1% → 94.3%
    /// coverage (absolute error 24.1% → 9.3%).
    private func prewarmParticleSystems() {
        guard !particleSystems.isEmpty else { return }
        let oracleReplaySeconds = WPEOracleMode.isEnabled
            ? WPEOracleMode.loadFrameOverride()?.baseTime
            : nil
        // `starttime` pre-simulates on BOTH paths now — a star field authored with
        // `starttime: 200` loads already full, as it does in WPE.
        let presimulateDelay = true
        let seconds = particleSystems.map {
            Self.particlePrewarmSeconds(
                for: $0.definition,
                manualPrewarmEnabled: Self.particlePrewarmEnabled,
                oracleReplaySeconds: oracleReplaySeconds
            )
        }
        // Registration is DFS, so a parent always precedes its children and its
        // chain index is already assigned when a child looks it up.
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
            // A chain with one live member takes the plain path, so every scene
            // without an eventfollow pair keeps its exact prior spawn sequence.
            if eligible.count > 1 {
                Self.prewarmFollowChain(eligible, presimulateDelay: presimulateDelay)
            } else if let only = eligible.first {
                only.system.prewarm(simulatedSeconds: only.seconds,
                                    presimulateDelay: presimulateDelay)
            }
        }
    }

    /// Step a whole `followParent` chain on one shared clock, parents first, so a
    /// child spawns against the position its parent reached on the SAME substep.
    /// Each member's window ENDS at the capture instant — a longer `starttime`
    /// means it started earlier — so the windows align by their end, not their start.
    nonisolated static func prewarmFollowChain(
        _ chain: [(system: WPEParticleSystem, seconds: Double)],
        presimulateDelay: Bool,
        step: Double = 1.0 / 60
    ) {
        guard step > 0, let longest = chain.map(\.seconds).max(), longest > 0 else { return }
        // One convergence window for the whole chain: a short-lived child must not
        // start simulating before the long-lived parent whose particles it rides,
        // or it spends its head period with nothing to follow.
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

    /// A particle whose parent chain runs through a `composelayer` group inherits
    /// that group's tint + opacity-mask effects: WPE renders the system into the
    /// group's isolated buffer, then the group recolours and spatially confines it
    /// (3462491575's matrix rain → cyan-tinted, masked to an upper-centre blob).
    /// The particle pipeline draws straight to scene, so bake those two effects
    /// onto the system instead. Returns the loaded mask texture + tint, or nil.
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

    /// Recursively expand a nested particle `children` tree into drawable
    /// systems. Unlike a global `visited` set, dedup is per-ancestry-chain so
    /// same-path siblings with different `origin` offsets (the matrix-rain
    /// columns) each instantiate; only a path repeating within its own chain
    /// is skipped to break cycles. A spawner with `renderer: []` is expanded
    /// but not registered as drawable.
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
        // Reload/cleanup cancels the owning load task cooperatively; bail
        // before doing any work (or recursing) on behalf of a dead load.
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
            // Event-driven children re-roll their chance on every parent event;
            // the system owns that roll because only it sees the events.
            if let registered, let childReference, childReference.rollsProbabilityPerEvent {
                registered.spawnProbability = childReference.probability
            }
        } else {
            registered = nil
            debugStage("particle", "expand-only \(object.name) — renderer disabled: \(particlePath)")
        }
        // A renderer:[] spawner (didn't register) forwards its OWN parent so its
        // children can still event-follow up the chain. A rendering parent that
        // FAILED to register forwards nil — its event-follow children must stay
        // gated rather than silently following the grandparent.
        let childParentSystem = definition.rendersSprite ? registered : parentSystem
        let childAncestry = ancestry + [particlePath]
        for child in parsedDefinition.childReferences {
            // `probability` is rolled when the child's spawn condition is met. For
            // event-driven children that condition fires per parent particle, so
            // the roll belongs in `WPEParticleSystem` (see `spawnProbability`);
            // gating here instead would decide once per SESSION — the whole effect
            // present or absent for the entire run, which is what Valve's own
            // eventfollow-at-0.2 thunderbolt preset would turn into.
            //
            // A `static` child's condition is "the system starts", so here IS its
            // once-only roll. Only an interior probability actually rolls: 0 and 1
            // are decided outright, which keeps every real corpus tree (37 static
            // entries, all 1.0) deterministic and safe for oracle replay.
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
    /// The subtree's anchor node — same selection as the layer path, so an
    /// emitter and its sibling image layers resolve identical depth + anchor.
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
        guard let texturePayload = try? await makeTextureResource(
            relativePath: texturePath,
            label: "particle texture \(texturePath)",
            on: actor
        ) else {
            debugStage("particle", "skip \(object.name) — texture load failed: \(texturePath)")
            return nil
        }
        // A reload may have reset `particleSystems` while this load was
        // suspended above — registering now would append a dead load's
        // subtree into the NEW load's scene (duplicated particle systems).
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
        // No `.tex-json` sidecar (or a single-frame one) but the `.tex` carries
        // a TEXS animation track: slice the atlas by the decoded per-frame
        // sub-rects. This is the Matrix-glyph case — frames live in the TEXS
        // chunk, not a sidecar, so the uniform-grid path would draw the whole
        // atlas as one quad.
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
        // A repacked scene can strip the TEXS frame table from a sequence atlas
        // (3462491575's matrix glyph sheet: single-frame 512×512 .tex, logical
        // 450×400, no sidecar). WPE still slices the LOGICAL image into its
        // largest exact square-cell grid (gcd 50 → 9×8 = 72 frames, matching the
        // authored "spritesheet 72"), so derive the same grid — but only for
        // particles that explicitly opted into sequence animation; a defaulted
        // `animationmode` must not slice single-image sprites.
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
        // Defensive: an R8 particle texture whose `.tex-json` sidecar is
        // missing/invalid would otherwise fall through to the non-mask path
        // and sample `.r8Unorm` alpha as 1 → an opaque quad (the RG88
        // "red square" failure mode, in single channel). R8 is always a
        // single-channel alpha mask, so flag it as such.
        if spriteSheet == nil, resolved.pixelFormat == .r8Unorm {
            spriteSheet = WPEParticleSpriteSheet(
                cols: 1, rows: 1, frameCount: 1, baseFrameRate: 0, isAlphaMask: true
            )
        }
        // Under the render oracle, seed spawn jitter deterministically so the scene
        // renders byte-identically run-to-run. `nil` in production ⇒ system CSPRNG.
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
        // Rigid-subtree rule (see `propagatingParallaxDepthThroughParents`):
        // the topmost ancestor's depth and origin drive the whole assembly.
        // 3448877775's meteor emitter authors NO depth of its own — its group
        // chain carries the -0.92 that keeps it locked to the stars and moon.
        let parallaxRoot = parallaxRootObjectID(of: object.id)
        system.parallaxDepth = parallaxAuthoredDepthByObjectID[parallaxRoot] ?? object.parallaxDepth
        let rootOrigin = parallaxAuthoredOriginByObjectID[parallaxRoot]
            ?? SIMD2<Double>(object.origin.x, object.origin.y)
        system.parallaxCenter = SIMD2<Double>(
            rootOrigin.x - Double(sceneRenderSize.width) * 0.5,
            rootOrigin.y - Double(sceneRenderSize.height) * 0.5
        )
        // Ancestor chain, so a keyframed transform-host `origin` can move this
        // emitter (particles are not render layers and miss the graph's own
        // parent→child composition).
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
        // REFRACT (lens water droplets / heat haze): needs the normal map too.
        // If it fails to load, fall back to the flat-sprite path rather than a
        // refraction that samples nothing.
        //
        // Take frame 0 of a dynamic source exactly like the albedo above does:
        // sprite-sheet normals (`particle/water/rain_drops_sheet_normal`) carry a
        // TEXS frame table, so they arrive as `.dynamicSource`, and frame 0 IS the
        // whole atlas (every TEXS frame shares imageID 0 and differs only by
        // sub-rect — the vertex stage already slices the sheet UVs). Demanding
        // `.staticTexture` here dropped refraction for precisely those systems and
        // painted their pure-white albedo instead — scene 3713073223's screen rain.
        if material?.isRefract == true, let normalPath = material?.normalTexturePath {
            // a normal map is DATA — sRGB gamma corrupts its vectors
            let normalPayload = try? await makeTextureResource(
                relativePath: normalPath, label: "particle normal \(normalPath)",
                colorSpace: .linear, on: actor)
            let normalTexture: MTLTexture? = switch normalPayload {
            case .staticTexture(let t): t
            case .dynamicSource(let source): source.texture(at: 0)
            case nil: nil
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
        if WPESceneDebugArtifacts.shared.isEnabled {
            // Dump the parsed motion-driving params so an emitter-placement /
            // fall-speed divergence vs WPE can be traced to either our PARSING
            // (these values wrong) or our SIMULATION (values right, motion wrong).
            let idx = particleSystems.count - 1
            let d = definition
            var s = "particle[\(idx)] name=\(object.name)\n"
            // def index (build order) never matches particle-state-N's traceIndex
            // (sorted+filtered) — this line is the pairing key across both dumps.
            s += "object=\(object.id) particle=\(object.particleRelativePath)\n"
            s += "material=\(d.materialRelativePath ?? "-") blend=\(blendMode.rawValue) animationMode=\(d.animationMode)\n"
            // A REFRACT material whose normal map fails to load silently degrades to
            // the flat-sprite path, which paints the (white) albedo instead of the
            // refracted background — record the whole chain so the dump distinguishes
            // "combo not parsed" from "normal not loaded".
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
