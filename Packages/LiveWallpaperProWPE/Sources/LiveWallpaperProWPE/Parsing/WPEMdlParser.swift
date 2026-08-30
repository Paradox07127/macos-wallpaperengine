import Foundation
import LiveWallpaperCore
import simd

public struct WPEPuppetModel: Equatable, Sendable {
    public let version: Int
    public let meshes: [WPEPuppetMesh]
    public let bones: [WPEPuppetBone]
    public let animations: [WPEPuppetAnimation]
    /// MDAT anchors mapping a named scene attachment to a bone and bind transform.
    public let attachments: [WPEPuppetAttachment]
    /// Complete authored MDL bytes. Parser-created models retain this as a lossless compatibility
    /// boundary for sections whose public semantics are known but whose binary layout/runtime
    /// behavior is not yet oracle-proven (for example morph shapes and texture channels).
    /// This is metadata only; retaining bytes does not imply that those sections are consumed.
    public let authoredData: Data?

    public init(
        version: Int,
        meshes: [WPEPuppetMesh],
        bones: [WPEPuppetBone] = [],
        animations: [WPEPuppetAnimation] = [],
        attachments: [WPEPuppetAttachment] = [],
        authoredData: Data? = nil
    ) {
        self.version = version
        self.meshes = meshes
        self.bones = bones
        self.animations = animations
        self.attachments = attachments
        self.authoredData = authoredData
    }

    /// Clip-mask texture name if any mesh declares an MDLV clip section (genericimage4 clipping).
    public var clipMaskName: String? {
        meshes.lazy.compactMap(\.clipMaskName).first
    }
}

public struct WPEMdlParseAudit: Equatable, Sendable {
    public enum SectionKind: Equatable, Sendable {
        case mdlvHeader
        case mdlvMesh
        case mdls
        case mdat
        case mdla
        case mdle
    }

    public struct KnownSkip: Equatable, Sendable {
        public let label: String
        public let range: Range<Int>
    }

    public struct SectionRecord: Equatable, Sendable {
        public let kind: SectionKind
        public let label: String
        public let range: Range<Int>
        public let intentionallySkippedRanges: [KnownSkip]
    }

    public struct Gap: Equatable, Sendable {
        public let range: Range<Int>
    }

    public let sections: [SectionRecord]
    public let unexplainedGaps: [Gap]
    public let trailingLeftover: Range<Int>?
}

public enum WPEPuppetIndexElementWidth: Int, Equatable, Hashable, Sendable {
    case uint16 = 2
    case uint32 = 4
}

public struct WPEPuppetMeshBounds: Equatable, Sendable {
    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>

    public init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct WPEPuppetMesh: Equatable, Sendable {
    public let materialPath: String
    public let vertices: [WPEPuppetVertex]
    /// CPU-side indices are normalized to UInt32. `indexElementWidth` preserves the authored MDL
    /// representation so the Metal upload and draw call use the matching index type.
    public let indices: [UInt32]
    public let indexElementWidth: WPEPuppetIndexElementWidth
    public let parts: [WPEPuppetMeshPart]
    /// Authored MDLV17+ object-local AABB. Preserved for later culling/bounds parity; not consumed
    /// by the renderer yet.
    public let bounds: WPEPuppetMeshBounds?
    /// Clip-mask texture name from the MDLV clip section that follows the part table
    /// (e.g. `masks/clipping_mask_39cb32c5`), used by the genericimage4 clip-composite path.
    public let clipMaskName: String?
    /// Authored MDLV22+ clip groups. The stored integers are mesh part-table indices, not the
    /// authored `WPEPuppetMeshPart.id` values (real files may repeat those IDs). WPE stores the
    /// target list before the source list, and the two are independent sets: every target is clipped
    /// by the union of every source (eye rigs author 1 target against 2 eye-whites).
    public let clipGroups: [WPEPuppetClipGroup]

    public init(
        materialPath: String,
        vertices: [WPEPuppetVertex],
        indices: [UInt32],
        indexElementWidth: WPEPuppetIndexElementWidth = .uint16,
        parts: [WPEPuppetMeshPart],
        bounds: WPEPuppetMeshBounds? = nil,
        clipMaskName: String? = nil,
        clipGroups: [WPEPuppetClipGroup] = []
    ) {
        self.materialPath = materialPath
        self.vertices = vertices
        self.indices = indices
        self.indexElementWidth = indexElementWidth
        self.parts = parts
        self.bounds = bounds
        self.clipMaskName = clipMaskName
        self.clipGroups = clipGroups
    }
}

public struct WPEPuppetClipGroup: Equatable, Sendable {
    public let maskName: String
    public let sourcePartIndices: [Int]
    public let targetPartIndices: [Int]

    public init(maskName: String, sourcePartIndices: [Int], targetPartIndices: [Int]) {
        self.maskName = maskName
        self.sourcePartIndices = sourcePartIndices
        self.targetPartIndices = targetPartIndices
    }
}

public struct WPEPuppetVertex: Hashable, Sendable {
    /// Object-local target geometry. Do not derive this from `uv`: puppet textures can be atlases.
    public let position: SIMD3<Float>
    public let uv: SIMD2<Float>
    public let skinBlendIndices: SIMD4<Int32>
    public let skinBlendWeights: SIMD4<Float>

    public init(
        position: SIMD3<Float>,
        uv: SIMD2<Float>,
        skinBlendIndices: SIMD4<Int32> = SIMD4<Int32>(0, 0, 0, 0),
        skinBlendWeights: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 0)
    ) {
        self.position = position
        self.uv = uv
        self.skinBlendIndices = skinBlendIndices
        self.skinBlendWeights = skinBlendWeights
    }
}

public struct WPEPuppetBone: Equatable, Sendable {
    public let index: Int
    public let parentIndex: Int?
    /// Raw MDLS metadata retained for future runtime animation. Parser must not bake it into MDLV vertices.
    public let rawMatrix: [Float]
    /// MDLS0002 per-bone world-bind payload. Retained as file-authored evidence;
    /// palette evaluation must not consume it until the composition rule is oracle-proven.
    public let worldBindMatrix: [Float]?
    /// Raw MDLS bone-name cstring.
    public let name: String
    /// MDLS simulation selector. Retained even when the native renderer does
    /// not yet execute the corresponding physics/IK simulation.
    public let simulationType: Int32
    /// Separate MDLS simulation/rig JSON cstring following the bind matrix.
    public let simulationJSON: String
    /// Generic typed projection of `simulationJSON`, retaining unknown nested fields and JSON
    /// scalar kinds without assigning unverified physics/IK semantics. Invalid/empty JSON remains
    /// available through `simulationJSON` and produces `nil` here.
    public let simulationJSONValue: WPESceneJSONValue?

    public init(
        index: Int,
        parentIndex: Int?,
        rawMatrix: [Float],
        worldBindMatrix: [Float]? = nil,
        name: String = "",
        simulationType: Int32 = 0,
        simulationJSON: String = ""
    ) {
        self.index = index
        self.parentIndex = parentIndex
        self.rawMatrix = rawMatrix
        self.worldBindMatrix = worldBindMatrix
        self.name = name
        self.simulationType = simulationType
        self.simulationJSON = simulationJSON
        self.simulationJSONValue = Self.parseSimulationJSON(simulationJSON)
    }

    private static func parseSimulationJSON(_ source: String) -> WPESceneJSONValue? {
        guard !source.isEmpty,
              let data = source.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return WPESceneJSONValue(jsonValue: value)
    }
}

public struct WPEPuppetAttachment: Equatable, Sendable {
    public let name: String
    public let boneIndex: Int
    /// MDAT0001 bind transform in the parent puppet's model space, stored as 16 little-endian
    /// f32 in column-major simd/Metal order.
    public let bindMatrix: [Float]

    public init(name: String, boneIndex: Int, bindMatrix: [Float]) {
        self.name = name
        self.boneIndex = boneIndex
        self.bindMatrix = bindMatrix
    }

    public var matrix: simd_float4x4 {
        WPEMdlParser.matrix(fromColumnMajorFloats: bindMatrix) ?? matrix_identity_float4x4
    }
}

public struct WPEPuppetMeshPart: Hashable, Sendable {
    public let id: UInt32
    public let start: Int
    public let count: Int

    public init(id: UInt32, start: Int, count: Int) {
        self.id = id
        self.start = start
        self.count = count
    }
}

/// Baked skeletal animation from the MDLA section. Channels are stored in MDLS bone
/// order; each keyframe is a per-frame TRS transform (no curve interpolation in the file).
public struct WPEPuppetAnimation: Equatable, Sendable {
    public let id: Int
    public let name: String
    /// Playback mode from the file; "loop" drives the wrap in `interpolationInfo`.
    public let mode: String
    public let fps: Float
    public let frameCount: Int
    public let channels: [WPEPuppetAnimChannel]
    /// Absolute byte range of this animation record in the source MDL.
    public let sourceRange: Range<Int>?
    /// Versioned MDLA bytes after the dense TRS channels. Preserved for parity work but deliberately
    /// not consumed by `WPEPuppetAnimationEvaluator` yet.
    public let tail: WPEPuppetAnimationTail?

    public init(
        id: Int,
        name: String,
        mode: String,
        fps: Float,
        frameCount: Int,
        channels: [WPEPuppetAnimChannel],
        sourceRange: Range<Int>? = nil,
        tail: WPEPuppetAnimationTail? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.fps = fps
        self.frameCount = frameCount
        self.channels = channels
        self.sourceRange = sourceRange
        self.tail = tail
    }
}

public struct WPEPuppetAnimationCurve: Equatable, Sendable {
    public let reserved: UInt32
    public let values: [Float]
    public let sourceRange: Range<Int>

    public init(reserved: UInt32, values: [Float], sourceRange: Range<Int>) {
        self.reserved = reserved
        self.values = values
        self.sourceRange = sourceRange
    }
}

public struct WPEPuppetAnimationCurveBlock: Equatable, Sendable {
    /// Absolute range including the one-byte `has_curves` discriminator.
    public let sourceRange: Range<Int>
    public let hasCurves: Bool
    public let curves: [WPEPuppetAnimationCurve]

    public init(sourceRange: Range<Int>, hasCurves: Bool, curves: [WPEPuppetAnimationCurve]) {
        self.sourceRange = sourceRange
        self.hasCurves = hasCurves
        self.curves = curves
    }
}

public struct WPEPuppetAnimationRawSegment: Equatable, Sendable {
    public let sourceRange: Range<Int>
    public let bytes: Data

    public init(sourceRange: Range<Int>, bytes: Data) {
        self.sourceRange = sourceRange
        self.bytes = bytes
    }
}

public struct WPEPuppetAnimationTail: Equatable, Sendable {
    public let mdlaVersion: Int
    public let sourceRange: Range<Int>
    public let blendCurves: WPEPuppetAnimationCurveBlock
    /// `nil` for MDLA0005; MDLA0006 preserves a block even when `hasCurves == false`.
    public let scalarCurves: WPEPuppetAnimationCurveBlock?
    /// Versioned tail fields not yet modeled by the Swift runtime, retained losslessly with their
    /// absolute source ranges instead of being collapsed into anonymous padding.
    public let unknownSegments: [WPEPuppetAnimationRawSegment]

    public init(
        mdlaVersion: Int,
        sourceRange: Range<Int>,
        blendCurves: WPEPuppetAnimationCurveBlock,
        scalarCurves: WPEPuppetAnimationCurveBlock?,
        unknownSegments: [WPEPuppetAnimationRawSegment]
    ) {
        self.mdlaVersion = mdlaVersion
        self.sourceRange = sourceRange
        self.blendCurves = blendCurves
        self.scalarCurves = scalarCurves
        self.unknownSegments = unknownSegments
    }
}

public struct WPEPuppetAnimChannel: Equatable, Sendable {
    /// Skin-bone/channel index from MDLA (channels appear in bone order; no explicit id in
    /// the file). Usually matches MDLS bone order, but `WPEPuppetModel.bones` may be empty or
    /// malformed while channels stay usable — channels double as the skin skeleton (channel
    /// index == skin-blend index), with keyframe 0 as the bind pose.
    public let boneIndex: Int
    public let keyframes: [WPEPuppetAnimKey]

    public init(boneIndex: Int, keyframes: [WPEPuppetAnimKey]) {
        self.boneIndex = boneIndex
        self.keyframes = keyframes
    }
}

public struct WPEPuppetAnimKey: Equatable, Sendable {
    public let frame: Int
    /// Baked PARENT-LOCAL transform. Frame 0 is the bind local transform for the matching
    /// MDLS bone; world space is recovered by composing the parent channels' transforms.
    public let translation: SIMD3<Float>
    public let euler: SIMD3<Float>
    public let scale: SIMD3<Float>

    public init(frame: Int, translation: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>) {
        self.frame = frame
        self.translation = translation
        self.euler = euler
        self.scale = scale
    }
}

/// One resolved puppet animation layer: an animation plus its playback `rate`, `blend` weight,
/// and whether it composes additively over the base layer (e.g. a blink/face layer over idle sway).
public struct WPEPuppetAnimationLayer: Equatable, Sendable {
    public let animation: WPEPuppetAnimation
    public let rate: Double
    public let additive: Bool
    public let blend: Float

    public init(animation: WPEPuppetAnimation, rate: Double, additive: Bool, blend: Float) {
        self.animation = animation
        self.rate = rate
        self.additive = additive
        self.blend = blend
    }
}

public struct WPEPuppetInterpolationInfo: Equatable, Sendable {
    public let frameA: Int
    public let frameB: Int
    public let t: Float

    public init(frameA: Int, frameB: Int, t: Float) {
        self.frameA = frameA
        self.frameB = frameB
        self.t = t
    }
}

/// Skinning `palette` plus the diagnostics the render gate uses to decide whether skinning is
/// safe to enable for this puppet.
public struct WPEPuppetPaletteEvaluation: Equatable, Sendable {
    public enum TransformSpace: String, Equatable, Sendable {
        case parentLocal
    }

    public let palette: [simd_float4x4]
    public let paletteCount: Int
    public let transformSpace: TransformSpace?
    public let parentChannelMapSucceeded: Bool

    static let empty = WPEPuppetPaletteEvaluation(
        palette: [],
        paletteCount: 0,
        transformSpace: nil,
        parentChannelMapSucceeded: false
    )
}

/// Evaluates puppet animation layers into a per-bone skinning palette indexed by skin-blend (bone)
/// index. MDLS raw matrices are the inverse-bind ground truth; MDLS raw + MDLA channels are always
/// parent-local and composed down the hierarchy. `palette[boneIndex] = worldCurrent · worldBind⁻¹`.
/// The first non-additive layer is the base pose; additive layers add their per-bone
/// delta-from-bind on top in TRS space (translation/euler added, scale multiplied), weighted by
/// `blend`. Frame 0 of every layer is the bind pose, so the palette is identity there (regression
/// guard against the P0 static draw).
public enum WPEPuppetAnimationEvaluator {
    public static func palette(
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        at time: Double
    ) -> [simd_float4x4] {
        evaluate(layers: layers, bones: bones, at: time).palette
    }

    public static func paletteEvaluation(
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        at time: Double
    ) -> WPEPuppetPaletteEvaluation {
        evaluate(layers: layers, bones: bones, at: time)
    }

    private static func evaluate(
        layers: [WPEPuppetAnimationLayer],
        bones: [WPEPuppetBone],
        at time: Double
    ) -> WPEPuppetPaletteEvaluation {
        guard let baseIndex = layers.indices.first(where: { !layers[$0].additive }) ?? layers.indices.first else {
            return .empty
        }
        let base = layers[baseIndex]
        let baseChannels = base.animation.channels
        guard !baseChannels.isEmpty else { return .empty }
        let requiredPaletteCount = paletteCount(for: baseChannels)

        let baseInterpolation = interpolationInfo(for: base.animation, at: time * base.rate)
        // Exclude the base layer by index (not by predicate): an all-additive stack must not
        // re-apply its own base layer's animation as an additive delta on top of itself.
        let additiveLayers: [(
            interpolation: WPEPuppetInterpolationInfo,
            channelForBone: [Int: Int],
            channels: [WPEPuppetAnimChannel],
            weight: Float
        )] =
            layers.indices.compactMap { index in
                let layer = layers[index]
                guard index != baseIndex, layer.additive, !layer.animation.channels.isEmpty else { return nil }
                var channelForBone: [Int: Int] = [:]
                for (position, channel) in layer.animation.channels.enumerated() {
                    channelForBone[channel.boneIndex] = position
                }
                return (
                    interpolationInfo(for: layer.animation, at: time * layer.rate),
                    channelForBone,
                    layer.animation.channels,
                    max(0, min(Float(layer.blend), 1))
                )
            }

        // Every layer at its bind frame → identity palette (exact, no FP drift through the inverse),
        // but ONLY when the bind frame IS the MDLS raw bind (pre-assembled MDLV0021/0023). A
        // character-sheet puppet (MDLV0019/0020) ships an exploded MDLS bind whose frame-0 pose is the
        // *assembled* character, so its frame-0 palette (`assembled · exploded⁻¹`) is NOT identity — it
        // is what unfolds the sheet. Short-circuiting to identity there leaves the sheet exploded, so
        // fall through to the general hierarchy path for that case.
        if baseInterpolation.frameA == 0, baseInterpolation.t == 0,
           additiveLayers.allSatisfy({ $0.interpolation.frameA == 0 && $0.interpolation.t == 0 }),
           baseFrameMatchesRawBind(channels: baseChannels, bones: bones) {
            return WPEPuppetPaletteEvaluation(
                palette: identityPalette(count: requiredPaletteCount),
                paletteCount: requiredPaletteCount,
                transformSpace: nil,
                parentChannelMapSucceeded: parentChannelMap(channels: baseChannels, bones: bones) != nil
            )
        }

        // Combined parent-LOCAL transform for a base channel: base pose plus each additive layer's
        // delta-from-its-own-bind in TRS space. `bind == true` yields the rest pose.
        func localMatrix(_ channelPosition: Int, bind: Bool) -> simd_float4x4 {
            let channel = baseChannels[channelPosition]
            guard let bindKey = channel.keyframes.first else { return matrix_identity_float4x4 }
            if bind {
                return matrix(translation: bindKey.translation, euler: bindKey.euler, scale: bindKey.scale)
            }

            let baseCurrent = sampledTRS(channel: channel, interpolation: baseInterpolation)
            let baseWeight = max(0, min(base.blend, 1))
            var translation = simd_mix(bindKey.translation, baseCurrent.translation, SIMD3<Float>(repeating: baseWeight))
            var scale = simd_mix(bindKey.scale, baseCurrent.scale, SIMD3<Float>(repeating: baseWeight))
            let bindRotation = rotationQuaternion(euler: bindKey.euler)
            let baseRotationDelta = baseCurrent.rotation * bindRotation.inverse
            var rotation = bindRotation * simd_slerp(
                simd_quatf(real: 1, imag: .zero),
                baseRotationDelta,
                baseWeight
            )

            for additive in additiveLayers {
                guard let position = additive.channelForBone[channel.boneIndex],
                      let additiveBind = additive.channels[position].keyframes.first else { continue }
                let additiveCurrent = sampledTRS(
                    channel: additive.channels[position],
                    interpolation: additive.interpolation
                )
                translation += (additiveCurrent.translation - additiveBind.translation) * additive.weight
                let additiveBindRotation = rotationQuaternion(euler: additiveBind.euler)
                let additiveRotationDelta = additiveCurrent.rotation * additiveBindRotation.inverse
                rotation *= simd_slerp(
                    simd_quatf(real: 1, imag: .zero),
                    additiveRotationDelta,
                    additive.weight
                )
                scale *= additiveScaleRatio(
                    current: additiveCurrent.scale,
                    bind: additiveBind.scale,
                    base: scale,
                    weight: additive.weight
                )
            }
            return matrix(translation: translation, rotation: rotation, scale: scale)
        }

        guard let parentChannel = parentChannelMap(channels: baseChannels, bones: bones) else {
            // No usable skeleton hierarchy. A genuinely bone-less model (flat single-root rig or a
            // unit test) is correctly skinned by the independent path — each channel is its own root.
            // But a puppet that DOES ship bones whose hierarchy we could not reconstruct must fail
            // closed rather than mis-compose a partial skeleton (the old "torso perturbed" scatter);
            // the render gate additionally refuses to skin when `parentChannelMapSucceeded` is false.
            let palette = bones.isEmpty
                ? independentPalette(channels: baseChannels, localMatrix: localMatrix)
                : []
            return WPEPuppetPaletteEvaluation(
                palette: palette,
                paletteCount: requiredPaletteCount,
                transformSpace: nil,
                parentChannelMapSucceeded: false
            )
        }
        // MDLS raw + MDLA channels are always parent-local (oracle-confirmed); the previous
        // translation-only world/local auto-detect was refuted and removed.
        let space: WPEPuppetPaletteEvaluation.TransformSpace = .parentLocal
        let palette = hierarchyPalette(
            channels: baseChannels,
            bones: bones,
            parentChannel: parentChannel,
            localMatrix: localMatrix
        )
        return WPEPuppetPaletteEvaluation(
            palette: palette,
            paletteCount: requiredPaletteCount,
            transformSpace: space,
            parentChannelMapSucceeded: true
        )
    }

    private static func additiveScaleRatio(
        current: SIMD3<Float>,
        bind: SIMD3<Float>,
        base: SIMD3<Float>,
        weight: Float
    ) -> SIMD3<Float> {
        func axis(_ current: Float, _ bind: Float, _ base: Float) -> Float {
            guard abs(bind) > 1e-6 else {
                // Zero authored bind scale = a collapsed-at-rest bone (e.g. 3226487183's eyelids,
                // which inflate 0→1 over the blink). A delta ratio is undefined there, so lerp the
                // running scale toward the layer's ABSOLUTE authored scale: weight 1 reproduces
                // `current` exactly; the old `return 1` froze the bone at the base scale and tore
                // the mixed-weight eye vertices against their normally-squishing neighbours.
                guard abs(base) > 1e-6 else { return 1 }
                return 1 + (current / base - 1) * weight
            }
            return 1 + (current / bind - 1) * weight
        }
        return SIMD3<Float>(
            axis(current.x, bind.x, base.x),
            axis(current.y, bind.y, base.y),
            axis(current.z, bind.z, base.z)
        )
    }

    public static func identityPalette(count: Int) -> [simd_float4x4] {
        Array(repeating: matrix_identity_float4x4, count: max(count, 1))
    }

    /// True when every base channel's frame-0 keyframe reproduces its bone's MDLS raw bind matrix —
    /// i.e. the file ships pre-assembled (MDLV0021/0023) so the frame-0 palette is exactly identity.
    /// False for a character-sheet puppet (MDLV0019/0020) whose frame-0 pose is the assembled character
    /// atop an exploded MDLS bind, where the frame-0 palette must instead unfold the sheet.
    /// A channel lacking a raw bone matrix or a frame-0 key counts as NOT matching: the identity
    /// fast path must be proven for every channel, never assumed on missing data.
    public static func baseFrameMatchesRawBind(channels: [WPEPuppetAnimChannel], bones: [WPEPuppetBone]) -> Bool {
        let rawByBone = rawMatricesByBone(bones)
        guard !rawByBone.isEmpty else { return true }
        for channel in channels {
            guard let raw = rawByBone[channel.boneIndex], let key = channel.keyframes.first else { return false }
            let frame0 = matrix(translation: key.translation, euler: key.euler, scale: key.scale)
            if !simd_almost_equal_elements(frame0, raw, 1e-3) { return false }
        }
        return true
    }

    /// Bone-index → assembled bind-WORLD matrix, for the attachment anchor pivot and the skinning
    /// bind basis. Composes each bone's parent-local bind down the hierarchy. For a PRE-ASSEMBLED
    /// puppet (MDLV0021/0023) the local bind is the raw MDLS matrix. For a CHARACTER-SHEET puppet
    /// (MDLV0019/0020) the raw MDLS bind is the EXPLODED source-sheet layout, so the assembled anchor
    /// comes from the base animation's frame-0 keyframe pose (the same frame-0 that unfolds the mesh).
    /// The two are identical for pre-assembled puppets, so this is a no-op there. A bone whose parent
    /// is missing or is part of a cycle composes to its own local (bounded best-effort on malformed
    /// data). Uses the FIRST animation's frame-0: a character sheet's animations all start from the
    /// same authored reference pose (corpus-verified equal to ~0.05 across a puppet's clips), so the
    /// scene-selected base animation would give the same anchor within authoring noise.
    public static func assembledBindWorldByBone(model: WPEPuppetModel) -> [Int: simd_float4x4] {
        let baseChannels = model.animations.first?.channels ?? []
        let useFrame0 = !baseChannels.isEmpty
            && !baseFrameMatchesRawBind(channels: baseChannels, bones: model.bones)
        var frame0ByBone: [Int: simd_float4x4] = [:]
        if useFrame0 {
            for channel in baseChannels {
                guard let key = channel.keyframes.first else { continue }
                frame0ByBone[channel.boneIndex] = matrix(
                    translation: key.translation, euler: key.euler, scale: key.scale
                )
            }
        }
        let localByIndex = Dictionary(
            model.bones.compactMap { bone -> (Int, simd_float4x4)? in
                if let frame0 = frame0ByBone[bone.index] { return (bone.index, frame0) }
                return WPEMdlParser.matrix(fromColumnMajorFloats: bone.rawMatrix).map { (bone.index, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let parentByIndex = Dictionary(
            model.bones.map { ($0.index, $0.parentIndex) },
            uniquingKeysWith: { first, _ in first }
        )
        // A bone composes through its parent chain only when that chain is acyclic and fully present.
        // Any bone whose ancestry revisits a node resolves to its own local — so a cycle can never be
        // folded into a transform, and the recursion below is guaranteed to terminate.
        func chainIsAcyclic(_ start: Int) -> Bool {
            var seen: Set<Int> = [start]
            var current = parentByIndex[start] ?? nil
            while let bone = current, localByIndex[bone] != nil {
                if !seen.insert(bone).inserted { return false }
                current = parentByIndex[bone] ?? nil
            }
            return true
        }
        var cache: [Int: simd_float4x4] = [:]
        func world(_ index: Int) -> simd_float4x4 {
            if let cached = cache[index] { return cached }
            guard let local = localByIndex[index] else { return matrix_identity_float4x4 }
            let composed: simd_float4x4
            if let parent = parentByIndex[index] ?? nil, parent != index,
               localByIndex[parent] != nil, chainIsAcyclic(index) {
                composed = world(parent) * local
            } else {
                composed = local
            }
            cache[index] = composed
            return composed
        }
        var result: [Int: simd_float4x4] = [:]
        for bone in model.bones where localByIndex[bone.index] != nil {
            result[bone.index] = world(bone.index)
        }
        return result
    }

    /// Palette length must cover every skin-blend index the shader can sample
    /// (`bonePalette[skinBlendIndex]`), which is `maxBoneIndex + 1`, not merely the channel count.
    static func paletteCount(for channels: [WPEPuppetAnimChannel]) -> Int {
        let maxBoneIndex = channels.map(\.boneIndex).max() ?? -1
        return max(channels.count, maxBoneIndex + 1, 1)
    }

    public static func matrixIsFinite(_ matrix: simd_float4x4) -> Bool {
        for column in [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        where !(column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite) {
            return false
        }
        return true
    }

    /// Fallback when no usable skeleton hierarchy is supplied (unit tests / bone-less models):
    /// treat each channel as an independent transform. Indexed by bone index, like the hierarchy path.
    private static func independentPalette(
        channels: [WPEPuppetAnimChannel],
        localMatrix: (Int, Bool) -> simd_float4x4
    ) -> [simd_float4x4] {
        var palette = identityPalette(count: paletteCount(for: channels))
        for (position, channel) in channels.enumerated() {
            guard channel.boneIndex >= 0, channel.boneIndex < palette.count else { continue }
            let bind = localMatrix(position, true)
            let determinant = simd_determinant(bind)
            guard determinant.isFinite, abs(determinant) > 1e-6 else { continue }
            let result = localMatrix(position, false) * simd_inverse(bind)
            guard matrixIsFinite(result) else { continue }
            palette[channel.boneIndex] = result
        }
        return palette
    }

    /// Maps each channel to its parent channel index (or `nil` for a root). Returns `nil` when the
    /// supplied skeleton doesn't cover every channel's bone, so the caller falls back to the
    /// no-hierarchy path instead of mis-skinning against a partial skeleton.
    private static func parentChannelMap(
        channels: [WPEPuppetAnimChannel],
        bones: [WPEPuppetBone]
    ) -> [Int?]? {
        guard !bones.isEmpty, !channels.isEmpty else { return nil }
        var channelForBone: [Int: Int] = [:]
        for (position, channel) in channels.enumerated() {
            channelForBone[channel.boneIndex] = position
        }
        var parentByBone: [Int: Int?] = [:]
        for bone in bones {
            parentByBone[bone.index] = bone.parentIndex
        }
        var parentChannel = [Int?](repeating: nil, count: channels.count)
        for (position, channel) in channels.enumerated() {
            guard let parentOptional = parentByBone[channel.boneIndex] else {
                return nil
            }
            if let parentBone = parentOptional {
                guard let parentPosition = channelForBone[parentBone] else {
                    // Parent bone has no animation channel → can't compose a correct world
                    // transform. Bail to the no-hierarchy fallback rather than mis-bind.
                    return nil
                }
                if parentPosition != position {
                    parentChannel[position] = parentPosition
                }
            }
        }
        return parentChannel
    }

    public static func hasUsableHierarchy(layers: [WPEPuppetAnimationLayer], bones: [WPEPuppetBone]) -> Bool {
        guard let base = layers.first(where: { !$0.additive }) ?? layers.first else { return false }
        return parentChannelMap(channels: base.animation.channels, bones: bones) != nil
    }

    private static func rawMatricesByBone(_ bones: [WPEPuppetBone]) -> [Int: simd_float4x4] {
        Dictionary(uniqueKeysWithValues: bones.compactMap { bone -> (Int, simd_float4x4)? in
            guard let raw = WPEMdlParser.matrix(fromColumnMajorFloats: bone.rawMatrix) else { return nil }
            return (bone.index, raw)
        })
    }

    private static func hierarchyPalette(
        channels: [WPEPuppetAnimChannel],
        bones: [WPEPuppetBone],
        parentChannel: [Int?],
        localMatrix: (Int, Bool) -> simd_float4x4
    ) -> [simd_float4x4] {
        let rawByBone = rawMatricesByBone(bones)

        func worldMatrices(bind: Bool) -> [simd_float4x4] {
            // Both the MDLS raw matrices (bind pose) and the MDLA channel keyframes (current pose) are
            // stored PARENT-LOCAL, so a bone's WORLD transform is recovered by composing it onto its
            // parent's world transform. Bind and current are composed identically: the palette
            // (`current · bind⁻¹`) is then exactly identity in the rest pose, and a parent bone's motion
            // flows into every descendant. Without this, a high bone's breathing/sway/blink never
            // reaches the bones it drives and the puppet skins nearly static.
            //
            // Oracle-validated against Wallpaper Engine `g_Bones` (RenderDoc, WPE 2.8.26): scenes
            // 3461168300 (Plana, 53 bones) and 3554161528 (32 bones) match WPE to <0.1 / <6 total
            // Frobenius across all bones, vs ~70–190 with the previous code, which used the raw matrices
            // as world bind directly (uncomposed) and a translation-only `worldAbsolute` auto-detect
            // that always misfired here because each bone's frame-0 local equals its raw local.
            var cache = [simd_float4x4?](repeating: nil, count: channels.count)
            for _ in 0..<channels.count {
                var progress = false
                for index in 0..<channels.count {
                    if cache[index] != nil { continue }
                    
                    let local = bind
                        ? (rawByBone[channels[index].boneIndex] ?? localMatrix(index, true))
                        : localMatrix(index, false)
                    
                    if let parent = parentChannel[index] {
                        if let parentWorld = cache[parent] {
                            cache[index] = parentWorld * local
                            progress = true
                        }
                    } else {
                        cache[index] = local
                        progress = true
                    }
                }
                if !progress { break }
            }
            
            for index in 0..<channels.count {
                if cache[index] == nil {
                    cache[index] = matrix_identity_float4x4
                }
            }
            return cache.compactMap { $0 }
        }

        let bindWorld = worldMatrices(bind: true)
        let currentWorld = worldMatrices(bind: false)
        // Output is indexed by skin-blend (bone) index — the shader samples bonePalette[skinIndex],
        // which only equals the channel position under the parser's boneIndex==channelIndex invariant.
        var palette = identityPalette(count: paletteCount(for: channels))
        for position in 0..<channels.count {
            let boneIndex = channels[position].boneIndex
            guard boneIndex >= 0, boneIndex < palette.count else { continue }
            let bind = bindWorld[position]
            let determinant = simd_determinant(bind)
            guard determinant.isFinite, abs(determinant) > 1e-6 else { continue }
            let result = currentWorld[position] * simd_inverse(bind)
            guard matrixIsFinite(result) else { continue }
            palette[boneIndex] = result
        }
        return palette
    }

    public static func interpolationInfo(
        for animation: WPEPuppetAnimation,
        at time: Double
    ) -> WPEPuppetInterpolationInfo {
        let fps = Double(animation.fps)
        let intervalCount = max(animation.frameCount, 0)
        guard fps.isFinite, fps > 0, intervalCount > 0 else {
            return WPEPuppetInterpolationInfo(frameA: 0, frameB: 0, t: 0)
        }
        let framePosition = max(time, 0) * fps
        guard framePosition.isFinite, framePosition < Double(Int.max) else {
            return WPEPuppetInterpolationInfo(frameA: 0, frameB: 0, t: 0)
        }
        let mode = animation.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mode {
        case "single":
            let clamped = min(framePosition, Double(intervalCount))
            if clamped >= Double(intervalCount) {
                return WPEPuppetInterpolationInfo(
                    frameA: max(intervalCount - 1, 0),
                    frameB: intervalCount,
                    t: 1
                )
            }
            let frameA = Int(floor(clamped))
            return WPEPuppetInterpolationInfo(
                frameA: frameA,
                frameB: frameA + 1,
                t: Float(clamped - Double(frameA))
            )
        case "mirror":
            let period = intervalCount * 2
            let phase = framePosition.truncatingRemainder(dividingBy: Double(period))
            let rawA = Int(floor(phase))
            let rawB = rawA + 1
            func mirrored(_ frame: Int) -> Int {
                frame <= intervalCount ? frame : period - frame
            }
            return WPEPuppetInterpolationInfo(
                frameA: mirrored(rawA),
                frameB: mirrored(rawB),
                t: Float(phase - Double(rawA))
            )
        default:
            // Wallpaper Engine treats empty and unknown modes as loop.
            let phase = framePosition.truncatingRemainder(dividingBy: Double(intervalCount))
            let frameA = Int(floor(phase))
            return WPEPuppetInterpolationInfo(
                frameA: frameA,
                frameB: frameA + 1,
                t: Float(phase - Double(frameA))
            )
        }
    }

    private static func sampledTRS(
        channel: WPEPuppetAnimChannel,
        interpolation: WPEPuppetInterpolationInfo
    ) -> (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        guard !channel.keyframes.isEmpty else {
            return (.zero, simd_quatf(real: 1, imag: .zero), SIMD3<Float>(repeating: 1))
        }
        let frameA = channel.keyframes[min(max(interpolation.frameA, 0), channel.keyframes.count - 1)]
        let frameB = channel.keyframes[min(max(interpolation.frameB, 0), channel.keyframes.count - 1)]
        let t = max(0, min(interpolation.t, 1))
        if frameA.frame == frameB.frame || t == 0 {
            return (frameA.translation, rotationQuaternion(euler: frameA.euler), frameA.scale)
        }
        if t == 1 {
            return (frameB.translation, rotationQuaternion(euler: frameB.euler), frameB.scale)
        }
        let weight = SIMD3<Float>(repeating: t)
        return (
            simd_mix(frameA.translation, frameB.translation, weight),
            simd_slerp(rotationQuaternion(euler: frameA.euler), rotationQuaternion(euler: frameB.euler), t),
            simd_mix(frameA.scale, frameB.scale, weight)
        )
    }

    private static func matrix(
        translation: SIMD3<Float>,
        euler: SIMD3<Float>,
        scale: SIMD3<Float>
    ) -> simd_float4x4 {
        matrix(translation: translation, rotation: rotationQuaternion(euler: euler), scale: scale)
    }

    private static func matrix(
        translation: SIMD3<Float>,
        rotation: simd_quatf,
        scale: SIMD3<Float>
    ) -> simd_float4x4 {
        translationMatrix(translation) * simd_float4x4(rotation) * scaleMatrix(scale)
    }

    private static func rotationQuaternion(euler: SIMD3<Float>) -> simd_quatf {
        let x = simd_quatf(angle: euler.x, axis: SIMD3<Float>(1, 0, 0))
        let y = simd_quatf(angle: euler.y, axis: SIMD3<Float>(0, 1, 0))
        let z = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 0, 1))
        return simd_normalize(z * y * x)
    }

    private static func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        )
    }

    private static func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(s.x, 0, 0, 0),
            SIMD4<Float>(0, s.y, 0, 0),
            SIMD4<Float>(0, 0, s.z, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
    }

}

private final class WPEMdlParseAuditRecorder {
    fileprivate struct OpenSection {
        let kind: WPEMdlParseAudit.SectionKind
        let label: String
        let start: Int
        var skips: [WPEMdlParseAudit.KnownSkip]
    }

    struct Checkpoint {
        fileprivate let sectionsCount: Int
        fileprivate let openSection: OpenSection?
    }

    private let dataCount: Int
    private var sections: [WPEMdlParseAudit.SectionRecord] = []
    private var openSection: OpenSection?

    init(dataCount: Int) {
        self.dataCount = dataCount
    }

    func beginSection(kind: WPEMdlParseAudit.SectionKind, label: String, start: Int) {
        openSection = OpenSection(kind: kind, label: label, start: start, skips: [])
    }

    func endSection(at end: Int) {
        guard let section = openSection else { return }
        sections.append(WPEMdlParseAudit.SectionRecord(
            kind: section.kind,
            label: section.label,
            range: section.start..<end,
            intentionallySkippedRanges: section.skips
        ))
        openSection = nil
    }

    func recordKnownSkip(label: String, range: Range<Int>) {
        guard !range.isEmpty, var section = openSection else { return }
        section.skips.append(WPEMdlParseAudit.KnownSkip(label: label, range: range))
        openSection = section
    }

    func checkpoint() -> Checkpoint {
        Checkpoint(sectionsCount: sections.count, openSection: openSection)
    }

    func rollback(to checkpoint: Checkpoint) {
        if sections.count > checkpoint.sectionsCount {
            sections.removeSubrange(checkpoint.sectionsCount..<sections.count)
        }
        openSection = checkpoint.openSection
    }

    func makeAudit() -> WPEMdlParseAudit {
        let sortedSections = sections.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound < $1.range.upperBound
        }
        var gaps: [WPEMdlParseAudit.Gap] = []
        var coveredEnd = 0
        for section in sortedSections {
            if section.range.lowerBound > coveredEnd {
                gaps.append(WPEMdlParseAudit.Gap(range: coveredEnd..<section.range.lowerBound))
            }
            coveredEnd = max(coveredEnd, section.range.upperBound)
        }
        let trailingLeftover = coveredEnd < dataCount ? coveredEnd..<dataCount : nil
        return WPEMdlParseAudit(
            sections: sortedSections,
            unexplainedGaps: gaps,
            trailingLeftover: trailingLeftover
        )
    }
}

public enum WPEMdlParser {
    /// Counts come straight from untrusted Workshop bytes: a crafted header claiming up to
    /// 0xFFFFFFFF entries would drive `reserveCapacity` into a multi-GB allocation (OOM trap)
    /// before the read loop could fail naturally on truncation. Caps sit far above the corpus
    /// maxima (dozens of meshes, ≤89 bones observed) — same idea as the MDLA 1024-animation cap.
    private static let maxMeshCount: UInt32 = 4_096
    private static let maxBoneCount: UInt32 = 4_096

    public static func parse(data: Data) throws -> WPEPuppetModel {
        try parse(data: data, auditRecorder: nil)
    }

    public static func parse(data: Data, audit: inout WPEMdlParseAudit?) throws -> WPEPuppetModel {
        audit = nil
        let auditRecorder = WPEMdlParseAuditRecorder(dataCount: data.count)
        let model = try parse(data: data, auditRecorder: auditRecorder)
        audit = auditRecorder.makeAudit()
        return model
    }

    private static func parse(
        data: Data,
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> WPEPuppetModel {
        var reader = WPEMdlBinaryReader(data: data)
        auditRecorder?.beginSection(kind: .mdlvHeader, label: "MDLV header", start: reader.currentOffset)
        // The header is version-branch-free: 9-byte NUL-terminated tag +
        // u32 model flags + u32 skin count + u32 mesh count. Byte-verified
        // against the engine's own assets/models/editor/camera/camera.mdl
        // (MDLV0017) and circle-xxl_puppet.mdl (MDLV0019); the previous
        // version-branched reader parsed mdlv 4/13/14/15/17/18 one byte off
        // and silently lost every such puppet.
        // count == 8 enforces the NUL in byte 9 — "MDLV00170" must not sneak
        // through as version 170 past the legacy-generation gate.
        let versionTag = try reader.readFixedString(byteCount: 9)
        guard versionTag.count == 8, versionTag.hasPrefix("MDLV"),
              let version = Int(versionTag.dropFirst(4)) else {
            throw WPEMdlParserError.invalidHeader
        }

        let headerMeshFlags = try reader.readUInt32()
        let skinCount = try reader.readUInt32()
        let meshCount = try reader.readUInt32()
        auditRecorder?.endSection(at: reader.currentOffset)
        guard meshCount <= maxMeshCount else {
            throw WPEMdlParserError.implausibleCount(
                section: "MDLV meshCount", count: meshCount, limit: maxMeshCount
            )
        }
        guard skinCount <= maxMeshCount else {
            throw WPEMdlParserError.implausibleCount(
                section: "MDLV skinCount", count: skinCount, limit: maxMeshCount
            )
        }
        var meshes: [WPEPuppetMesh] = []
        meshes.reserveCapacity(Int(meshCount))

        for meshIndex in 0..<Int(meshCount) {
            meshes.append(try parseMesh(
                version: version,
                headerMeshFlags: headerMeshFlags,
                skinCount: skinCount,
                meshIndex: meshIndex,
                auditRecorder: auditRecorder,
                reader: &reader
            ))
        }

        // Optional skeleton or animation metadata must not invalidate already parsed static mesh geometry.
        var metadataReader = reader
        let bones: [WPEPuppetBone]
        let skeletonAuditCheckpoint = auditRecorder?.checkpoint()
        do {
            bones = try parseSkeletonIfPresent(reader: &metadataReader, auditRecorder: auditRecorder)
        } catch {
            if let skeletonAuditCheckpoint {
                auditRecorder?.rollback(to: skeletonAuditCheckpoint)
            }
            Logger.warning(
                "WPE puppet MDL skeleton parse failed; rendering the static mesh without bones: \(error)",
                category: .wpeRender
            )
            bones = []
            metadataReader = reader
        }

        let attachments: [WPEPuppetAttachment]
        let attachmentAuditCheckpoint = auditRecorder?.checkpoint()
        do {
            var attachmentReader = metadataReader
            attachments = try parseAttachmentsIfPresent(reader: &attachmentReader, auditRecorder: auditRecorder)
            metadataReader = attachmentReader
        } catch {
            if let attachmentAuditCheckpoint {
                auditRecorder?.rollback(to: attachmentAuditCheckpoint)
            }
            Logger.warning(
                "WPE puppet MDL attachment parse failed; rendering without MDAT anchors: \(error)",
                category: .wpeRender
            )
            attachments = []
        }

        let animations: [WPEPuppetAnimation]
        let animationAuditCheckpoint = auditRecorder?.checkpoint()
        do {
            animations = try parseAnimationsIfPresent(reader: &metadataReader, auditRecorder: auditRecorder)
        } catch {
            if let animationAuditCheckpoint {
                auditRecorder?.rollback(to: animationAuditCheckpoint)
            }
            Logger.warning(
                "WPE puppet MDL animation parse failed; rendering the static mesh without animations: \(error)",
                category: .wpeRender
            )
            animations = []
        }

        let resolvedBones: [WPEPuppetBone]
        let elementAuditCheckpoint = auditRecorder?.checkpoint()
        do {
            resolvedBones = try parseElementWorldBindsIfPresent(
                reader: &metadataReader,
                bones: bones,
                auditRecorder: auditRecorder
            )
        } catch {
            if let elementAuditCheckpoint {
                auditRecorder?.rollback(to: elementAuditCheckpoint)
            }
            Logger.warning(
                "WPE puppet MDLE parse failed; keeping MDLS bind data: \(error)",
                category: .wpeRender
            )
            resolvedBones = bones
        }

        return WPEPuppetModel(
            version: version,
            meshes: meshes,
            bones: resolvedBones,
            animations: animations,
            attachments: attachments,
            authoredData: data
        )
    }

    private static func readIgnoredUInt8(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?,
        label: String
    ) throws {
        let start = reader.currentOffset
        _ = try reader.readUInt8()
        auditRecorder?.recordKnownSkip(label: label, range: start..<reader.currentOffset)
    }

    private static func readIgnoredUInt16(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?,
        label: String
    ) throws {
        let start = reader.currentOffset
        _ = try reader.readUInt16()
        auditRecorder?.recordKnownSkip(label: label, range: start..<reader.currentOffset)
    }

    private static func readIgnoredUInt32(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?,
        label: String
    ) throws {
        let start = reader.currentOffset
        _ = try reader.readUInt32()
        auditRecorder?.recordKnownSkip(label: label, range: start..<reader.currentOffset)
    }

    private static func skipKnownBytes(
        byteCount: Int,
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?,
        label: String
    ) throws {
        let start = reader.currentOffset
        try reader.skip(byteCount: byteCount)
        auditRecorder?.recordKnownSkip(label: label, range: start..<reader.currentOffset)
    }

    private static func parseMesh(
        version: Int,
        headerMeshFlags: UInt32,
        skinCount: UInt32,
        meshIndex: Int,
        auditRecorder: WPEMdlParseAuditRecorder?,
        reader: inout WPEMdlBinaryReader
    ) throws -> WPEPuppetMesh {
        auditRecorder?.beginSection(
            kind: .mdlvMesh,
            label: "MDLV mesh \(meshIndex)",
            start: reader.currentOffset
        )
        // Each mesh leads with `skinCount` material paths (every corpus file
        // authors exactly one); we render the first skin.
        var materialPath = ""
        for skinIndex in 0..<Int(skinCount) {
            let path = try reader.readCString()
            if skinIndex == 0 { materialPath = path }
        }
        let flagA = try reader.readUInt32()
        if flagA == 2 {
            try readIgnoredUInt32(reader: &reader, auditRecorder: auditRecorder, label: "MDLV mesh flag payload")
        }
        let bounds: WPEPuppetMeshBounds?
        if version >= 17 {
            bounds = WPEPuppetMeshBounds(
                minimum: SIMD3<Float>(
                    try reader.readFloat(),
                    try reader.readFloat(),
                    try reader.readFloat()
                ),
                maximum: SIMD3<Float>(
                    try reader.readFloat(),
                    try reader.readFloat(),
                    try reader.readFloat()
                )
            )
        } else {
            bounds = nil
        }
        let meshFlags = version > 14 ? try reader.readUInt32() : headerMeshFlags
        let vertexByteCount = try reader.readUInt32()
        let vertexStride = stride(for: meshFlags)
        guard vertexStride > 0, vertexByteCount % UInt32(vertexStride) == 0 else {
            throw WPEMdlParserError.invalidVertexBuffer(byteCount: vertexByteCount, stride: vertexStride)
        }
        // The declared buffer must fit in the remaining bytes — otherwise a crafted byte count
        // (up to 4 GiB) would size `reserveCapacity` long before the reads hit truncation.
        guard Int(vertexByteCount) <= reader.dataCount - reader.currentOffset else {
            throw WPEMdlParserError.invalidVertexBuffer(byteCount: vertexByteCount, stride: vertexStride)
        }
        let vertexCount = vertexByteCount / UInt32(vertexStride)
        var vertices: [WPEPuppetVertex] = []
        vertices.reserveCapacity(Int(vertexCount))

        for _ in 0..<vertexCount {
            vertices.append(try parseVertex(
                meshFlags: meshFlags,
                auditRecorder: auditRecorder,
                reader: &reader
            ))
        }

        let indexByteCount = try reader.readUInt32()
        let indexElementWidth: WPEPuppetIndexElementWidth = version >= 23 && vertexCount > UInt32(UInt16.max)
            ? .uint32
            : .uint16
        let indexStride = UInt32(indexElementWidth.rawValue)
        let triangleStride = 3 * indexStride
        guard indexByteCount % triangleStride == 0,
              Int(indexByteCount) <= reader.dataCount - reader.currentOffset else {
            throw WPEMdlParserError.invalidIndexBuffer(indexByteCount)
        }
        let indexCount = indexByteCount / indexStride
        var indices: [UInt32] = []
        indices.reserveCapacity(Int(indexCount))
        for _ in 0..<indexCount {
            switch indexElementWidth {
            case .uint16:
                indices.append(UInt32(try reader.readUInt16()))
            case .uint32:
                indices.append(try reader.readUInt32())
            }
        }

        let parts = version >= 21
            ? try parseVersion21Parts(
                vertexCount: Int(vertexCount),
                auditRecorder: auditRecorder,
                reader: &reader
            )
            : []

        // MDLV22+ always stores a mask-count block after each mesh. It must advance the main
        // reader: otherwise a multi-mesh model starts its next mesh four bytes too early.
        let clipGroups = version > 21
            ? parseClipGroups(partCount: parts.count, reader: &reader)
            : []

        let mesh = WPEPuppetMesh(
            materialPath: materialPath,
            vertices: vertices,
            indices: indices,
            indexElementWidth: indexElementWidth,
            parts: parts,
            bounds: bounds,
            clipMaskName: clipGroups.first?.maskName,
            clipGroups: clipGroups
        )
        auditRecorder?.endSection(at: reader.currentOffset)
        return mesh
    }

    /// Best-effort parse of the MDLV22+ mask block. Parsing is transactional so older synthetic
    /// fixtures that omit an empty mask-count do not consume the following MDLS/MDLA tag.
    private static func parseClipGroups(
        partCount: Int,
        reader: inout WPEMdlBinaryReader
    ) -> [WPEPuppetClipGroup] {
        var r = reader
        guard let groupCount = try? r.readUInt32(),
              groupCount <= maxMeshCount else { return [] }
        var groups: [WPEPuppetClipGroup] = []
        groups.reserveCapacity(Int(groupCount))
        for _ in 0..<groupCount {
            guard (try? r.readUInt32()) != nil,
                  (try? r.readUInt32()) != nil,
                  let name = try? r.readCString(),
                  !name.isEmpty,
                  name.utf8.count <= 1_024,
                  (try? r.readUInt32()) != nil,
                  let targetCount = try? r.readUInt32(),
                  targetCount <= UInt32(partCount),
                  targetCount <= UInt32((r.dataCount - r.currentOffset) / MemoryLayout<UInt32>.size) else {
                return []
            }
            var targets: [Int] = []
            targets.reserveCapacity(Int(targetCount))
            for _ in 0..<targetCount {
                guard let index = try? r.readUInt32(), index < UInt32(partCount) else { return [] }
                targets.append(Int(index))
            }
            guard let sourceCount = try? r.readUInt32(),
                  sourceCount <= UInt32(partCount),
                  sourceCount <= UInt32((r.dataCount - r.currentOffset) / MemoryLayout<UInt32>.size) else {
                return []
            }
            var sources: [Int] = []
            sources.reserveCapacity(Int(sourceCount))
            for _ in 0..<sourceCount {
                guard let index = try? r.readUInt32(), index < UInt32(partCount) else { return [] }
                sources.append(Int(index))
            }
            groups.append(WPEPuppetClipGroup(
                maskName: name,
                sourcePartIndices: sources,
                targetPartIndices: targets
            ))
        }
        reader = r
        return groups
    }

    private static func parseVertex(
        meshFlags: UInt32,
        auditRecorder: WPEMdlParseAuditRecorder?,
        reader: inout WPEMdlBinaryReader
    ) throws -> WPEPuppetVertex {
        let position = SIMD3<Float>(
            try reader.readFloat(),
            try reader.readFloat(),
            try reader.readFloat()
        )

        if meshFlags & WPEMdlMeshFlags.normal != 0 {
            try skipKnownBytes(
                byteCount: 3 * MemoryLayout<Float>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV vertex normal"
            )
        }
        if meshFlags & WPEMdlMeshFlags.tangent != 0 {
            try skipKnownBytes(
                byteCount: 4 * MemoryLayout<Float>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV vertex tangent"
            )
        }
        if meshFlags & WPEMdlMeshFlags.extra4 != 0 {
            try skipKnownBytes(
                byteCount: 4 * MemoryLayout<UInt8>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV vertex extra4"
            )
        }
        var skinBlendIndices = SIMD4<Int32>(0, 0, 0, 0)
        var skinBlendWeights = SIMD4<Float>(0, 0, 0, 0)
        if meshFlags & WPEMdlMeshFlags.skinBlendIndices != 0 {
            // Skin-blend indices are 4× little-endian Int32 (not floats, which
            // the old decode misread — collapsing every index to bone 0).
            skinBlendIndices = SIMD4<Int32>(
                try reader.readInt32(),
                try reader.readInt32(),
                try reader.readInt32(),
                try reader.readInt32()
            )
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendWeights != 0 {
            skinBlendWeights = SIMD4<Float>(
                try reader.readFloat(),
                try reader.readFloat(),
                try reader.readFloat(),
                try reader.readFloat()
            )
        }

        let uv: SIMD2<Float>
        if meshFlags & WPEMdlMeshFlags.uv != 0 {
            uv = SIMD2<Float>(try reader.readFloat(), try reader.readFloat())
        } else {
            uv = SIMD2<Float>(0, 0)
        }
        if meshFlags & WPEMdlMeshFlags.uv2 != 0 {
            try skipKnownBytes(
                byteCount: 2 * MemoryLayout<Float>.size,
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLV vertex uv2"
            )
        }

        return WPEPuppetVertex(
            position: position,
            uv: uv,
            skinBlendIndices: skinBlendIndices,
            skinBlendWeights: skinBlendWeights
        )
    }

    private static func stride(for meshFlags: UInt32) -> Int {
        var stride = 3 * MemoryLayout<Float>.size
        if meshFlags & WPEMdlMeshFlags.normal != 0 {
            stride += 3 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.tangent != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.extra4 != 0 {
            stride += 4 * MemoryLayout<UInt8>.size
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendIndices != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.skinBlendWeights != 0 {
            stride += 4 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.uv != 0 {
            stride += 2 * MemoryLayout<Float>.size
        }
        if meshFlags & WPEMdlMeshFlags.uv2 != 0 {
            stride += 2 * MemoryLayout<Float>.size
        }
        return stride
    }

    private static func parseVersion21Parts(
        vertexCount: Int,
        auditRecorder: WPEMdlParseAuditRecorder?,
        reader: inout WPEMdlBinaryReader
    ) throws -> [WPEPuppetMeshPart] {
        let uv2Marker = try reader.readUInt8()
        if uv2Marker == 1 {
            let hasUV2Payload = try reader.readUInt8()
            if hasUV2Payload != 0 {
                try readIgnoredUInt16(reader: &reader, auditRecorder: auditRecorder, label: "MDLV uv2 payload marker")
                try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDLV uv2 payload flag")
                let payloadSize = try reader.readUInt32()
                let expectedSize = UInt32(vertexCount * 12)
                try skipKnownBytes(
                    byteCount: Int(max(payloadSize, expectedSize)),
                    reader: &reader,
                    auditRecorder: auditRecorder,
                    label: "MDLV uv2 payload"
                )
            }
        } else if uv2Marker != 0 {
            throw WPEMdlParserError.unsupportedSectionMarker(uv2Marker)
        }

        let hasParts = try reader.readUInt8()
        guard hasParts != 0 else { return [] }

        let byteCount = try reader.readUInt32()
        guard byteCount % 16 == 0,
              Int(byteCount) <= reader.dataCount - reader.currentOffset else {
            throw WPEMdlParserError.invalidPartTable(byteCount)
        }
        let partCount = Int(byteCount / 16)
        var parts: [WPEPuppetMeshPart] = []
        parts.reserveCapacity(partCount)
        for _ in 0..<partCount {
            let id = try reader.readUInt32()
            try readIgnoredUInt32(reader: &reader, auditRecorder: auditRecorder, label: "MDLV part reserved")
            let start = try reader.readUInt32()
            let count = try reader.readUInt32()
            parts.append(WPEPuppetMeshPart(id: id, start: Int(start), count: Int(count)))
        }
        return parts
    }

    private static func parseSkeletonIfPresent(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> [WPEPuppetBone] {
        guard let skeletonOffset = reader.findTag("MDLS", from: reader.currentOffset) else {
            return []
        }
        try reader.seek(to: skeletonOffset)

        let skeletonTag = try reader.readFixedString(byteCount: 8)
        guard skeletonTag.hasPrefix("MDLS") else { return [] }
        let skeletonVersion = Int(skeletonTag.suffix(4)) ?? 0
        auditRecorder?.beginSection(kind: .mdls, label: skeletonTag, start: skeletonOffset)
        try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDLS section flag")
        let declaredSectionEnd = Int(try reader.readUInt32())
        let boneCount = UInt32(try reader.readUInt16())
        try readIgnoredUInt16(
            reader: &reader,
            auditRecorder: auditRecorder,
            label: "MDLS bone-count padding"
        )
        let skeletonSectionEnd = declaredSectionEnd > reader.currentOffset
            ? min(declaredSectionEnd, reader.dataCount)
            : reader.dataCount

        guard boneCount <= maxBoneCount else {
            throw WPEMdlParserError.implausibleCount(
                section: "MDLS boneCount", count: boneCount, limit: maxBoneCount
            )
        }
        var bones: [WPEPuppetBone] = []
        bones.reserveCapacity(Int(boneCount))
        for index in 0..<boneCount {
            let name = try reader.readCString(sectionEnd: skeletonSectionEnd)
            let simulationType = try reader.readInt32()
            let fileParent = try reader.readUInt32()
            let parent: Int?
            if fileParent == UInt32.max || fileParent >= index {
                parent = nil
            } else {
                parent = Int(fileParent)
            }
            let matrixByteCount = try reader.readUInt32()
            guard matrixByteCount == 16 * UInt32(MemoryLayout<Float>.size) else {
                throw WPEMdlParserError.invalidSkeletonMatrix(matrixByteCount)
            }

            var matrix: [Float] = []
            matrix.reserveCapacity(16)
            for _ in 0..<16 {
                matrix.append(try reader.readFloat())
            }
            let simulationJSON = try reader.readCString(sectionEnd: skeletonSectionEnd)

            bones.append(WPEPuppetBone(
                index: Int(index),
                parentIndex: parent,
                rawMatrix: matrix,
                name: name,
                simulationType: simulationType,
                simulationJSON: simulationJSON
            ))
        }
        if skeletonVersion == 2, reader.currentOffset + 3 <= skeletonSectionEnd {
            try readIgnoredUInt16(
                reader: &reader,
                auditRecorder: auditRecorder,
                label: "MDLS0002 extras flag"
            )
            let hasWorldBinds = try reader.readUInt8() != 0
            if hasWorldBinds {
                var worldBinds = [[Float]]()
                worldBinds.reserveCapacity(bones.count)
                for _ in bones.indices {
                    var matrix = [Float]()
                    matrix.reserveCapacity(16)
                    for _ in 0..<16 {
                        matrix.append(try reader.readFloat())
                    }
                    worldBinds.append(matrix)
                }
                bones = zip(bones, worldBinds).map { bone, worldBind in
                    WPEPuppetBone(
                        index: bone.index,
                        parentIndex: bone.parentIndex,
                        rawMatrix: bone.rawMatrix,
                        worldBindMatrix: worldBind,
                        name: bone.name,
                        simulationType: bone.simulationType,
                        simulationJSON: bone.simulationJSON
                    )
                }
            }
            let paddingStart = reader.currentOffset
            let paddingEnd = min(paddingStart + 8, skeletonSectionEnd)
            try reader.seek(to: paddingEnd)
            auditRecorder?.recordKnownSkip(label: "MDLS0002 world-bind padding", range: paddingStart..<paddingEnd)
        }
        if skeletonSectionEnd <= reader.dataCount {
            let paddingStart = reader.currentOffset
            try reader.seek(to: skeletonSectionEnd)
            auditRecorder?.recordKnownSkip(label: "MDLS section padding", range: paddingStart..<reader.currentOffset)
        }
        auditRecorder?.endSection(at: reader.currentOffset)
        return bones
    }

    /// MDLE stores one file-authored world-bind matrix per MDLS bone. Preserve
    /// these values for trace/oracle work; palette consumption remains gated
    /// until the composition rule is proven independently.
    private static func parseElementWorldBindsIfPresent(
        reader: inout WPEMdlBinaryReader,
        bones: [WPEPuppetBone],
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> [WPEPuppetBone] {
        guard let elementOffset = reader.findTag("MDLE", from: reader.currentOffset) else {
            return bones
        }
        try reader.seek(to: elementOffset)
        let tag = try reader.readFixedString(byteCount: 8)
        guard tag.hasPrefix("MDLE") else { return bones }
        auditRecorder?.beginSection(kind: .mdle, label: tag, start: elementOffset)
        try readIgnoredUInt8(
            reader: &reader,
            auditRecorder: auditRecorder,
            label: "MDLE tag terminator"
        )
        let declaredSectionEnd = Int(try reader.readUInt32())
        let payloadByteCount = try reader.readUInt32()
        let expectedByteCount = UInt64(bones.count) * UInt64(16 * MemoryLayout<Float>.size)
        guard expectedByteCount <= UInt64(UInt32.max),
              payloadByteCount == UInt32(expectedByteCount) else {
            throw WPEMdlParserError.invalidElementMatrixPayload(
                actual: payloadByteCount,
                expected: UInt32(clamping: expectedByteCount)
            )
        }

        var matrices = [[Float]]()
        matrices.reserveCapacity(bones.count)
        for _ in bones.indices {
            var matrix = [Float]()
            matrix.reserveCapacity(16)
            for _ in 0..<16 { matrix.append(try reader.readFloat()) }
            matrices.append(matrix)
        }
        let sectionEnd = declaredSectionEnd > reader.currentOffset
            ? min(declaredSectionEnd, reader.dataCount)
            : reader.currentOffset
        if reader.currentOffset < sectionEnd {
            let paddingStart = reader.currentOffset
            try reader.seek(to: sectionEnd)
            auditRecorder?.recordKnownSkip(
                label: "MDLE section padding",
                range: paddingStart..<reader.currentOffset
            )
        }
        auditRecorder?.endSection(at: reader.currentOffset)

        return zip(bones, matrices).map { bone, worldBind in
            WPEPuppetBone(
                index: bone.index,
                parentIndex: bone.parentIndex,
                rawMatrix: bone.rawMatrix,
                worldBindMatrix: worldBind,
                name: bone.name,
                simulationType: bone.simulationType,
                simulationJSON: bone.simulationJSON
            )
        }
    }

    public static func matrix(fromColumnMajorFloats values: [Float]) -> simd_float4x4? {
        guard values.count >= 16 else { return nil }
        return simd_float4x4(
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        )
    }

    /// Parses MDAT0001 anchors: a section header followed by a UTF-8 name, bone index, and column-major bind matrix per anchor.
    private static func parseAttachmentsIfPresent(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> [WPEPuppetAttachment] {
        guard let attachmentOffset = reader.findTag("MDAT", from: reader.currentOffset) else {
            return []
        }
        // MDAT precedes MDLA in the section order; if the next MDAT lies past MDLA it is a false
        // positive inside the animation payload, so there is no real attachment section to read.
        if let animationOffset = reader.findTag("MDLA", from: reader.currentOffset),
           animationOffset < attachmentOffset {
            return []
        }
        try reader.seek(to: attachmentOffset)
        let tag = try reader.readFixedString(byteCount: 8)
        guard tag == "MDAT0001" else { return [] }
        auditRecorder?.beginSection(kind: .mdat, label: tag, start: attachmentOffset)
        try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDAT section flag")
        let declaredSectionEnd = Int(try reader.readUInt32())
        let anchorCount = try reader.readUInt16()
        let sectionEnd = declaredSectionEnd > reader.currentOffset
            ? min(declaredSectionEnd, reader.dataCount)
            : reader.dataCount

        var attachments: [WPEPuppetAttachment] = []
        attachments.reserveCapacity(Int(anchorCount))
        for _ in 0..<anchorCount {
            // Keep every read inside the declared section; a false-positive `MDAT` tag would otherwise
            // read garbage anchors from neighbouring data. On overrun, bail to the no-attachment path.
            guard reader.currentOffset + 2 <= sectionEnd else {
                throw WPEMdlParserError.invalidAttachmentHeader(offset: attachmentOffset)
            }
            let boneIndex = Int(try reader.readUInt16())
            let name = try reader.readCString(sectionEnd: sectionEnd)
            guard reader.currentOffset + 16 * MemoryLayout<Float>.size <= sectionEnd else {
                throw WPEMdlParserError.invalidAttachmentHeader(offset: attachmentOffset)
            }
            var matrix: [Float] = []
            matrix.reserveCapacity(16)
            for _ in 0..<16 { matrix.append(try reader.readFloat()) }
            attachments.append(WPEPuppetAttachment(name: name, boneIndex: boneIndex, bindMatrix: matrix))
        }
        if sectionEnd <= reader.dataCount {
            let paddingStart = reader.currentOffset
            try reader.seek(to: sectionEnd)
            auditRecorder?.recordKnownSkip(label: "MDAT section padding", range: paddingStart..<reader.currentOffset)
        }
        auditRecorder?.endSection(at: reader.currentOffset)
        return attachments
    }

    /// One keyframe = 9 little-endian f32: [Tx,Ty,Tz, Rx,Ry,Rz, Sx,Sy,Sz].
    private static let animationKeyByteCount = 9 * MemoryLayout<Float>.size

    private static func parseAnimationCurveBlock(
        boneCount: Int,
        sectionEnd: Int,
        reader: inout WPEMdlBinaryReader
    ) throws -> WPEPuppetAnimationCurveBlock {
        let blockStart = reader.currentOffset
        let marker = try reader.readUInt8()
        guard marker == 0 || marker == 1 else {
            throw WPEMdlParserError.invalidAnimationTail(offset: blockStart)
        }
        var curves: [WPEPuppetAnimationCurve] = []
        if marker == 1 {
            curves.reserveCapacity(boneCount)
            for _ in 0..<boneCount {
                let curveStart = reader.currentOffset
                let reserved = try reader.readUInt32()
                let byteCount = try reader.readUInt32()
                guard byteCount % UInt32(MemoryLayout<Float>.size) == 0,
                      Int(byteCount) <= sectionEnd - reader.currentOffset else {
                    throw WPEMdlParserError.invalidAnimationTail(offset: curveStart)
                }
                var values: [Float] = []
                values.reserveCapacity(Int(byteCount) / MemoryLayout<Float>.size)
                for _ in 0..<(Int(byteCount) / MemoryLayout<Float>.size) {
                    values.append(try reader.readFloat())
                }
                curves.append(WPEPuppetAnimationCurve(
                    reserved: reserved,
                    values: values,
                    sourceRange: curveStart..<reader.currentOffset
                ))
            }
        }
        return WPEPuppetAnimationCurveBlock(
            sourceRange: blockStart..<reader.currentOffset,
            hasCurves: marker == 1,
            curves: curves
        )
    }

    private static func skipAnimationFloatPayload(
        byteCount: UInt32,
        sectionEnd: Int,
        reader: inout WPEMdlBinaryReader
    ) throws {
        guard byteCount % UInt32(MemoryLayout<Float>.size) == 0,
              Int(byteCount) <= sectionEnd - reader.currentOffset else {
            throw WPEMdlParserError.invalidAnimationTail(offset: reader.currentOffset)
        }
        try reader.skip(byteCount: Int(byteCount))
    }

    private static func isAnimationMainTrackByteCount(_ byteCount: UInt32, frameCount: UInt32) -> Bool {
        let sampleCount = UInt64(frameCount) + 1
        return byteCount > 0 && (
            UInt64(byteCount) == sampleCount * UInt64(animationKeyByteCount) ||
                UInt64(byteCount) == sampleCount * UInt64(MemoryLayout<Float>.size)
        )
    }

    private static func animationRawSegment(
        range: Range<Int>,
        reader: WPEMdlBinaryReader
    ) throws -> WPEPuppetAnimationRawSegment? {
        guard !range.isEmpty else { return nil }
        return WPEPuppetAnimationRawSegment(sourceRange: range, bytes: try reader.data(in: range))
    }

    private static func parseAnimationTail(
        mdlaVersion: Int,
        frameCount: UInt32,
        boneCount: Int,
        sectionEnd: Int,
        hasFollowingAnimation: Bool,
        reader: inout WPEMdlBinaryReader
    ) throws -> WPEPuppetAnimationTail {
        let tailStart = reader.currentOffset
        let transFlag = try reader.readUInt32()
        switch transFlag {
        case 0:
            if let byteCount = reader.peekUInt32(),
               isAnimationMainTrackByteCount(byteCount, frameCount: frameCount) {
                _ = try reader.readUInt32()
                try skipAnimationFloatPayload(byteCount: byteCount, sectionEnd: sectionEnd, reader: &reader)
                while reader.peekUInt32() == 0,
                      let tailByteCount = reader.peekUInt32(relativeOffset: MemoryLayout<UInt32>.size),
                      isAnimationMainTrackByteCount(tailByteCount, frameCount: frameCount) {
                    _ = try reader.readUInt32()
                    _ = try reader.readUInt32()
                    try skipAnimationFloatPayload(
                        byteCount: tailByteCount,
                        sectionEnd: sectionEnd,
                        reader: &reader
                    )
                }
            }
        case 1:
            let extraByteCount = try reader.readUInt32()
            try skipAnimationFloatPayload(
                byteCount: extraByteCount,
                sectionEnd: sectionEnd,
                reader: &reader
            )
            if extraByteCount > 0 { _ = try reader.readUInt32() }
            let mainByteCount = try reader.readUInt32()
            try skipAnimationFloatPayload(
                byteCount: mainByteCount,
                sectionEnd: sectionEnd,
                reader: &reader
            )
            if extraByteCount > 0 { _ = try reader.readUInt32() }
        default:
            throw WPEMdlParserError.invalidAnimationTail(offset: tailStart)
        }

        let prefixEnd = reader.currentOffset
        let blendCurves = try parseAnimationCurveBlock(
            boneCount: boneCount,
            sectionEnd: sectionEnd,
            reader: &reader
        )
        let afterBlend = reader.currentOffset

        let hasV4Events = try reader.readUInt8()
        guard hasV4Events == 0 || hasV4Events == 1 else {
            throw WPEMdlParserError.invalidAnimationTail(offset: reader.currentOffset - 1)
        }
        if hasV4Events == 1 {
            let eventCount = try reader.readUInt32()
            guard eventCount <= 65_536 else {
                throw WPEMdlParserError.invalidAnimationTail(offset: reader.currentOffset - 4)
            }
            for _ in 0..<eventCount {
                _ = try reader.readFloat()
                _ = try reader.readUInt32()
                let byteCount = try reader.readUInt32()
                try skipAnimationFloatPayload(
                    byteCount: byteCount,
                    sectionEnd: sectionEnd,
                    reader: &reader
                )
            }
        }

        for _ in 0..<6 { _ = try reader.readFloat() }
        let beforeScalar = reader.currentOffset
        let scalarCurves: WPEPuppetAnimationCurveBlock? = mdlaVersion == 6
            ? try parseAnimationCurveBlock(boneCount: boneCount, sectionEnd: sectionEnd, reader: &reader)
            : nil
        let afterScalar = reader.currentOffset

        let eventCount = try reader.readUInt32()
        guard eventCount <= 65_536 else {
            throw WPEMdlParserError.invalidAnimationTail(offset: reader.currentOffset - 4)
        }
        for _ in 0..<eventCount {
            _ = try reader.readUInt32()
            _ = try reader.readCString(sectionEnd: sectionEnd)
        }

        if hasFollowingAnimation,
           reader.peekUInt32() == 0,
           let nextID = reader.peekUInt32(relativeOffset: MemoryLayout<UInt32>.size),
           nextID > 0, nextID <= 100_000,
           reader.peekUInt32(relativeOffset: 2 * MemoryLayout<UInt32>.size) == 0 {
            _ = try reader.readUInt32()
        }
        guard reader.currentOffset <= sectionEnd else {
            throw WPEMdlParserError.invalidAnimationTail(offset: reader.currentOffset)
        }

        var unknownSegments: [WPEPuppetAnimationRawSegment] = []
        if let prefix = try animationRawSegment(range: tailStart..<prefixEnd, reader: reader) {
            unknownSegments.append(prefix)
        }
        if let middle = try animationRawSegment(range: afterBlend..<beforeScalar, reader: reader) {
            unknownSegments.append(middle)
        }
        if let suffix = try animationRawSegment(range: afterScalar..<reader.currentOffset, reader: reader) {
            unknownSegments.append(suffix)
        }
        return WPEPuppetAnimationTail(
            mdlaVersion: mdlaVersion,
            sourceRange: tailStart..<reader.currentOffset,
            blendCurves: blendCurves,
            scalarCurves: scalarCurves,
            unknownSegments: unknownSegments
        )
    }

    /// Parses corpus-validated MDLA0005/0006 channel-major skeletal animation records.
    /// Each channel contains `frameCount + 1` nine-float keyframes and maps to MDLS bone order.
    private static func parseAnimationsIfPresent(
        reader: inout WPEMdlBinaryReader,
        auditRecorder: WPEMdlParseAuditRecorder?
    ) throws -> [WPEPuppetAnimation] {
        guard let animationOffset = reader.findTag("MDLA", from: reader.currentOffset) else {
            return []
        }
        try reader.seek(to: animationOffset)

        let animationTag = try reader.readFixedString(byteCount: 8)
        guard animationTag == "MDLA0005" || animationTag == "MDLA0006" else { return [] }
        guard let mdlaVersion = Int(animationTag.suffix(4)) else { return [] }
        auditRecorder?.beginSection(kind: .mdla, label: animationTag, start: animationOffset)
        try readIgnoredUInt8(reader: &reader, auditRecorder: auditRecorder, label: "MDLA section flag")
        let declaredSectionEnd = Int(try reader.readUInt32())
        let animationCount = try reader.readUInt32()
        let sectionEnd = declaredSectionEnd == 0 ? reader.dataCount : declaredSectionEnd
        guard sectionEnd >= reader.currentOffset, sectionEnd <= reader.dataCount,
              animationCount <= 1_024 else {
            throw WPEMdlParserError.invalidAnimationHeader(offset: animationOffset)
        }

        var animations: [WPEPuppetAnimation] = []
        animations.reserveCapacity(Int(animationCount))
        for animationIndex in 0..<animationCount {
            let animationStart = reader.currentOffset
            let id = try reader.readInt32()
            let reservedID = try reader.readUInt32()
            var name = try reader.readCString(sectionEnd: sectionEnd)
            if name.isEmpty {
                name = try reader.readCString(sectionEnd: sectionEnd)
            }
            let mode = try reader.readCString(sectionEnd: sectionEnd)
            let fps = try reader.readFloat()
            let signedFrameCount = try reader.readInt32()
            let reserved0 = try reader.readUInt32()
            let channelCount = try reader.readUInt32()
            let reserved1 = try reader.readUInt32()
            let channelByteCount = try reader.readUInt32()

            guard reservedID == 0, reserved0 == 0, reserved1 == 0,
                  fps.isFinite, fps > 0,
                  signedFrameCount > 0, signedFrameCount < 10_000,
                  channelCount > 0, channelCount < 10_000 else {
                throw WPEMdlParserError.invalidAnimationHeader(offset: animationStart)
            }
            let frameCount = UInt32(signedFrameCount)

            let expectedChannelByteCount = (UInt64(frameCount) + 1) * UInt64(animationKeyByteCount)
            guard expectedChannelByteCount <= UInt64(UInt32.max),
                  channelByteCount == UInt32(expectedChannelByteCount) else {
                throw WPEMdlParserError.invalidAnimationChannelByteCount(
                    animationID: Int(id),
                    byteCount: channelByteCount,
                    expected: expectedChannelByteCount <= UInt64(UInt32.max)
                        ? UInt32(expectedChannelByteCount) : UInt32.max
                )
            }

            let keyframeCount = Int(channelByteCount) / animationKeyByteCount
            let channelCountInt = Int(channelCount)
            let minimumDataByteCount = UInt64(channelCount) * UInt64(channelByteCount)
                + UInt64(max(channelCountInt - 1, 0) * 2 * MemoryLayout<UInt32>.size)
            guard UInt64(reader.currentOffset) + minimumDataByteCount <= UInt64(sectionEnd) else {
                throw WPEMdlParserError.invalidAnimationHeader(offset: animationStart)
            }

            var channels: [WPEPuppetAnimChannel] = []
            channels.reserveCapacity(channelCountInt)
            for channelIndex in 0..<channelCountInt {
                var keyframes: [WPEPuppetAnimKey] = []
                keyframes.reserveCapacity(keyframeCount)
                for frame in 0..<keyframeCount {
                    let translation = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    let euler = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    let scale = SIMD3<Float>(
                        try reader.readFloat(), try reader.readFloat(), try reader.readFloat()
                    )
                    keyframes.append(WPEPuppetAnimKey(
                        frame: frame,
                        translation: translation,
                        euler: euler,
                        scale: scale
                    ))
                }
                channels.append(WPEPuppetAnimChannel(boneIndex: channelIndex, keyframes: keyframes))

                if channelIndex + 1 < channelCountInt {
                    let delimiterMarker = try reader.readUInt32()
                    let delimiterByteCount = try reader.readUInt32()
                    guard delimiterMarker == 0, delimiterByteCount == channelByteCount else {
                        throw WPEMdlParserError.invalidAnimationChannelDelimiter(
                            animationID: Int(id),
                            channelIndex: channelIndex,
                            marker: delimiterMarker,
                            byteCount: delimiterByteCount,
                            expected: channelByteCount
                        )
                    }
                }
            }

            let tail = try parseAnimationTail(
                mdlaVersion: mdlaVersion,
                frameCount: frameCount,
                boneCount: channelCountInt,
                sectionEnd: sectionEnd,
                hasFollowingAnimation: animationIndex + 1 < animationCount,
                reader: &reader
            )
            animations.append(WPEPuppetAnimation(
                id: Int(id),
                name: name,
                mode: mode,
                fps: fps,
                frameCount: Int(frameCount),
                channels: channels,
                sourceRange: animationStart..<reader.currentOffset,
                tail: tail
            ))
        }

        if reader.currentOffset + MemoryLayout<UInt32>.size == sectionEnd {
            let finalPaddingStart = reader.currentOffset
            let finalPadding = try reader.readUInt32()
            guard finalPadding == 0 else {
                throw WPEMdlParserError.invalidAnimationTail(offset: finalPaddingStart)
            }
            auditRecorder?.recordKnownSkip(
                label: "MDLA final padding",
                range: finalPaddingStart..<reader.currentOffset
            )
        }
        guard reader.currentOffset == sectionEnd else {
            throw WPEMdlParserError.invalidAnimationTail(offset: reader.currentOffset)
        }
        auditRecorder?.endSection(at: reader.currentOffset)
        return animations
    }
}

private enum WPEMdlMeshFlags {
    static let normal: UInt32 = 0x2
    static let tangent: UInt32 = 0x4
    static let uv: UInt32 = 0x8
    static let uv2: UInt32 = 0x20
    static let extra4: UInt32 = 0x10000
    static let skinBlendIndices: UInt32 = 0x800000
    static let skinBlendWeights: UInt32 = 0x1000000
}

public enum WPEMdlParserError: Error, Equatable, Sendable {
    case invalidHeader
    case implausibleCount(section: String, count: UInt32, limit: UInt32)
    case truncated(offset: Int, requested: Int, available: Int)
    case unterminatedString(offset: Int)
    case invalidString(offset: Int)
    case unsupportedSectionMarker(UInt8)
    case invalidPartTable(UInt32)
    case invalidVertexBuffer(byteCount: UInt32, stride: Int)
    case invalidIndexBuffer(UInt32)
    case invalidSkeletonMatrix(UInt32)
    case invalidElementMatrixPayload(actual: UInt32, expected: UInt32)
    case invalidAttachmentHeader(offset: Int)
    case invalidAnimationHeader(offset: Int)
    case invalidAnimationTail(offset: Int)
    case invalidAnimationChannelByteCount(animationID: Int, byteCount: UInt32, expected: UInt32)
    case invalidAnimationChannelDelimiter(
        animationID: Int,
        channelIndex: Int,
        marker: UInt32,
        byteCount: UInt32,
        expected: UInt32
    )
}

private struct WPEMdlBinaryReader {
    private let data: Data
    private var offset: Int = 0

    var currentOffset: Int {
        offset
    }

    var dataCount: Int {
        data.count
    }

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw WPEMdlParserError.truncated(offset: offset, requested: 1, available: data.count)
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let b0 = UInt16(try readUInt8())
        let b1 = UInt16(try readUInt8())
        return b0 | (b1 << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let b0 = UInt32(try readUInt8())
        let b1 = UInt32(try readUInt8())
        let b2 = UInt32(try readUInt8())
        let b3 = UInt32(try readUInt8())
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readFixedString(byteCount: Int) throws -> String {
        let start = offset
        try ensureAvailable(byteCount: byteCount)
        offset += byteCount
        let bytes = data[start..<offset].prefix { $0 != 0 }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw WPEMdlParserError.invalidString(offset: start)
        }
        return string
    }

    mutating func readCString() throws -> String {
        let start = offset
        while offset < data.count, data[offset] != 0 {
            offset += 1
        }
        guard offset < data.count else {
            throw WPEMdlParserError.unterminatedString(offset: start)
        }
        let bytes = data[start..<offset]
        offset += 1
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw WPEMdlParserError.invalidString(offset: start)
        }
        return string
    }

    /// Section-bounded `readCString`. A malformed/truncated name whose terminator
    /// lies past `sectionEnd` fails fast on the existing `unterminatedString`
    /// path instead of scanning (and UTF-8 decoding) the rest of the file.
    mutating func readCString(sectionEnd: Int) throws -> String {
        let start = offset
        let limit = min(sectionEnd, data.count)
        while offset < limit, data[offset] != 0 {
            offset += 1
        }
        guard offset < limit else {
            throw WPEMdlParserError.unterminatedString(offset: start)
        }
        let bytes = data[start..<offset]
        offset += 1
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw WPEMdlParserError.invalidString(offset: start)
        }
        return string
    }

    mutating func skip(byteCount: Int) throws {
        try ensureAvailable(byteCount: byteCount)
        offset += byteCount
    }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw WPEMdlParserError.truncated(
                offset: newOffset,
                requested: 0,
                available: data.count
            )
        }
        offset = newOffset
    }

    func peekUInt32(relativeOffset: Int = 0) -> UInt32? {
        readUInt32(at: offset + relativeOffset)
    }

    func data(in range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            throw WPEMdlParserError.truncated(
                offset: range.lowerBound,
                requested: range.count,
                available: data.count
            )
        }
        return Data(data[range])
    }

    private func readUInt32(at absoluteOffset: Int) -> UInt32? {
        guard absoluteOffset >= 0, absoluteOffset + 4 <= data.count else { return nil }
        return UInt32(data[absoluteOffset])
            | (UInt32(data[absoluteOffset + 1]) << 8)
            | (UInt32(data[absoluteOffset + 2]) << 16)
            | (UInt32(data[absoluteOffset + 3]) << 24)
    }

    func findTag(_ tag: String, from start: Int) -> Int? {
        let bytes = Data(tag.utf8)
        return data.range(of: bytes, options: [], in: start..<data.count)?.lowerBound
    }

    private func ensureAvailable(byteCount: Int) throws {
        guard byteCount >= 0, offset + byteCount <= data.count else {
            throw WPEMdlParserError.truncated(
                offset: offset,
                requested: byteCount,
                available: data.count
            )
        }
    }
}
