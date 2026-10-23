#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

extension WPEParityFrameRenderer {
    /// Writes a user-property change between frames; changed text layers are re-laid now. `changedJSON` holds the
    /// changed project properties, `mergedJSON` all of them (1401731d0.c:143-840).
    func applyUserProperties(_ update: WPEParityUserPropertyUpdate, changedJSON: String = "{}",
                             mergedJSON: String = "{}") throws {
        try replaceConditionalProperties(changed: Self.propertySnapshot(changedJSON),
                                         merged: Self.propertySnapshot(mergedJSON))
        update.apply(to: &state)
        let updatedBloom = bloomSettingsFromState(update.bloom)
        if updatedBloom != bloom {
            bloom = updatedBloom
            repackBloom()
        }
        if !update.texts.isEmpty {
            discardSupersededFailedTexts()
        }
        for text in update.texts {
            textRequests.append(.init(text))
            for (name, value) in WPEParityTextFields.seed(text) {
                state.setScriptField(name, of: text.id, to: value, invalidating: .textLayout)
            }
        }
        script?.applyUserProperties(changedJSON: changedJSON, mergedJSON: mergedJSON, state: &state)
    }

    static func propertySnapshot(_ json: String) throws -> WPESceneJSONValue {
        let raw = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let value = WPESceneJSONValue(jsonValue: raw), case .object = value else {
            throw WPEParityFrameRenderError.invalidUserProperties
        }
        return value
    }

    /// Prepare all immutable texture replacements and their existing readers before adopting them. Native
    /// reload destroys its old resources before its placeholder fallback; matching that failure path is still
    /// open. A failed Mac preparation currently leaves the valid cohort intact and rejects the product commit.
    func replaceConditionalProperties(changed: WPESceneJSONValue, merged: WPESceneJSONValue) throws {
        let prepared = try planner.preparingConditionalProperties(changed: changed, merged: merged)
        var candidate = prepared.planner
        guard !prepared.affectedOperations.isEmpty else {
            planner = candidate
            return
        }
        let current = graphs.layout
        let affectedNames = Set(Self.drawNames(current.frames[0]).compactMap { index, name in
            prepared.affectedOperations.contains(index) ? name : nil
        })
        let reuse = Layout(planned: current.planned, effects: current.effects,
                           draws: current.draws.filter { !prepared.affectedOperations.contains($0.key) },
                           skipped: current.skipped, fade: current.fade)
        let planned = try plan.layout(effects: state, texts: candidate.texts,
                                      mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
        let layout = try Self.makeLayout(planned, effects: state.effectVisibility, artifacts: artifacts,
                                         planner: &candidate, encoder: drawEncoder,
                                         state: state, reusing: reuse)
        for (index, name) in Self.drawNames(planned.frames[0])
            where affectedNames.contains(name) && planned.programs[index] != nil && layout.draws[index] == nil {
            throw layout.skipped[index] ?? WPEParityFrameSkip.noMaterial
        }
        try installGraphs(layout, cachePrevious: false)
        planner = candidate
        packedConstants.removeAll()
        fadeConstants.removeAll()
        repackBloom()
    }

    /// Runs `script`'s init against the loaded state; its events and update then run inside every frame.
    func attachScript(_ script: WPEParitySceneScript) throws {
        self.script = script
        script.engine.materialFunctionHandler = scriptMaterialFunction
        script.engine.transformMatrixHandler = scriptTransformMatrix
        script.engine.videoTextureHandler = scriptVideoCommand
        script.engine.textureAnimationHandler = scriptTextureAnimation
        script.engine.animationLayerHandler = scriptAnimationLayer
        script.engine.puppetHandler = scriptPuppet
        script.engine.particleSystemHandler = scriptParticleSystem
        script.engine.propertyAnimationLookup = { [animations] in animations.animation(objectID: $0, pass: $1, name: $2) }
        script.engine.modelDataAdmissionHandler = scriptModelDataAdmission
        try script.start(state: &state)
    }

    var scriptModelDataProvider: WPEParityScriptModelDataProvider {
        WPEParityModelDataLayerAdmission.provider(plan: plan, device: device, admitShape: scriptModelDataAdmission)
    }

    /// Immutable loader inputs survive renderer resize without keeping its old graph or resource owner alive.
    var scriptModelDataAdmission:
        (WPEParitySceneModelData.Shape, WPEParityModelDataMutation) throws -> (any WPEParityModelDataPreparedShape)? {
        let plan = plan
        let artifacts = artifacts
        let device = device
        return { shape, mutation in
            try WPEParityModelDataMetalShape.prepare(shape, mutation: mutation, plan: plan,
                                                     artifacts: artifacts, device: device)
        }
    }

    /// Loads a `general.precache` material as a ModelData program so a later createModelData finds its shader.
    nonisolated(nonsending) func precacheMaterial(
        _ path: String, shaders: WPEParityFrameShaderSource
    ) async throws {
        guard plan.scene.modelDataMesh(materialPath: path) != nil else {
            throw WPEParityModelDataFailure.native(1)
        }
        let program = try WPEParityModelDataMetalShape.program(materialPath: path, plan: plan)
        if case .success? = artifacts[program.hlsl] {
            return
        }
        let artifact = try await shaders.artifact(for: program)
        artifacts[program.hlsl] = .success(artifact)
    }

    /// Compiles the programs a script-created image layer of `model` draws with, as a candidate layout plans them.
    nonisolated(nonsending) func precacheCreatedImage(
        _ model: String, shaders: WPEParityFrameShaderSource
    ) async throws {
        let image = WPEParitySceneState.CreatedImage(model: model, size: nil, perspective: false)
        guard let description = plan.scene.createdImageObject(id: "", image: image) else {
            throw WPEParityModelDataFailure.safety("image model \(model) is unavailable")
        }
        var candidate = state
        let id = try String(candidate.appendImageLayer(image, id: nil, transparent: description.transparentMember,
                                                       fullscreen: description.fullscreen) { _ in })
        let planned = try plan.layout(effects: candidate, texts: planner.texts)
        for (index, program) in planned.programs where planned.frames[0].owners[index] == id {
            if case .success? = artifacts[program.hlsl] {
                continue
            }
            artifacts[program.hlsl] = try await .success(shaders.artifact(for: program))
        }
    }

    /// Warm leaf images and childless sound layers use the common post-update removal path; a removed sound
    /// stops through `takeSoundVisibility`. Other class destructors and dependent owners stay rejected.
    var scriptLayerRemovalAdmission: (String, UInt32?) -> Bool {
        // The engine continues through renderer replacement. Capture immutable loaded-class metadata,
        // without keeping the old renderer/Metal owners alive or consulting a dead weak renderer.
        let objects = plan.scene.scene.objects
        let parents = plan.document.objectParentByID
        let videoIDs = objects.filter { videos.hasOwner($0.id) }.map(\.id)
        let loadedIDs = plan.state.loadedIDs
        let soundIDs = Set(plan.document.soundObjects.map(\.id))
        return { id, modelDataToken in
            // Created image clones own no class resource beyond their template's shared images.
            if modelDataToken != nil || !loadedIDs.contains(id) {
                return true
            }
            // Sounds are not scene objects (no draw), so they can never be a dependency target.
            if soundIDs.contains(id) {
                return !parents.values.contains(id)
            }
            guard let object = objects.first(where: { $0.id == id }), case .image = object.kind,
                  object.puppet == nil, !videoIDs.contains(id), !parents.values.contains(id),
                  !object.dependencyTarget else { return false }
            return true
        }
    }

    func attachMedia(_ mailbox: WPESceneMediaEventMailbox?, generation: Int) {
        media = mailbox
        mediaGeneration = generation
    }

    /// The same accepted input supplies both textures and script properties/events before animation and update.
    func consumeMediaInputs() {
        guard let media else { return }
        for input in media.drainParityInputs(generation: mediaGeneration) {
            if let textures = input.textures {
                mediaTextures = textures
                mediaCrops.removeAll()
            }
            mediaDiagnostics = input.diagnostics
            script?.applyMedia(properties: input.systemProperties, events: input.events, state: &state)
        }
    }

    /// Like the native cache name, round(aspect × 10) tells crops of one image apart.
    struct MediaCrop: Hashable {
        let image: ObjectIdentifier
        let tenths: Int
    }

    /// The snapshot image centre-cropped to the slot `aspect` (width / height); whole for keepaspect (nil).
    func croppedMediaTexture(_ kind: WPEMediaSystemTexture, aspect: Float?) -> MTLTexture? {
        guard let image = mediaTextures?.texture(for: kind) else { return nil }
        guard let aspect else { return image }
        let key = MediaCrop(image: ObjectIdentifier(image), tenths: Int((aspect * 10).rounded()))
        if let cropped = mediaCrops[key] {
            return cropped
        }
        let rect = WPEUserShortcutIconImage.cropRect(width: image.width, height: image.height, aspect: aspect)
        guard rect.width != image.width || rect.height != image.height else { return image }
        guard rect.width > 0, rect.height > 0 else { return nil }
        // The image holds straight sRGB-encoded RGBA8; a byte copy keeps both, a CGContext redraw would premultiply.
        var rgba = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        image.getBytes(&rgba, bytesPerRow: rect.width * 4,
                       from: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height), mipmapLevel: 0)
        let cropped = WPEUserShortcutIconStore.makeTexture(
            from: WPEUserShortcutIconImage(rgba: rgba, width: rect.width, height: rect.height), device: device
        )
        mediaCrops[key] = cropped
        return cropped
    }

    /// Event 3 to every binding; later frames run no script.
    func destroyScript() {
        script?.engine.destroy(state: &state)
        script = nil
    }

    /// Object updates precede camera selection; scripts/animations of this frame affect the next selection.
    /// The last effectively visible camera owns the world pose. Root paths hold while an object is active.
    func selectCamera(dt: Float) {
        let active = WPEParityCamera.activeObjectID(document: plan.document, state: state)
        var selected = rootCamera
        if case let .vector(value)? = state.scriptField("perspectiveoverridefov", of: "") {
            selected.perspectiveFOV = value.x
        }
        // 1891a0 selects effective O148 from raw O140; 183a70 reads near/far before the manager tick.
        // Camera objects and queues may replace only effective FOV after this canonical snapshot.
        if selected.scenePerspective != nil {
            if case let .vector(value)? = state.scriptField("fov", of: "") {
                selected.scenePerspective?.fov = value.x
            }
            if case let .vector(value)? = state.scriptField("nearz", of: "") {
                selected.scenePerspective?.near = value.x
            }
            if case let .vector(value)? = state.scriptField("farz", of: "") {
                selected.scenePerspective?.far = value.x
            }
        }
        var sceneZoom = generalZoom
        if case let .vector(value)? = state.scriptField("zoom", of: "") {
            sceneZoom = value.x
        }
        if let active {
            selected = selected.applyingObject(world: layers.world(active), objectID: active, document: plan.document,
                                               state: state, generalZoom: sceneZoom)
            if let queue = cameraQueues[active], queue.selectedIndex != nil {
                selected.zoom = sceneZoom * (queue.selectedZoom ?? 1)
                if selected.scenePerspective != nil {
                    selected.scenePerspective?.fov = queue.selectedFOV ?? 50
                }
            }
        } else {
            cameraPose = cameraPaths.advance(dt: dt)
            if let pose = cameraPose {
                selected = selected.posed(pose, generalZoom: sceneZoom)
            } else {
                // 1401891a0.c:72-75, :132-139: without a path, pose and zoom are the root values.
                func root(_ name: String) -> SIMD4<Float>? {
                    guard case let .vector(value)? = state.scriptField("cameraTransforms.\(name)", of: "") else {
                        return nil
                    }
                    return value
                }
                func vector(_ name: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
                    root(name).map { SIMD3($0.x, $0.y, $0.z) } ?? fallback
                }
                let pose = WPEParityCameraPose(eye: vector("eye", rootCamera.eye), center: vector("center", rootCamera.center),
                                               up: vector("up", rootCamera.up), zoom: root("zoom")?.x ?? 1)
                selected = selected.posed(pose, generalZoom: sceneZoom)
            }
        }
        selected.shake = cameraShake
        selected = selected.shaken(time: clock.timeUniform)
        if camera != selected || activeCameraID != active {
            layersMoved = true
        }
        camera = selected
        activeCameraID = active
    }

    /// One common-scene sweep shares the native scene RNG across particle and camera queue consumers.
    func updateSceneObjects(camera: WPEParityCamera, timeOfDay: Float) {
        particles.beginFrame()
        particles.scene.applyScriptInstanceFields(state: state)
        let viewProjection = camera.projection * camera.view
        // `audio` advances later in the frame, so particles read the previous frame's spectrum.
        let spectrum = audio.bands16
        for id in state.commonOrder {
            if let queue = cameraQueues[id],
               let output = queue.advance(dt: clock.frametime, world: layers.world(id),
                                          orthographic: plan.scene.engineFlags.orthographicProjection, state: state) {
                state.set(.origin, of: id, to: SIMD4(output.origin, 0))
                state.set(.angles, of: id, to: SIMD4(output.angles, 0))
                applyTransforms()
            } else if particles.scene.liveCount(id) != nil {
                let frame = state.isVisible(id)
                    ? WPEParityParticleFrameContext(time: clock.timeUniform, cursor: pointer.position,
                                                    viewProjection: viewProjection, objectMatrix: layers.world(id),
                                                    timeOfDay: timeOfDay, previousFrametime: clock.previousFrametime,
                                                    frametime: clock.frametime,
                                                    spectrumLeft: spectrum.left, spectrumRight: spectrum.right) : nil
                particles.scene.advance(objectID: id, dt: clock.frametime, frame: frame)
            }
        }
    }

    func applyLayerFields() {
        guard seenLayerFields != state.scriptFieldsGeneration else { return }
        if layers.applyFields(state: state) {
            layersMoved = true
        }
        seenLayerFields = state.scriptFieldsGeneration
    }

    /// Only changed fields are pushed: replaying an unchanged blendin would re-arm a ramp the animator finished.
    func applyAnimationLayerFields() {
        guard seenAnimationLayerFields != state.scriptFieldsGeneration else { return }
        seenAnimationLayerFields = state.scriptFieldsGeneration
        if animationLayerFields?.membership != state.membershipGeneration {
            animationLayerFields = (state.membershipGeneration, makeAnimationLayerFields())
        }
        for layer in animationLayerFields?.layers ?? [] {
            var changed: [String: WPEParitySceneState.ScriptValue] = [:]
            for field in layer.fields {
                guard let value = state.scriptFields[field.key],
                      value != (pushedAnimationLayerFields[field.key] ?? field.seed) else { continue }
                pushedAnimationLayerFields[field.key] = value
                changed[field.name] = value
            }
            guard !changed.isEmpty else { continue }
            func float(_ name: String) -> Float? {
                guard case let .vector(value)? = changed[name] else { return nil }
                return value.x
            }
            func flag(_ name: String) -> Bool? {
                float(name).map { $0 != 0 }
            }
            var name: String?
            if case let .string(value)? = changed["name"] {
                name = value
            }
            puppets[layer.objectID]?.updateLayer(at: layer.sceneIndex, enabled: flag("visible"), rate: float("rate"),
                                                 blend: float("blend"), name: name, additive: flag("additive"),
                                                 blendIn: flag("blendin"), blendOut: flag("blendout"),
                                                 blendTime: float("blendtime"))
        }
    }

    private func makeAnimationLayerFields() -> [AnimationLayerFields] {
        #if DEBUG
        animationLayerFieldIndexBuilds += 1
        #endif
        let authored = Dictionary(plan.document.imageObjects.map { ($0.id, $0.animationLayers) }) { first, _ in first }
        func scalar(_ value: Double) -> WPEParitySceneState.ScriptValue {
            .vector(SIMD4(Float(value), 0, 0, 0))
        }
        var result: [AnimationLayerFields] = []
        for (id, puppet) in puppets {
            let scenes = authored[id] ?? []
            for layer in puppet.layers where scenes.indices.contains(layer.sceneIndex) {
                let scene = scenes[layer.sceneIndex]
                let seeds: [(String, WPEParitySceneState.ScriptValue)] = [
                    ("visible", scalar(scene.visible ? 1 : 0)), ("additive", scalar(scene.additive ? 1 : 0)),
                    ("blendin", scalar(scene.blendIn ? 1 : 0)), ("blendout", scalar(scene.blendOut ? 1 : 0)),
                    ("name", .string(scene.name)), ("rate", scalar(scene.rate)), ("blend", scalar(scene.blend)),
                    ("blendtime", scalar(scene.blendTime)),
                ]
                let fields = seeds.map { name, seed in
                    (name: name, seed: seed, key: WPEParitySceneState.ScriptFieldKey(
                        objectID: id, name: "animationlayers.\(layer.sceneIndex).\(name)"
                    ))
                }
                result.append(AnimationLayerFields(objectID: id, sceneIndex: layer.sceneIndex, fields: fields))
            }
        }
        return result
    }

    /// Bloom fields share canonical State with scripts and accepted document deltas.
    /// A full settings snapshot must not replace unchanged or rejected seeds over live values.
    private func bloomSettingsFromState(_ source: WPEParityBloomSettings) -> WPEParityBloomSettings {
        var settings = source
        if case let .vector(value)? = state.scriptField("bloomstrength", of: "") {
            settings.strength = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomthreshold", of: "") {
            settings.threshold = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomhdrstrength", of: "") {
            settings.hdrStrength = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomhdrthreshold", of: "") {
            settings.hdrThreshold = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomhdrfeather", of: "") {
            settings.hdrFeather = value.x
        }
        if case let .vector(value)? = state.scriptField("bloomhdrscatter", of: "") {
            settings.hdrScatter = value.x
        }
        if case let .integer(value)? = state.scriptField("bloomhdriterations", of: "") {
            settings.hdrIterations = Int(value)
        }
        if case let .vector(value)? = state.scriptField("bloomtint", of: "") {
            settings.tint = SIMD3(value.x, value.y, value.z)
        }
        return settings
    }

    /// LDR/HDR bloom fields scripts wrote, rebuilt after the tick (14017fa70.c:478-481).
    func applyScriptBloom() {
        guard state.generation(.bloom) != seenScriptBloom else { return }
        seenScriptBloom = state.generation(.bloom)
        let settings = bloomSettingsFromState(bloom)
        guard settings != bloom else { return }
        bloom = settings
        repackBloom()
    }

    /// Scene colour terms are consumed after the script tick, before this frame's lighting constants are packed.
    /// The shadow layout follows `camera`'s eye and forward, so it is rebuilt every frame (140190c80.c:938-967).
    func applyScriptLighting(camera: WPEParityCamera) throws {
        let quality = plan.scene.engineFlags.shadowQuality
        let atlasID = WPEParitySceneResource.shadowAtlas
        let shadows = quality != 0 && targets[atlasID] != nil
        guard shadows || seenScriptLighting != state.generation(.lighting)
            || seenLightTransforms != state.transformGeneration || seenLightVisibility != state.visibilityGeneration
            || layers.hasAttachments else { return }
        if shadows {
            let layout = WPEParityShadowLayout(
                document: plan.document, transforms: layers, state: state, quality: quality, eye: camera.eyePosition,
                forward: WPEParityUniformParallax.viewVectors(view: camera.view).forward,
                orthographic: plan.scene.engineFlags.orthographicProjection, previousAtlasSize: shadowLayout?.atlasSize
            )
            let batches = shadowLayout?.batches.count
            shadowLayout = layout
            if layout.batches.count != batches {
                reserveArena(for: graphs.layout)
            }
            if layout.atlasSize != .zero, let atlas = targets[atlasID],
               SIMD2(atlas.width, atlas.height) != layout.atlasSize {
                targets[atlasID] = try Self.makeTarget(
                    WPELogicalResource(id: atlasID, width: layout.atlasSize.x, height: layout.atlasSize.y,
                                       format: WPEParitySceneResource.depthFormat, lifetime: .imported),
                    device: device
                )
                retiredTextures.append(atlas)
            }
        }
        lights = WPEParityUniformLights(document: plan.document, transforms: layers, state: state,
                                        shadowQuality: quality, shadows: shadowLayout)
        seenScriptLighting = state.generation(.lighting)
        seenLightTransforms = state.transformGeneration
        seenLightVisibility = state.visibilityGeneration
    }

    var scriptFieldDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] {
        var defaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [:]
        for text in planner.texts.values {
            for (name, value) in WPEParityTextFields.seed(text.object) {
                defaults[.init(objectID: text.object.id, name: name)] = value
            }
            defaults[.init(objectID: text.object.id, name: "size")] =
                .vector(SIMD4(lowHalf: text.scriptSize, highHalf: .zero))
        }
        defaults.merge(videos.scriptFieldDefaults) { _, actual in actual }
        // Root zoom starts at 1 (140186c90.c:136); the root pose is the scene's root camera.
        defaults[.init(objectID: "", name: "cameraTransforms.eye")] = .vector(SIMD4(rootCamera.eye, 0))
        defaults[.init(objectID: "", name: "cameraTransforms.center")] = .vector(SIMD4(rootCamera.center, 0))
        defaults[.init(objectID: "", name: "cameraTransforms.up")] = .vector(SIMD4(rootCamera.up, 0))
        defaults[.init(objectID: "", name: "cameraTransforms.zoom")] = .vector(SIMD4(1, 0, 0, 0))
        return defaults
    }

    func takeSoundVisibility(_ body: (String, Bool) -> Void) {
        // Removal bumps only membership, and a removed object reads invisible.
        let generation = SIMD2(state.visibilityGeneration, state.membershipGeneration)
        guard seenSoundVisibility != generation else { return }
        for sound in plan.document.soundObjects {
            body(sound.id, state.isVisible(sound.id))
        }
        seenSoundVisibility = generation
    }

    /// Sound volumes scripts wrote since the last call, by sound object; the runtime applies volume² × master.
    func takeScriptSoundVolumes(_ body: (String, Float) -> Void) {
        guard let script, state.generation(.soundGain) != seenScriptSound else { return }
        seenScriptSound = state.generation(.soundGain)
        for id in script.soundIDs {
            if case let .vector(volume)? = state.scriptField("volume", of: id) {
                body(id, volume.x)
            }
        }
    }

    /// These descriptors have no native onChanged hook; consume their stored fields at the next sound update.
    func takeScriptSoundBounds(_ body: (String, Double?, Double?) -> Void) {
        guard let script, seenSoundBoundsFields != state.scriptFieldsGeneration else { return }
        seenSoundBoundsFields = state.scriptFieldsGeneration
        for id in script.soundIDs {
            let minimum: Double? = if case let .vector(value)? = state.scriptField("mintime", of: id) {
                Double(value.x)
            } else {
                nil
            }
            let maximum: Double? = if case let .vector(value)? = state.scriptField("maxtime", of: id) {
                Double(value.x)
            } else {
                nil
            }
            body(id, minimum, maximum)
        }
    }

    /// The cursor pass of the frame, before the animations (14017fa70.c:473-476).
    func runScriptEvents(_ script: WPEParitySceneScript, camera: WPEParityCamera, pointer: SIMD2<Float>,
                         edges: [(position: SIMD2<Float>, down: Bool)], buttonDown: Bool,
                         timeOfDay: Float) throws {
        try script.updateCursorTargets(state: state, quad: { try cursorQuad($0, camera: camera) })
        for edge in edges {
            script.cursor(at: edge.position * logicalSize, world: camera.cursorWorld(normalizedPointer: edge.position),
                          leftDown: edge.down, timeOfDay: timeOfDay, state: &state)
        }
        script.cursor(at: pointer * logicalSize, world: camera.cursorWorld(normalizedPointer: pointer),
                      leftDown: buttonDown, timeOfDay: timeOfDay, state: &state)
    }

    /// A layer's mesh corners in client pixels, y down, with its frame's parallax (140189e10.c:124-156).
    func cursorQuad(_ id: String,
                    camera: WPEParityCamera) throws -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)? {
        guard let size = layers.layers[id]?.size, size.x > 0, size.y > 0 else { return nil }
        var placed = layers
        placed.camera = camera
        var model = placed.model(id)
        // A text box also takes its glyphs' anchor (1402585c0.c:35-148) and block offset (140256f20.c:302-325).
        if let text = texts[id] {
            let anchor = WPEParityTextMatrices.anchorOffset(text.object.anchor, margins: camera.cropMargins,
                                                            orthographic: text.orthographic)
            model = WPEParityTextMatrices.layerModel(model, anchorOffset: anchor, blockOffset: text.layout.blockOffset)
        }
        let matrix = try placed.projection(id) * placed.view(id, parallax: parallax.smoothed) * model
        let pixels = logicalSize
        func corner(_ x: Float, _ y: Float) -> SIMD2<Float> {
            let clip = matrix * SIMD4(x, y, 0, 1)
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            return SIMD2((ndc.x + 1) * 0.5, (1 - ndc.y) * 0.5) * pixels
        }
        let half = size * 0.5
        return (corner(-half.x, -half.y), corner(half.x, -half.y),
                corner(half.x, half.y), corner(-half.x, half.y))
    }
}
#endif
