import Foundation

/// WPE property keyframes sampled on an integer-frame cache and driven by a shared root clock.
public final class WPEParityPropertyAnimation {
    /// The four property types that WPE permits keyframes to override.
    public enum ValueType: Int, Sendable {
        case float = 1, vec2, vec3, vec4
    }

    /// The authored binding name used to resolve child animations.
    public let name: String?
    /// The authored parent binding key, if present.
    public let parentKey: String?
    /// WPE preserves this flag but does not use it to advance property animations.
    public let random: Bool
    /// Current root time in seconds.
    public var time: Float {
        root?.clockTime ?? clockTime
    }

    /// Current root playback direction, either 1 or -1.
    public var direction: Float {
        root?.clockDirection ?? clockDirection
    }

    /// Whether the root has reached the end of a single animation.
    public var finished: Bool {
        root?.clockFinished ?? clockFinished
    }

    /// The last explicit frame stamp processed by the root.
    public var frameStamp: UInt64? {
        root?.lastFrameStamp ?? lastFrameStamp
    }

    /// Components of the property type; `value` fills only these lanes.
    public var componentCount: Int {
        valueType.rawValue
    }

    /// The sampled components, or nil when the authored channels cannot override the property.
    public var value: SIMD4<Float>? {
        guard samples.count == valueType.rawValue else { return nil }
        let time = time
        let frame = min(length - 1, max(0, Int(time * fps)))
        let next = min(frame + 1, length)
        let fraction = fmodf(time, 1 / fps) * fps
        var result = SIMD4<Float>.zero
        for channel in samples.indices {
            result[channel] = samples[channel][frame] * (1 - fraction) + samples[channel][next] * fraction
        }
        return result
    }

    /// Names fired by the most recent advance, in authored event order.
    public var firedEvents: [String] {
        events.compactMap { $0.fired ? $0.name : nil }
    }

    private enum Mode { case loop, mirror, single }

    private struct Keyframe {
        var frame: Int
        var value: Float
        var back: SIMD2<Float>
        var front: SIMD2<Float>
        var step: Bool
    }

    private struct Event {
        var time: Float
        var name: String
        var fired = false
    }

    private let root: WPEParityPropertyAnimation?
    private let valueType: ValueType
    private let fps: Float
    private let length: Int
    private let duration: Float
    private let mode: Mode
    private let startPaused: Bool
    private let samples: [[Float]]
    private var events: [Event]
    private var clockTime: Float = 0
    private var clockDirection: Float = 1
    private var clockFinished = false
    private var lastFrameStamp: UInt64?
    private var previousTime: Float = 0
    private var previousDirection: Float = 1
    private var travelledTime: Float = 0

    /// Parses a raw property; a supplied parent must match parent.key and already have its root resolved.
    public init?(property: WPESceneJSONValue, valueType: ValueType,
                 parent: WPEParityPropertyAnimation? = nil) {
        guard let animation = property["animation"],
              let options = animation["options"],
              let authoredFPS = Self.number(options["fps"]),
              let authoredLength = Self.integer(options["length"]),
              authoredFPS > 0, authoredLength > 0, authoredLength < Int.max,
              (Float(authoredLength) / authoredFPS).isFinite,
              Float(authoredLength) / authoredFPS > 0 else { return nil }

        name = Self.string(options["name"])
        parentKey = Self.string(options["parent"]?["key"])
        if let parentKey {
            guard let parent, parent.name == parentKey else { return nil }
            root = parent.root ?? parent
        } else {
            root = nil
        }
        self.valueType = valueType
        fps = root?.fps ?? authoredFPS
        length = root?.length ?? authoredLength
        duration = Float(length) / fps
        switch Self.string(options["mode"]) {
        case "mirror": mode = .mirror
        case "single": mode = .single
        default: mode = .loop
        }
        random = options["random"] == .bool(true)
        startPaused = options["startpaused"] == .bool(true)

        var offsets = [Float](repeating: 0, count: 4)
        if animation["relative"] == .bool(true), case let .string(value) = property["value"] {
            let components = value.split(whereSeparator: { $0.isWhitespace })
            if components.count >= 3 {
                for index in 0 ..< 3 {
                    offsets[index] = Float(components[index]) ?? 0
                }
            }
        }
        var caches: [[Float]] = []
        for channel in 0 ..< 4 {
            guard case let .array(entries) = animation["c\(channel)"] else { break }
            var keys: [Keyframe] = []
            for entry in entries {
                guard let frame = Self.integer(entry["frame"]),
                      let value = Self.number(entry["value"]),
                      keys.last.map({ frame > $0.frame }) ?? true else { continue }
                let step = entry["step"] == .bool(true)
                keys.append(Keyframe(frame: frame, value: value + offsets[channel],
                                     back: step ? .zero : Self.tangent(entry["back"]),
                                     front: step ? .zero : Self.tangent(entry["front"]), step: step))
            }
            if options["wraploop"] == .bool(true), let first = keys.first {
                keys.append(Keyframe(frame: length, value: first.value,
                                     back: -first.front, front: -first.back, step: first.step))
            }
            guard !keys.isEmpty else { caches = []; break }
            caches.append((0 ... length).map { Self.sample(frame: $0, keys: keys) })
        }
        samples = caches
        var parsedEvents: [Event] = []
        if case let .array(entries) = options["events"] {
            for entry in entries {
                guard let frame = Self.number(entry["frame"]),
                      let name = Self.string(entry["name"]) else { continue }
                parsedEvents.append(Event(time: frame / fps, name: name))
            }
        }
        events = parsedEvents
    }

    /// Advances without allocation; pass the same frame stamp to all bindings sharing a root.
    public func advance(dt: Float, frameStamp: UInt64? = nil) {
        if let root {
            root.advance(dt: dt, frameStamp: frameStamp)
            if let frameStamp, lastFrameStamp == frameStamp {
                return
            }
            lastFrameStamp = frameStamp
            updateEvents(clock: root)
            return
        }
        if let frameStamp, lastFrameStamp == frameStamp {
            return
        }
        lastFrameStamp = frameStamp
        previousTime = clockTime
        previousDirection = clockDirection
        travelledTime = 0
        if !startPaused, !clockFinished, dt.isFinite, dt > 0 {
            switch mode {
            case .loop:
                travelledTime = dt
                clockTime = fmodf(clockTime + dt, duration)
            case .mirror:
                travelledTime = dt
                let phase = clockDirection > 0 ? clockTime : 2 * duration - clockTime
                let wrapped = fmodf(phase + dt, 2 * duration)
                if wrapped >= duration {
                    clockTime = 2 * duration - wrapped
                    clockDirection = -1
                } else {
                    clockTime = wrapped
                    clockDirection = 1
                }
            case .single:
                clockTime = min(clockTime + dt, duration)
                travelledTime = clockTime - previousTime
                clockFinished = clockTime >= duration
            }
        }
        updateEvents(clock: self)
    }

    private func updateEvents(clock: WPEParityPropertyAnimation) {
        for index in events.indices {
            let eventTime = events[index].time
            var fired = false
            if clock.travelledTime > 0, eventTime >= 0, eventTime <= clock.duration {
                switch clock.mode {
                case .loop:
                    if eventTime < clock.duration {
                        let distance = eventTime >= clock.previousTime
                            ? eventTime - clock.previousTime
                            : clock.duration - clock.previousTime + eventTime
                        fired = distance < clock.travelledTime
                    }
                case .single:
                    fired = eventTime >= clock.previousTime && eventTime < clock.clockTime
                case .mirror:
                    let period = 2 * clock.duration
                    let phase = clock.previousDirection > 0
                        ? clock.previousTime : period - clock.previousTime
                    let forward = eventTime >= phase ? eventTime - phase : period - phase + eventTime
                    let backwardPhase = period - eventTime
                    let backward = backwardPhase >= phase
                        ? backwardPhase - phase : period - phase + backwardPhase
                    fired = min(forward, backward) < clock.travelledTime
                }
            }
            events[index].fired = fired
        }
    }

    private static func number(_ raw: WPESceneJSONValue?) -> Float? {
        guard case let .number(value) = raw, Float(value).isFinite else { return nil }
        return Float(value)
    }

    private static func integer(_ raw: WPESceneJSONValue?) -> Int? {
        guard case let .number(value) = raw, value.isFinite,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func string(_ raw: WPESceneJSONValue?) -> String? {
        guard case let .string(value) = raw else { return nil }
        return value
    }

    private static func tangent(_ raw: WPESceneJSONValue?) -> SIMD2<Float> {
        guard case .object = raw, raw?["enabled"] != .bool(false) else { return .zero }
        return SIMD2(number(raw?["x"]) ?? 0, number(raw?["y"]) ?? 0)
    }

    private static func sample(frame: Int, keys: [Keyframe]) -> Float {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if frame <= first.frame {
            return first.value
        }
        if frame >= last.frame {
            return last.value
        }
        for index in 1 ..< keys.count {
            let b = keys[index]
            guard frame <= b.frame else { continue }
            let a = keys[index - 1]
            if frame == b.frame {
                return b.value
            }
            if b.step {
                return a.value
            }
            let halfSpan = 0.5 * (Float(b.frame) - Float(a.frame))
            let x = SIMD4(Float(a.frame), Float(a.frame) + halfSpan * a.front.x,
                          Float(b.frame) + halfSpan * b.back.x, Float(b.frame))
            let y = SIMD4(a.value, a.value + a.front.y, b.value + b.back.y, b.value)
            var u: Float = 0
            var step: Float = 0.4995
            for _ in 0 ..< 1000 {
                let position = cubic(x, u)
                if abs(position - Float(frame)) < 0.01 {
                    break
                }
                if position > Float(frame) {
                    u -= step
                } else {
                    u += step
                }
                step *= 0.5
            }
            return cubic(y, min(1, max(0, u)))
        }
        return last.value
    }

    private static func cubic(_ points: SIMD4<Float>, _ u: Float) -> Float {
        let v = 1 - u
        return v * v * v * points.x + 3 * v * v * u * points.y
            + 3 * v * u * u * points.z + u * u * u * points.w
    }
}
