import Foundation

/// What a camera path sets for the frame: eye, center, up and the camera zoom (scene+0xf0..0x114).
public struct WPEParityCameraPose: Sendable, Equatable {
    public var eye: SIMD3<Float>
    public var center: SIMD3<Float>
    public var up: SIMD3<Float>
    public var zoom: Float

    public init(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>, zoom: Float) {
        self.eye = eye
        self.center = center
        self.up = up
        self.zoom = zoom
    }
}

/// One camera path of a `camera.paths` file (FUN_140198e20).
public struct WPEParityCameraPath: Sendable, Equatable {
    public struct Keyframe: Sendable, Equatable {
        public var timestamp: Float
        public var pose: WPEParityCameraPose

        public init(timestamp: Float, pose: WPEParityCameraPose) {
            self.timestamp = timestamp
            self.pose = pose
        }
    }

    public var keyframes: [Keyframe]
    public var duration: Float

    public init(keyframes: [Keyframe], duration: Float) {
        self.keyframes = keyframes
        self.duration = duration
    }
}

/// The scene's camera paths and the playback position WPE keeps in scene+0xe4/0xe8/0xec.
public struct WPEParityCameraPaths: Sendable, Equatable {
    public let paths: [WPEParityCameraPath]
    public private(set) var pathIndex = 0
    public private(set) var keyframeIndex = 0
    /// Seconds since the current path started; a keyframe step keeps it, a path change clears it.
    public private(set) var time: Float = 0

    public init(paths: [WPEParityCameraPath] = []) {
        self.paths = paths
    }

    /// 140186c90.c:984-1021: every `camera.paths` entry clears the list, and a string entry then loads its file, so
    /// only a string in last place leaves paths.
    public init(camera: WPESceneJSONValue?, assets: WPEParityProgramAssets) {
        var paths: [WPEParityCameraPath] = []
        for entry in WPEParityProgramScene.array(camera?["paths"]) {
            paths = WPEParityProgramScene.string(entry).flatMap(assets.json).map(Self.parse) ?? []
        }
        self.init(paths: paths)
    }

    /// FUN_140198e20: a path entry that is not an object, or has no `transforms`, ends the list; a disabled path or
    /// transform is skipped, but a transform's default timestamp still counts the skipped ones.
    static func parse(_ file: WPESceneJSONValue) -> [WPEParityCameraPath] {
        var paths: [WPEParityCameraPath] = []
        for path in WPEParityProgramScene.array(file["paths"]) {
            guard case .object = path, case let .array(transforms)? = path["transforms"], !transforms.isEmpty else {
                break
            }
            if path["disabled"] == .bool(true) {
                continue
            }
            let duration = Float(number(path["duration"]) ?? 0)
            var keyframes: [WPEParityCameraPath.Keyframe] = []
            for (index, transform) in transforms.enumerated() {
                guard case .object = transform, transform["disabled"] != .bool(true) else { continue }
                let timestamp: Float = if let authored = number(transform["timestamp"]) {
                    Float(authored)
                } else if index != 0 {
                    Float(index) / Float(transforms.count - 1) * duration
                } else {
                    0
                }
                let zoom = transform["zoom"].map { Float(number($0) ?? 0) } ?? 1
                keyframes.append(.init(timestamp: timestamp, pose: WPEParityCameraPose(
                    eye: vector(transform["eye"]), center: vector(transform["center"]), up: vector(transform["up"]),
                    zoom: zoom
                )))
            }
            paths.append(WPEParityCameraPath(keyframes: keyframes, duration: duration))
        }
        return paths
    }

    /// The pose at the current time, then the step by `dt` (1401891a0.c:145-277). Nil leaves the scene camera: there
    /// are no paths, or the first has no keyframes (1401891a0.c:73).
    public mutating func advance(dt: Float) -> WPEParityCameraPose? {
        guard let first = paths.first, !first.keyframes.isEmpty else { return nil }
        let path = paths[pathIndex]
        guard !path.keyframes.isEmpty else {
            nextPath()
            return nil
        }
        let keys = path.keyframes
        let current = keys[keyframeIndex]
        let hasNext = keyframeIndex + 1 < keys.count
        let end: Float
        let pose: WPEParityCameraPose
        if time < current.timestamp {
            end = (hasNext ? keys[keyframeIndex + 1].timestamp : 0) + current.timestamp
            pose = current.pose
        } else if !hasNext {
            end = path.duration - current.timestamp
            pose = current.pose
        } else {
            let next = keys[keyframeIndex + 1]
            end = next.timestamp
            pose = Self.interpolate(current.pose, next.pose,
                                    (time - current.timestamp) / (next.timestamp - current.timestamp))
        }
        time += dt
        if end < time {
            let step = keyframeIndex + 1
            if step >= keys.count || path.duration <= keys[step].timestamp {
                nextPath()
            } else {
                keyframeIndex = step
            }
        }
        return pose
    }

    /// The fade's g_Alpha after this frame's step (14017fa70.c:743-764): it falls from 1 over the path's first half
    /// second and rises to 1 over its last; the fade draws only when it is above 0.
    public var fadeAlpha: Float {
        guard pathIndex < paths.count else { return 0 }
        let duration = paths[pathIndex].duration
        let remaining = duration - time
        if remaining < 0.5 {
            return 1 - (remaining + remaining)
        }
        guard remaining > duration - 0.5 else { return 0 }
        let elapsed = duration - remaining
        return 1 - (elapsed + elapsed)
    }

    private mutating func nextPath() {
        pathIndex = pathIndex + 1 >= paths.count ? 0 : pathIndex + 1
        keyframeIndex = 0
        time = 0
    }

    /// Cubic Hermite with both tangents (b − a)/2, written in WPE's operation order (1401891a0.c:173-250).
    static func interpolate(_ a: WPEParityCameraPose, _ b: WPEParityCameraPose, _ s: Float) -> WPEParityCameraPose {
        let s2 = s * s
        let s3 = s2 * s
        let h11 = s3 - s2
        let h01 = s2 * 3 - (s3 + s3)
        let h00 = ((s3 + s3) - s2 * 3) + 1
        let h10 = (s3 - (s2 + s2)) + s
        func hermite(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>) -> SIMD3<Float> {
            let tangent = (p1 - p0) * 0.5
            let first = (p0 - p0) * 0.5 + tangent
            let second = (p1 - p1) * 0.5 + tangent
            return ((first * h10 + h00 * p0) + second * h11) + h01 * p1
        }
        let zoom = hermite(SIMD3(repeating: a.zoom), SIMD3(repeating: b.zoom)).x
        return WPEParityCameraPose(eye: hermite(a.eye, b.eye), center: hermite(a.center, b.center),
                                   up: hermite(a.up, b.up), zoom: zoom)
    }

    /// A JSON number; WPE reads `timestamp` only when it is one.
    private static func number(_ value: WPESceneJSONValue?) -> Double? {
        if case let .number(number)? = value {
            number
        } else {
            nil
        }
    }

    /// "x y z" read with atof from each run of spaces; a missing component is 0 (FUN_140198e20).
    static func vector(_ value: WPESceneJSONValue?) -> SIMD3<Float> {
        guard case let .string(text)? = value else { return .zero }
        return WPEParityNumericConversion.asciiSpaceVector3(text)
    }
}
