#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import os
import simd

extension WPEParityFrameRenderer {
    /// Moves the layer worlds to the state's transforms when any changed, and every frame while a child hangs on a
    /// puppet attachment point, whose bones this frame's animator step moved.
    func applyTransforms() {
        let moved = instance.state.transformGeneration != seenTransforms
        guard moved || layers.hasAttachments else { return }
        if moved {
            seenTransforms = instance.state.transformGeneration
            for (index, id) in instance.state.ids.enumerated() {
                let object = instance.state.objects[index]
                layers.setTransform(id, origin: object.origin, angles: object.angles, scale: object.scale)
            }
        }
        layers.refreshWorlds { instance.puppets[$0]?.boneWorld }
        layersMoved = true
    }

    /// Encodes the frame with the effects the state shows and without the operations of hidden objects. A change
    /// recompiles the graphs, and an effect change re-plans the draws it alters, except when it returns to the
    /// previous set.
    func selectGraphs() throws -> Bool {
        if pendingVideoAdmission != nil {
            return false
        }
        if Self.renderTargetAliasingFailed.withLock({ $0 }), !graphs.aliasedTargets.isEmpty {
            try installGraphs(graphs.layout, cachePrevious: false)
        }
        let currentPost = plan.postConfig(state: instance.state)
        let effectiveN = currentPost.hdrEnabled && currentPost.bloomEnabled ? currentPost.hdrBloomLevelCount : 0
        func matchesPost(_ post: WPEParityPostProcessConfig) -> Bool {
            post.bloomEnabled == currentPost.bloomEnabled
                && (post.hdrEnabled && post.bloomEnabled ? post.hdrBloomLevelCount : 0) == effectiveN
        }
        if instance.state.membershipGeneration == seenMembership, instance.state.modelDataGeneration != seenModelData,
           refreshModelDataDrawVersions() {
            seenModelData = instance.state.modelDataGeneration
        }
        if instance.state.membershipGeneration != seenMembership || instance.state.modelDataGeneration != seenModelData {
            var candidatePlanner = planner
            if instance.state.membershipGeneration != seenMembership {
                layers = plan.modelDataTransforms(state: instance.state, existing: layers)
                candidatePlanner.adoptModelDataTransforms(layers)
                layersMoved = true
            }
            let previous = graphs.layout
            let planned = try plan.layout(effects: instance.state, texts: planner.texts,
                                          mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
            let layout = try Self.makeLayout(planned, effects: instance.state.effectVisibility, artifacts: artifacts,
                                             planner: &candidatePlanner, encoder: drawEncoder,
                                             state: instance.state, reusing: previous)
            // Removed owners cannot return through the visibility cache. Existing command buffers retain
            // their submitted resource versions; this drops the renderer's obsolete draw/graph references.
            guard try installVideoReadyLayout(layout, planner: candidatePlanner, cachePrevious: false) else { return false }
            retireRemovedObjects(from: previous.planned)
            packedConstants.removeAll()
            fadeConstants.removeAll()
            seenMembership = instance.state.membershipGeneration
            seenModelData = instance.state.modelDataGeneration
            repackBloom()
        }
        guard instance.state.visibilityGeneration != seenVisibility || instance.state.effectVisibilityGeneration != seenEffects
            || !matchesPost(graphs.layout.post) else {
            return true
        }
        let hidden = instance.state.objects.indices.map { !instance.state.isVisible(at: $0) }
        let effects = instance.state.effectVisibility
        if hidden != graphs.hidden || effects != graphs.layout.effects || !matchesPost(graphs.layout.post) {
            if let previous = previousGraphs, previous.hidden == hidden, previous.layout.effects == effects,
               matchesPost(previous.layout.post),
               previous.executors.allSatisfy({ executor in
                   executor.graph.resources.values.allSatisfy { resource in
                       resource.lifetime == .imported || executor.transientTextures[resource.id] != nil
                           || targets[resource.id].map { Self.matches($0, resource: resource) } == true
                   }
               }) {
                let replaced = graphs
                graphs = previous
                previousGraphs = cacheable(replaced)
                planner.use(graphs.layout.planned)
                targetSamplers = Self.targetSamplers(graphs, targets: targets)
                reserveArena(for: graphs.layout)
            } else {
                var candidatePlanner = planner
                var layout = graphs.layout
                if effects != layout.effects || !matchesPost(layout.post) {
                    layout = try Self.makeLayout(plan.layout(effects: instance.state, texts: planner.texts,
                                                             mipMappedFrameBufferRequested: mipMappedFrameBufferRequested), effects: effects,
                                                 artifacts: artifacts, planner: &candidatePlanner, encoder: drawEncoder,
                                                 state: instance.state, reusing: layout)
                }
                guard try installVideoReadyLayout(layout, planner: candidatePlanner, cachePrevious: true) else { return false }
            }
            packedConstants.removeAll()
            fadeConstants.removeAll()
            repackBloom()
        }
        seenVisibility = instance.state.visibilityGeneration
        seenEffects = instance.state.effectVisibilityGeneration
        return true
    }

    /// Drops the images and targets only objects removed since `previous` used; the next committed frame retires them.
    func retireRemovedObjects(from previous: WPEParityFrameLayout) {
        let removed = Set(previous.frames.flatMap(\.owners.values).filter { !instance.state.isAlive($0) })
        guard !removed.isEmpty else { return }
        retiredTextures += planner.releaseImages(of: removed, droppedFrom: previous)
        var kept = Set(graphs.layout.frames.flatMap(\.resources).map(\.id))
        var owned: Set<WPEResourceID> = []
        for frame in previous.frames {
            for (index, operation) in frame.operations.enumerated() {
                if frame.owners[index].map(removed.contains) == true {
                    owned.formUnion(Self.touchedResources(operation.kind))
                } else {
                    kept.formUnion(Self.touchedResources(operation.kind))
                }
            }
        }
        for id in owned.subtracting(kept) {
            if let texture = targets.removeValue(forKey: id) {
                retiredTextures.append(texture)
            }
        }
    }

    private static func touchedResources(_ kind: WPERenderOperation.Kind) -> [WPEResourceID] {
        switch kind {
        case let .setTargets(color, depth): (color + [depth].compactMap(\.self)).map(\.resource)
        case let .clearColor(view, _), let .clearDepth(view, _): [view.resource]
        case let .draw(draw): draw.reads.map(\.resource)
        case let .copy(source, destination), let .resolve(source, destination),
             let .swapResources(source, destination): [source, destination]
        case let .resourceScope(_, resources): resources
        case let .generateMips(id): [id]
        }
    }

    /// Equal-layout buffer writes replace only the existing draw's immutable resource version. Membership,
    /// shape count, placement or material/program/layout changes take the ordinary graph transaction above.
    private func refreshModelDataDrawVersions() -> Bool {
        let layout = graphs.layout
        var draws = layout.draws
        var shapes: [Int: WPEParitySceneModelData.Shape] = [:]
        var indices: [String: Set<Int>] = [:]
        for (operation, description) in layout.frames[0].draws {
            guard case let .scene(description) = description,
                  let token = instance.state.object(description.objectID)?.modelDataToken else { continue }
            guard description.geometry == .modelMesh, let model = instance.state.modelData(token),
                  let index = WPEParitySceneModel.meshIndex(description.pass, objectID: description.objectID),
                  model.shapes.indices.contains(index),
                  let prepared = model.shapes[index].prepared as? WPEParityModelDataMetalShape,
                  var draw = draws[operation], case let .modelData(previous) = draw.geometry,
                  prepared.canReplaceDrawVersion(previous),
                  let placement = draw.placement, placement.objectID == description.objectID,
                  placement.kind == .layer, placement.text == nil, layers.layers[description.objectID] != nil,
                  layout.frames.allSatisfy({ frame in
                      guard case let .scene(other)? = frame.draws[operation] else { return false }
                      return other.pass == description.pass && other.objectID == description.objectID
                          && other.geometry == .modelMesh && other.compositeOwnerID == description.compositeOwnerID
                  }) else { return false }
            indices[description.objectID, default: []].insert(index)
            draw.geometry = .modelData(prepared)
            draws[operation] = draw
            shapes[operation] = model.shapes[index]
        }
        for id in instance.state.commonOrder {
            guard let token = instance.state.object(id)?.modelDataToken, let model = instance.state.modelData(token) else { continue }
            guard indices[id] == Set(model.shapes.indices) else { return false }
        }
        var planned = layout.planned
        planned.modelDataShapes = shapes
        let replaced = Layout(planned: planned, effects: layout.effects, draws: draws,
                              skipped: layout.skipped, fade: layout.fade)
        retiredDrops += previousGraphs?.executors.reduce(0) { $0 + $1.droppedDraws } ?? 0
        previousGraphs = nil
        planner.use(planned)
        graphs = Graphs(layout: replaced, hidden: graphs.hidden, executors: graphs.executors,
                        operations: graphs.operations, particleDraws: graphs.particleDraws,
                        particleSnapshotSkips: graphs.particleSnapshotSkips)
        return true
    }

    /// Candidate values on the existing renderer. Initialization touches only newly allocated target versions.
    struct PreparedGraphs {
        let graphs: Graphs
        let targets: [WPEResourceID: MTLTexture]
        let samplers: [ObjectIdentifier: WPEParitySamplerState]
        let initialization: MTLCommandBuffer?
    }

    func prepareGraphs(_ layout: Layout) throws -> PreparedGraphs {
        var candidateTargets = targets
        let made = try Self.makeGraphs(layout: layout, state: instance.state, device: device, encoder: drawEncoder,
                                       arena: arena, targets: &candidateTargets, resourceBindings: resourceBindings,
                                       snapshotObjects: particleSnapshotObjects, aliasing: Self.aliasesRenderTargets(plan))
        let added = candidateTargets.filter { id, texture in
            targets[id].map { ObjectIdentifier($0) != ObjectIdentifier(texture) } ?? true
        }
        let initialization = try Self.clear(Array(added.values), queue: queue,
                                            colors: Self.clearColors(layout, targets: added))
        return PreparedGraphs(graphs: made, targets: candidateTargets,
                              samplers: Self.targetSamplers(made, targets: candidateTargets),
                              initialization: initialization)
    }

    /// All fallible preparation precedes this same-owner value publication.
    func publishGraphs(_ prepared: PreparedGraphs, cachePrevious: Bool) {
        retiredDrops += previousGraphs?.executors.reduce(0) { $0 + $1.droppedDraws } ?? 0
        previousGraphs = cachePrevious ? cacheable(graphs) : nil
        graphs = prepared.graphs
        // Named pool history survives graph changes; Metal retains submitted texture versions.
        targets = prepared.targets
        targetSamplers = prepared.samplers
        reserveArena(for: graphs.layout)
    }

    /// Nil for graphs holding aliased targets: their heaps would stay resident beside the new graphs' own.
    private func cacheable(_ replaced: Graphs) -> Graphs? {
        guard replaced.aliasedTargets.isEmpty else {
            retiredDrops += replaced.executors.reduce(0) { $0 + $1.droppedDraws }
            return nil
        }
        return replaced
    }

    /// Raises the non-particle share to what `layout` needs. It never shrinks, so a cached graph still fits.
    func reserveArena(for layout: Layout) {
        let needed = Self.baseArenaBytes(layout, shadowBatches: shadowLayout?.batches.count ?? 1)
        guard needed > baseArenaBytes else { return }
        arena.capacity += needed - baseArenaBytes
        baseArenaBytes = needed
    }

    /// The largest frame variant's cbuffer and argument-table bytes outside particle draws, a shadow caster's once
    /// per atlas batch, plus a quarter and 64 KiB.
    static func baseArenaBytes(_ layout: Layout, shadowBatches: Int) -> Int {
        let bytes = layout.frames.map { frame in
            layout.draws.reduce(0) { total, entry in
                guard let description = frame.draws[entry.key] else { return total }
                if case .particles = entry.value.geometry {
                    return total
                }
                let casts = if case let .scene(draw) = description, draw.target == WPEParitySceneResource.shadowAtlas {
                    shadowBatches
                } else {
                    1
                }
                return total + entry.value.pipeline.argumentBytes * casts
            }
        }.max() ?? 0
        return bytes + bytes / 4 + (1 << 16)
    }

    /// Existing non-text callers use the same preparation and publication, with unchanged clear policy.
    func installGraphs(_ layout: Layout, cachePrevious: Bool) throws {
        let prepared = try prepareGraphs(layout)
        publishGraphs(prepared, cachePrevious: cachePrevious)
    }

    /// A resized non-unique FBO receives a new physical ID. Preserve the effect's binding permutation by the
    /// authored swap command identity, including effects currently disabled on both sides of the resize.
    func migratedBindings(from previous: WPEParityFrameRenderer) throws -> WPEParityResourceBindings {
        func swaps(_ plan: WPEParityFramePlan) throws -> [WPEPassIdentity: (WPEResourceID, WPEResourceID)] {
            var result: [WPEPassIdentity: (WPEResourceID, WPEResourceID)] = [:]
            for probe in try plan.probeFrames() {
                for operation in probe.frame.operations {
                    if case let .swapResources(first, second) = operation.kind {
                        result[operation.pass] = (first, second)
                    }
                }
            }
            return result
        }
        let old = try swaps(previous.plan)
        let current = try swaps(plan)
        var ids: [WPEResourceID: WPEResourceID] = [:]
        for (pass, pair) in old {
            guard let next = current[pass] else { continue }
            ids[pair.0] = next.0
            ids[pair.1] = next.1
        }
        return previous.resourceBindings.mapValues { bindings in
            Dictionary(bindings.map { (ids[$0.key] ?? $0.key, ids[$0.value] ?? $0.value) }) { first, _ in first }
        }
    }

    static func targetSamplers(_ graphs: Graphs, targets: [WPEResourceID: MTLTexture])
        -> [ObjectIdentifier: WPEParitySamplerState] {
        var result: [ObjectIdentifier: WPEParitySamplerState] = [:]
        for frame in graphs.layout.frames {
            for (id, sampler) in frame.samplers {
                // An aliased pooled target is a different texture in each executor and none in `targets`.
                let aliased = graphs.executors.compactMap { executor in
                    executor.graph.resources[id]?.lifetime == .pooled ? executor.transientTextures[id] : nil
                }
                for texture in [targets[id]].compactMap(\.self) + aliased {
                    result[ObjectIdentifier(texture)] = .wpe(filter: sampler.filter == .point ? .point : .linear,
                                                             address: sampler.address == .wrap ? .wrap : .clamp)
                }
            }
        }
        return result
    }

    /// Post-process constants for `bloom` where they differ from the planned ones; WPE refreshes them on the next
    /// frame.
    func repackBloom() {
        postConstants.removeAll()
        let layout = graphs.layout
        guard instance.bloom != layout.post.bloomSettings else { return }
        var config = layout.post
        config.bloomSettings = instance.bloom
        // A State write may precede this frame's selectGraphs. Its new N must first publish an admitted layout;
        // otherwise index-zipping constants could apply to different down/up passes or silently drop the update.
        guard !layout.post.hdrEnabled || !layout.post.bloomEnabled
            || config.hdrBloomLevelCount == layout.post.hdrBloomLevelCount else { return }
        let operations = layout.frames[0].draws.compactMap { index, draw -> Int? in
            if case .post = draw {
                index
            } else {
                nil
            }
        }.sorted()
        let rebuilt = WPEParityPostProcessBuilder.build(config).draws
        guard operations.count == rebuilt.count, zip(operations, rebuilt).allSatisfy({ operation, draw in
            guard case let .post(planned)? = layout.frames[0].draws[operation] else { return false }
            return planned.shader == draw.shader && planned.material == draw.material && planned.reads == draw.reads
        }) else { return }
        for (operation, draw) in zip(operations, rebuilt) {
            guard case let .post(planned)? = layout.frames[0].draws[operation], planned.constants != draw.constants,
                  let constants = layout.draws[operation]?.constants else { continue }
            let values = draw.constants.mapValues { $0.count == 1 ? WPECBufferValue.float($0[0]) : .vector($0) }
            postConstants[operation] = constants.mapValues { $0.merging(values) { $1 } }
        }
    }

    /// Plans `planned`'s draws in operation order, so the planner's layer images and videos come out the same every
    /// build; a draw `previous` has unchanged keeps its plan.
    static func makeLayout(_ planned: WPEParityFrameLayout, effects: [Bool],
                           artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>],
                           planner: inout WPEParityFrameDrawPlanner, encoder: WPEParityDrawEncoder,
                           state: WPEParitySceneState, reusing previous: Layout?) throws -> Layout {
        planner.use(planned)
        let names = drawNames(planned.frames[0])
        var earlier: [DrawName: Int] = [:]
        for (index, name) in previous.map({ drawNames($0.frames[0]) }) ?? [:] {
            earlier[name] = index
        }
        // Per frame; the first resource with an id wins, as `first(where:)` would.
        let byID: (WPEParityFrame) -> [WPEResourceID: WPELogicalResource] = { frame in
            Dictionary(frame.resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let currentResources = previous == nil ? [] : planned.frames.map(byID)
        let previousResources = previous?.frames.map(byID) ?? []
        var draws: [Int: WPEParityFrameDrawPlan] = [:]
        var skipped = planned.skipped
        for (index, program) in planned.programs.sorted(by: { $0.key < $1.key }) {
            if let previous, previous.frames.count == planned.frames.count,
               let match = names[index].flatMap({ earlier[$0] }), let plan = previous.draws[match],
               Self.sameModelDataVersion(planned.modelDataShapes[index], geometry: plan.geometry),
               planned.frames.indices.allSatisfy({
                   planned.frames[$0].draws[index] == previous.frames[$0].draws[match]
                       && Self.resourcesMatch(planned.frames[$0], currentResources[$0], previous.frames[$0],
                                              previousResources[$0], draw: index)
               }) {
                draws[index] = plan
                continue
            }
            let artifact = artifacts[program.hlsl] ?? .failure(.noShader("\(program.shader): not compiled at load"))
            do throws(WPEParityFrameSkip) {
                let draw = try planner.makePlan(index, artifact: artifact.get(), state: state)
                try Self.prepare(draw, encoder: encoder)
                draws[index] = draw
            } catch {
                skipped[index] = error
            }
        }
        for (index, description) in planned.frames[0].draws {
            if let pass = requiredPost(description), draws[index] == nil {
                throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                    pass: pass, reason: skipped[index] ?? .noMaterial
                )
            }
        }
        if let requiredPresentationPass = planned.requiredPresentationPass {
            let terminalIndex = planned.frames[0].draws.first { _, draw in
                guard case let .post(post) = draw else { return false }
                return post.shader == requiredPresentationPass
            }?.key
            guard let index = terminalIndex, draws[index] != nil, let program = planned.programs[index] else {
                throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                    pass: requiredPresentationPass, reason: terminalIndex.flatMap { skipped[$0] } ?? .noMaterial
                )
            }
            try validatePresentation(program, pass: requiredPresentationPass, post: planned.post)
        }
        let fade = planned.frames[0].draws.first { _, draw in
            if case let .post(post) = draw {
                post.shader == "fade"
            } else {
                false
            }
        }?.key
        return Layout(planned: planned, effects: effects, draws: draws, skipped: skipped, fade: fade)
    }

    /// `current` with the draws of `objects` that `kept` lacks planned again in operation order, for a change that
    /// leaves the composed frame as it is.
    static func replanDraws(of objects: Set<String>, in current: Layout, keeping kept: [Int: WPEParityFrameDrawPlan],
                            artifacts: [WPEHLSLProgram: Result<WPEParityShaderArtifact, WPEParityFrameSkip>],
                            planner: inout WPEParityFrameDrawPlanner, encoder: WPEParityDrawEncoder,
                            state: WPEParitySceneState) -> Layout {
        planner.use(current.planned)
        var draws = kept
        var skipped = current.skipped
        for (index, program) in current.planned.programs.sorted(by: { $0.key < $1.key }) {
            guard draws[index] == nil, case let .scene(draw)? = current.frames[0].draws[index],
                  objects.contains(draw.objectID) else { continue }
            let artifact = artifacts[program.hlsl] ?? .failure(.noShader("\(program.shader): not compiled at load"))
            do throws(WPEParityFrameSkip) {
                let plan = try planner.makePlan(index, artifact: artifact.get(), state: state)
                try prepare(plan, encoder: encoder)
                draws[index] = plan
                skipped[index] = nil
            } catch {
                skipped[index] = error
            }
        }
        return Layout(planned: current.planned, effects: current.effects, draws: draws, skipped: skipped,
                      fade: current.fade)
    }

    static func requiredPost(_ draw: WPEParityFrameDraw) -> String? {
        guard case let .post(post) = draw, post.shader != "fade", post.shader != "ccsimple" else { return nil }
        return post.shader
    }

    static func validatePresentation(_ program: WPEParityProgram, pass: String,
                                     post: WPEParityPostProcessConfig) throws {
        let expectedShader = pass == "combine_hdr" ? "combine_hdr" : "passthroughsrgb"
        // DISPLAYHDR=1 writes above reference white, which only a half-float backbuffer keeps.
        let displayHDR = pass == "combine_hdr" && post.displayHDREnabled
            && WPEParityFrameDrawPlanner.pixelFormats[post.backbufferFormat] == .rgba16Float
        guard program.shader == expectedShader,
              !program.combos.contains(where: { combo in
                  combo.value == "1" && (combo.name == "LINEAR" || combo.name == "DISPLAYHDR" && !displayHDR)
              }) else {
            throw WPEParityFrameRenderError.requiredPostProcessUnavailable(
                pass: pass, reason: .program("Unsupported HDR presentation shader or transfer combo: \(program.shader)")
            )
        }
    }

    private static func sameModelDataVersion(_ shape: WPEParitySceneModelData.Shape?,
                                             geometry: WPEParityFrameDrawPlan.Geometry) -> Bool {
        switch (shape, geometry) {
        case let (shape?, .modelData(previous)):
            (shape.prepared as? WPEParityModelDataMetalShape) === previous
        case (nil, .modelData): false
        case (nil, _): true
        default: false
        }
    }

    /// Resource and sampler creation is validated before the graph promises a draw's writes.
    private static func prepare(_ draw: WPEParityFrameDrawPlan,
                                encoder: WPEParityDrawEncoder) throws(WPEParityFrameSkip) {
        do {
            for textures in draw.textures {
                try encoder.prepare(pipeline: draw.pipeline, depthStencil: draw.depthStencil,
                                    textureNames: Set(textures.keys), samplers: draw.samplers)
            }
        } catch {
            throw .pipeline(String(describing: error))
        }
    }

    private static func resourcesMatch(_ current: WPEParityFrame, _ currentResources: [WPEResourceID: WPELogicalResource],
                                       _ previous: WPEParityFrame,
                                       _ previousResources: [WPEResourceID: WPELogicalResource], draw: Int) -> Bool {
        guard let description = current.draws[draw] else { return false }
        let ids: Set<WPEResourceID> = switch description {
        case let .scene(scene): Set(scene.reads + [scene.target])
        case let .post(post): Set(post.reads)
        }
        for id in ids {
            guard currentResources[id] == previousResources[id],
                  current.samplers[id] == previous.samplers[id] else { return false }
        }
        return true
    }

    static func drawNames(_ frame: WPEParityFrame) -> [Int: DrawName] {
        var counts: [WPEPassIdentity: Int] = [:]
        var names: [Int: DrawName] = [:]
        for index in frame.draws.keys.sorted() {
            let pass = frame.operations[index].pass
            names[index] = DrawName(pass: pass, occurrence: counts[pass, default: 0])
            counts[pass, default: 0] += 1
        }
        return names
    }

    /// Prepare only the HDR pyramid on the existing target owner, including a reachable cold-off branch.
    /// Declaring unused pooled resources does not give them a graph lifetime, so makeGraphs alone cannot do this.
    static func prepareHDRBloomTargets(_ post: WPEParityPostProcessConfig, device: MTLDevice,
                                       targets: inout [WPEResourceID: MTLTexture]) throws {
        guard post.hdrEnabled else { return }
        var capacity = post
        capacity.sceneBloomEnabled = true
        capacity.userBloomEnabled = true
        capacity.objectTableNonEmpty = true
        capacity.bloomSettings.hdrIterations = capacity.hdrBloomCapacity
        let ids = Set((1 ... capacity.hdrBloomCapacity).map { WPEResourceID("_rt_\(1 << $0)FrameBuffer") })
        for resource in WPEParityPostProcessBuilder.build(capacity).resources where ids.contains(resource.id) {
            guard resource.lifetime == .pooled else { continue }
            if let texture = targets[resource.id], matches(texture, resource: resource) {
                continue
            }
            targets[resource.id] = try makeTarget(resource, device: device)
        }
    }

    static func aliasesRenderTargets(_ plan: WPEParityFramePlan) -> Bool {
        plan.scene.renderTargetAliasing && !renderTargetAliasingFailed.withLock { $0 }
    }

    /// Compiles each frame variant of `layout` without the operations of objects `state` hides, allocating the
    /// targets the graphs need that `targets` lacks. With `aliasing`, a pooled target every variant proves fully
    /// overwritten before it is read lives in the executors' memory and its renderer texture is released.
    static func makeGraphs(layout: Layout, state: WPEParitySceneState, device: MTLDevice,
                           encoder: WPEParityDrawEncoder, arena: WPEParityFrameArena,
                           targets: inout [WPEResourceID: MTLTexture],
                           resourceBindings: WPEParityResourceBindings = [:], snapshotObjects: Set<String>,
                           aliasing: Bool = false) throws -> Graphs {
        var particleDraws: [WPEParityParticleDrawKey: Int] = [:]
        var snapshotSkips: [String: WPEParityFrameSkip] = [:]
        for (index, description) in layout.frames[0].draws {
            if case let .scene(draw) = description, case let .particles(key) = draw.geometry {
                particleDraws[key] = index
            }
        }
        let projections = layout.frames.indices.map { variant in
            WPEParityParticleGraph(frame: layout.frames[variant], state: state, draws: layout.draws, variant: variant,
                                   snapshotObjects: snapshotObjects)
        }
        for projected in projections {
            snapshotSkips.merge(projected.snapshotSkips) { first, _ in first }
        }
        func compile(discardable: Set<WPEResourceID>, proofs: [WPERenderGraphCoverageProof]) throws
            -> [WPECompiledRenderGraph] {
            try zip(layout.frames, projections).enumerated().map { variant, pair in
                try WPERenderGraphCompiler.compile(resources: pair.0.resources, operations: pair.1.operations,
                                                   discardableHistory: discardable,
                                                   coverage: proofs.isEmpty ? WPERenderGraphCoverageProof() : proofs[variant],
                                                   preservingTransfers: pair.1.preservingTransfers)
            }
        }
        func executors(_ graphs: [WPECompiledRenderGraph]) throws -> [WPEParityGraphExecutor] {
            try graphs.map { graph in
                try WPEParityGraphExecutor(graph: graph, device: device, drawEncoder: encoder, arena: arena,
                                           pixelFormats: WPEParityFrameDrawPlanner.pixelFormats,
                                           resourceBindings: resourceBindings)
            }
        }
        let aliased: [WPEParityGraphExecutor]? = if aliasing {
            try? aliasedExecutors(layout, projections, compile: compile, executors: executors)
        } else {
            nil
        }
        let built = try aliased ?? executors(compile(discardable: [], proofs: []))
        for (frame, executor) in zip(layout.frames, built) {
            // Script functions can use persistent FBOs without any graph draw/read lifetime. They must be
            // allocated before module-global/init execution, while ordinary graph transients remain unchanged.
            let graph = executor.graph
            let prepared = Set(graph.lifetimes.keys).union(frame.resources.filter { $0.lifetime == .persistent }.map(\.id))
            for id in prepared where executor.transientTextures[id] == nil {
                guard let resource = frame.resources.first(where: { $0.id == id }), resource.lifetime != .imported else { continue }
                if let texture = targets[id], Self.matches(texture, resource: resource) {
                    continue
                }
                targets[id] = try makeTarget(resource, device: device)
            }
        }
        let graphs = Graphs(layout: layout, hidden: state.objects.indices.map { !state.isVisible(at: $0) },
                            executors: built, operations: projections.map(\.sources), particleDraws: particleDraws,
                            particleSnapshotSkips: snapshotSkips)
        for id in graphs.aliasedTargets {
            targets[id] = nil
        }
        return graphs
    }

    /// Nil when no pooled target qualifies. A target one variant aliases must not be read at entry by another, which
    /// would see the renderer texture that variant no longer writes, so candidates shrink until every variant agrees.
    private static func aliasedExecutors(
        _ layout: Layout, _ projections: [WPEParityParticleGraph],
        compile: (Set<WPEResourceID>, [WPERenderGraphCoverageProof]) throws -> [WPECompiledRenderGraph],
        executors: ([WPECompiledRenderGraph]) throws -> [WPEParityGraphExecutor]
    ) throws -> [WPEParityGraphExecutor]? {
        let proofs = zip(layout.frames, projections).map { coverageProof($1, frame: $0, layout: layout) }
        var discardable = historyCandidates(layout)
        while !discardable.isEmpty {
            let graphs = try compile(discardable, proofs)
            let agreed = discardable.filter { id in
                graphs.allSatisfy { $0.lifetimes[id] == nil || $0.storage[id] != .dedicated }
            }
            if agreed == discardable {
                return try executors(graphs)
            }
            discardable = agreed
        }
        return nil
    }

    /// Pooled targets whose history a graph may drop, except composites a layer's albedo or its children fill: those
    /// are first drawn in some other effect or visibility set and then read what this graph would no longer keep.
    private static func historyCandidates(_ layout: Layout) -> Set<WPEResourceID> {
        var filled: Set<WPEResourceID> = []
        for frame in layout.frames {
            for case let .scene(draw) in frame.draws.values where draw.fillsComposite || draw.compositeOwnerID != nil {
                filled.insert(draw.target)
            }
            for block in frame.particleBlocks where block.compositeOwnerID != nil {
                filled.insert(block.color)
            }
        }
        let pooled = layout.frames.flatMap(\.resources).filter { $0.lifetime == .pooled }.map(\.id)
        return Set(pooled).subtracting(filled)
    }

    /// Facts about each draw of `projected`; particle and camera-fade draws, which can encode nothing, stay unproven.
    private static func coverageProof(_ projected: WPEParityParticleGraph, frame: WPEParityFrame,
                                      layout: Layout) -> WPERenderGraphCoverageProof {
        var draws: [Int: WPEDrawCoverage] = [:]
        var owners: [Int: String] = [:]
        for (index, source) in projected.sources.enumerated() {
            switch source {
            case let .layout(operation):
                owners[index] = frame.owners[operation]
                if case .draw = projected.operations[index].kind {
                    draws[index] = coverage(operation, frame: frame, layout: layout)
                }
            case let .particlePrefix(block), let .particleSnapshot(block), let .particleSuffix(block):
                let particles = frame.particleBlocks[block]
                owners[index] = frame.owners[particles.operations.lowerBound] ?? particles.objectID
            case .state:
                break
            }
        }
        return WPERenderGraphCoverageProof(draws: draws, owners: owners)
    }

    private static func coverage(_ operation: Int, frame: WPEParityFrame, layout: Layout) -> WPEDrawCoverage {
        let unproven = WPEDrawCoverage(alwaysExecutes: false, fullscreenGeometry: false, mayDiscard: true,
                                       writesEverySample: false)
        guard operation != layout.fade, let plan = layout.draws[operation], plan.pipeline.geometry == nil,
              let program = layout.planned.programs[operation], program.hlsl.geometry == nil,
              let vertex = program.hlsl.vertex.flatMap({ String(bytes: $0, encoding: .utf8) }),
              let fragment = program.hlsl.fragment.flatMap({ String(bytes: $0, encoding: .utf8) }) else { return unproven }
        let quad: Bool
        let alphaToCoverage: Bool
        switch frame.draws[operation] {
        case let .scene(draw)? where draw.target != WPEParitySceneResource.shadowAtlas:
            // Only an intermediate effect pass draws the 2x2 quad with the fixed effect-pass matrices.
            quad = draw.geometry == .fullscreenQuad && !draw.layerMatrices && !draw.fullscreenLayer
                && !draw.fillsComposite && !draw.multipliesDestination && draw.source != .textClearAlpha
            alphaToCoverage = draw.blend == .alphaToCoverage
        case .post?:
            quad = true
            alphaToCoverage = false
        case .scene?, nil:
            return unproven
        }
        let raster = plan.rasterizer
        let solid = raster.cullMode == .none && raster.fillMode == .solid && !raster.scissorEnable
        return WPEDrawCoverage(
            alwaysExecutes: true, fullscreenGeometry: quad && solid && passesQuadThrough(vertex),
            mayDiscard: fragment.range(of: #"\b(discard|clip)\b"#, options: .regularExpression) != nil,
            writesEverySample: !alphaToCoverage && !fragment.contains("SV_Coverage")
        )
    }

    /// The vertex stage's only position write emits the input quad as is or through the MVP, and nothing writes the
    /// input position first.
    private static func passesQuadThrough(_ source: String) -> Bool {
        let lines = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let positions = lines.filter { $0.contains("gl_Position") && $0 != "float4 gl_Position : SV_POSITION;" }
        let inputWrites = lines.contains { line in
            guard let assignment = line.firstIndex(of: "=") else { return false }
            return line[..<assignment].contains("a_Position")
        }
        return !inputWrites && positions.count == 1 && [
            "OUT.gl_Position = vec4(IN.a_Position, 1.0);", "OUT.gl_Position = vec4(IN.a_Position, 1);",
            "OUT.gl_Position = mul(vec4(IN.a_Position, 1.0), g_ModelViewProjectionMatrix);",
        ].contains(positions[0])
    }

    /// One context per visible particle object: scene time, cursor in [0, 1]² y down, the scene camera's
    /// view-projection and the object's world matrix.
    static func particleFrames(_ objects: [(id: String, index: Int?)], state: WPEParitySceneState,
                               layers: WPEParityLayerTransformSet, camera: WPEParityCamera, time: Float,
                               cursor: SIMD2<Float>?, timeOfDay: Float = 0)
        -> [String: WPEParityParticleFrameContext] {
        let viewProjection = camera.projection * camera.view
        var frames: [String: WPEParityParticleFrameContext] = [:]
        for (id, index) in objects where index.map(state.isVisible(at:)) ?? true {
            frames[id] = WPEParityParticleFrameContext(time: time, cursor: cursor, viewProjection: viewProjection,
                                                       objectMatrix: layers.world(id), timeOfDay: timeOfDay)
        }
        return frames
    }

    static func matches(_ texture: MTLTexture, resource: WPELogicalResource) -> Bool {
        texture.width == resource.width && texture.height == resource.height
            && texture.mipmapLevelCount == resource.mipCount && texture.sampleCount == resource.sampleCount
            && texture.pixelFormat == WPEParityFrameDrawPlanner.pixelFormats[resource.format]
    }

    static func makeTarget(_ resource: WPELogicalResource, device: MTLDevice) throws -> MTLTexture {
        guard let format = WPEParityFrameDrawPlanner.pixelFormats[resource.format] else {
            throw WPEParityGraphExecutionError.unsupportedFormat(resource.format)
        }
        // Reject before Metal's Objective-C descriptor validation can abort the process.
        let maximumDimension = WPEMetalTextureLimits.maximum2DTextureDimension(for: device)
        guard resource.width > 0, resource.height > 0,
              resource.width <= maximumDimension, resource.height <= maximumDimension,
              resource.mipCount > 0,
              resource.mipCount <= Int.bitWidth - max(resource.width, resource.height).leadingZeroBitCount,
              [1, 2, 4, 8].contains(resource.sampleCount), device.supportsTextureSampleCount(resource.sampleCount),
              resource.sampleCount == 1 || resource.mipCount == 1 else {
            throw WPEParityFrameRenderError.allocationFailed(resource.id)
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = resource.sampleCount > 1 ? .type2DMultisample : .type2D
        descriptor.pixelFormat = format
        descriptor.width = resource.width
        descriptor.height = resource.height
        descriptor.mipmapLevelCount = resource.mipCount
        descriptor.sampleCount = resource.sampleCount
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEParityFrameRenderError.allocationFailed(resource.id)
        }
        texture.label = resource.id.rawValue
        return texture
    }

    static func clearColors(_ layout: Layout, targets: [WPEResourceID: MTLTexture])
        -> [ObjectIdentifier: WPEClearColor] {
        var colors: [ObjectIdentifier: WPEClearColor] = [:]
        for resource in layout.frames.flatMap(\.resources) {
            if let color = resource.initialClear, let texture = targets[resource.id] {
                colors[ObjectIdentifier(texture)] = color
            }
        }
        return colors
    }

    /// Pooled targets can be read before their first write. Initialize every readable mip as a Mac safety policy;
    /// the original quality-enabled first-frame contents remain an evidence boundary.
    @discardableResult
    static func clear(_ textures: [MTLTexture], queue: MTLCommandQueue,
                      colors: [ObjectIdentifier: WPEClearColor] = [:]) throws -> MTLCommandBuffer? {
        guard !textures.isEmpty else { return nil }
        guard let commandBuffer = queue.makeCommandBuffer() else { throw WPEParityFrameRenderError.encoderUnavailable }
        for texture in textures {
            let pass = MTLRenderPassDescriptor()
            if texture.pixelFormat == .depth32Float {
                pass.depthAttachment.texture = texture
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.storeAction = .store
            } else {
                let color = colors[ObjectIdentifier(texture)] ?? .init(red: 0, green: 0, blue: 0, alpha: 0)
                try WPEParityGraphExecutor.encodeColorClear(texture, color: color, on: commandBuffer)
                continue
            }
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw WPEParityFrameRenderError.encoderUnavailable
            }
            encoder.endEncoding()
        }
        let mipmapped = textures.filter { $0.mipmapLevelCount > 1 && $0.pixelFormat != .depth32Float }
        if !mipmapped.isEmpty {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw WPEParityFrameRenderError.encoderUnavailable
            }
            for texture in mipmapped {
                blit.generateMipmaps(for: texture)
            }
            blit.endEncoding()
        }
        commandBuffer.commit()
        return commandBuffer
    }
}
#endif
