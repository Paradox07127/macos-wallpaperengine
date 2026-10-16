import Foundation
import simd

/// Every particle object of one scene in scene.json `objects` order, all drawing from one mt19937 and one CRT
/// `rand()`. Not Sendable: the systems share those generators.
public struct WPEParityParticleScene {
    struct Object {
        let id: String
        var system: WPEParityParticleSystem
    }

    private(set) var objects: [Object] = []
    private var indexByID: [String: Int] = [:]
    private var seenScriptFieldsGeneration = 0

    /// `engineFlags` supplies the 2D defaults (orthographic projection) and the HDR bit for brightness
    /// overrides. Each object prewarms with `frames[id]` (default context when absent) before the next is created.
    /// A supplied scene generator continues its stream; `seed` is used only when no generator was supplied.
    public init(document: WPESceneDocument, assets: WPEParityProgramAssets, engineFlags: WPEEngineComboFlags,
                seed: UInt32, frames: [String: WPEParityParticleFrameContext] = [:], rng suppliedRNG: WPEParityMT19937? = nil) {
        let rng = suppliedRNG ?? WPEParityMT19937(seed: seed)
        let crt = WPEParityCRTRandom()
        let is3D = !engineFlags.orthographicProjection
        for particle in document.particleObjects {
            guard let config = WPEParityParticleConfig(path: particle.particleRelativePath, assets: assets,
                                                       is3D: is3D) else { continue }
            let frame = frames[particle.id] ?? WPEParityParticleFrameContext()
            var instance = WPEParityParticleSystem.Instance(particle.instanceOverride, hdr: engineFlags.hdr)
            // Load copies the CP block before 22bd40 and the root prewarm (D/14022af30.c:390-417).
            if let override = particle.instanceOverride {
                for index in 0 ..< WPEParityParticleControlPoint.count {
                    instance.controlPointOffsets[index] = override.controlPointOffsets[index].map { SIMD3<Float>($0) }
                    instance.controlPointAngles[index] = override.controlPointAngles[index].map { SIMD3<Float>($0) }
                }
            }
            indexByID[particle.id] = objects.count
            objects.append(Object(id: particle.id, system: WPEParityParticleSystem(
                config: config, instance: instance, rng: rng, crt: crt, context: frame
            )))
        }
    }

    /// The low 32 bits of milliseconds since 1970.
    public static func productSeed(now: Date = Date()) -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(now.timeIntervalSince1970 * 1000))
    }

    /// Applies the typed instance fields before the next object update (140230650:55–64). Neither live
    /// slots nor RNG/emitter/history state are rebuilt. The general field generation includes rate, which has
    /// no native dirty hook; unchanged fields therefore require no object walk or parameter work.
    public mutating func applyScriptInstanceFields(state: WPEParitySceneState) {
        guard seenScriptFieldsGeneration != state.scriptFieldsGeneration else { return }
        for index in objects.indices {
            objects[index].system.applyScriptInstanceFields(state: state, objectID: objects[index].id)
        }
        seenScriptFieldsGeneration = state.scriptFieldsGeneration
    }

    /// Steps every object in `objects` order. An object without a context is hidden: it is not stepped, and while its
    /// root system holds live particles it is reset (140230650.c:19). `worldSpace` is taken from the particle flags.
    public mutating func advance(dt: Float, frames: [String: WPEParityParticleFrameContext]) {
        for index in objects.indices {
            advanceObject(at: index, dt: dt, frame: frames[objects[index].id])
        }
    }

    /// Advances one scene object in the caller's resolved object order, sharing this scene's generator.
    /// A nil frame applies the same hidden-root reset as the whole-scene entry point.
    public mutating func advance(objectID: String, dt: Float, frame: WPEParityParticleFrameContext?) {
        guard let index = indexByID[objectID] else { return }
        advanceObject(at: index, dt: dt, frame: frame)
    }

    private mutating func advanceObject(at index: Int, dt: Float, frame: WPEParityParticleFrameContext?) {
        guard let frame else {
            if objects[index].system.liveCount > 0 {
                objects[index].system.reset()
            }
            return
        }
        objects[index].system.advance(dt: dt, frame: frame)
    }

    /// Renderer and slot facts from the same resolved Config tree as prototypes and simulation, without slots,
    /// prewarm or RNG. Every node gets the object's override (22f890), whose count scales emission, not slots.
    public static func prototype(for key: WPEParityParticleDrawKey, document: WPESceneDocument,
                                 assets: WPEParityProgramAssets) -> WPEParityParticlePrototype? {
        guard let object = document.particleObjects.first(where: { $0.id == key.objectID }),
              let root = WPEParityParticleConfig(path: object.particleRelativePath, assets: assets, is3D: false),
              let config = root.descendant(at: key.path[...]) else { return nil }
        return WPEParityParticlePrototype(renderers: config.renderers, slotCount: config.maxCount)
    }

    /// Each accepted system's base program and resolved bound/default texture names, without simulation or RNG.
    /// The caller must retain compile failures as diagnostics rather than manufacture a false snapshot fact.
    public static func materialProbes(document: WPESceneDocument, assets: WPEParityProgramAssets,
                                      engineFlags: WPEEngineComboFlags) -> [WPEParityParticleMaterialProbe] {
        var probes: [WPEParityParticleMaterialProbe] = []
        for particle in document.particleObjects {
            guard let config = WPEParityParticleConfig(path: particle.particleRelativePath, assets: assets,
                                                       is3D: !engineFlags.orthographicProjection) else {
                probes.append(WPEParityParticleMaterialProbe(
                    objectID: particle.id, path: [],
                    material: .unavailable("particle \(particle.id): \(particle.particleRelativePath) unavailable")
                ))
                continue
            }
            config.appendMaterialProbes(objectID: particle.id, path: [], assets: assets, engineFlags: engineFlags,
                                        into: &probes)
        }
        return probes
    }

    /// 1402366f0: a live system (even a lone rope particle) triggers the snapshot once per owner. A nil material
    /// fact prunes the system and its children; the boundary indexes unfiltered batches.
    public mutating func drawStream(objectID: String, ownerModel: simd_float4x4, worldModel: simd_float4x4,
                                    needsFullFrameBuffer: ([WPEParityParticlePathElement]) throws -> Bool?) rethrows
        -> WPEParityParticleDrawStream {
        guard let index = indexByID[objectID] else {
            return WPEParityParticleDrawStream(batches: [], snapshotBoundary: nil)
        }
        return try objects[index].system.drawStream(objectID: objectID, ownerModel: ownerModel, worldModel: worldModel,
                                                    needsFullFrameBuffer: needsFullFrameBuffer)
    }

    /// Compatibility lookup for a prototype key, packing only matching entries in the object traversal.
    /// Product drawing consumes the object API once so renderer keys do not reorder instances.
    public mutating func batches(for key: WPEParityParticleDrawKey) -> [WPEParityParticleVertexBatch] {
        guard let index = indexByID[key.objectID] else { return [] }
        return objects[index].system.drawBatches(objectID: key.objectID, matching: key).map(\.vertices)
    }

    /// Live particles of the object's systems, children included; nil for an unknown object.
    public func liveCount(_ objectID: String) -> Int? {
        indexByID[objectID].map { objects[$0].system.totalLiveCount }
    }
}

extension WPEParityParticleSystem {
    /// Native draw order (1402366f0): own entries, each static child's complete subtree, then each event group's
    /// instances, completing an instance's subtree before the next.
    mutating func drawBatches(objectID: String, matching: WPEParityParticleDrawKey? = nil)
        -> [WPEParityParticleDrawBatch] {
        drawStream(objectID: objectID, ownerModel: instanceTransform, worldModel: matrix_identity_float4x4,
                   matching: matching, needsFullFrameBuffer: { _ in false }).batches
    }

    mutating func drawStream(objectID: String, ownerModel: simd_float4x4, worldModel: simd_float4x4,
                             matching: WPEParityParticleDrawKey? = nil,
                             needsFullFrameBuffer: ([WPEParityParticlePathElement]) throws -> Bool?) rethrows
        -> WPEParityParticleDrawStream {
        var batches: [WPEParityParticleDrawBatch] = []
        var snapshotBoundary: Int?
        try appendDrawStream(at: WPEParityParticleDrawKey(objectID: objectID, path: [], renderer: 0),
                             incomingModel: worldModel * ownerModel, worldModel: worldModel,
                             matching: matching, needsFullFrameBuffer: needsFullFrameBuffer,
                             into: &batches, snapshotBoundary: &snapshotBoundary)
        return WPEParityParticleDrawStream(batches: batches, snapshotBoundary: snapshotBoundary)
    }

    private mutating func appendDrawStream(at node: WPEParityParticleDrawKey,
                                           incomingModel: simd_float4x4, worldModel: simd_float4x4,
                                           matching: WPEParityParticleDrawKey?,
                                           needsFullFrameBuffer: ([WPEParityParticlePathElement]) throws -> Bool?,
                                           into batches: inout [WPEParityParticleDrawBatch],
                                           snapshotBoundary: inout Int?) rethrows {
        // 1402366f0.c:26–259: the material gate encloses own rendering and both child loops.
        guard let needsSnapshot = try needsFullFrameBuffer(node.path) else { return }
        if snapshotBoundary == nil, liveCount != 0, needsSnapshot {
            snapshotBoundary = batches.count
        }
        let ownModel = config.flags & 1 == 0 ? incomingModel : worldModel
        var mainBatch: WPEParityParticleVertexBatch?
        for renderer in renderers.indices {
            var key = node
            key.renderer = renderer
            if matching == nil || matching == key, let vertices = batch(renderer, mainBatch: &mainBatch) {
                batches.append(WPEParityParticleDrawBatch(key: key, vertices: vertices, modelMatrix: ownModel))
            }
        }
        // World own draw uses C, but its children start from E, even with zero live particles/renderers.
        let childModel = config.flags & 1 == 0 ? ownModel : instanceTransform
        for index in children.indices {
            var key = node
            key.path.append(.staticChild(index))
            let model = children[index].config.flags & 1 == 0
                ? childModel * children[index].instanceTransform : childModel
            try children[index].appendDrawStream(at: key, incomingModel: model, worldModel: worldModel, matching: matching,
                                                 needsFullFrameBuffer: needsFullFrameBuffer,
                                                 into: &batches, snapshotBoundary: &snapshotBoundary)
        }
        for group in eventChildren.indices {
            var key = node
            key.path.append(.eventGroup(group))
            for index in eventChildren[group].indices {
                let model = eventChildren[group][index].config.flags & 1 == 0
                    ? childModel * eventChildren[group][index].instanceTransform : childModel
                try eventChildren[group][index].appendDrawStream(at: key, incomingModel: model,
                                                                 worldModel: worldModel, matching: matching,
                                                                 needsFullFrameBuffer: needsFullFrameBuffer,
                                                                 into: &batches, snapshotBoundary: &snapshotBoundary)
            }
        }
    }

    private mutating func batch(_ index: Int, mainBatch: inout WPEParityParticleVertexBatch?)
        -> WPEParityParticleVertexBatch? {
        let renderer = renderers[index]
        guard liveCount > (renderer.kind == .rope ? 1 : 0) else { return nil }
        if renderer.kind == .sprite || renderer.kind == .spriteTrail {
            if let mainBatch {
                return WPEParityParticleVertexBatch(bytes: mainBatch.bytes, stride: mainBatch.stride,
                                                    count: mainBatch.count,
                                                    renderVar0: Self.mainRenderVar0(renderer: renderer))
            }
            let batch = vertices(for: renderer)
            mainBatch = batch
            return batch
        }
        return vertices(for: renderer)
    }
}
