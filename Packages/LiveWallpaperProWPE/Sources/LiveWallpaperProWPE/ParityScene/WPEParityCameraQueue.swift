import Foundation
import simd

public enum WPEParityCameraQueueError: Error, Equatable {
    /// Item-owned bindings require the existing SceneScript manager's item lifetime and load boundary.
    case itemScripts(path: String)
}

/// One camera object's `path` resource and queue (1401f2030/1401f2ad0). Root `camera.paths` has a separate clock.
/// Confined to the frame owner, like WPEParityPropertyAnimation and the scene's shared random stream.
public final class WPEParityCameraQueue {
    public struct Output: Sendable, Equatable {
        /// Native writes these back to the camera object's local origin/angles, without a parent inverse.
        public let origin: SIMD3<Float>
        public let angles: SIMD3<Float>
        /// Item scalars override the camera object's own fields only while an item is selected.
        public let zoom: Float
        public let fov: Float
    }

    private struct Item {
        let visible: Bool
        let clock: WPEParityPropertyAnimation
        /// center xyz, eye xyz, up xyz, zoom, fov. Missing channels keep the current world-derived default.
        let channels: [WPEParityPropertyAnimation?]
        var zoom: Float = 1
        var fov: Float = 50
    }

    public let objectID: String
    public let path: String
    public var itemCount: Int {
        items.count
    }

    public private(set) var selectedIndex: Int?
    public var selectedZoom: Float? {
        selectedIndex.map { items[$0].zoom }
    }

    public var selectedFOV: Float? {
        selectedIndex.map { items[$0].fov }
    }

    public var selectedTime: Float? {
        selectedIndex.map { items[$0].clock.time }
    }

    private var items: [Item]
    private let eligible: [Int]
    private var remaining: [Int]
    private var previousRandom: Int?
    private let authoredMode: String
    /// Original 140077e10 takes an inclusive range and the scene's existing Main+1cd0 MT19937.
    private let randomInteger: (Int32, Int32) -> Int32

    /// A missing/nonstring path, unreadable JSON or non-array `paths` produces no queue, as in 1401f2030.
    /// Item scripts remain an explicit preparation error until their original manager consumer is connected.
    public init?(object: WPESceneJSONValue, assets: WPEParityProgramAssets,
                 randomInteger: @escaping (Int32, Int32) -> Int32) throws {
        guard let objectID = WPEParitySceneAnimations.id(object),
              let path = WPEParityProgramScene.string(object["path"]), let file = assets.json(path),
              case let .array(records)? = file["paths"] else { return nil }
        var items: [Item] = []
        for record in records {
            guard case .object = record, case let .object(authoredOptions)? = record["options"] else { continue }
            guard !Self.hasScript(record) else { throw WPEParityCameraQueueError.itemScripts(path: path) }
            // Camera items use a standalone native clock. Property-animation parent metadata is not read here.
            var options = authoredOptions
            options.removeValue(forKey: "parent")
            let clockProperty = WPESceneJSONValue.object(["animation": .object(["options": .object(options)])])
            guard let clock = WPEParityPropertyAnimation(property: clockProperty, valueType: .float) else { continue }
            var channels: [WPEParityPropertyAnimation?] = []
            for name in ["center", "eye", "up", "zoom", "fov"] {
                let count = name == "zoom" || name == "fov" ? 1 : 3
                for axis in 0 ..< count {
                    let raw = count == 1 ? record[name] : record[name]?["c\(axis)"]
                    guard case let .array(keys)? = raw, !keys.isEmpty else {
                        channels.append(nil)
                        continue
                    }
                    let property = WPESceneJSONValue.object(["animation": .object([
                        "options": .object(options), "c0": .array(keys),
                    ])])
                    channels.append(WPEParityPropertyAnimation(property: property, valueType: .float, sharingClock: clock))
                }
            }
            let visible = record["visible"]?["value"] ?? record["visible"]
            items.append(Item(visible: visible != .bool(false), clock: clock, channels: channels))
        }
        self.objectID = objectID
        self.path = path
        self.items = items
        eligible = items.indices.filter { items[$0].visible }
        remaining = eligible
        let mode = object["queuemode"]?["value"] ?? object["queuemode"]
        authoredMode = mode == .string("sequential") ? "sequential" : "random"
        self.randomInteger = randomInteger
    }

    /// Called in the existing object-update sweep, before active-camera selection. Hidden self/ancestor freezes
    /// the clock. An item finishes on this step, and the following update resets it and selects the next item.
    public func advance(dt: Float, world: simd_float4x4, orthographic: Bool,
                        state: WPEParitySceneState) -> Output? {
        guard state.isAlive(objectID), state.isVisible(objectID), !eligible.isEmpty else { return nil }
        if let index = selectedIndex, items[index].clock.finished {
            items[index].clock.resetFinished()
            select(state: state)
        } else if selectedIndex == nil {
            select(state: state)
        }
        guard let index = selectedIndex else { return nil }
        let item = items[index]
        // Native passes no event-dispatch context to 1401a9f60 here; item clock events are not dispatched.
        item.clock.advance(dt: dt, collectEvents: false)
        let eye = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        func normalized(_ vector: SIMD4<Float>) -> SIMD3<Float> {
            let length = sqrt((vector.y * vector.y + vector.x * vector.x) + vector.z * vector.z)
            let inverse: Float = 1 / length
            return SIMD3(vector.x * inverse, vector.y * inverse, vector.z * inverse)
        }
        var center = eye - normalized(world.columns.2) * 5
        var origin = eye
        var up = normalized(world.columns.1)
        for axis in 0 ..< 3 {
            if let value = item.channels[axis]?.value {
                center[axis] = value.x
            }
            if let value = item.channels[3 + axis]?.value {
                origin[axis] = value.x
            }
            if let value = item.channels[6 + axis]?.value {
                up[axis] = value.x
            }
        }
        if orthographic {
            items[index].zoom = item.channels[9]?.value?.x ?? 1
        } else {
            items[index].fov = item.channels[10]?.value?.x ?? 50
        }
        return Output(origin: origin, angles: Self.angles(eye: origin, center: center, up: up),
                      zoom: items[index].zoom, fov: items[index].fov)
    }

    private func select(state: WPEParitySceneState) {
        let mode = state.scriptField("queuemode", of: objectID) ?? .string(authoredMode)
        if mode == .string("sequential") {
            let start = (selectedIndex ?? -1) + 1
            selectedIndex = (0 ..< items.count).lazy.map { (start + $0) % self.items.count }
                .first { self.items[$0].visible }
            return
        }
        if remaining.isEmpty {
            remaining = eligible
        }
        let draw = randomInteger(0, Int32(remaining.count - 1))
        precondition(draw >= 0 && Int(draw) < remaining.count, "scene random consumer returned an invalid inclusive index")
        var position = Int(draw)
        if let previousRandom, remaining.count > 1 {
            while remaining[position] == previousRandom {
                position = (position + 1) % remaining.count
            }
        }
        selectedIndex = remaining.remove(at: position)
        previousRandom = selectedIndex
    }

    /// 1401f2ad0:31f2–3306 extracts local XYZ radians from the native lookAt matrix, then rebuilds local TRS.
    private static func angles(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> SIMD3<Float> {
        let matrix = WPEParityCamera.lookAt(eye: eye, center: center, up: up)
        let roll = atan2(matrix.columns.1.x, matrix.columns.0.x)
        let sine = sin(roll)
        let cosine = cos(roll)
        let pitch = atan2(-matrix.columns.2.x, sqrt(matrix.columns.2.z * matrix.columns.2.z
                + matrix.columns.2.y * matrix.columns.2.y))
        let yaw = atan2(sine * matrix.columns.0.z - cosine * matrix.columns.1.z,
                        cosine * matrix.columns.1.y - sine * matrix.columns.0.y)
        return SIMD3(yaw, pitch, roll)
    }

    private static func hasScript(_ value: WPESceneJSONValue) -> Bool {
        switch value {
        case let .object(fields): fields["script"] != nil || fields.values.contains(where: hasScript)
        case let .array(values): values.contains(where: hasScript)
        default: false
        }
    }
}
