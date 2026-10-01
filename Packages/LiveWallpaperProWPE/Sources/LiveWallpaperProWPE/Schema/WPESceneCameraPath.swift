import Foundation

public struct WPESceneCameraPathTransform: Equatable, Sendable {
    public let timestamp: Double
    public let eye: SIMD3<Double>
    public let center: SIMD3<Double>
    public let up: SIMD3<Double>
    public let zoom: Double
}

/// Root camera.paths assets. Object path/queuemode are a separate, unverified binding.
public struct WPESceneCameraPath: Equatable, Sendable {
    public let name: String
    public let authoredDuration: Double
    public let transforms: [WPESceneCameraPathTransform]

    public var duration: Double {
        transforms.last?.timestamp ?? 0
    }

    /// The last transform holds until `authoredDuration - 1` when that exceeds the last timestamp.
    public var playbackDuration: Double {
        max(duration, authoredDuration - 1)
    }

    public func sample(at time: Double) -> WPESceneCameraPathTransform? {
        guard let first = transforms.first, let last = transforms.last else { return nil }
        guard time.isFinite, time > first.timestamp else { return first }
        guard time < last.timestamp else { return last }
        guard let upper = transforms.firstIndex(where: { $0.timestamp > time }), upper > 0 else { return last }
        // Catmull-Rom with each segment repeating its own endpoints as tangent keys (p0=p1, p3=p2).
        let p1 = transforms[upper - 1], p2 = transforms[upper]
        let t = (time - p1.timestamp) / (p2.timestamp - p1.timestamp)
        let weight = 0.5 * t + 1.5 * t * t - t * t * t
        func vector(_ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
            b + (c - b) * weight
        }
        return .init(timestamp: time, eye: vector(p1.eye, p2.eye), center: vector(p1.center, p2.center),
                     up: vector(p1.up, p2.up), zoom: p1.zoom + (p2.zoom - p1.zoom) * weight)
    }

    public static func parse(data: Data) throws -> [Self] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = root["paths"] as? [[String: Any]] else { throw ParseError.invalidAsset }
        return try paths.map { path in
            guard let rows = path["transforms"] as? [[String: Any]], !rows.isEmpty else { throw ParseError.invalidAsset }
            var previous = -Double.infinity
            let transforms = try rows.map { row -> WPESceneCameraPathTransform in
                guard let t = WPEValueParser.double(row["timestamp"]), t.isFinite, t >= 0, t > previous,
                      let eye = WPEValueParser.vector3(row["eye"]), let center = WPEValueParser.vector3(row["center"]),
                      let up = WPEValueParser.vector3(row["up"]),
                      [eye.x, eye.y, eye.z, center.x, center.y, center.z, up.x, up.y, up.z].allSatisfy(\.isFinite),
                      let zoom = WPEValueParser.double(row["zoom"]), zoom.isFinite, zoom > 0 else { throw ParseError.invalidAsset }
                previous = t
                return .init(timestamp: t, eye: eye, center: center, up: up, zoom: zoom)
            }
            let duration = WPEValueParser.double(path["duration"]) ?? 0
            guard duration.isFinite, duration >= 0 else { throw ParseError.invalidAsset }
            return .init(name: path["name"] as? String ?? "", authoredDuration: duration, transforms: transforms)
        }
    }

    public enum ParseError: Error { case invalidAsset }
}
