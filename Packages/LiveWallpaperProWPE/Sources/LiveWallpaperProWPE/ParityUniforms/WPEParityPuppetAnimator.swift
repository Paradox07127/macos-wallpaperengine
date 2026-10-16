import Foundation
import simd

/// Per-frame `g_Bones` of one puppet layer as WPE computes them (FUN_1401fdf90).
public struct WPEParityPuppetAnimator: Sendable {
    public enum Mode: Sendable, Equatable {
        case loop, mirror, single

        /// FUN_1401a8c10: ASCII case-insensitive "mirror" sets flag bit0, "single" bit1, anything else loops.
        init(_ string: String) {
            switch string.lowercased() {
            case "mirror": self = .mirror
            case "single": self = .single
            default: self = .loop
            }
        }
    }

    public struct Layer: Sendable {
        public let id: Int
        /// Index in the authored scene layer table; retained even when another layer names a missing animation.
        public let sceneIndex: Int
        public let animation: WPEPuppetAnimation
        public let mode: Mode
        public fileprivate(set) var name: String
        public fileprivate(set) var enabled: Bool
        public fileprivate(set) var rate: Float
        public fileprivate(set) var blend: Float
        public fileprivate(set) var additive: Bool
        public fileprivate(set) var blendOut: Bool
        public fileprivate(set) var blendTime: Float
        public let frameDuration: Float
        /// frameCount × frameDuration.
        public let duration: Float
        /// Cleared once a non-single ramp completes (FUN_14026c8b0).
        public fileprivate(set) var blendIn: Bool
        public private(set) var time: Float = 0
        /// Mirror playback running backwards (flag bit 31).
        public private(set) var reversing = false
        /// Single playback reached the end (flag 0x40000000).
        public private(set) var finished = false
        /// Playback pause is independent of the descriptor's `visible` bit (FUN_14026c450).
        public private(set) var paused = false
        public private(set) var weight: Float = 0
        private var frameAssigned = false

        public var frame: Float {
            time / frameDuration
        }

        public var fps: Float {
            1 / frameDuration
        }

        /// FUN_14026c480 tests only the paused/finished flags, including when `visible` is false.
        public var isPlaying: Bool {
            !paused && !finished
        }

        fileprivate mutating func control(_ action: Control) {
            switch action {
            case .play:
                if finished {
                    time = 0
                }
                finished = false
                paused = false
            case .pause:
                paused = true
            case .stop:
                time = 0
                paused = true
                finished = false
                reversing = false
            case let .setFrame(frame):
                time = frameDuration * frame
                frameAssigned = true
            }
        }

        /// The object update qualifies the ended notification using the flags from before the step. Seeking
        /// suppresses that notification once, even when the sought frame wraps or reaches a single's end.
        fileprivate mutating func advance(_ delta: Float) -> Bool {
            let canEnd = !paused && !finished && !frameAssigned
            let previousTime = time, previousReversing = reversing
            step(delta)
            frameAssigned = false
            updateWeight()
            guard canEnd else { return false }
            switch mode {
            case .loop: return time < previousTime
            case .mirror: return reversing != previousReversing
            case .single: return finished
            }
        }

        /// FUN_1401a9f60; a rate ≤ 0 passes through unchanged: 0 holds, negative runs backwards.
        mutating func step(_ delta: Float) {
            guard !paused, !finished, !(mode == .single && duration <= time), duration > 0 else { return }
            time += reversing ? -delta : delta
            switch mode {
            case .single:
                if time >= duration {
                    finished = true
                    time = duration
                }
            case .loop:
                if time < 0 {
                    time = (time + duration).truncatingRemainder(dividingBy: duration)
                }
                if time >= duration {
                    time = time.truncatingRemainder(dividingBy: duration)
                }
            case .mirror:
                if !reversing, time >= duration {
                    reversing = true
                    time = duration - time.truncatingRemainder(dividingBy: duration)
                } else if reversing, time <= 0 {
                    reversing = false
                    time = -time.truncatingRemainder(dividingBy: duration)
                }
            }
        }

        /// FUN_14026c8b0: blend × blend-in ramp × blend-out ramp.
        mutating func updateWeight() {
            let ramp = min(duration * 0.5, blendTime)
            let enabled = min(duration, blendTime) > 0
            weight = blend
            if blendIn {
                let rampIn = enabled ? min(time / ramp, 1) : 1
                weight *= rampIn
                if mode != .single, rampIn >= 1 {
                    blendIn = false
                }
            }
            if blendOut, enabled {
                weight *= min((duration - time) / ramp, 1)
            }
        }
    }

    /// The native IAnimationLayer methods mutate playback state; the next object update evaluates its pose.
    public enum Control: Sendable, Equatable {
        case play, pause, stop
        case setFrame(Float)
    }

    struct Pose {
        var translation: SIMD3<Float>
        var rotation: simd_quatf
        var scale: SIMD3<Float>

        var matrix: simd_float4x4 {
            var matrix = simd_float4x4(rotation)
            matrix.columns.0 *= scale.x
            matrix.columns.1 *= scale.y
            matrix.columns.2 *= scale.z
            matrix.columns.3 = SIMD4(translation, 1)
            return matrix
        }
    }

    public private(set) var layers: [Layer]
    /// currentWorld · inverse(bindWorld) per MDLS bone.
    public private(set) var palette: [simd_float4x4] = []
    /// This frame's world matrix per MDLS bone (puppet+0x2c8), the parent matrix attachments compose with.
    public private(set) var boneWorld: [simd_float4x4] = []
    /// MDLA +f0 curves, reset to one each update and consumed by the native SKINNING_ALPHA vertex path.
    public private(set) var bonesAlpha: [Float] = []
    /// Authored layer identities whose native ended condition fired in the last object update, in layer order.
    public private(set) var endedLayers: [Int] = []
    private let parents: [Int?]
    private let restLocal: [simd_float4x4]
    /// puppet+0x230: each rest local split into T, R, S; the first layer's base and every additive reference.
    private let restPose: [Pose]
    private let inverseBindWorld: [simd_float4x4]
    private var poses: [Pose?] = []

    /// Disabled layers remain addressable; FUN_1401fdf90 skips their update/evaluation, not their identity.
    /// A layer naming an animation absent from the model still has no evaluable animation.
    public init(model: WPEPuppetModel, layers sceneLayers: [WPESceneAnimationLayer]) {
        layers = sceneLayers.enumerated().compactMap { index, scene in
            guard let animation = model.animations.first(where: { $0.id == scene.animation }) else {
                return nil
            }
            let frameDuration = 1 / animation.fps
            let mode = Mode(animation.mode)
            var layer = Layer(id: scene.id, sceneIndex: index, animation: animation, mode: mode, name: scene.name,
                              enabled: scene.visible, rate: Float(scene.rate),
                              blend: Float(scene.blend), additive: scene.additive, blendOut: mode == .single && scene.blendOut,
                              blendTime: Float(scene.blendTime), frameDuration: frameDuration,
                              duration: Float(animation.frameCount) * frameDuration, blendIn: scene.blendIn)
            layer.updateWeight()
            return layer
        }
        // The MDLS parser keeps a parent only when it precedes the bone, so one forward pass composes worlds.
        parents = model.bones.enumerated().map { index, bone in bone.parentIndex.flatMap { $0 < index ? $0 : nil } }
        restLocal = model.bones.map { WPEMdlParser.matrix(fromColumnMajorFloats: $0.rawMatrix) ?? matrix_identity_float4x4 }
        restPose = restLocal.map { Self.pose(of: $0) }
        let bindWorld = Self.world(locals: restLocal, parents: parents)
        inverseBindWorld = bindWorld.map(\.inverse)
        boneWorld = bindWorld
        palette = bindWorld
        if model.meshes.first.map({ $0.flags & 4 != 0 }) == true {
            bonesAlpha = [Float](repeating: 1, count: restLocal.count)
        }
        poses = [Pose?](repeating: nil, count: restLocal.count)
        evaluate()
    }

    public mutating func advance(dt: Double) {
        endedLayers.removeAll(keepingCapacity: true)
        for index in layers.indices where layers[index].enabled {
            if layers[index].advance(Float(dt) * layers[index].rate) {
                endedLayers.append(layers[index].sceneIndex)
            }
        }
        evaluate()
    }

    /// The host animation API updates the retained authored layer, then consumers observe the new palette at the
    /// normal evaluation boundary. Disabled layers keep their playback cursor instead of being re-created.
    @discardableResult
    public mutating func updateLayer(at sceneIndex: Int, enabled: Bool? = nil,
                                     rate: Float? = nil, blend: Float? = nil, name: String? = nil,
                                     additive: Bool? = nil, blendIn: Bool? = nil, blendOut: Bool? = nil,
                                     blendTime: Float? = nil) -> Bool {
        guard let index = layers.firstIndex(where: { $0.sceneIndex == sceneIndex }) else { return false }
        if let enabled {
            layers[index].enabled = enabled
        }
        if let rate {
            layers[index].rate = rate
        }
        if let blend {
            layers[index].blend = blend
        }
        if let name {
            layers[index].name = name
        }
        if let additive {
            layers[index].additive = additive
        }
        if let blendIn {
            layers[index].blendIn = blendIn
        }
        if let blendOut {
            layers[index].blendOut = blendOut
        }
        if let blendTime {
            layers[index].blendTime = blendTime
        }
        return true
    }

    @discardableResult
    public mutating func controlLayer(at sceneIndex: Int, action: Control) -> Bool {
        guard let index = layers.firstIndex(where: { $0.sceneIndex == sceneIndex }) else { return false }
        layers[index].control(action)
        return true
    }

    /// 3 float4 per bone for `float4x3 g_Bones[BONECOUNT]`: math rows 0, 1, 2 with translation in .w.
    public var bones: [SIMD4<Float>] {
        Self.packedRows(palette)
    }

    public var values: [String: WPECBufferValue] {
        let rows = bones
        var result: [String: WPECBufferValue] = ["g_Bones": .array(stride(from: 0, to: rows.count, by: 3).map {
            .matrix(WPEFloatMatrix(columns: Array(rows[$0 ..< $0 + 3])))
        })]
        if !bonesAlpha.isEmpty {
            // The stage rewriter packs native float[BONECOUNT] into float4[ceil(BONECOUNT / 4)].
            // Padding is outside the valid bone indices; the strict cbuffer packer keeps the reflected shape.
            result["g_BonesAlpha"] = .array(stride(from: 0, to: bonesAlpha.count, by: 4).map { start in
                .vector((0 ..< 4).map { lane in
                    start + lane < bonesAlpha.count ? bonesAlpha[start + lane] : 0
                })
            })
        }
        return result
    }

    static func packedRows(_ palette: [simd_float4x4]) -> [SIMD4<Float>] {
        palette.flatMap { matrix in
            let rows = matrix.transpose
            return [rows.columns.0, rows.columns.1, rows.columns.2]
        }
    }

    /// FUN_140170580 truncates the Float quotient to Int32 with CVTTSS2SI before clamping A. Its masked-invalid
    /// result is Int32.min, including NaN, infinity and finite overflow; the interpolation factor stays unchanged.
    static func frame(time: Float, frameDuration: Float, frameCount: Int) -> (a: Int, b: Int, t: Float) {
        let index = Int32(exactly: (time / frameDuration).rounded(.towardZero)) ?? Int32.min
        let a = min(max(Int(index), 0), max(frameCount - 1, 0))
        return (a, min(a + 1, frameCount), time.truncatingRemainder(dividingBy: frameDuration) / frameDuration)
    }

    private static func world(locals: [simd_float4x4], parents: [Int?]) -> [simd_float4x4] {
        var world: [simd_float4x4] = []
        world.reserveCapacity(locals.count)
        for (index, local) in locals.enumerated() {
            let composed = parents[index].map { world[$0] * local } ?? local
            world.append(composed)
        }
        return world
    }

    private mutating func evaluate() {
        // nil = untouched by every layer, drawn at its MDLS rest matrix.
        for bone in poses.indices {
            poses[bone] = nil
        }
        for bone in bonesAlpha.indices {
            bonesAlpha[bone] = 1
        }
        for layer in layers where layer.enabled {
            let frame = Self.frame(time: layer.time, frameDuration: layer.frameDuration,
                                   frameCount: layer.animation.frameCount)
            evaluateAlpha(layer, frame: frame)
            for channel in layer.animation.channels where poses.indices.contains(channel.boneIndex) {
                let bone = channel.boneIndex
                let sample = Self.interpolate(channel.keyframes[frame.a], channel.keyframes[frame.b], t: frame.t)
                if layer.additive {
                    poses[bone] = Self.add(sample, reference: restPose[bone], onto: poses[bone] ?? restPose[bone],
                                           weight: layer.weight)
                } else if layer.weight == 1 {
                    // FUN_1401f89a0 overwrites instead of blending when the weight is exactly 1.
                    poses[bone] = sample
                } else {
                    poses[bone] = Self.blend(sample, over: poses[bone] ?? restPose[bone], weight: layer.weight)
                }
            }
        }
        for bone in poses.indices {
            let local = poses[bone]?.matrix ?? restLocal[bone]
            boneWorld[bone] = parents[bone].map { boneWorld[$0] * local } ?? local
            palette[bone] = boneWorld[bone] * inverseBindWorld[bone]
        }
    }

    private mutating func evaluateAlpha(_ layer: Layer, frame: (a: Int, b: Int, t: Float)) {
        guard !bonesAlpha.isEmpty, let block = layer.animation.tail?.blendCurves, block.hasCurves else { return }
        for (bone, curve) in block.curves.enumerated() where bonesAlpha.indices.contains(bone) {
            guard layer.animation.channels.indices.contains(bone), layer.animation.channels[bone].flags & 3 != 1,
                  curve.values.indices.contains(frame.a), curve.values.indices.contains(frame.b) else { continue }
            let sample = curve.values[frame.a] * (1 - frame.t) + curve.values[frame.b] * frame.t
            let previous = bonesAlpha[bone]
            if layer.additive {
                // 1401ffcb1..fff35: add the delta from one, bounded by the previous value and sampled value.
                bonesAlpha[bone] = min(max(previous + (sample - 1) * layer.weight, min(previous, sample)),
                                       max(previous, sample))
            } else if layer.weight == 1 {
                bonesAlpha[bone] = sample
            } else {
                bonesAlpha[bone] = previous * (1 - layer.weight) + sample * layer.weight
            }
        }
    }

    /// Lerp T and S, nlerp the rotation on the shorter arc (FUN_1401f9020 SoA inner loop).
    private static func interpolate(_ a: WPEPuppetAnimKey, _ b: WPEPuppetAnimKey, t: Float) -> Pose {
        let qa = rotation(euler: a.euler), qb = rotation(euler: b.euler)
        let tb = simd_dot(qa, qb) < 0 ? -t : t
        return Pose(translation: a.translation * (1 - t) + b.translation * t,
                    rotation: simd_normalize(qa * (1 - t) + qb * tb),
                    scale: a.scale * (1 - t) + b.scale * t)
    }

    /// FUN_1401f9020: sample · w + previous · (1 − w), rotation renormalized.
    private static func blend(_ sample: Pose, over previous: Pose, weight: Float) -> Pose {
        let signedWeight = simd_dot(sample.rotation, previous.rotation) < 0 ? -weight : weight
        return Pose(translation: sample.translation * weight + previous.translation * (1 - weight),
                    rotation: simd_normalize(sample.rotation * signedWeight + previous.rotation * (1 - weight)),
                    scale: sample.scale * weight + previous.scale * (1 - weight))
    }

    /// FUN_1401f9820: T and S add (sample − rest) · w; the rotation delta conj(rest) · sample is nlerped from
    /// identity by w (sign of the delta's w) and post-multiplied without renormalizing.
    private static func add(_ sample: Pose, reference: Pose, onto base: Pose, weight: Float) -> Pose {
        let delta = reference.rotation.conjugate * sample.rotation
        let signedWeight = delta.real.sign == .minus ? -weight : weight
        let ramp = simd_normalize(simd_quatf(real: delta.real * signedWeight + (1 - weight),
                                             imag: delta.imag * signedWeight))
        return Pose(translation: base.translation + (sample.translation - reference.translation) * weight,
                    rotation: base.rotation * ramp,
                    scale: base.scale + (sample.scale - reference.scale) * weight)
    }

    /// Z·Y·X: the load-time key conversion stores (cx cy cz + sx sy sz, sx cy cz − cx sy sz, …) (140261880.c:2212-2234).
    private static func rotation(euler: SIMD3<Float>) -> simd_quatf {
        simd_normalize(simd_quatf(angle: euler.z, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: euler.y, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: euler.x, axis: SIMD3(1, 0, 0)))
    }

    private static func pose(of key: WPEPuppetAnimKey) -> Pose {
        Pose(translation: key.translation, rotation: rotation(euler: key.euler), scale: key.scale)
    }

    /// The MDLS local split into T, R, S (1401fdf90.c:587-676); the negative-determinant flip.
    private static func pose(of matrix: simd_float4x4) -> Pose {
        let axes = [matrix.columns.0, matrix.columns.1, matrix.columns.2].map { SIMD3($0.x, $0.y, $0.z) }
        var scale = SIMD3(simd_length(axes[0]), simd_length(axes[1]), simd_length(axes[2]))
        if simd_determinant(matrix) < 0 {
            scale.x = -scale.x
        }
        let basis = (0 ..< 3).map { scale[$0] == 0 ? axes[$0] : axes[$0] / scale[$0] }
        return Pose(translation: SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z),
                    rotation: simd_quatf(simd_float3x3(basis)), scale: scale)
    }
}
