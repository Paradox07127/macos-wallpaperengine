import Foundation
import simd

/// Every particle object of one scene in scene.json `objects` order, all drawing from one mt19937 and one CRT
/// `rand()` (R22 Q7). Not Sendable: the systems share those generators.
public struct WPEParityParticleScene {
    struct Object {
        let id: String
        var system: WPEParityParticleSystem
    }

    private(set) var objects: [Object] = []
    private var indexByID: [String: Int] = [:]
    private var seenScriptFieldsGeneration = 0

    /// `engineFlags` supplies the 2D defaults (orthographic projection, R22 Q8) and the HDR bit for brightness
    /// overrides. Each object prewarms with `frames[id]` (default context when absent) before the next is created.
    public init(document: WPESceneDocument, assets: WPEParityProgramAssets, engineFlags: WPEEngineComboFlags,
                seed: UInt32, frames: [String: WPEParityParticleFrameContext] = [:]) {
        let rng = WPEParityMT19937(seed: seed)
        let crt = WPEParityCRTRandom()
        let is3D = !engineFlags.orthographicProjection
        for particle in document.particleObjects {
            guard let config = WPEParityParticleConfig(path: particle.particleRelativePath, assets: assets,
                                                       is3D: is3D) else { continue }
            var frame = frames[particle.id] ?? WPEParityParticleFrameContext()
            frame.worldSpace = config.flags & 1 != 0
            let instance = WPEParityParticleSystem.Instance(particle.instanceOverride, hdr: engineFlags.hdr)
            indexByID[particle.id] = objects.count
            objects.append(Object(id: particle.id, system: WPEParityParticleSystem(
                config: config, instance: instance, rng: rng, crt: crt, context: frame
            )))
        }
    }

    /// The low 32 bits of milliseconds since 1970 (R22 Q7).
    public static func productSeed(now: Date = Date()) -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(now.timeIntervalSince1970 * 1000))
    }

    /// Applies the typed instance fields before the next object update (R25 §2; 140230650:55–64). Neither live
    /// slots nor RNG/emitter/history state are rebuilt. The general field generation includes rate, which has
    /// no native dirty hook; unchanged fields therefore require no object walk or parameter work.
    @discardableResult
    public mutating func applyScriptInstanceFields(state: WPEParitySceneState) -> [String] {
        guard seenScriptFieldsGeneration != state.scriptFieldsGeneration else { return [] }
        var changed: [String] = []
        for index in objects.indices {
            let id = objects[index].id
            if objects[index].system.applyScriptInstanceFields(state: state, objectID: id) {
                changed.append(id)
            }
        }
        seenScriptFieldsGeneration = state.scriptFieldsGeneration
        return changed
    }

    /// Steps every object in `objects` order. An object without a context is hidden: it is not stepped, and while its
    /// root system holds live particles it is reset (140230650.c:19). `worldSpace` is taken from the particle flags.
    public mutating func advance(dt: Float, frames: [String: WPEParityParticleFrameContext]) {
        for index in objects.indices {
            guard var frame = frames[objects[index].id] else {
                if objects[index].system.liveCount > 0 {
                    objects[index].system.reset()
                }
                continue
            }
            frame.worldSpace = objects[index].system.config.flags & 1 != 0
            objects[index].system.advance(dt: dt, frame: frame)
        }
    }

    /// Renderer and slot facts from the same resolved Config tree as prototypes and simulation, without slots,
    /// prewarm or RNG. Only the root uses the object's instance override, as in the existing child constructor.
    public static func prototype(for key: WPEParityParticleDrawKey, document: WPESceneDocument,
                                 assets: WPEParityProgramAssets) -> WPEParityParticlePrototype? {
        guard let object = document.particleObjects.first(where: { $0.id == key.objectID }),
              let root = WPEParityParticleConfig(path: object.particleRelativePath, assets: assets, is3D: false),
              let config = root.descendant(at: key.path[...]) else { return nil }
        let instance = WPEParityParticleSystem.Instance(key.path.isEmpty ? object.instanceOverride : nil, hdr: false)
        return WPEParityParticlePrototype(renderers: config.renderers,
                                          slotCount: Int((Float(config.maxCount) * instance.count).rounded()))
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

    /// 1402366f0: a live system triggers once per owner before its renderer entries, including a one-particle rope
    /// that yields no batch. The callback reads cached base-material facts: nil prunes this system and its children,
    /// just as a nil native material does; unknown facts may throw. Even empty systems must pass this material gate.
    /// The boundary refers to unfiltered batches and must not move when the caller drops or filters draws.
    public mutating func drawStream(objectID: String, ownerModel: simd_float4x4, worldModel: simd_float4x4,
                                    needsFullFrameBuffer: ([WPEParityParticlePathElement]) throws -> Bool?) rethrows
        -> WPEParityParticleDrawStream {
        guard let index = indexByID[objectID] else {
            return WPEParityParticleDrawStream(batches: [], snapshotBoundary: nil)
        }
        return try objects[index].system.drawStream(objectID: objectID, ownerModel: ownerModel, worldModel: worldModel,
                                                    needsFullFrameBuffer: needsFullFrameBuffer)
    }

    /// Top-level diagnostic convenience. Product composite drawing passes its live W/C explicitly.
    public mutating func drawStream(for objectID: String,
                                    needsFullFrameBuffer: ([WPEParityParticlePathElement]) throws -> Bool?) rethrows
        -> WPEParityParticleDrawStream {
        let owner = indexByID[objectID].map { objects[$0].system.instanceTransform } ?? matrix_identity_float4x4
        return try drawStream(objectID: objectID, ownerModel: owner, worldModel: matrix_identity_float4x4,
                              needsFullFrameBuffer: needsFullFrameBuffer)
    }

    /// Native draw order (1402366f0): own entries, each static child's complete subtree, then each event group's
    /// instances, completing an instance's subtree before the next. Each actual entry is packed once here.
    public mutating func drawBatches(for objectID: String) -> [WPEParityParticleDrawBatch] {
        drawStream(for: objectID, needsFullFrameBuffer: { _ in false }).batches
    }

    /// Compatibility lookup for a prototype key. Uses the same traversal/packing as `drawBatches(for:)`, packing
    /// only matching entries. Product drawing consumes the object API once so renderer keys do not reorder instances.
    public mutating func batches(for key: WPEParityParticleDrawKey) -> [WPEParityParticleVertexBatch] {
        guard let index = indexByID[key.objectID] else { return [] }
        return objects[index].system.drawBatches(objectID: key.objectID, matching: key).map(\.vertices)
    }

    /// Live particles of the object's systems, children included; nil for an unknown object.
    public func liveCount(_ objectID: String) -> Int? {
        indexByID[objectID].map { objects[$0].system.totalLiveCount }
    }

    /// Legacy placement-chain query, derived from E without storing cumulative L. This is not a mixed-space draw
    /// model: terminal event groups retain the parent chain, and multiple event instances have no single matrix.
    public func childLocal(for key: WPEParityParticleDrawKey) -> simd_float4x4? {
        guard let index = indexByID[key.objectID] else { return nil }
        return objects[index].system.localTransform(at: key.path[...], accumulated: matrix_identity_float4x4)
    }
}

extension WPEParityParticleSystem {
    mutating func drawBatches(objectID: String, matching: WPEParityParticleDrawKey? = nil)
        -> [WPEParityParticleDrawBatch] {
        drawStream(objectID: objectID, matching: matching, needsFullFrameBuffer: { _ in false }).batches
    }

    mutating func drawStream(objectID: String, matching: WPEParityParticleDrawKey? = nil,
                             needsFullFrameBuffer: ([WPEParityParticlePathElement]) throws -> Bool?) rethrows
        -> WPEParityParticleDrawStream {
        try drawStream(objectID: objectID, ownerModel: instanceTransform, worldModel: matrix_identity_float4x4,
                       matching: matching, needsFullFrameBuffer: needsFullFrameBuffer)
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

    func localTransform(at path: ArraySlice<WPEParityParticlePathElement>, accumulated: simd_float4x4) -> simd_float4x4? {
        guard let first = path.first else { return accumulated }
        switch first {
        case let .staticChild(index):
            guard children.indices.contains(index) else { return nil }
            return children[index].localTransform(at: path.dropFirst(), accumulated: accumulated * children[index].instanceTransform)
        case let .eventGroup(group):
            guard eventChildren.indices.contains(group) else { return nil }
            if path.count == 1 {
                return accumulated
            }
            guard eventChildren[group].count == 1 else { return nil }
            return eventChildren[group][0].localTransform(at: path.dropFirst(),
                                                          accumulated: accumulated * eventChildren[group][0].instanceTransform)
        }
    }

    private mutating func batch(_ index: Int, mainBatch: inout WPEParityParticleVertexBatch?)
        -> WPEParityParticleVertexBatch? {
        guard renderers.indices.contains(index) else { return nil }
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
