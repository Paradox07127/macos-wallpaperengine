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

    /// Native draw order (1402366f0): own entries, each static child's complete subtree, then each event group's
    /// instances, completing an instance's subtree before the next. Each actual entry is packed once here.
    public mutating func drawBatches(for objectID: String) -> [WPEParityParticleDrawBatch] {
        guard let index = indexByID[objectID] else { return [] }
        return objects[index].system.drawBatches(objectID: objectID)
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

    /// Legacy static-path matrix; a terminal event group retains its parent's matrix even when empty. Mixed paths
    /// through multiple event instances have no single matrix. Product draws use each actual DrawBatch's matrix.
    public func childLocal(for key: WPEParityParticleDrawKey) -> simd_float4x4? {
        guard let index = indexByID[key.objectID] else { return nil }
        return objects[index].system.localTransform(at: key.path[...])
    }
}

extension WPEParityParticleSystem {
    mutating func drawBatches(objectID: String, matching: WPEParityParticleDrawKey? = nil)
        -> [WPEParityParticleDrawBatch] {
        var batches: [WPEParityParticleDrawBatch] = []
        appendDrawBatches(at: WPEParityParticleDrawKey(objectID: objectID, path: [], renderer: 0),
                          matching: matching, into: &batches)
        return batches
    }

    private mutating func appendDrawBatches(at node: WPEParityParticleDrawKey,
                                            matching: WPEParityParticleDrawKey?,
                                            into batches: inout [WPEParityParticleDrawBatch]) {
        var mainBatch: WPEParityParticleVertexBatch?
        for renderer in renderers.indices {
            var key = node
            key.renderer = renderer
            if matching == nil || matching == key, let vertices = batch(renderer, mainBatch: &mainBatch) {
                batches.append(WPEParityParticleDrawBatch(key: key, vertices: vertices, localTransform: localTransform))
            }
        }
        for index in children.indices {
            var key = node
            key.path.append(.staticChild(index))
            children[index].appendDrawBatches(at: key, matching: matching, into: &batches)
        }
        for group in eventChildren.indices {
            var key = node
            key.path.append(.eventGroup(group))
            for index in eventChildren[group].indices {
                eventChildren[group][index].appendDrawBatches(at: key, matching: matching, into: &batches)
            }
        }
    }

    func localTransform(at path: ArraySlice<WPEParityParticlePathElement>) -> simd_float4x4? {
        guard let first = path.first else { return localTransform }
        switch first {
        case let .staticChild(index):
            guard children.indices.contains(index) else { return nil }
            return children[index].localTransform(at: path.dropFirst())
        case let .eventGroup(group):
            guard eventChildren.indices.contains(group) else { return nil }
            if path.count == 1 {
                return localTransform
            }
            guard eventChildren[group].count == 1 else { return nil }
            return eventChildren[group][0].localTransform(at: path.dropFirst())
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
