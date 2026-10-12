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

    /// `engineFlags` supplies the 2D defaults (orthographic projection, R22 Q8) and the HDR bit for brightness
    /// overrides. Each object prewarms with `frames[id]` (default context when absent) before the next is created.
    public init(document: WPESceneDocument, assets: WPEParityProgramAssets, engineFlags: WPEEngineComboFlags,
                seed: UInt32, frames: [String: WPEParityParticleFrameContext] = [:]) {
        let rng = WPEParityMT19937(seed: seed)
        let crt = WPEParityCRTRandom()
        let is3D = !engineFlags.orthographicProjection
        let resolveMaterial = { (path: String) -> WPEParityParticleMaterial? in
            WPEParityProgramMaterial(path: path, assets: assets).map {
                WPEParityParticleMaterial(texture0: $0.textures[0].flatMap(assets.textureHeader(named:)))
            }
        }
        for particle in document.particleObjects {
            let path = particle.particleRelativePath
            guard let json = assets.json(path) else { continue }
            let config = WPEParityParticleConfig(json: json, ancestors: [path], eventChild: false, is3D: is3D,
                                                 resolveChild: assets.json, resolveMaterial: resolveMaterial)
            var frame = frames[particle.id] ?? WPEParityParticleFrameContext()
            frame.worldSpace = config.flags & 1 != 0
            let instance = WPEParityParticleSystem.Instance(particle.instanceOverride, json: json, hdr: engineFlags.hdr)
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

    /// Steps every object in `objects` order. An object without a context is invisible: it is not stepped and its
    /// particles are removed (R16 Q5). `worldSpace` is taken from the particle flags.
    public mutating func advance(dt: Float, frames: [String: WPEParityParticleFrameContext]) {
        for index in objects.indices {
            guard var frame = frames[objects[index].id] else {
                objects[index].system.removeAllParticles()
                continue
            }
            frame.worldSpace = objects[index].system.config.flags & 1 != 0
            objects[index].system.advance(dt: dt, frame: frame)
        }
    }

    /// A root or static node gives zero or one batch, an event group one per instance with live particles. A
    /// system with no live particle (rope: fewer than two) gives none, and the caller skips the draw (R22 Q3).
    public mutating func batches(for key: WPEParityParticleDrawKey) -> [WPEParityParticleVertexBatch] {
        guard let index = indexByID[key.objectID] else { return [] }
        return objects[index].system.batches(node: key.node[...], renderer: key.renderer, eventGroup: key.eventGroup)
    }

    /// Static-child translations from the object down to `key.node`, so that M = object world × this (R16 Q4);
    /// event groups use their parent's. Nil when the key names no system.
    public func childLocal(for key: WPEParityParticleDrawKey) -> simd_float4x4? {
        guard let index = indexByID[key.objectID] else { return nil }
        return objects[index].system.localTransform(at: key.node[...])
    }
}

extension WPEParityParticleSystem {
    mutating func batches(node: ArraySlice<Int>, renderer: Int, eventGroup: Int?) -> [WPEParityParticleVertexBatch] {
        if let first = node.first {
            guard children.indices.contains(first) else { return [] }
            return children[first].batches(node: node.dropFirst(), renderer: renderer, eventGroup: eventGroup)
        }
        guard let eventGroup else {
            return batch(renderer).map { [$0] } ?? []
        }
        guard eventChildren.indices.contains(eventGroup) else { return [] }
        var batches: [WPEParityParticleVertexBatch] = []
        for index in eventChildren[eventGroup].indices {
            if let batch = eventChildren[eventGroup][index].batch(renderer) {
                batches.append(batch)
            }
        }
        return batches
    }

    func localTransform(at node: ArraySlice<Int>) -> simd_float4x4? {
        guard let first = node.first else { return localTransform }
        guard children.indices.contains(first) else { return nil }
        return children[first].localTransform(at: node.dropFirst())
    }

    private mutating func batch(_ index: Int) -> WPEParityParticleVertexBatch? {
        guard renderers.indices.contains(index) else { return nil }
        let renderer = renderers[index]
        guard liveCount > (renderer.kind == .rope ? 1 : 0) else { return nil }
        return vertices(for: renderer)
    }
}
