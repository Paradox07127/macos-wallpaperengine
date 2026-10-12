/// Emits WPE's RenderScene (140183550) up to the end of the object loop: scene clear, image layers and their effect
/// chains, and the MSAA resolve. Bloom, mip-mapped/HDR copies, ccsimple, fade and present are not part of it.
public enum WPEParitySceneFrameBuilder {
    public static func build(_ scene: WPEParitySceneDescription) -> WPEParitySceneFrame {
        var emitter = WPEParitySceneEmitter(scene)
        emitter.renderScene()
        return WPEParitySceneFrame(operations: emitter.operations,
                                   resources: emitter.resources.values.sorted { $0.id < $1.id },
                                   draws: emitter.draws)
    }
}

private typealias Resource = WPEParitySceneResource

private struct WPEParitySceneDestination {
    let color: WPEResourceID
    let depth: WPEResourceID?
    let alphaMax: Bool
    /// Top level writes RGB only; a parent composite gets RGBA once any ancestor counted R+0x1c9.
    var writeMask: WPEParitySceneWriteMask {
        alphaMax ? .rgba : .rgb
    }
}

private struct WPEParitySceneEmitter {
    let scene: WPEParitySceneDescription
    let roots: [WPEParitySceneObject]
    let childrenByParent: [String: [WPEParitySceneObject]]
    let sceneColor: WPEResourceID
    let sceneDepth: WPEResourceID
    var operations: [WPERenderOperation] = []
    var resources: [WPEResourceID: WPELogicalResource] = [:]
    var draws: [WPEPassIdentity: WPEParitySceneDraw] = [:]

    init(_ scene: WPEParitySceneDescription) {
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

        let multisampled = scene.msaaSamples > 1
        sceneColor = multisampled ? Resource.multisampled : Resource.backbuffer
        sceneDepth = multisampled ? Resource.multisampledDepth : Resource.backbufferDepth
        let format = scene.backbufferFormat
        register(Resource.backbuffer, scene.width, scene.height, format: format, lifetime: .output)
        register(Resource.backbufferDepth, scene.width, scene.height, format: Resource.depthFormat)
        register(Resource.fullFrameBuffer, scene.width, scene.height, format: format)
        if multisampled {
            register(Resource.multisampled, scene.width, scene.height, format: format, samples: scene.msaaSamples)
            register(Resource.multisampledDepth, scene.width, scene.height, format: Resource.depthFormat,
                     samples: scene.msaaSamples)
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
        let top = WPEParitySceneDestination(color: sceneColor, depth: sceneDepth, alphaMax: false)
        for object in roots {
            render(object, into: top, level: 0)
        }
        if sceneColor != Resource.backbuffer {
            emit("scene.resolve", .resolve(source: sceneColor, destination: Resource.backbuffer))
        }
    }

    /// 1401e8aa0. `level` is the nesting depth below a top-level layer; nested layers take their own pooled pair.
    private mutating func render(_ object: WPEParitySceneObject, into destination: WPEParitySceneDestination,
                                 level: Int) {
        guard object.visible else { return }
        let children = childrenByParent[object.id] ?? []
        let effects = object.effects.filter(\.enabled)
        let lastPass = (effects.count - 1, (effects.last?.passes.count ?? 0) - 1)
        let n = effects.count + effects.reduce(0) { $0 + $1.passes.count(where: \.compose) }
        let bit4 = object.requiresLayerComposite || scene.forcesLayerComposite

        // 1401e8aa0.c:169-176; a copybackground composelayer samples the snapshot too.
        if bit4 || !children.isEmpty || (object.passthrough && object.copyBackground) {
            snapshot(WPEPassIdentity("\(object.id)/snapshot"))
        }
        guard n > 0 || bit4 else {
            return renderWithoutComposite(object, children: children, into: destination, level: level)
        }

        let width = object.fullscreen ? scene.width : object.width
        let height = object.fullscreen ? scene.height : object.height
        let composites = [
            bit4 ? Resource.layerCompositeA(object.id)
                : Resource.pooledComposite(width: width, height: height, index: 2 * level),
            Resource.pooledComposite(width: width, height: height, index: 2 * level + 1),
        ]
        for composite in composites {
            register(composite, width, height)
        }
        // 1401e8aa0.c:476-487: the last reader always lands on composites[0].
        var current = bit4 ? n % 2 : (n - 1) % 2
        fillComposite(object, composites[current])
        let childDestination = WPEParitySceneDestination(color: composites[current], depth: nil,
                                                         alphaMax: destination.alphaMax || !object.copyBackground)
        for child in children {
            render(child, into: childDestination, level: level + 1)
        }

        for (effectIndex, effect) in effects.enumerated() {
            for fbo in effect.fbos {
                register(Resource.effectFBO(objectID: object.id, effectID: effect.id, name: fbo.name),
                         fbo.width, fbo.height, format: fbo.format)
            }
            let drawsDestination = !bit4 && effectIndex == effects.count - 1
            let readsFullFrame = effect.passes.contains(where: \.readsFullFrameBuffer)
            for (passIndex, pass) in effect.passes.enumerated() {
                let identity = WPEPassIdentity("\(object.id)/\(effect.id)/\(passIndex)")
                func fbo(_ name: String) -> WPEResourceID {
                    Resource.effectFBO(objectID: object.id, effectID: effect.id, name: name)
                }
                let target: WPEResourceID
                var depth: WPEResourceID?
                var blend = pass.blend
                var alphaMax = false
                var mask = WPEParitySceneWriteMask.rgba
                var geometry = WPEParitySceneDraw.Geometry.fullscreenQuad
                if let name = pass.target {
                    target = fbo(name)
                } else if drawsDestination {
                    // Every target-less pass of the last effect lands in the destination (U7).
                    target = destination.color
                    depth = destination.depth
                    blend = object.blend
                    alphaMax = destination.alphaMax
                    mask = destination.writeMask
                    geometry = .layerMesh
                } else {
                    target = composites[current ^ 1]
                }
                bind(identity, target, depth: depth)
                if passIndex == 0, readsFullFrame {
                    snapshot(WPEPassIdentity("\(object.id)/\(effect.id)/snapshot"))
                }
                let reads = [composites[current]] + pass.binds.map(fbo)
                    + (pass.readsFullFrameBuffer ? [Resource.fullFrameBuffer] : [])
                draw(WPEParitySceneDraw(pass: identity, objectID: object.id, effectID: effect.id,
                                        passIndex: passIndex, shader: pass.shader, reads: reads, target: target,
                                        blend: blend, alphaMax: alphaMax, writeMask: mask, geometry: geometry))
                if pass.compose, (effectIndex, passIndex) != lastPass {
                    current ^= 1
                }
            }
            current ^= 1
        }

        guard bit4 else { return }
        // 1401e8aa0.c:1078-1115
        let identity = WPEPassIdentity("\(object.id)/passthrough4")
        bind(identity, destination.color, depth: destination.depth)
        draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: "effectpassthrough_4",
                                reads: [composites[current], Resource.fullFrameBuffer], target: destination.color,
                                blend: object.blend, alphaMax: destination.alphaMax,
                                writeMask: destination.writeMask, geometry: .layerMesh))
    }

    /// 140207b50: albedo into the starting composite with ONE/ZERO and RGBA.
    private mutating func fillComposite(_ object: WPEParitySceneObject, _ composite: WPEResourceID) {
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
        let (shader, reads) = albedoSource(object)
        draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: shader, reads: reads, target: composite,
                                blend: .normal, writeMask: .rgba, geometry: .fullscreenQuad))
    }

    /// No enabled effect and no bit4: the layer draws its albedo straight into the destination and its children
    /// follow into the same destination.
    private mutating func renderWithoutComposite(_ object: WPEParitySceneObject,
                                                 children: [WPEParitySceneObject],
                                                 into destination: WPEParitySceneDestination, level: Int) {
        if !object.fullscreen, !object.passthrough || object.copyBackground {
            let identity = WPEPassIdentity("\(object.id)/albedo")
            let (shader, reads) = albedoSource(object)
            bind(identity, destination.color, depth: destination.depth)
            draw(WPEParitySceneDraw(pass: identity, objectID: object.id, shader: shader, reads: reads,
                                    target: destination.color, blend: object.blend, alphaMax: destination.alphaMax,
                                    writeMask: destination.writeMask, geometry: .layerMesh))
        }
        for child in children {
            render(child, into: destination, level: level)
        }
    }

    /// A passthrough layer that copies the background draws composelayer (mesh+0x2e8) over the snapshot.
    private mutating func albedoSource(_ object: WPEParitySceneObject) -> (String, [WPEResourceID]) {
        if object.passthrough {
            return ("composelayer", [Resource.fullFrameBuffer])
        }
        let image = Resource.layerImage(object.id)
        register(image, object.width, object.height, lifetime: .imported)
        return (object.materialShader, [image])
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
                                               overwritesTargets: opaque && draw.geometry == .fullscreenQuad,
                                               state: WPEDrawStateKey(draw))))
    }

    private mutating func emit(_ identity: WPEPassIdentity, _ kind: WPERenderOperation.Kind) {
        operations.append(WPERenderOperation(pass: identity, kind))
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
