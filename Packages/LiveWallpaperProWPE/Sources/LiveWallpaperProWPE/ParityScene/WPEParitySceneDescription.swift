/// Material `blending` of a draw; `.normal` is WPE's ONE/ZERO (blending off).
public enum WPEParitySceneBlend: String, Hashable, Sendable {
    case normal
    case translucent
    case additive
    case alphaToCoverage = "alphatocoverage"

    public init(material raw: String?) {
        switch raw?.lowercased() {
        case "translucent": self = .translucent
        case "additive": self = .additive
        case "alphatocoverage": self = .alphaToCoverage
        default: self = .normal
        }
    }

    /// FUN_140099f60 treats material modes 0/3 alike only for depth-write eligibility, not pixel coverage.
    var permitsDepthWrite: Bool {
        self == .normal || self == .alphaToCoverage
    }
}

public enum WPEParitySceneWriteMask: Hashable, Sendable {
    case rgba
    case rgb
}

/// What binding a material pass sets besides blending (140155fc0.c:713-738); an absent key keeps WPE's baseline.
public struct WPEParitySceneMaterialState: Hashable, Sendable {
    public enum AlphaWriting: Hashable, Sendable {
        /// `"default"`: the draw keeps the mask of the target it lands in.
        case inherit
        case enabled
        case disabled
    }

    public var depthTest: Bool
    public var depthWrite: Bool
    /// False for `cullmode` `nocull`.
    public var cullsBackFaces: Bool
    public var alphaWriting: AlphaWriting

    public init(depthTest: Bool = true, depthWrite: Bool = true, cullsBackFaces: Bool = true,
                alphaWriting: AlphaWriting = .inherit) {
        self.depthTest = depthTest
        self.depthWrite = depthWrite
        self.cullsBackFaces = cullsBackFaces
        self.alphaWriting = alphaWriting
    }
}

public enum WPEParitySceneDiagnostic: Hashable, Sendable {
    /// A block-compressed effect FBO format, which cannot be a render target; the FBO is allocated as `rgba8unorm`.
    case compressedFBOFormat(fbo: String, format: String)
    /// A particle child omitted by the current depth-8/cycle product policy (native permits depth 0...10).
    case particleChildOmitted(objectID: String, path: String)
    /// A new nested branch outside the bounded local/static contract; healthy siblings remain accepted.
    case particleChildUnsupported(objectID: String, path: [WPEParityParticlePathElement],
                                  asset: String, field: String, reason: String)
}

/// The material JSON pass a draw comes from, and for an effect pass the effect file pass that names it.
public struct WPEParitySceneMaterialSource: Hashable, Sendable {
    public var materialPath: String
    /// Index into the material's `passes`.
    public var materialPass: Int
    public var effectFile: String?
    /// Index into the effect file's `passes`, commands included.
    public var effectPass: Int?
    /// Combos the engine adds to the pass JSON for this draw.
    public var combos: [String: Int]
    /// Shader the engine draws with instead of the pass JSON's, such as a rope-only particle system's.
    public var shader: String?
    /// Texture names the engine sets on the material's slots for this draw.
    public var textures: [Int: String]

    public init(materialPath: String, materialPass: Int = 0, effectFile: String? = nil, effectPass: Int? = nil,
                combos: [String: Int] = [:], shader: String? = nil, textures: [Int: String] = [:]) {
        self.materialPath = materialPath
        self.materialPass = materialPass
        self.effectFile = effectFile
        self.effectPass = effectPass
        self.combos = combos
        self.shader = shader
        self.textures = textures
    }

    public static let composeLayer = WPEParitySceneMaterialSource(materialPath: "materials/util/composelayer.json")

    /// The clip mask merge (14020d6a0.c:147).
    public static let flatTexture = WPEParitySceneMaterialSource(materialPath: "materials/util/flattexture.json")

    /// genericimage4 with the combos FUN_140206ae0 adds; FOG_COMPUTED (and FOG, which the pass JSON never sets) goes
    /// when the layer material's own program (`layerFog`) has no FOG ≠ 0. Material flag 0x18 (LIGHTING/REFLECTION=0)
    /// is not modelled: the document does not carry it.
    public static func layerPassthrough(colorBlendMode: Int, layerFog: Bool,
                                        puppet: WPEParityScenePuppet? = nil) -> WPEParitySceneMaterialSource {
        var combos = ["BLENDMODE": colorBlendMode == 31 ? 0 : colorBlendMode]
        if layerFog {
            combos["FOG_COMPUTED"] = 1
        }
        combos.merge(puppet?.skinningCombos ?? [:]) { _, new in new }
        return WPEParitySceneMaterialSource(materialPath: "materials/util/effectpassthrough_4.json", combos: combos)
    }

    /// basefont(_depth) for grey glyphs, basefontrgba(_depth) for colour glyphs (1401b3430.c:145-244).
    public static func textGlyphs(_ atlas: WPEParityGlyphAtlasInstance.Atlas, depth: Bool,
                                  mode: WPEParityTextGlyphMode = .bitmap,
                                  combos: [String: Int] = [:]) -> WPEParitySceneMaterialSource {
        WPEParitySceneMaterialSource(materialPath: mode.materialPath(atlas: atlas, depth: depth), combos: combos)
    }

    public static func textBackground(depth: Bool) -> WPEParitySceneMaterialSource {
        WPEParitySceneMaterialSource(materialPath: "materials/fonts/fontbackground\(depth ? "_depth" : "").json")
    }

    public static let textClearAlpha = WPEParitySceneMaterialSource(
        materialPath: "materials/util/composelayer_clearalpha.json"
    )
}

/// A text layer's frame inputs: its fields, the layout with atlas UVs, and the values its draws derive from them.
public struct WPEParitySceneText: Hashable, Sendable {
    public var object: WPEParityTextObject
    public var layout: WPEParityTextLayout
    /// `WPEParityGlyphAtlasInstance.key` of the atlas the quad UVs index.
    public var atlasKey: String
    /// Enabled effects (+0x320) the layout was made with.
    public var effectCount: Int
    /// Parameters belong to the admitted mesh mode, not merely a JSON request.
    public var fieldParameters: WPEParityTextDrawParameters? {
        guard let mesh = layout.mesh, mesh.glyphMode == .distanceField else { return nil }
        return WPEParityTextDrawParameters(object: object, pointSize: mesh.pointSize)
    }

    /// p of the translations and the FBO size: min(padding, 512) with effects, bit4 or opaquebackground, else 0.
    public var padding: SIMD2<Float>
    /// Script `size` (+0x2f0): the float box + 2p, (2, 2) without a mesh (FUN_140258900).
    public var scriptSize: SIMD2<Float> {
        (layout.mesh.map { SIMD2($0.maxX - $0.minX, $0.top - $0.bottom) } ?? SIMD2(2, 2)) + padding * 2
    }

    /// Background colour × (HDR ? backgroundbrightness : 1) and the layer alpha (140258050.c:106-116).
    public var background: SIMD4<Float>
    /// The same background identity names the direct quad and the opaque composite clear.
    public var backgroundPass: WPEPassIdentity {
        WPEPassIdentity("\(object.id)/background")
    }

    /// Scene orthographic bit (C+0x118 & 0x400): only then does the anchor move the layer.
    public var orthographic: Bool
    /// Perspective scene with depthtest enabled: the `_depth` font materials (140258050.c:119-128).
    public var depthMaterials: Bool

    public init(object: WPEParityTextObject, effectCount: Int, layout: WPEParityTextLayout, atlasKey: String,
                hdr: Bool, orthographic: Bool) {
        self.object = object
        self.layout = layout
        self.atlasKey = atlasKey
        self.effectCount = effectCount
        let input = object.layoutInput(effectCount: effectCount)
        padding = input.appliesPadding ? SIMD2(min(input.padding.x, 512), min(input.padding.y, 512)) : .zero
        let brightness = hdr ? object.backgroundBrightness : 1
        background = SIMD4(object.backgroundColor * brightness, object.alpha)
        self.orthographic = orthographic
        depthMaterials = !orthographic && object.depthTest == .enabled
    }
}

/// Mesh0 of an image layer's model JSON `"puppet"` (FUN_1401fbae0): positions go straight into the layer MVP.
public struct WPEParityScenePuppet: Hashable, Sendable {
    public var vertices: [WPEPuppetVertex]
    public let vertexStream: WPEPuppetVertexStream?
    public var indices: [UInt16]
    public let parts: [WPEPuppetMeshPart]
    /// Stable part-table indices, supplied by the animation sort consumer when its order actually changes.
    public private(set) var partOrder: [Int]
    public private(set) var clipGeneration: UInt64 = 0
    /// MDLS bone count; BONECOUNT and the length of `g_Bones`.
    public var boneCount: Int
    /// FUN_1402076e0: mesh0's format has bone indices (0x800000) and the model has bones.
    public var skinned: Bool
    /// Mesh0 flag bit 2 enables the native g_BonesAlpha path, independently of MORPHING.
    public var skinningAlpha: Bool
    /// Mesh0's float4 position (format 0x10000), whose w is the 1-based morph texel index.
    public var morphing: Bool {
        vertexStream.map { $0.layout.format & 0x10000 != 0 } ?? false
    }

    /// puppet+0x390, the first mesh with flag & 2 (1401fbae0.c:237-238); WPE builds a second mesh from it.
    public var blendMeshIndex: Int?
    /// Texture 0 of the layer material, which the clip mask draws sample (14020d6a0.c:44).
    public var albedoTexture: String?
    public var clipGroups: [WPEParityPuppetClipGroup]
    /// FUN_14020b720's sub-meshes: segment k draws `clipIndices[clipSegments[k]]`.
    public var clipIndices: [UInt16]
    public var clipSegments: [Range<Int>]
    /// puppet+0x430; empty without clip groups, where the whole mesh draws at once.
    public var clipOperations: [WPEParityPuppetClipOperation]

    public init(vertices: [WPEPuppetVertex], indices: [UInt16], boneCount: Int, skinned: Bool,
                blendMeshIndex: Int? = nil, parts: [WPEPuppetMeshPart] = [],
                clipGroups: [WPEParityPuppetClipGroup] = [], vertexStream: WPEPuppetVertexStream? = nil,
                skinningAlpha: Bool = false) {
        self.vertices = vertices
        self.vertexStream = vertexStream
        self.indices = indices
        self.parts = parts
        partOrder = Array(parts.indices)
        self.boneCount = boneCount
        self.skinned = skinned
        self.skinningAlpha = skinningAlpha
        self.blendMeshIndex = blendMeshIndex
        self.clipGroups = clipGroups
        (clipIndices, clipSegments, clipOperations) = Self.clipPlan(parts: parts, groups: clipGroups, indices: indices)
    }

    /// Rebuild only when the sorted order changes. Invalid/duplicate entries are ignored and unauthored entries
    /// keep their original relative order; no per-frame vertex stream or shader rebuild is required.
    @discardableResult
    public mutating func setPartOrder(_ order: [Int]) -> Bool {
        let order = Self.normalizedPartOrder(order, count: parts.count)
        guard order != partOrder else { return false }
        partOrder = order
        (clipIndices, clipSegments, clipOperations) = Self.clipPlan(parts: parts, groups: clipGroups, indices: indices,
                                                                    partOrder: order)
        clipGeneration &+= 1
        return true
    }

    private static func normalizedPartOrder(_ order: [Int], count: Int) -> [Int] {
        var seen: Set<Int> = []
        let accepted = order.filter { (0 ..< count).contains($0) && seen.insert($0).inserted }
        return accepted + (0 ..< count).filter { !seen.contains($0) }
    }

    /// FUN_14020b720 over the part table in file order, which is the draw order while no animation reorders it
    /// (1401fdf90.c:4434-4470). A segment concatenates the index ranges of its parts (14020c710).
    static func clipPlan(parts: [WPEPuppetMeshPart], groups: [WPEParityPuppetClipGroup], indices: [UInt16],
                         partOrder: [Int]? = nil)
        -> (indices: [UInt16], segments: [Range<Int>], operations: [WPEParityPuppetClipOperation]) {
        guard !groups.isEmpty else { return ([], [], []) }
        let order = normalizedPartOrder(partOrder ?? Array(parts.indices), count: parts.count)
        // 14020ae00.c:289-314: bit0 clipped, bit2 clipped in a group with flag 8, bit3 mask part.
        var partFlags = [UInt32](repeating: 0, count: parts.count)
        for group in groups {
            for part in group.clipped where parts.indices.contains(part) {
                partFlags[part] |= group.flags & 8 != 0 ? 5 : 1
            }
            for part in group.mask where parts.indices.contains(part) {
                partFlags[part] |= 8
            }
        }
        struct Record {
            let group: Int
            var firstClipped = Int.max
            var firstMask = -1
            var lastMask = -1
            var clipped: [Int] = []
            var maskSegment: [Int] = []
        }
        var records: [Record] = []
        var groupOfPart: [Int: Int] = [:]
        var hidden: Set<Int> = []
        for (index, group) in groups.enumerated() {
            var record = Record(group: index)
            for (position, part) in order.enumerated() {
                if group.clipped.contains(part) {
                    record.clipped.append(part)
                    record.firstClipped = min(record.firstClipped, position)
                    groupOfPart[part] = index
                }
                if group.mask.contains(part) {
                    record.firstMask = record.firstMask < 0 ? position : record.firstMask
                    record.lastMask = position
                    if group.flags & 4 != 0 {
                        hidden.insert(part)
                    }
                }
            }
            // The mask draws every part between the first and last mask part that the group does not clip.
            record.maskSegment = record.firstMask < 0 ? []
                : order[record.firstMask ... record.lastMask].filter { !record.clipped.contains($0) }
            records.append(record)
        }
        for index in records.indices {
            var parent = groups[index].parent
            var seen: Set<Int> = [index]
            while let ancestor = parent, groups.indices.contains(ancestor), seen.insert(ancestor).inserted {
                records[index].lastMask = max(records[index].lastMask, records[ancestor].lastMask)
                parent = groups[ancestor].parent
            }
        }
        // Stable sort on the first clipped part (comparator at 0x1401fac40).
        records = records.enumerated().sorted { ($0.element.firstClipped, $0.offset) < ($1.element.firstClipped, $1.offset) }
            .map(\.element)

        var clipIndices: [UInt16] = []
        var segments: [Range<Int>] = []
        enum PlannedOperation {
            case segment(Int)
            case clip(group: Int, segment: Int)
        }
        var planned: [PlannedOperation] = []
        var maskSegments: [Int: Int] = [:]
        var pending: [Int] = []
        func segment(_ list: [Int]) -> Int {
            let start = clipIndices.count
            for part in list {
                let range = parts[part].start ..< parts[part].start + parts[part].count
                clipIndices += indices[range.clamped(to: indices.indices)]
            }
            segments.append(start ..< clipIndices.count)
            return segments.count - 1
        }
        func flush() {
            guard !pending.isEmpty else { return }
            planned.append(.segment(segment(pending)))
            pending.removeAll()
        }
        // 14020cab0: the mask segment, the clipped segment, then op 1, or op 2 with each ancestor's mask segment.
        func clip(_ record: Record, _ clipped: [Int]) {
            let mask = segment(record.maskSegment)
            maskSegments[record.group] = mask
            _ = segment(clipped)
            planned.append(.clip(group: record.group, segment: mask))
        }
        for (position, part) in order.enumerated() {
            let flags = partFlags[part]
            if flags & 1 == 0 {
                if !hidden.contains(part) {
                    pending.append(part)
                }
            } else if flags & 0xC == 0 {
                continue
            }
            if flags & 8 == 0 {
                // A run of parts clipped by the same flag-8 group draws where its first part sits; WPE starts a
                // new run at every part of it.
                guard flags & 4 != 0, let group = groupOfPart[part],
                      let record = records.first(where: { $0.group == group }) else { continue }
                let run = order[position...].prefix { groupOfPart[$0] == group }
                flush()
                clip(record, Array(run))
            } else {
                for record in records where groups[record.group].flags & 8 == 0 && record.lastMask == position {
                    flush()
                    clip(record, record.clipped)
                }
            }
        }
        flush()
        // All identities exist before resolving ancestry, including a parent whose clipped operation comes later
        // (or whose own target is absent). Ancestors consume mask geometry, not the parent's target segment.
        let usedGroups = planned.compactMap { operation -> Int? in
            if case let .clip(group, _) = operation {
                return group
            }
            return nil
        }
        for group in usedGroups {
            var parent = groups[group].parent
            var seen: Set<Int> = [group]
            while let ancestor = parent, groups.indices.contains(ancestor), seen.insert(ancestor).inserted {
                if maskSegments[ancestor] == nil, let record = records.first(where: { $0.group == ancestor }) {
                    maskSegments[ancestor] = segment(record.maskSegment)
                }
                parent = groups[ancestor].parent
            }
        }
        let operations: [WPEParityPuppetClipOperation] = planned.map { operation in
            switch operation {
            case let .segment(index): return .segment(index)
            case let .clip(group, index):
                var ancestors: [WPEParityPuppetClipOperation.Mask] = []
                var parent = groups[group].parent
                var seen: Set<Int> = [group]
                while let ancestor = parent, groups.indices.contains(ancestor), seen.insert(ancestor).inserted {
                    if let mask = maskSegments[ancestor] {
                        ancestors.append(.init(group: ancestor, segment: mask))
                    }
                    parent = groups[ancestor].parent
                }
                return .clip(group: group, ancestors: ancestors, segment: index)
            }
        }
        return (clipIndices, segments, operations)
    }

    /// WPE uploads the index bytes as R16_UINT, bytes / 2 of them (14020ae00.c:77, 14009a880 arg 7 = 0), so
    /// a u32 index buffer reads as its low and high halves.
    public static func indices(of mesh: WPEPuppetMesh) -> [UInt16] {
        switch mesh.indexElementWidth {
        case .uint16: mesh.indices.map { UInt16(truncatingIfNeeded: $0) }
        case .uint32: mesh.indices.flatMap { [UInt16(truncatingIfNeeded: $0), UInt16(truncatingIfNeeded: $0 >> 16)] }
        }
    }

    /// FUN_140207710.
    public var skinningCombos: [String: Int] {
        guard skinned else { return [:] }
        var combos = ["SKINNING": 1, "BONECOUNT": boneCount]
        if skinningAlpha {
            combos["SKINNING_ALPHA"] = 1
        }
        if morphing {
            combos["MORPHING"] = 1
        }
        return combos
    }
}

/// One MDLV clip group of mesh0 (140261880.c:342-530), indices into the part table.
public struct WPEParityPuppetClipGroup: Hashable, Sendable {
    /// Entry +0x8: parts drawn only inside the mask.
    public var clipped: [Int]
    /// Entry +0x20: parts that shape the mask.
    public var mask: [Int]
    /// Entry +0x44: bit0 additive clipped draw, bit1 inverted mask, bit2 mask parts not drawn themselves, bit3 clipped
    /// parts draw where they sit instead of after the last mask part.
    public var flags: UInt32
    /// Entry +0x38, the texture the mask draw samples in slot 1.
    public var maskTexture: String
    /// Entry +0x48.
    public var parent: Int?

    public init(clipped: [Int], mask: [Int], flags: UInt32 = 0, maskTexture: String, parent: Int? = nil) {
        self.clipped = clipped
        self.mask = mask
        self.flags = flags
        self.maskTexture = maskTexture
        self.parent = parent
    }

    /// The parent is the first other group that clips every mask part of this one; a link closing a cycle is dropped
    /// (140261880.c:540-631).
    public static func groups(of mesh: WPEPuppetMesh) -> [WPEParityPuppetClipGroup] {
        var groups = mesh.clipGroups.map {
            WPEParityPuppetClipGroup(clipped: $0.targetPartIndices, mask: $0.sourcePartIndices,
                                     flags: $0.flags, maskTexture: $0.maskName)
        }
        guard groups.count > 1 else { return groups }
        for index in groups.indices where !groups[index].mask.isEmpty {
            groups[index].parent = groups.indices.first { other in
                other != index && groups[index].mask.allSatisfy(groups[other].clipped.contains)
            }
            var seen: Set<Int> = []
            var next = groups[index].parent
            while let current = next {
                guard seen.insert(current).inserted else {
                    groups[index].parent = nil
                    break
                }
                next = groups[current].parent
            }
        }
        return groups
    }
}

/// One entry of puppet+0x430 as FUN_140208670 draws it.
public enum WPEParityPuppetClipOperation: Hashable, Sendable {
    public struct Mask: Hashable, Sendable {
        public let group: Int
        public let segment: Int
    }

    /// Op 0: the segment with the layer material.
    case segment(Int)
    /// Op 1 (no ancestors) or op 2: each ancestor's mask, then the group's own from `segment`, multiplied into
    /// `_rt_FullAlphaMask`; then the clipped parts, segment `segment + 1`, through it.
    case clip(group: Int, ancestors: [Mask], segment: Int)
}

/// What one frame of the WPE scene loop needs to know; everything else (uniforms, meshes) stays with the caller.
public struct WPEParitySceneDescription: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// Backbuffer, `_rt_FullFrameBuffer` and the multisampled scene target; HDR scenes use `rgba16float`.
    public var backbufferFormat: String
    public var clearColor: SIMD3<Double>
    public var clearEnabled: Bool
    /// 1 renders straight into the backbuffer; more routes through `_rt_FullFrameBufferMultiSampled`.
    public var msaaSamples: Int
    /// `general.transparentsorting` in a perspective scene: transparent members draw after every other root, in
    /// `transparentOrder`.
    public var transparentSorting: Bool
    /// Member ids as the scene state last sorted them; empty keeps members in paint order.
    public var transparentOrder: [String]
    /// Global fog flags 0x1800000 (`general.fogdistance` / `fogheight`) send every layer through its own `_a` composite.
    public var forcesLayerComposite: Bool
    /// The frame runs WPE's shadow pass into `_rt_shadowAtlas` before RenderScene.
    public var shadowAtlas: Bool
    public var objects: [WPEParitySceneObject]
    public var diagnostics: [WPEParitySceneDiagnostic]

    public init(width: Int, height: Int, backbufferFormat: String = WPEParitySceneResource.colorFormat,
                clearColor: SIMD3<Double> = .zero, clearEnabled: Bool = true,
                msaaSamples: Int = 1, transparentSorting: Bool = false, transparentOrder: [String] = [],
                forcesLayerComposite: Bool = false, shadowAtlas: Bool = false,
                objects: [WPEParitySceneObject], diagnostics: [WPEParitySceneDiagnostic] = []) {
        self.width = width
        self.height = height
        self.backbufferFormat = backbufferFormat
        self.clearColor = clearColor
        self.clearEnabled = clearEnabled
        self.msaaSamples = msaaSamples
        self.transparentSorting = transparentSorting
        self.transparentOrder = transparentOrder
        self.forcesLayerComposite = forcesLayerComposite
        self.shadowAtlas = shadowAtlas
        self.objects = objects
        self.diagnostics = diagnostics
    }
}

public struct WPEParitySceneObject: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case image
        /// A `.mdl` model; its sub-mesh materials come from the model file and it takes no effects.
        case model(WPEParitySceneModel)
        /// A particle system; it draws only its renderer entries and takes no composite or effects.
        case particle(WPEParitySceneParticle)
        /// A text layer: glyph draws straight into the destination, or into its FBO ahead of its effects.
        case text(WPEParitySceneText)
        /// `"shape": "quad"` (FUN_14025faf0): only its last effect's passes draw, with no albedo or composite.
        case shape(WPEParitySceneShape)
    }

    public var id: String
    public var kind: Kind
    /// obj+0x124; ties keep input order.
    public var sortKey: Int
    public var visible: Bool
    public var width: Int
    public var height: Int
    public var materialShader: String
    /// Material pass of the albedo (or model) draw.
    public var material: WPEParitySceneMaterialSource?
    /// Layer material blend used where the layer lands in the scene or its parent composite.
    public var blend: WPEParitySceneBlend
    /// Depth, cull and alpha-write state of the albedo (or model) material pass.
    public var materialState: WPEParitySceneMaterialState
    /// The albedo material's combos, shader defaults included, set FOG ≠ 0.
    public var materialFog: Bool
    public var colorBlendMode: Int
    public var passthrough: Bool
    public var copyBackground: Bool
    public var fullscreen: Bool
    public var ledSource: Bool
    /// FUN_14020ae00 set bit4 for the layer's puppet.
    public var puppetForcesComposite: Bool
    public var puppet: WPEParityScenePuppet?
    /// Layer `nointerpolation` or albedo TEXI flag bit0: the layer's composites sample with point filtering.
    public var noInterpolation: Bool
    /// Layer `clampuvs` (WPE default on): the layer's composites clamp instead of wrap.
    public var clampUVs: Bool
    public var parentID: String?
    public var effects: [WPEParitySceneEffect]
    /// Another object's `"dependencies"` names this image or text layer: flags304 0x1010 gives it an `_a` composite,
    /// which it keeps rendering while hidden; only the draw into the scene stops (140186c90.c:783-788, 1401ea2d0).
    public var dependencyTarget: Bool
    /// Frame resources (`_rt_*` names the frame builds) each albedo or model material samples, keyed by material path.
    public var materialFrameReads: [String: [WPEResourceID]]
    /// Common flag 0x100: in the scene's transparent member vector (14018ff60.c:347-350).
    public var transparentMember: Bool

    public init(id: String, kind: Kind = .image, sortKey: Int = 0, visible: Bool = true, width: Int, height: Int,
                materialShader: String = "genericimage2", material: WPEParitySceneMaterialSource? = nil,
                blend: WPEParitySceneBlend = .translucent,
                materialState: WPEParitySceneMaterialState = WPEParitySceneMaterialState(), materialFog: Bool = false,
                colorBlendMode: Int = 0, passthrough: Bool = false, copyBackground: Bool = true,
                fullscreen: Bool = false, ledSource: Bool = false, puppetForcesComposite: Bool = false,
                puppet: WPEParityScenePuppet? = nil, noInterpolation: Bool = false, clampUVs: Bool = true,
                parentID: String? = nil, effects: [WPEParitySceneEffect] = [], dependencyTarget: Bool = false,
                materialFrameReads: [String: [WPEResourceID]] = [:], transparentMember: Bool = false) {
        self.id = id
        self.kind = kind
        self.sortKey = sortKey
        self.visible = visible
        self.width = width
        self.height = height
        self.materialShader = materialShader
        self.material = material
        self.blend = blend
        self.materialState = materialState
        self.materialFog = materialFog
        self.colorBlendMode = colorBlendMode
        self.passthrough = passthrough
        self.copyBackground = copyBackground
        self.fullscreen = fullscreen
        self.ledSource = ledSource
        self.puppetForcesComposite = puppetForcesComposite
        self.puppet = puppet
        self.noInterpolation = noInterpolation
        self.clampUVs = clampUVs
        self.parentID = parentID
        self.effects = effects
        self.dependencyTarget = dependencyTarget
        self.materialFrameReads = materialFrameReads
        self.transparentMember = transparentMember
    }

    /// Layer bit4 (1401e6f50.c:24-29), without the global 0x1800000 flag.
    public var requiresLayerComposite: Bool {
        ![0, 31].contains(colorBlendMode) || ledSource || puppetForcesComposite
    }

    /// A text layer sized to its FBO. Its glyphs blend translucent, additive for colorBlendMode 31; its bit4
    /// composite gets FOG_COMPUTED and, with the `_depth` materials, a depth test (140257840.c:28-124).
    /// Always a transparent member (constructor 140256ae0).
    public static func text(_ text: WPEParitySceneText, sortKey: Int = 0, visible: Bool = true,
                            parentID: String? = nil, effects: [WPEParitySceneEffect] = []) -> Self {
        let colorBlendMode = text.object.colorBlendMode
        return WPEParitySceneObject(
            id: text.object.id, kind: .text(text), sortKey: sortKey, visible: visible,
            width: text.layout.fboSize.x, height: text.layout.fboSize.y, materialShader: "font",
            material: .textGlyphs(.mono, depth: text.depthMaterials),
            blend: colorBlendMode == 31 ? .additive : .translucent,
            materialState: WPEParitySceneMaterialState(depthTest: text.depthMaterials, depthWrite: false,
                                                       cullsBackFaces: false),
            materialFog: true, colorBlendMode: colorBlendMode, parentID: parentID, effects: effects,
            transparentMember: true
        )
    }
}

/// The mesh a shape quad's last pass draws (FUN_140260190), stride float3 + float2 like every WPE quad.
public struct WPEParitySceneShape: Hashable, Sendable {
    public struct Vertex: Hashable, Sendable {
        public var position: SIMD3<Float>
        public var texcoord: SIMD2<Float>
    }

    /// `point0`–`point3` of the first effect's first material pass, when its shader declares all four.
    public var points: [SIMD2<Float>]?

    public init(points: [SIMD2<Float>]? = nil) {
        self.points = points
    }

    /// The four points at (w·p.x − w/2, h·(1 − p.y) − h/2) with uv p, or the centred w×h quad of FUN_1401ede30 with
    /// flags 1 (no inset).
    public func vertices(width: Float, height: Float) -> [Vertex] {
        let corners = points ?? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        return corners.map { point in
            Vertex(position: SIMD3(width * point.x - width / 2, height * (1 - point.y) - height / 2, 0),
                   texcoord: point)
        }
    }

    /// 140260190.c:208-210 and 1401ede30.c:90-92: the point quad is a fan around point0, the default quad two strips.
    public var indices: [UInt16] {
        points == nil ? [0, 2, 1, 1, 2, 3] : [0, 2, 1, 0, 3, 2]
    }
}

/// One step from a particle system to a static child or to every active instance of an event group.
public enum WPEParityParticlePathElement: Hashable, Sendable {
    case staticChild(Int)
    case eventGroup(Int)
}

/// A renderer-entry prototype. An event segment can address more than one actual system instance.
public struct WPEParityParticleDrawKey: Hashable, Sendable {
    public var objectID: String
    public var path: [WPEParityParticlePathElement]
    /// Index into the drawn system's `renderers`.
    public var renderer: Int

    public init(objectID: String, path: [WPEParityParticlePathElement], renderer: Int) {
        self.objectID = objectID
        self.path = path
        self.renderer = renderer
    }

    /// Compatibility for the original static-prefix / terminal-event address. `path` is the sole stored address.
    public init(objectID: String, node: [Int] = [], renderer: Int, eventGroup: Int? = nil) {
        self.init(objectID: objectID,
                  path: node.map(WPEParityParticlePathElement.staticChild)
                      + (eventGroup.map { [.eventGroup($0)] } ?? []), renderer: renderer)
    }

    /// Keeps existing pass identities while distinguishing ordered mixed paths such as /0/e1 and /e1/0.
    public var passIdentity: WPEPassIdentity {
        let suffix = path.map { element in
            switch element {
            case let .staticChild(index): "/\(index)"
            case let .eventGroup(index): "/e\(index)"
            }
        }.joined()
        return WPEPassIdentity("\(objectID)/particle\(suffix)/r\(renderer)")
    }
}

/// A particle object's draws in WPE order: a system's entries in JSON order, then its static children depth
/// first, then one group per event child.
public struct WPEParitySceneParticle: Hashable, Sendable {
    public var draws: [WPEParitySceneParticleDraw]

    public init(draws: [WPEParitySceneParticleDraw]) {
        self.draws = draws
    }
}

public struct WPEParitySceneParticleDraw: Hashable, Sendable {
    public var key: WPEParityParticleDrawKey
    public var shader: String
    /// Pass 0 of the system's `material`, with the entry's combos and the rope-only shader override.
    public var source: WPEParitySceneMaterialSource
    public var blend: WPEParitySceneBlend
    public var materialState: WPEParitySceneMaterialState
    /// REFRACT: the pass samples `_rt_FullFrameBuffer`.
    public var readsFullFrameBuffer: Bool
    /// Particle JSON `flags` bit0 and bit2.
    public var worldSpace: Bool
    public var perspective: Bool

    public init(key: WPEParityParticleDrawKey, shader: String, source: WPEParitySceneMaterialSource,
                blend: WPEParitySceneBlend, materialState: WPEParitySceneMaterialState,
                readsFullFrameBuffer: Bool = false, worldSpace: Bool = false, perspective: Bool = false) {
        self.key = key
        self.shader = shader
        self.source = source
        self.blend = blend
        self.materialState = materialState
        self.readsFullFrameBuffer = readsFullFrameBuffer
        self.worldSpace = worldSpace
        self.perspective = perspective
    }
}

public struct WPEParitySceneEffect: Hashable, Sendable {
    public var id: String
    public var enabled: Bool
    public var passes: [WPEParityScenePass]
    public var fbos: [WPEParitySceneFBO]

    public init(id: String, enabled: Bool = true, passes: [WPEParityScenePass], fbos: [WPEParitySceneFBO] = []) {
        self.id = id
        self.enabled = enabled
        self.passes = passes
        self.fbos = fbos
    }
}

public struct WPEParityScenePass: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case draw
        /// Effect `copy` command into `target`; a `nil` source (or target) is the composite the next pass samples.
        case copy(source: String?)
        /// Effect command: exchange these FBO bindings before the following pass executes.
        case swap(first: String, second: String)
    }

    public var shader: String
    /// Name of an FBO declared by the effect; `nil` writes the ping-pong composite (or the layer's destination).
    public var target: String?
    /// Effect FBO names sampled besides the previous composite, which every pass samples.
    public var binds: [String]
    public var compose: Bool
    public var readsFullFrameBuffer: Bool
    public var blend: WPEParitySceneBlend
    public var kind: Kind
    /// Nil for a command.
    public var source: WPEParitySceneMaterialSource?
    /// `_rt_*` textures besides the effect's FBOs and `_rt_FullFrameBuffer`, such as another layer's composite.
    public var frameReads: [WPEResourceID]
    /// State of this pass's material before the layer's final-pass override (1401ebf60 / virtual +0x108).
    public var materialState: WPEParitySceneMaterialState

    public init(shader: String, target: String? = nil, binds: [String] = [], compose: Bool = false,
                readsFullFrameBuffer: Bool = false, blend: WPEParitySceneBlend = .normal, kind: Kind = .draw,
                source: WPEParitySceneMaterialSource? = nil, frameReads: [WPEResourceID] = [],
                materialState: WPEParitySceneMaterialState = .init()) {
        self.shader = shader
        self.target = target
        self.binds = binds
        self.compose = compose
        self.readsFullFrameBuffer = readsFullFrameBuffer
        self.blend = blend
        self.kind = kind
        self.source = source
        self.frameReads = frameReads
        self.materialState = materialState
    }
}

public struct WPEParitySceneFBO: Hashable, Sendable {
    public var name: String
    public var width: Int
    public var height: Int
    public var format: String
    /// Another layer reads or declares it: every effect resolves the name to one scene-wide resource.
    public var shared: Bool
    /// A set partner registers the FBO as persistent; ordered `.swap` passes, not this pair, drive the exchanges.
    public var swapPartner: String?
    /// `"unique": true`: WPE names it after the effect's scene id, so no other effect shares its texture.
    public var unique: Bool
    /// The extent before `scale` divides it (fit applied) and `scale`; with the name they key a non-unique FBO in
    /// WPE's scene-wide pool.
    public var unscaledSize: SIMD2<Int>
    public var scale: Int
    /// Original extent rule, retained so text relayout or viewport changes use the same conversion as first load.
    /// Nil for caller-created FBOs whose width and height are already absolute.
    public var sizing: WPEParitySceneFBOSizing?
    public var initialClear: WPEClearColor?
    /// A safe material function can address this FBO even when no draw operation uses it.
    public var scriptClearable: Bool
    public var repeats: Bool

    public init(name: String, width: Int, height: Int, format: String = "rgba8unorm", shared: Bool = false,
                swapPartner: String? = nil, unique: Bool = false, unscaledSize: SIMD2<Int>? = nil, scale: Int = 1,
                sizing: WPEParitySceneFBOSizing? = nil, initialClear: WPEClearColor? = nil,
                scriptClearable: Bool = false, repeats: Bool = false) {
        self.name = name
        self.width = width
        self.height = height
        self.format = format
        self.shared = shared
        self.swapPartner = swapPartner
        self.unique = unique
        self.unscaledSize = unscaledSize ?? SIMD2(width, height)
        self.scale = scale
        self.sizing = sizing
        self.initialClear = initialClear
        self.scriptClearable = scriptClearable
        self.repeats = repeats
    }
}

public struct WPEParitySceneFBOSizing: Hashable, Sendable {
    public var scale: Double
    public var fit: Double?
    public var width: Double?
    public var height: Double?
    /// Logical extent of the declaring layer, before explicit overrides, fit and divisor. Shared declarations
    /// retain their owner's extent even when another layer reads them. Nil for caller-created sizing rules.
    public var layerSize: SIMD2<Int>?

    public init(scale: Double = 1, fit: Double? = nil, width: Double? = nil, height: Double? = nil,
                layerSize: SIMD2<Int>? = nil) {
        self.scale = scale
        self.fit = fit
        self.width = width
        self.height = height
        self.layerSize = layerSize
    }
}
