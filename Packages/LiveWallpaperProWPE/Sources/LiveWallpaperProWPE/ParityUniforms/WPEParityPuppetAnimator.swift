import Foundation
import simd

/// Per-frame `g_Bones` of one puppet layer as WPE computes them (FUN_1401fdf90, R12).
public struct WPEParityPuppetAnimator: Sendable {
    public enum Mode: Sendable, Equatable {
        case loop, mirror, single

        /// [I] R12 did not find the string-to-flag mapping; the old evaluator's: "mirror", "single", else loop.
        init(_ string: String) {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "mirror": self = .mirror
            case "single": self = .single
            default: self = .loop
            }
        }
    }

    public struct Layer: Sendable {
        public let animation: WPEPuppetAnimation
        public let mode: Mode
        public let rate: Float
        public let blend: Float
        public let additive: Bool
        public let blendOut: Bool
        public let blendTime: Float
        public let frameDuration: Float
        /// [I] frameCount × frameDuration.
        public let duration: Float
        /// Cleared once a non-single ramp completes (FUN_14026c8b0).
        public private(set) var blendIn: Bool
        public private(set) var time: Float = 0
        /// Mirror playback running backwards (flag bit 31).
        public private(set) var reversing = false
        /// Single playback reached the end (flag 0x40000000).
        public private(set) var finished = false
        public private(set) var weight: Float = 0

        /// FUN_1401a9f60; a rate ≤ 0 passes through unchanged: 0 holds, negative runs backwards.
        mutating func step(_ delta: Float) {
            guard !finished, !(mode == .single && duration <= time), duration > 0 else { return }
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
    private let parents: [Int?]
    private let restLocal: [simd_float4x4]
    private let inverseBindWorld: [simd_float4x4]

    /// Invisible layers and layers naming an animation the model lacks are dropped (FUN_1401fdf90 skips +0xD0 bit0 = 0).
    public init(model: WPEPuppetModel, layers sceneLayers: [WPESceneAnimationLayer]) {
        layers = sceneLayers.compactMap { scene in
            guard scene.visible, let animation = model.animations.first(where: { $0.id == scene.animation }) else {
                return nil
            }
            let frameDuration = 1 / animation.fps
            var layer = Layer(animation: animation, mode: Mode(animation.mode), rate: Float(scene.rate),
                              blend: Float(scene.blend), additive: scene.additive, blendOut: scene.blendOut,
                              blendTime: Float(scene.blendTime), frameDuration: frameDuration,
                              duration: Float(animation.frameCount) * frameDuration, blendIn: scene.blendIn)
            layer.updateWeight()
            return layer
        }
        // The MDLS parser keeps a parent only when it precedes the bone, so one forward pass composes worlds.
        parents = model.bones.enumerated().map { index, bone in bone.parentIndex.flatMap { $0 < index ? $0 : nil } }
        restLocal = model.bones.map { WPEMdlParser.matrix(fromColumnMajorFloats: $0.rawMatrix) ?? matrix_identity_float4x4 }
        inverseBindWorld = Self.world(locals: restLocal, parents: parents).map(\.inverse)
        evaluate()
    }

    public mutating func advance(dt: Double) {
        for index in layers.indices {
            layers[index].step(Float(dt) * layers[index].rate)
            layers[index].updateWeight()
        }
        evaluate()
    }

    /// 3 float4 per bone for `float4x3 g_Bones[BONECOUNT]`: math rows 0, 1, 2 with translation in .w.
    public var bones: [SIMD4<Float>] {
        Self.packedRows(palette)
    }

    public var values: [String: WPECBufferValue] {
        let rows = bones
        return ["g_Bones": .array(stride(from: 0, to: rows.count, by: 3).map {
            .matrix(WPEFloatMatrix(columns: Array(rows[$0 ..< $0 + 3])))
        })]
    }

    static func packedRows(_ palette: [simd_float4x4]) -> [SIMD4<Float>] {
        palette.flatMap { matrix in
            let rows = matrix.transpose
            return [rows.columns.0, rows.columns.1, rows.columns.2]
        }
    }

    /// FUN_140170580: A = clamp(Int(time / frameDuration), 0, N − 1), B = min(A + 1, N).
    static func frame(time: Float, frameDuration: Float, frameCount: Int) -> (a: Int, b: Int, t: Float) {
        let a = min(max(Int(time / frameDuration), 0), max(frameCount - 1, 0))
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
        var poses = [Pose?](repeating: nil, count: restLocal.count)
        for layer in layers {
            let frame = Self.frame(time: layer.time, frameDuration: layer.frameDuration,
                                   frameCount: layer.animation.frameCount)
            for channel in layer.animation.channels where poses.indices.contains(channel.boneIndex) {
                let bone = channel.boneIndex
                let sample = Self.interpolate(channel.keyframes[frame.a], channel.keyframes[frame.b], t: frame.t)
                if layer.additive {
                    let reference = layer.mode == .single ? Self.pose(of: restLocal[bone])
                        : Self.pose(of: channel.keyframes[0])
                    poses[bone] = Self.add(sample, reference: reference,
                                           onto: poses[bone] ?? Self.pose(of: restLocal[bone]), weight: layer.weight)
                } else if layer.weight == 1 {
                    // FUN_1401f89a0 overwrites instead of blending when the weight is exactly 1.
                    poses[bone] = sample
                } else {
                    poses[bone] = Self.blend(sample, over: poses[bone] ?? Self.pose(of: restLocal[bone]),
                                             weight: layer.weight)
                }
            }
        }
        let locals = poses.enumerated().map { $1?.matrix ?? restLocal[$0] }
        palette = zip(Self.world(locals: locals, parents: parents), inverseBindWorld).map { $0 * $1 }
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

    /// [I] R12 did not decode WPE's additive branch; this is `WPEPuppetAnimationEvaluator`'s additive delta.
    private static func add(_ sample: Pose, reference: Pose, onto base: Pose, weight: Float) -> Pose {
        let delta = simd_slerp(simd_quatf(real: 1, imag: .zero), sample.rotation * reference.rotation.inverse, weight)
        var scale = base.scale
        for axis in 0 ..< 3 {
            // A collapsed-at-rest track carries absolute scale; division would lose it.
            scale[axis] = abs(reference.scale[axis]) <= 1e-6
                ? base.scale[axis] + (sample.scale[axis] - base.scale[axis]) * weight
                : base.scale[axis] * (1 + (sample.scale[axis] / reference.scale[axis] - 1) * weight)
        }
        return Pose(translation: base.translation + (sample.translation - reference.translation) * weight,
                    rotation: base.rotation * delta, scale: scale)
    }

    /// [I] Euler order Z·Y·X as the old evaluator; R12 did not find where WPE converts the 9-float key.
    private static func rotation(euler: SIMD3<Float>) -> simd_quatf {
        simd_normalize(simd_quatf(angle: euler.z, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: euler.y, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: euler.x, axis: SIMD3(1, 0, 0)))
    }

    private static func pose(of key: WPEPuppetAnimKey) -> Pose {
        Pose(translation: key.translation, rotation: rotation(euler: key.euler), scale: key.scale)
    }

    /// [I] Rest pose a first layer with weight < 1 blends against: the MDLS local split into T, R, S.
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
