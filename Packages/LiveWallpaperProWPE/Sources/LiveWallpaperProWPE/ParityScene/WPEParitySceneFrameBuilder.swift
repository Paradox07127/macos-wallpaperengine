/// Emits WPE's RenderScene (140183550) up to the end of the object loop: scene clear, image layers and their effect
/// chains, and the MSAA resolve. Bloom, mip-mapped/HDR copies, ccsimple, fade and present are not part of it.
public enum WPEParitySceneFrameBuilder {
    /// The parity of `frameIndex` picks which FBO of each swap pair the effect writes this frame.
    public static func build(_ scene: WPEParitySceneDescription, frameIndex: Int = 0) -> WPEParitySceneFrame {
        var emitter = WPEParitySceneEmitter(scene, frameIndex: frameIndex)
        emitter.renderScene()
        // A composite pair is registered up front, but WPE creates only min(2, bit4 + n) (1401ea500.c:113-126).
        let used = Set(emitter.operations.flatMap(\.kind.resources))
        return WPEParitySceneFrame(operations: emitter.operations,
                                   resources: emitter.resources.values.filter { used.contains($0.id) }
                                       .sorted { $0.id < $1.id },
                                   draws: emitter.draws, samplers: emitter.samplers, diagnostics: scene.diagnostics,
                                   owners: emitter.owners)
    }
}

private typealias Resource = WPEParitySceneResource

private struct WPEParitySceneDestination {
    let color: WPEResourceID
    let depth: WPEResourceID?
    let alphaMax: Bool
    /// The layer whose composite `color` is; nil for the scene.
    let compositeOwnerID: String?
    /// Top level writes RGB only; a parent composite gets RGBA once any ancestor counted R+0x1c9.
    var writeMask: WPEParitySceneWriteMask {
        alphaMax ? .rgba : .rgb
    }

    /// A material pass's `alphawriting` overrides the destination's mask.
    func writeMask(_ state: WPEParitySceneMaterialState) -> WPEParitySceneWriteMask {
        switch state.alphaWriting {
        case .inherit: writeMask
        case .enabled: .rgba
        case .disabled: .rgb
        }
    }
}

private struct WPEParitySceneEmitter {
    let scene: WPEParitySceneDescription
    let roots: [WPEParitySceneObject]
    let childrenByParent: [String: [WPEParitySceneObject]]
    let sceneColor: WPEResourceID
    let sceneDepth: WPEResourceID
    /// 1401ea500.c:110-112: HDR frames (Main+0x128 bit13) give the layer composites a half-float format.
    let compositeFormat: String
    var operations: [WPERenderOperation] = []
    var resources: [WPEResourceID: WPELogicalResource] = [:]
    var draws: [WPEPassIdentity: WPEParitySceneDraw] = [:]
    var samplers: [WPEResourceID: WPEParitySceneSampler] = [:]
    /// Effect FBO resource → the resource its name is currently bound to; absent means itself.
    var bindings: [WPEResourceID: WPEResourceID] = [:]
    var owners: [WPEPassIdentity: String] = [:]
    /// The object being rendered; children nest inside their parent's.
    private var owner: String?
    /// Each `_rt_imageLayerComposite_<id>_a` the scene has and the layer it belongs to, so a draw of another layer
    /// may name it in its reads before the owner renders.
    private let layerComposites: [WPEResourceID: WPEParitySceneObject]

    init(_ scene: WPEParitySceneDescription, frameIndex: Int) {
        self.scene = scene
        let ids = Set(scene.objects.map(\.id))
        // 14018aac0.c:42-81 stable sort on obj+0x124.
        let ordered = scene.objects.enumerated()
            .sorted { ($0.element.sortKey, $0.offset) < ($1.element.sortKey, $1.offset) }
            .map(\.element)
        var roots: [WPEParitySceneObject] = []
        var children: [String: [WPEParitySceneObject]] = [:]
        for object in ordered {
            if let parent = object.parentID, ids.contains(parent) {
                children[parent, default: []].append(object)
            } else {
                roots.append(object)
            }
        }
        self.roots = roots
        childrenByParent = children
        var layerComposites: [WPEResourceID: WPEParitySceneObject] = [:]
        for object in scene.objects where object.hasLayerComposite(scene) {
            layerComposites[Resource.layerCompositeA(object.id)] = object
        }
        self.layerComposites = layerComposites

        let multisampled = scene.msaaSamples > 1
        sceneColor = multisampled ? Resource.multisampled : Resource.backbuffer
        sceneDepth = multisampled ? Resource.multisampledDepth : Resource.backbufferDepth
        let format = scene.backbufferFormat
        compositeFormat = format == "rgba16float" ? format : Resource.colorFormat
        register(Resource.backbuffer, scene.width, scene.height, format: format, lifetime: .output)
        register(Resource.backbufferDepth, scene.width, scene.height, format: Resource.depthFormat)
        register(Resource.fullFrameBuffer, scene.width, scene.height, format: format)
        if multisampled {
            register(Resource.multisampled, scene.width, scene.height, format: format, samples: scene.msaaSamples)
            register(Resource.multisampledDepth, scene.width, scene.height, format: Resource.depthFormat,
                     samples: scene.msaaSamples)
        }
        // One exchange per frame: odd frames start with every pair swapped. Each side of a pair is written in one
        // frame and read in the next, so its contents must outlive the frame.
        for object in scene.objects {
            for effect in object.effects {
                for fbo in effect.fbos {
                    guard let partner = fbo.swapPartner else { continue }
                    let id = Self.fboID(object, effect, fbo.name)
                    register(id, fbo.width, fbo.height, format: fbo.format, lifetime: .persistent)
                    if frameIndex % 2 != 0 {
                        bindings[id] = Self.fboID(object, effect, partner)
                    }
                }
            }
        }
    }

    mutating func renderScene() {
        let pass: WPEPassIdentity = "scene"
        emit(pass, .setTargets(color: [WPETextureView(sceneColor)], depth: WPETextureView(sceneDepth)))
        if scene.clearEnabled {
            let color = scene.clearColor
            emit(pass, .clearColor(WPETextureView(sceneColor),
                                   WPEClearColor(red: color.x, green: color.y, blue: color.z, alpha: 1)))
            emit(pass, .clearDepth(WPETextureView(sceneDepth), depth: 0))
        }
        let top = WPEParitySceneDestination(color: sceneColor, depth: sceneDepth, alphaMax: false,
                                            compositeOwnerID: nil)
        for object in roots {
            render(object, into: top, ancestors: [])
        }
        if sceneColor != Resource.backbuffer {
            emit("scene.resolve", .resolve(source: sceneColor, destination: Resource.backbuffer))
        }
    }

    /// 1401e8aa0. `ancestors` are the composites the enclosing layers draw their children into.
    private mutating func render(_ object: WPEParitySceneObject, into destination: WPEParitySceneDestination,
                                 ancestors: [WPEResourceID]) {
        // 1401e8aa0.c:90-100 with 1401ea2d0: a dependency target renders while hidden, without its scene draw.
        guard object.visible || object.dependencyTarget else { return }
        let enclosing = owner
        owner = object.dependencyTarget ? nil : object.id
        defer { owner = enclosing }
        let children = childrenByParent[object.id] ?? []
        if case let .shape(shape) = object.kind {
            return renderShape(object, shape, into: destination)
        }
        if case let .particle(particle) = object.kind {
            renderParticles(object, particle, into: destination)
            for child in children {
                render(child, into: destination, ancestors: ancestors)
            }
            return
        }
        // FUN_1402222a0: a model draws into the bound target with no composite and no effects.
        if case let .model(model) = object.kind {
            return renderModel(object, model, children: children, into: destination, ancestors: ancestors)
        }
        let effects = object.effects.filter(\.enabled)
        let lastPass = (effects.count - 1, (effects.last?.passes.count ?? 0) - 1)
        let n = effects.count + effects.reduce(0) { $0 + $1.passes.count(where: \.compose) }
        let ownBit4 = object.requiresLayerComposite || scene.forcesLayerComposite
        let bit4 = object.hasLayerComposite(scene)
        let clearsAlpha = if case let .text(text) = object.kind, n > 0, !text.object.opaqueBackground {
            true
        } else {
            false
        }

        // 1401e8aa0.c:169-176; a copybackground composelayer and a text FBO's clearalpha sample the snapshot too.
        if ownBit4 || !children.isEmpty || (object.passthrough && object.copyBackground) || clearsAlpha {
            snapshot(WPEPassIdentity("\(object.id)/snapshot"))
        }
        guard n > 0 || bit4 else {
            return renderWithoutComposite(object, children: children, into: destination, ancestors: ancestors)
        }

        let (width, height) = compositeExtent(object)
        let sampler = object.compositeSampler
        let composites = (0 ..< 2).map { index in
            bit4 && index == 0 ? Resource.layerCompositeA(object.id)
                : Resource.pooledComposite(width: width, height: height, sampler: sampler, index: index,
                                           ancestors: ancestors)
        }
        for composite in composites {
            registerComposite(composite, of: object)
        }
        // 1401e8aa0.c:476-487: the last reader always lands on composites[0].
        var current = bit4 ? n % 2 : (n - 1) % 2
        fillComposite(object, composites[current])
        let childDestination = WPEParitySceneDestination(color: composites[current], depth: nil,
                                                         alphaMax: destination.alphaMax || !object.copyBackground,
                                                         compositeOwnerID: object.id)
        for child in children {
            render(child, into: childDestination, ancestors: ancestors + [composites[current]])
        }

        // 1401e7170.c:719-751: effect+0x144, the last draw pass, takes the layer mesh, blend and mask.
        let finalPass = bit4 ? nil : effects.last?.passes.lastIndex { $0.kind == .draw }
        var flips = 0
        for (effectIndex, effect) in effects.enumerated() {
            for fbo in effect.fbos {
                register(Self.fboID(object, effect, fbo.name), fbo.width, fbo.height, format: fbo.format)
            }
            let readsFullFrame = effect.passes.contains(where: \.readsFullFrameBuffer)
            for (passIndex, pass) in effect.passes.enumerated() {
                let identity = WPEPassIdentity("\(object.id)/\(effect.id)/\(passIndex)")
                // 1401e8aa0.c:805-809: after N−1 flips the loop breaks; the rest of the last effect runs with the
                // layer's matrices and no composite target bound (:951-997, :1052-1075).
                let lastSegment = !bit4 && flips == n - 1
                func fbo(_ name: String) -> WPEResourceID {
                    bound(Self.fboID(object, effect, name))
                }
                if case let .copy(source) = pass.kind {
                    emit(identity, .copy(source: source.map(fbo) ?? composites[current],
                                         destination: pass.target.map(fbo) ?? composites[current]))
                    continue
                }
                let target: WPEResourceID
                var depth: WPEResourceID?
                var blend = pass.blend
                var alphaMax = false
                var compositeOwnerID: String?
                var mask = WPEParitySceneWriteMask.rgba
                var geometry = WPEParitySceneDraw.Geometry.fullscreenQuad
                if lastSegment {
                    compositeOwnerID = destination.compositeOwnerID
                }
                if let name = pass.target {
                    target = fbo(name)
                } else if lastSegment {
                    target = destination.color
                    depth = destination.depth
                    alphaMax = destination.alphaMax
                } else {
                    target = composites[current ^ 1]
                }
                if lastSegment, passIndex == finalPass {
                    blend = object.blend
                    mask = destination.writeMask
                    geometry = object.layerGeometry
                }
                bind(identity, target, depth: depth)
                if passIndex == 0, readsFullFrame {
                    snapshot(WPEPassIdentity("\(object.id)/\(effect.id)/snapshot"))
                }
                let reads = [composites[current]] + pass.binds.map(fbo)
                    + (pass.readsFullFrameBuffer ? [Resource.fullFrameBuffer] : []) + frameReads(pass.frameReads)
                draw(WPEParitySceneDraw(pass: identity, objectID: object.id, effectID: effect.id,
                                        passIndex: passIndex, shader: pass.shader, source: pass.source, reads: reads,
                                        target: target, blend: blend, alphaMax: alphaMax,
                                        compositeOwnerID: compositeOwnerID, writeMask: mask, geometry: geometry,
                                        layerMatrices: lastSegment && geometry == .fullscreenQuad))
                if pass.compose, (effectIndex, passIndex) != lastPass {
                    current ^= 1
                    flips += 1
                }
            }
            exchangeSwapPairs(object, effect)
            current ^= 1
            flips += 1
        }

        guard bit4, object.visible else { return }
        owner = object.id
        // 1401e8aa0.c:1078-1115; a puppet's is FUN_140208c80.
        let identity = WPEPassIdentity("\(object.id)/passthrough4")
        bind(identity, destination.color, depth: destination.depth)
        draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: "effectpassthrough_4",
                                source: .layerPassthrough(colorBlendMode: object.colorBlendMode,
                                                          layerFog: object.materialFog, puppet: object.puppet),
                                reads: [composites[current], Resource.fullFrameBuffer], target: destination.color,
                                blend: object.colorBlendMode == 31 ? .additive : object.blend,
                                alphaMax: destination.alphaMax, compositeOwnerID: destination.compositeOwnerID,
                                writeMask: destination.writeMask, geometry: object.layerGeometry,
                                depthTest: object.materialState.depthTest,
                                depthWrite: object.materialState.depthWrite))
    }

    /// 140207b50: albedo into the starting composite with ONE/ZERO and RGBA.
    private mutating func fillComposite(_ object: WPEParitySceneObject, _ composite: WPEResourceID) {
        if case let .text(text) = object.kind {
            return fillTextComposite(object, text, composite)
        }
        if object.fullscreen {
            // 1401e8aa0.c:720-736
            transfer(WPEPassIdentity("\(object.id)/fullscreen"), into: composite)
            return
        }
        let identity = WPEPassIdentity("\(object.id)/albedo")
        bind(identity, composite, depth: nil)
        if object.passthrough, !object.copyBackground {
            emit(identity, .clearColor(WPETextureView(composite), WPEClearColor(red: 0, green: 0, blue: 0, alpha: 0)))
            return
        }
        let (shader, source, reads) = albedoSource(object)
        draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: shader, source: source, reads: reads,
                                target: composite, blend: .normal, writeMask: .rgba, geometry: .fullscreenQuad,
                                fillsComposite: true))
    }

    /// No enabled effect and no bit4: the layer draws its albedo straight into the destination and its children
    /// follow into the same destination.
    private mutating func renderWithoutComposite(_ object: WPEParitySceneObject,
                                                 children: [WPEParitySceneObject],
                                                 into destination: WPEParitySceneDestination,
                                                 ancestors: [WPEResourceID]) {
        if case let .text(text) = object.kind {
            renderTextDirect(object, text, into: destination)
        } else if !object.fullscreen, !object.passthrough || object.copyBackground {
            let identity = WPEPassIdentity("\(object.id)/albedo")
            let (shader, albedo, reads) = albedoSource(object)
            bind(identity, destination.color, depth: destination.depth)
            // FUN_140208670: a puppet draws its mesh with the layer material plus the skinning combos.
            var source = albedo
            source?.combos.merge(object.puppet?.skinningCombos ?? [:]) { _, new in new }
            draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: shader, source: source,
                                    reads: reads, target: destination.color, blend: object.blend,
                                    alphaMax: destination.alphaMax,
                                    compositeOwnerID: destination.compositeOwnerID,
                                    writeMask: destination.writeMask, geometry: object.layerGeometry))
        }
        for child in children {
            render(child, into: destination, ancestors: ancestors)
        }
    }

    /// FUN_1402222a0: each sub-mesh in file order binds its own material, draws into the bound target and unbinds;
    /// the model sets no target or state itself. Blending other than opaque (0, 3) turns depth writes off
    /// (140155fc0.c:713-738). The draws read only the frame resources their materials name.
    private mutating func renderModel(_ object: WPEParitySceneObject, _ model: WPEParitySceneModel,
                                      children: [WPEParitySceneObject],
                                      into destination: WPEParitySceneDestination, ancestors: [WPEResourceID]) {
        for (index, mesh) in model.meshes.enumerated() {
            let identity = WPEParitySceneModel.pass(objectID: object.id, mesh: index)
            let state = mesh.materialState
            let reads = frameReads(mesh.material.flatMap { object.materialFrameReads[$0.materialPath] } ?? [])
            bind(identity, destination.color, depth: destination.depth)
            draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: mesh.shader, source: mesh.material,
                                    reads: reads, target: destination.color, blend: mesh.blend,
                                    alphaMax: destination.alphaMax, compositeOwnerID: destination.compositeOwnerID,
                                    writeMask: destination.writeMask(state), geometry: .modelMesh,
                                    depthTest: state.depthTest, depthWrite: state.depthWrite && mesh.blend == .normal,
                                    cullsBackFaces: state.cullsBackFaces))
        }
        for child in children {
            render(child, into: destination, ancestors: ancestors)
        }
    }

    /// 140258050: the opaquebackground quad, then each glyph list, straight into the destination. Without a mesh
    /// nothing draws.
    private mutating func renderTextDirect(_ object: WPEParitySceneObject, _ text: WPEParitySceneText,
                                           into destination: WPEParitySceneDestination) {
        guard let mesh = text.layout.mesh else { return }
        let depth = text.depthMaterials
        var passes: [(WPEPassIdentity, String, WPEParitySceneMaterialSource, WPEParitySceneDraw.Geometry)] = []
        if text.object.opaqueBackground {
            passes.append((WPEPassIdentity("\(object.id)/background"), "flat", .textBackground(depth: depth),
                           .textBackground))
        }
        for atlas in mesh.drawnLists {
            passes.append((Self.glyphPass(object, atlas), "font", .textGlyphs(atlas, depth: depth), .textGlyphs(atlas)))
        }
        for (identity, shader, source, geometry) in passes {
            bind(identity, destination.color, depth: destination.depth)
            draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: shader, source: source, reads: [],
                                    target: destination.color, blend: object.blend, alphaMax: destination.alphaMax,
                                    compositeOwnerID: destination.compositeOwnerID,
                                    writeMask: destination.writeMask, geometry: geometry, depthTest: depth))
        }
    }

    /// 140257c30 then 140257d70: clearalpha over the snapshot (or an opaque Clear), then the glyph lists translucent.
    private mutating func fillTextComposite(_ object: WPEParitySceneObject, _ text: WPEParitySceneText,
                                            _ composite: WPEResourceID) {
        let opaque = text.object.opaqueBackground
        let fill = WPEPassIdentity("\(object.id)/\(opaque ? "background" : "clearalpha")")
        bind(fill, composite, depth: nil)
        if opaque {
            let color = SIMD4<Double>(text.background)
            emit(fill, .clearColor(WPETextureView(composite),
                                   WPEClearColor(red: color.x, green: color.y, blue: color.z, alpha: color.w)))
        } else {
            draw(WPEParitySceneDraw(pass: fill, objectID: object.id, shader: "composelayer", source: .textClearAlpha,
                                    reads: [Resource.fullFrameBuffer], target: composite, blend: .normal,
                                    writeMask: .rgba, geometry: .layerMesh))
        }
        for atlas in text.layout.mesh?.drawnLists ?? [] {
            let identity = Self.glyphPass(object, atlas)
            bind(identity, composite, depth: nil)
            draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: "font",
                                    source: .textGlyphs(atlas, depth: text.depthMaterials), reads: [],
                                    target: composite, blend: .translucent, writeMask: .rgba,
                                    geometry: .textGlyphs(atlas), fillsComposite: true))
        }
    }

    private static func glyphPass(_ object: WPEParitySceneObject,
                                  _ atlas: WPEParityGlyphAtlasInstance.Atlas) -> WPEPassIdentity {
        WPEPassIdentity("\(object.id)/glyphs\(atlas == .color ? "/color" : "")")
    }

    /// FUN_1402366f0: each renderer entry draws with its material pass's state; a REFRACT object copies
    /// `_rt_FullFrameBuffer` once per frame, before its first REFRACT draw (R16 Q3).
    private mutating func renderParticles(_ object: WPEParitySceneObject, _ particle: WPEParitySceneParticle,
                                          into destination: WPEParitySceneDestination) {
        var snapshotTaken = false
        for entry in particle.draws {
            let key = entry.key
            let path = key.node.map { "/\($0)" }.joined() + (key.eventGroup.map { "/e\($0)" } ?? "")
            let identity = WPEPassIdentity("\(object.id)/particle\(path)/r\(key.renderer)")
            if entry.readsFullFrameBuffer, !snapshotTaken {
                snapshot(WPEPassIdentity("\(object.id)/particle/snapshot"))
                snapshotTaken = true
            }
            bind(identity, destination.color, depth: destination.depth)
            let state = entry.materialState
            draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: entry.shader, source: entry.source,
                                    reads: entry.readsFullFrameBuffer ? [Resource.fullFrameBuffer] : [],
                                    target: destination.color, blend: entry.blend, alphaMax: destination.alphaMax,
                                    compositeOwnerID: destination.compositeOwnerID,
                                    writeMask: destination.writeMask(state), geometry: .particles(key),
                                    depthTest: state.depthTest, depthWrite: state.depthWrite && entry.blend == .normal,
                                    cullsBackFaces: state.cullsBackFaces))
        }
    }

    /// A passthrough layer that copies the background draws composelayer (mesh+0x2e8) over the snapshot.
    private mutating func albedoSource(_ object: WPEParitySceneObject)
        -> (String, WPEParitySceneMaterialSource?, [WPEResourceID]) {
        if object.passthrough {
            return ("composelayer", .composeLayer, [Resource.fullFrameBuffer])
        }
        let image = Resource.layerImage(object.id)
        register(image, object.width, object.height, lifetime: .imported)
        let named = object.material.flatMap { object.materialFrameReads[$0.materialPath] } ?? []
        return (object.materialShader, object.material, [image] + frameReads(named))
    }

    /// FUN_14025faf0: no albedo, composite or children. The passes of the last effect draw into the bound target
    /// with the layer matrices, every one with DIRECTDRAW=1 (14025ff50); `previous` is never bound (1401ebf60.c:146).
    private mutating func renderShape(_ object: WPEParitySceneObject, _: WPEParitySceneShape,
                                      into destination: WPEParitySceneDestination) {
        guard let effect = object.effects.last(where: \.enabled) else { return }
        for fbo in effect.fbos {
            register(Self.fboID(object, effect, fbo.name), fbo.width, fbo.height, format: fbo.format)
        }
        // 1401ebf60.c:178-183, 345: effect+0x144, the last draw pass, draws the shape mesh additive (140260790).
        let finalPass = effect.passes.lastIndex { $0.kind == .draw }
        let readsFullFrame = effect.passes.contains(where: \.readsFullFrameBuffer)
        for (passIndex, pass) in effect.passes.enumerated() {
            let identity = WPEPassIdentity("\(object.id)/\(effect.id)/\(passIndex)")
            func fbo(_ name: String) -> WPEResourceID {
                bound(Self.fboID(object, effect, name))
            }
            if case let .copy(source) = pass.kind {
                if let source, let target = pass.target {
                    emit(identity, .copy(source: fbo(source), destination: fbo(target)))
                }
                continue
            }
            let final = passIndex == finalPass
            let target = pass.target.map(fbo) ?? destination.color
            bind(identity, target, depth: pass.target == nil ? destination.depth : nil)
            if passIndex == 0, readsFullFrame {
                snapshot(WPEPassIdentity("\(object.id)/\(effect.id)/snapshot"))
            }
            var source = pass.source
            source?.combos["DIRECTDRAW"] = 1
            let reads = pass.binds.map(fbo) + (pass.readsFullFrameBuffer ? [Resource.fullFrameBuffer] : [])
                + frameReads(pass.frameReads)
            draw(WPEParitySceneDraw(pass: identity, objectID: object.id, effectID: effect.id, passIndex: passIndex,
                                    shader: pass.shader, source: source, reads: reads, target: target,
                                    blend: final ? .additive : pass.blend,
                                    alphaMax: pass.target == nil && destination.alphaMax,
                                    compositeOwnerID: destination.compositeOwnerID,
                                    writeMask: final ? destination.writeMask : .rgba,
                                    geometry: final ? .shapeQuad : .fullscreenQuad, layerMatrices: !final))
        }
        exchangeSwapPairs(object, effect)
    }

    private mutating func exchangeSwapPairs(_ object: WPEParitySceneObject, _ effect: WPEParitySceneEffect) {
        for fbo in effect.fbos {
            guard let partner = fbo.swapPartner, fbo.name < partner else { continue }
            let first = Self.fboID(object, effect, fbo.name)
            let second = Self.fboID(object, effect, partner)
            let exchanged = (bound(second), bound(first))
            (bindings[first], bindings[second]) = exchanged
        }
    }

    /// 1401ea500.c:102-116
    private func compositeExtent(_ object: WPEParitySceneObject) -> (Int, Int) {
        (max(4, object.fullscreen ? scene.width : object.width), max(4, object.fullscreen ? scene.height : object.height))
    }

    private mutating func registerComposite(_ composite: WPEResourceID, of object: WPEParitySceneObject) {
        let (width, height) = compositeExtent(object)
        register(composite, width, height, format: compositeFormat)
        samplers[composite] = object.compositeSampler
    }

    /// The material names the frame has: `_rt_FullFrameBuffer` and every layer's `_a`. Any other name stays out,
    /// and the draw that samples it is skipped downstream.
    private mutating func frameReads(_ names: [WPEResourceID]) -> [WPEResourceID] {
        names.filter { name in
            if let owner = layerComposites[name] {
                registerComposite(name, of: owner)
                return true
            }
            return name == Resource.fullFrameBuffer
        }
    }

    /// A name `effect` does not declare resolves to the first enabled effect of the layer that does.
    private static func fboID(_ object: WPEParitySceneObject, _ effect: WPEParitySceneEffect,
                              _ name: String) -> WPEResourceID {
        func declaration(_ candidate: WPEParitySceneEffect) -> WPEParitySceneFBO? {
            candidate.fbos.first { $0.name == name }
        }
        let owner = declaration(effect) != nil ? effect
            : object.effects.first { $0.enabled && declaration($0) != nil } ?? effect
        guard let fbo = declaration(owner) else {
            return Resource.effectFBO(objectID: object.id, effectID: owner.id, name: name)
        }
        return fbo.shared ? Resource.sharedFBO(name)
            : Resource.effectFBO(fbo, effectID: owner.id, fullscreen: object.fullscreen)
    }

    private func bound(_ id: WPEResourceID) -> WPEResourceID {
        bindings[id] ?? id
    }

    private mutating func snapshot(_ identity: WPEPassIdentity) {
        transfer(identity, into: Resource.fullFrameBuffer)
    }

    /// CopyResource cannot change the sample count, so a multisampled scene is resolved instead.
    private mutating func transfer(_ identity: WPEPassIdentity, into destination: WPEResourceID) {
        emit(identity, sceneColor == Resource.backbuffer
            ? .copy(source: sceneColor, destination: destination)
            : .resolve(source: sceneColor, destination: destination))
    }

    private mutating func bind(_ identity: WPEPassIdentity, _ color: WPEResourceID, depth: WPEResourceID?) {
        emit(identity, .setTargets(color: [WPETextureView(color)], depth: depth.map { WPETextureView($0) }))
    }

    private mutating func draw(_ draw: WPEParitySceneDraw) {
        draws[draw.pass] = draw
        let opaque = draw.blend == .normal && draw.writeMask == .rgba && !draw.alphaMax
        emit(draw.pass, .draw(WPEDrawOperation(reads: draw.reads.map { WPETextureView($0) },
                                               readsDestination: !opaque,
                                               overwritesTargets: opaque && draw.geometry == .fullscreenQuad
                                                   && !draw.layerMatrices,
                                               depthTest: draw.depthTest, depthWrite: draw.depthWrite,
                                               state: WPEDrawStateKey(draw))))
    }

    private mutating func emit(_ identity: WPEPassIdentity, _ kind: WPERenderOperation.Kind) {
        operations.append(WPERenderOperation(pass: identity, kind))
        if let owner {
            owners[identity] = owner
        }
    }

    /// Every named RT in WPE's pool, including FFB, sc.* and effect FBOs, keeps its contents across frames.
    private mutating func register(_ id: WPEResourceID, _ width: Int, _ height: Int,
                                   format: String = Resource.colorFormat, samples: Int = 1,
                                   lifetime: WPEResourceLifetime = .pooled) {
        guard resources[id] == nil else { return }
        resources[id] = WPELogicalResource(id: id, width: width, height: height, format: format,
                                           sampleCount: samples, lifetime: lifetime)
    }
}

private extension WPEParitySceneObject {
    var layerGeometry: WPEParitySceneDraw.Geometry {
        puppet == nil ? .layerMesh : .puppetMesh
    }

    /// FUN_140099980 with the layer's flags.
    var compositeSampler: WPEParitySceneSampler {
        WPEParitySceneSampler(filter: noInterpolation ? .point : .linear, address: clampUVs ? .clamp : .wrap)
    }

    /// Bit4 of an image or text layer, which then owns `_rt_imageLayerComposite_<id>_a`.
    func hasLayerComposite(_ scene: WPEParitySceneDescription) -> Bool {
        switch kind {
        case .image, .text: requiresLayerComposite || scene.forcesLayerComposite || dependencyTarget
        case .model, .particle, .shape: false
        }
    }
}

private extension WPEParityTextMesh {
    /// WPE creates a mesh only for a list that has glyphs (1401b0410.c:707-729).
    var drawnLists: [WPEParityGlyphAtlasInstance.Atlas] {
        (mono.glyphKeys.isEmpty ? [] : [.mono]) + (color.glyphKeys.isEmpty ? [] : [.color])
    }
}

private extension WPERenderOperation.Kind {
    var resources: [WPEResourceID] {
        switch self {
        case let .setTargets(color, depth): (color + [depth].compactMap(\.self)).map(\.resource)
        case let .clearColor(view, _), let .clearDepth(view, _): [view.resource]
        case let .draw(draw): draw.reads.map(\.resource)
        case let .copy(source, destination), let .resolve(source, destination): [source, destination]
        case let .generateMips(id): [id]
        }
    }
}
