#if !LITE_BUILD
import Foundation
import JavaScriptCore
import LiveWallpaperProWPE
import simd

struct WPEScriptCameraTransforms: Equatable, Sendable {
    var eye = SIMD3<Double>.zero
    var center = SIMD3<Double>(0, 0, -1)
    var up = SIMD3<Double>(0, 1, 0)
    var zoom = 1.0

    var motion: WPESceneCameraMotionSample {
        let forward = simd_normalize(center - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let normalizedUp = simd_cross(right, forward)
        let rotation = simd_double3x3(right, normalizedUp, -forward)
        let yaw = asin(max(-1, min(1, -rotation.columns.0.z)))
        let pitch: Double
        let roll: Double
        if abs(cos(yaw)) > 1e-8 {
            pitch = atan2(rotation.columns.1.z, rotation.columns.2.z)
            roll = atan2(rotation.columns.0.y, rotation.columns.0.x)
        } else {
            pitch = atan2(-rotation.columns.2.y, rotation.columns.1.y)
            roll = 0
        }
        return .init(origin: eye, zoom: zoom, angles: SIMD3(pitch, yaw, roll))
    }

    var isValid: Bool {
        let components = [eye.x, eye.y, eye.z, center.x, center.y, center.z, up.x, up.y, up.z, zoom]
        let direction = center - eye
        let cross = simd_cross(direction, up)
        return components.allSatisfy { $0.isFinite && Float($0).isFinite }
            && Float(zoom) > 0
            && Float((abs(eye.x) + abs(eye.y) + abs(eye.z)) * zoom).isFinite
            && simd_length_squared(direction).isFinite && simd_length_squared(direction) > 1e-12
            && simd_length_squared(cross).isFinite && simd_length_squared(cross) > 1e-12
    }
}

struct WPEStaticCameraScriptSnapshot: Equatable, Sendable {
    var transforms = WPEScriptCameraTransforms()
    var hasOverride = false
    var allowsMutation = true
}

/// One constant-size transaction per VM callback. No JS objects cross lanes.
final class WPESceneScriptCameraBridge {
    private weak var shared: WPESharedScriptState?
    private var pending: WPEScriptCameraTransforms?
    private var active = false
    private var failed = false

    init(shared: WPESharedScriptState?) {
        self.shared = shared
    }

    func beginEvaluation() {
        pending = nil; failed = false; active = true
    }

    func failEvaluation() {
        failed = true
    }

    func finishEvaluation(commit: Bool) {
        defer { pending = nil; active = false }
        guard active, commit, !failed, let pending else { return }
        shared?.publishStaticCamera(pending)
    }

    private var current: WPEScriptCameraTransforms {
        pending ?? shared?.staticCameraSnapshot().transforms ?? .init()
    }

    func install(on scene: JSValue, in context: JSContext) {
        context.evaluateScript("if (typeof CameraTransforms === 'undefined') { globalThis.CameraTransforms = function() { this.eye = new Vec3(0,0,0); this.center = new Vec3(0,0,-1); this.up = new Vec3(0,1,0); this.zoom = 1; }; }")
        let get: @convention(block) () -> JSValue? = { [weak self, weak context] in
            guard let self, let context,
                  let result = context.objectForKeyedSubscript("CameraTransforms")?.construct(withArguments: []),
                  let vector = context.objectForKeyedSubscript("Vec3") else { return nil }
            let value = current
            for (name, v) in [("eye", value.eye), ("center", value.center), ("up", value.up)] {
                result.setObject(vector.construct(withArguments: [v.x, v.y, v.z]), forKeyedSubscript: name as NSString)
            }
            result.setObject(value.zoom, forKeyedSubscript: "zoom" as NSString)
            return result
        }
        let set: @convention(block) (JSValue) -> Void = { [weak self, weak context] raw in
            guard let self, active, !failed else { return }
            guard shared?.staticCameraSnapshot().allowsMutation != false else {
                failEvaluation()
                if let context {
                    context.exception = JSValue(newErrorFromMessage: "CameraTransforms mutation is not admitted for perspective scenes", in: context)
                }
                return
            }
            func vector(_ key: String) -> SIMD3<Double>? {
                guard let value = raw.objectForKeyedSubscript(key), value.isObject else { return nil }
                var values = SIMD3<Double>.zero
                for (index, key) in ["x", "y", "z"].enumerated() {
                    guard let v = value.objectForKeyedSubscript(key), v.isNumber, v.toDouble().isFinite else { return nil }
                    values[index] = v.toDouble()
                }
                return values
            }
            guard raw.isObject, let eye = vector("eye"), let center = vector("center"), let up = vector("up"),
                  let zoom = raw.objectForKeyedSubscript("zoom"), zoom.isNumber else {
                failEvaluation()
                if let context {
                    context.exception = JSValue(newErrorFromMessage: "CameraTransforms requires finite eye, center, up and positive zoom", in: context)
                }
                return
            }
            let value = WPEScriptCameraTransforms(eye: eye, center: center, up: up, zoom: zoom.toDouble())
            guard value.isValid else {
                failEvaluation()
                if let context {
                    context.exception = JSValue(newErrorFromMessage: "CameraTransforms has an invalid projection basis", in: context)
                }
                return
            }
            pending = value
        }
        scene.setObject(get, forKeyedSubscript: "getCameraTransforms" as NSString)
        scene.setObject(set, forKeyedSubscript: "setCameraTransforms" as NSString)
    }
}
#endif
