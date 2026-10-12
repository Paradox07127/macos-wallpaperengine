#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// The scene's particle systems and each frame's share of the arena for their vertices.
struct WPEParityParticleFrame {
    var scene: WPEParityParticleScene
    /// Arena bytes particle vertices may take in one frame; the rest of the arena stays with cbuffers and tables.
    let budget: Int
    /// Batches dropped because a frame's particle vertices outgrew `budget`, over the renderer's life.
    private(set) var dropped = 0
    private var used = 0
    private var overflowed = false

    init(scene: WPEParityParticleScene, budget: Int) {
        self.scene = scene
        self.budget = budget
    }

    mutating func beginFrame() {
        used = 0
        overflowed = false
    }

    /// Copies `batch` into the frame's arena; once one batch does not fit, every later batch of the frame is dropped.
    mutating func upload(_ batch: WPEParityParticleVertexBatch,
                         to arena: WPEParityFrameArena.Frame) -> WPEParityFrameArena.Allocation? {
        let length = Self.aligned(batch.bytes.count)
        guard !overflowed, used + length <= budget, let allocation = arena.allocate(length: batch.bytes.count) else {
            overflowed = true
            dropped += 1
            return nil
        }
        used += length
        batch.bytes.withUnsafeBytes { allocation.contents.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        return allocation
    }

    static func aligned(_ length: Int) -> Int {
        let alignment = WPEParityFrameArena.alignment
        return (length + alignment - 1) / alignment * alignment
    }
}

/// A particle system read from its own JSON through the public `WPEParityParticleSystem` init, without children or
/// prewarm: its renderer entries and slot count are known before the scene's systems exist.
enum WPEParityParticleProbe {
    /// Children are numbered as `WPEParityProgramScene` keys them: missing or recursive files take no index.
    static func system(for key: WPEParityParticleDrawKey, document: WPESceneDocument,
                       assets: WPEParityProgramAssets) -> WPEParityParticleSystem? {
        guard let object = document.particleObjects.first(where: { $0.id == key.objectID }),
              var json = assets.json(object.particleRelativePath) else { return nil }
        var ancestors = [object.particleRelativePath]
        for index in key.node {
            let statics = children(json, ancestors: ancestors, assets: assets).statics
            guard statics.indices.contains(index) else { return nil }
            (json, ancestors) = (statics[index].json, ancestors + [statics[index].path])
        }
        if let group = key.eventGroup {
            let events = children(json, ancestors: ancestors, assets: assets).events
            guard events.indices.contains(group) else { return nil }
            json = events[group].json
        }
        guard case var .object(fields) = json else { return nil }
        fields["starttime"] = nil
        fields["children"] = nil
        let root = key.node.isEmpty && key.eventGroup == nil
        return WPEParityParticleSystem(json: .object(fields), instanceOverride: root ? object.instanceOverride : nil,
                                       rng: WPEParityMT19937())
    }

    private static func children(_ json: WPESceneJSONValue, ancestors: [String], assets: WPEParityProgramAssets)
        -> (statics: [(path: String, json: WPESceneJSONValue)], events: [(path: String, json: WPESceneJSONValue)]) {
        guard case let .array(entries)? = json["children"] else { return ([], []) }
        var statics: [(path: String, json: WPESceneJSONValue)] = []
        var events: [(path: String, json: WPESceneJSONValue)] = []
        for entry in entries {
            func string(_ key: String) -> String? {
                if case let .string(value)? = entry[key] {
                    value
                } else {
                    nil
                }
            }
            let flags: Int? = if case let .number(value)? = entry["flags"] {
                Int(value)
            } else {
                nil
            }
            let kind = WPEParticleChildEventKind(authoredType: string("type"), flags: flags)
            let path = string("name") ?? string("particle") ?? ""
            guard !ancestors.contains(path), let child = assets.json(path) else { continue }
            switch kind {
            case .staticSystem: statics.append((path, child))
            case .spawn, .death: events.append((path, child))
            default: break
            }
        }
        return (statics, events)
    }
}
#endif
