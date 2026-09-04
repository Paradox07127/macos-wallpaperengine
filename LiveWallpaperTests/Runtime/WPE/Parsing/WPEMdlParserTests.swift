import Darwin
import Foundation
import LiveWallpaperProWPE
import Testing
import simd
@testable import LiveWallpaper

@Suite("WPE puppet animation evaluator")
struct WPEPuppetAnimationEvaluatorTests {
    private func animation(
        frameCount: Int,
        mode: String,
        channels: [WPEPuppetAnimChannel]
    ) -> WPEPuppetAnimation {
        WPEPuppetAnimation(id: 1, name: "a", mode: mode, fps: 30, frameCount: frameCount, channels: channels)
    }

    private func channel(_ keys: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) -> WPEPuppetAnimChannel {
        WPEPuppetAnimChannel(
            boneIndex: 0,
            keyframes: keys.enumerated().map { index, k in
                WPEPuppetAnimKey(frame: index, translation: k.0, euler: k.1, scale: k.2)
            }
        )
    }

    @Test("Frame 0 yields an identity palette (the bind pose, so the rest mesh is unchanged)")
    func frameZeroIsIdentity() {
        let anim = animation(frameCount: 2, mode: "loop", channels: [
            channel([
                (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
                (SIMD3(10, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
                (SIMD3(20, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
            ])
        ])
        let palette = WPEPuppetAnimationEvaluator.palette(layers: [WPEPuppetAnimationLayer(animation: anim, rate: 1, additive: false, blend: 1)], bones: [], at: 0)
        #expect(palette.count == 1)
        #expect(palette.allSatisfy { simd_equal($0, matrix_identity_float4x4) })
    }

    @Test("Frame-0 identity fast path requires proof for every base channel")
    func baseFrameMatchesRawBindStrictness() {
        let identityRaw: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let bone = WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: identityRaw)
        let restKey = WPEPuppetAnimKey(
            frame: 0, translation: .zero, euler: .zero, scale: SIMD3(1, 1, 1)
        )
        let matching = WPEPuppetAnimChannel(boneIndex: 0, keyframes: [restKey])
        #expect(WPEPuppetAnimationEvaluator.baseFrameMatchesRawBind(channels: [matching], bones: [bone]))

        let orphan = WPEPuppetAnimChannel(boneIndex: 5, keyframes: [restKey])
        #expect(!WPEPuppetAnimationEvaluator.baseFrameMatchesRawBind(
            channels: [matching, orphan], bones: [bone]
        ))

        let empty = WPEPuppetAnimChannel(boneIndex: 0, keyframes: [])
        #expect(!WPEPuppetAnimationEvaluator.baseFrameMatchesRawBind(channels: [empty], bones: [bone]))

        let assembled = WPEPuppetAnimChannel(boneIndex: 0, keyframes: [
            WPEPuppetAnimKey(frame: 0, translation: SIMD3(10, 0, 0), euler: .zero, scale: SIMD3(1, 1, 1))
        ])
        #expect(!WPEPuppetAnimationEvaluator.baseFrameMatchesRawBind(channels: [assembled], bones: [bone]))
    }

    @Test("Assembled bind-world uses frame-0 for character sheets, raw MDLS for pre-assembled")
    func assembledBindWorldPicksFrameZeroForCharacterSheet() {
        func rawBone(_ t: SIMD3<Float>) -> WPEPuppetBone {
            WPEPuppetBone(
                index: 0, parentIndex: nil,
                rawMatrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t.x, t.y, t.z, 1]
            )
        }
        func model(rawT: SIMD3<Float>, frame0T: SIMD3<Float>) -> WPEPuppetModel {
            let channel = WPEPuppetAnimChannel(boneIndex: 0, keyframes: [
                WPEPuppetAnimKey(frame: 0, translation: frame0T, euler: .zero, scale: SIMD3(1, 1, 1))
            ])
            return WPEPuppetModel(
                version: 19,
                meshes: [],
                bones: [rawBone(rawT)],
                animations: [WPEPuppetAnimation(id: 1, name: "a", mode: "loop", fps: 30, frameCount: 1, channels: [channel])]
            )
        }
        let sheet = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(
            model: model(rawT: SIMD3(287, -672, 0), frame0T: SIMD3(2, -108, 0))
        )
        #expect(sheet[0].map { simd_equal($0.columns.3, SIMD4<Float>(2, -108, 0, 1)) } == true)
        let assembled = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(
            model: model(rawT: SIMD3(287, -672, 0), frame0T: SIMD3(287, -672, 0))
        )
        #expect(assembled[0].map { simd_equal($0.columns.3, SIMD4<Float>(287, -672, 0, 1)) } == true)
    }

    @Test("Assembled bind-world composes parent-child, falls back on missing channel and on a cycle")
    func assembledBindWorldCompositionAndFallbacks() {
        func rawBone(_ index: Int, parent: Int?, _ t: SIMD3<Float>) -> WPEPuppetBone {
            WPEPuppetBone(
                index: index, parentIndex: parent,
                rawMatrix: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, t.x, t.y, t.z, 1]
            )
        }
        func chan(_ bone: Int, _ t: SIMD3<Float>) -> WPEPuppetAnimChannel {
            WPEPuppetAnimChannel(boneIndex: bone, keyframes: [
                WPEPuppetAnimKey(frame: 0, translation: t, euler: .zero, scale: SIMD3(1, 1, 1))
            ])
        }
        let model = WPEPuppetModel(
            version: 19, meshes: [],
            bones: [rawBone(0, parent: nil, SIMD3(1, 0, 0)),
                    rawBone(1, parent: 0, SIMD3(100, 0, 0))],
            animations: [WPEPuppetAnimation(
                id: 1, name: "a", mode: "loop", fps: 30, frameCount: 1,
                channels: [chan(0, SIMD3(10, 0, 0)), chan(1, SIMD3(5, 0, 0))]
            )]
        )
        let world = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(model: model)
        #expect(world[0].map { simd_equal($0.columns.3, SIMD4<Float>(10, 0, 0, 1)) } == true)
        #expect(world[1].map { simd_equal($0.columns.3, SIMD4<Float>(15, 0, 0, 1)) } == true)

        let missingChild = WPEPuppetModel(
            version: 19, meshes: [],
            bones: [rawBone(0, parent: nil, SIMD3(1, 0, 0)),
                    rawBone(1, parent: 0, SIMD3(100, 0, 0))],
            animations: [WPEPuppetAnimation(
                id: 1, name: "a", mode: "loop", fps: 30, frameCount: 1, channels: [chan(0, SIMD3(10, 0, 0))]
            )]
        )
        let missing = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(model: missingChild)
        #expect(missing[1].map { simd_equal($0.columns.3, SIMD4<Float>(110, 0, 0, 1)) } == true)

        let cyclic = WPEPuppetModel(
            version: 19, meshes: [],
            bones: [rawBone(0, parent: 1, SIMD3(1, 0, 0)),
                    rawBone(1, parent: 0, SIMD3(2, 0, 0))],
            animations: []
        )
        let cyc = WPEPuppetAnimationEvaluator.assembledBindWorldByBone(model: cyclic)
        #expect(cyc[0].map { simd_equal($0.columns.3, SIMD4<Float>(1, 0, 0, 1)) } == true)
    }

    @Test("Translation and rotation interpolate between stored frames")
    func interpolatesTRSBetweenStoredFrames() {
        let anim = animation(frameCount: 2, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(10, 0, 0), SIMD3(0, 0, .pi / 2), SIMD3(3, 3, 3)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
        ])])
        let palette = WPEPuppetAnimationEvaluator.palette(layers: [WPEPuppetAnimationLayer(animation: anim, rate: 1, additive: false, blend: 1)], bones: [], at: 0.5 / 30.0)
        let skinned = palette[0] * SIMD4<Float>(1, 0, 0, 1)

        let rootTwo = sqrt(Float(2))
        #expect(abs(skinned.x - (5 + rootTwo)) < 0.001)
        #expect(abs(skinned.y - rootTwo) < 0.001)
    }

    @Test("Additive rotation composes as quaternions instead of summed Euler axes")
    func additiveRotationUsesQuaternionComposition() {
        let base = animation(frameCount: 2, mode: "loop", channels: [channel([
            (.zero, .zero, SIMD3(1, 1, 1)),
            (.zero, SIMD3(.pi / 2, 0, 0), SIMD3(1, 1, 1)),
            (.zero, .zero, SIMD3(1, 1, 1))
        ])])
        let additive = animation(frameCount: 2, mode: "loop", channels: [channel([
            (.zero, .zero, SIMD3(1, 1, 1)),
            (.zero, SIMD3(0, .pi / 2, 0), SIMD3(1, 1, 1)),
            (.zero, .zero, SIMD3(1, 1, 1))
        ])])
        let layers = [
            WPEPuppetAnimationLayer(animation: base, rate: 1, additive: false, blend: 1),
            WPEPuppetAnimationLayer(animation: additive, rate: 1, additive: true, blend: 1)
        ]
        let palette = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: [], at: 1.0 / 30.0)
        let actual = palette[0] * SIMD4<Float>(0, 0, 1, 1)
        let x = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let y = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let expected = simd_float4x4(x * y) * SIMD4<Float>(0, 0, 1, 1)

        #expect(simd_distance(actual, expected) < 0.001)
    }

    @Test("Pure-translation channel skins by the per-frame delta from the bind pose")
    func translationDeltaMatrix() {
        let anim = animation(frameCount: 2, mode: "loop", channels: [
            channel([
                (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
                (SIMD3(10, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
                (SIMD3(20, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
            ])
        ])
        let palette = WPEPuppetAnimationEvaluator.palette(layers: [WPEPuppetAnimationLayer(animation: anim, rate: 1, additive: false, blend: 1)], bones: [], at: 1.0 / 30.0)
        let skinned = palette[0] * SIMD4<Float>(1, 2, 0, 1)
        #expect(skinned == SIMD4<Float>(11, 2, 0, 1))
    }

    @Test("Additive layer composes its delta on top of the base (blink-style Y-scale)")
    func additiveLayerComposesOnBase() {
        let base = animation(frameCount: 2, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
        ])])
        let blink = animation(frameCount: 2, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0.5, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
        ])])
        let layers = [
            WPEPuppetAnimationLayer(animation: base, rate: 1, additive: false, blend: 1),
            WPEPuppetAnimationLayer(animation: blink, rate: 1, additive: true, blend: 1)
        ]
        let atBind = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: [], at: 0)
        #expect(atBind.allSatisfy { simd_equal($0, matrix_identity_float4x4) })
        let blended = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: [], at: 1.0 / 30.0)
        let skinned = blended[0] * SIMD4<Float>(0, 2, 0, 1)
        #expect(abs(skinned.y - 1.0) < 1e-5)
        #expect(abs(skinned.x) < 1e-5)
    }

    @Test("Additive layer with a ZERO bind scale follows the authored absolute scale (eyelid inflate)")
    func additiveZeroBindScaleFollowsAuthoredAbsolute() {
        let base = animation(frameCount: 3, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 1, 1))
        ])])
        let blink = animation(frameCount: 3, mode: "loop", channels: [channel([
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0.5, 1)),
            (SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 1))
        ])])
        func layers(blend: Float) -> [WPEPuppetAnimationLayer] {
            [
                WPEPuppetAnimationLayer(animation: base, rate: 1, additive: false, blend: 1),
                WPEPuppetAnimationLayer(animation: blink, rate: 1, additive: true, blend: blend)
            ]
        }
        let peak = WPEPuppetAnimationEvaluator.palette(layers: layers(blend: 1), bones: [], at: 1.0 / 30.0)
        let peakSkinned = peak[0] * SIMD4<Float>(3, 2, 0, 1)
        #expect(abs(peakSkinned.x - 3.0) < 1e-5)
        #expect(abs(peakSkinned.y - 1.0) < 1e-5)
        let rest = WPEPuppetAnimationEvaluator.palette(layers: layers(blend: 1), bones: [], at: 2.0 / 30.0)
        let restSkinned = rest[0] * SIMD4<Float>(3, 2, 0, 1)
        #expect(abs(restSkinned.x) < 1e-5)
        #expect(abs(restSkinned.y) < 1e-5)
        let half = WPEPuppetAnimationEvaluator.palette(layers: layers(blend: 0.5), bones: [], at: 1.0 / 30.0)
        let halfSkinned = half[0] * SIMD4<Float>(3, 2, 0, 1)
        #expect(abs(halfSkinned.y - 2.0 * 0.75) < 1e-5)
    }

    @Test("A parent bone's rotation propagates through the hierarchy into a child bone's palette")
    func parentRotationPropagatesToChild() {
        func columnMajor(translation: SIMD3<Float>) -> [Float] {
            [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, translation.x, translation.y, translation.z, 1]
        }
        let bones = [
            WPEPuppetBone(index: 0, parentIndex: nil, rawMatrix: columnMajor(translation: .zero)),
            WPEPuppetBone(index: 1, parentIndex: 0, rawMatrix: columnMajor(translation: SIMD3(100, 0, 0)))
        ]
        let anim = WPEPuppetAnimation(
            id: 1, name: "sway", mode: "loop", fps: 30, frameCount: 2,
            channels: [
                WPEPuppetAnimChannel(boneIndex: 0, keyframes: [
                    WPEPuppetAnimKey(frame: 0, translation: .zero, euler: .zero, scale: SIMD3(1, 1, 1)),
                    WPEPuppetAnimKey(frame: 1, translation: .zero, euler: SIMD3(0, 0, .pi / 2), scale: SIMD3(1, 1, 1))
                ]),
                WPEPuppetAnimChannel(boneIndex: 1, keyframes: [
                    WPEPuppetAnimKey(frame: 0, translation: SIMD3(100, 0, 0), euler: .zero, scale: SIMD3(1, 1, 1)),
                    WPEPuppetAnimKey(frame: 1, translation: SIMD3(100, 0, 0), euler: .zero, scale: SIMD3(1, 1, 1))
                ])
            ]
        )
        let layers = [WPEPuppetAnimationLayer(animation: anim, rate: 1, additive: false, blend: 1)]

        let bind = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: bones, at: 0)
        #expect(bind.count == 2)
        #expect(bind.allSatisfy { simd_equal($0, matrix_identity_float4x4) })

        let posed = WPEPuppetAnimationEvaluator.palette(layers: layers, bones: bones, at: 1.0 / 30.0)
        let childAnchor = posed[1] * SIMD4<Float>(100, 0, 0, 1)
        #expect(abs(childAnchor.x) < 1e-3)
        #expect(abs(childAnchor.y - 100) < 1e-3)
    }
}

@Suite("WPE MDL parser")
struct WPEMdlParserTests {
    /// The live Workshop content directory. Only the property-based skeleton
    /// sweep uses it now; the three tests that pinned a model/package COUNT were
    /// deleted — they asserted on how many items this Mac happened to have.
    private static var workshopCorpusRoot: URL {
        let passwd = getpwuid(getuid())
        let realHome = passwd.map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent(
                "Library/Application Support/Steam/steamapps/workshop/content/431960",
                isDirectory: true
            )
    }

    private static var workshopCorpusAvailable: Bool {
        FileManager.default.fileExists(atPath: workshopCorpusRoot.path)
    }

    @Test("Parses MDLV23 textured mesh vertices indices and parts")
    func parsesMDLV23TexturedMesh() throws {
        let model = try WPEMdlParser.parse(data: makeSingleTriangleMDLV23())
        let mesh = try #require(model.meshes.first)

        #expect(model.version == 23)
        #expect(mesh.materialPath == "materials/test.json")
        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[0].position == SIMD3<Float>(-10, -20, 0))
        #expect(mesh.vertices[1].position == SIMD3<Float>(10, -20, 0))
        #expect(mesh.vertices[2].position == SIMD3<Float>(0, 20, 0))
        #expect(mesh.vertices[0].uv == SIMD2<Float>(0, 1))
        #expect(mesh.vertices[1].uv == SIMD2<Float>(1, 1))
        #expect(mesh.vertices[2].uv == SIMD2<Float>(0.5, 0))
        #expect(mesh.bounds == WPEPuppetMeshBounds(
            minimum: SIMD3<Float>(-10, -20, 0),
            maximum: SIMD3<Float>(10, 20, 0)
        ))
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.indexElementWidth == .uint16)
        #expect(mesh.parts == [
            WPEPuppetMeshPart(id: 7, start: 0, count: 3)
        ])
    }

    @Test("Preserves MDLV23 clip masks and source-target part-table indices")
    func parsesMDLV23ClipGroups() throws {
        var data = makeSingleTriangleMDLV23()
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(625))
        data.appendLE(UInt32(0))
        data.appendCString("masks/clipping_mask_test")
        data.appendLE(UInt32(0))
        // MDLV authors targets first, then the corresponding closing sources.
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(0))

        let mesh = try #require(WPEMdlParser.parse(data: data).meshes.first)
        #expect(mesh.clipMaskName == "masks/clipping_mask_test")
        #expect(mesh.clipGroups == [WPEPuppetClipGroup(
            maskName: "masks/clipping_mask_test",
            sourcePartIndices: [0],
            targetPartIndices: [0]
        )])
    }

    @Test("MDLV23 promotes indices to UInt32 when the mesh exceeds UInt16 vertex capacity")
    func parsesMDLV23UInt32Indices() throws {
        let model = try WPEMdlParser.parse(data: makeLargeMDLV23WithUInt32Indices())
        let mesh = try #require(model.meshes.first)

        #expect(mesh.vertices.count == 65_537)
        #expect(mesh.indexElementWidth == .uint32)
        #expect(mesh.indices == [0, 65_535, 65_536])
        #expect(mesh.indices.max() == 65_536)
        #expect(mesh.indices.allSatisfy { $0 < UInt32(mesh.vertices.count) })
        #expect(mesh.parts == [WPEPuppetMeshPart(id: 9, start: 0, count: 3)])
    }

    @Test("Parses MDLV23 skin blend indices as little-endian Int32, not float bit patterns")
    func parsesMDLV23SkinBlendIndicesAsInt32() throws {
        let model = try WPEMdlParser.parse(data: makeSingleVertexSkinnedMDLV23())
        let mesh = try #require(model.meshes.first)
        let vertex = try #require(mesh.vertices.first)

        #expect(vertex.skinBlendIndices == SIMD4<Int32>(7, 1, 1, 1))
        #expect(vertex.skinBlendWeights == SIMD4<Float>(1, 0, 0, 0))
        #expect(vertex.position == SIMD3<Float>(149.086, -686.59, 0))
        #expect(vertex.uv == SIMD2<Float>(0.65, 0.198))
    }

    @Test("Parses MDLV19 header with the leading meshCount byte (same layout as v23)")
    func parsesMDLV19HeaderWithLeadingByte() throws {
        let model = try WPEMdlParser.parse(data: makeSingleVertexSkinnedMDLV19())
        let mesh = try #require(model.meshes.first)
        let vertex = try #require(mesh.vertices.first)

        #expect(model.version == 19)
        #expect(model.meshes.count == 1)
        #expect(mesh.materialPath == "materials/test.json")
        #expect(vertex.skinBlendIndices == SIMD4<Int32>(7, 1, 1, 1))
        #expect(vertex.skinBlendWeights == SIMD4<Float>(1, 0, 0, 0))
        #expect(vertex.position == SIMD3<Float>(149.086, -686.59, 0))
        #expect(vertex.uv == SIMD2<Float>(0.65, 0.198))
    }

    @Test("MDLV23 skeleton fixture audit accounts for every byte")
    func auditAccountsForMDLV23SkeletonFixture() throws {
        var audit: WPEMdlParseAudit?
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithSkeleton(), audit: &audit)
        let parseAudit = try #require(audit)

        #expect(model.version == 23)
        #expect(parseAudit.sections.contains { $0.kind == .mdlvMesh })
        #expect(parseAudit.sections.contains { $0.kind == .mdls })
        #expect(parseAudit.unexplainedGaps.isEmpty)
        #expect(parseAudit.trailingLeftover == nil)
    }

    @Test("MDLV19 fixture audit accounts for every byte")
    func auditAccountsForMDLV19Fixture() throws {
        var audit: WPEMdlParseAudit?
        let model = try WPEMdlParser.parse(data: makeSingleVertexSkinnedMDLV19(), audit: &audit)
        let parseAudit = try #require(audit)

        #expect(model.version == 19)
        #expect(parseAudit.sections.contains { $0.kind == .mdlvMesh })
        #expect(parseAudit.unexplainedGaps.isEmpty)
        #expect(parseAudit.trailingLeftover == nil)
    }

    @Test("Audit surfaces bytes appended after the parsed MDL")
    func auditSurfacesTrailingLeftoverBytes() throws {
        var data = makeSingleVertexSkinnedMDLV19()
        let junkRangeStart = data.count
        data.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])
        var audit: WPEMdlParseAudit?

        _ = try WPEMdlParser.parse(data: data, audit: &audit)
        let parseAudit = try #require(audit)

        #expect(parseAudit.unexplainedGaps.isEmpty)
        #expect(parseAudit.trailingLeftover == junkRangeStart..<data.count)
    }

    @Test("Parses MDLV16 scene model header with the leading meshCount byte")
    func parsesMDLV16SceneModelHeaderWithLeadingByte() throws {
        let model = try WPEMdlParser.parse(data: makeSingleTriangleMDLV16SceneModel())
        let mesh = try #require(model.meshes.first)

        #expect(model.version == 16)
        #expect(model.meshes.count == 1)
        #expect(mesh.materialPath == "materials/models/Hollow Cylinder/diffuse_0.json")
        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[0].position == SIMD3<Float>(-1, -1, 0))
        #expect(mesh.vertices[1].position == SIMD3<Float>(1, -1, 0))
        #expect(mesh.vertices[2].position == SIMD3<Float>(0, 1, 0))
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.bounds == nil)
    }

    // The real header is version-branch-free: 9-byte NUL-terminated tag +
    // u32 model flags + u32 skin count + u32 mesh count. Byte-verified against
    // the engine's own assets/models/editor/camera/camera.mdl (MDLV0017:
    // "MDLV0017\0" 0f000000 01000000 01000000 'm'aterials/…), which the
    // version-branched reader mis-parsed one byte off into
    // invalidVertexBuffer(0x726F7469 = ASCII "itor" from the material path).
    @Test("Parses the real MDLV17 header layout (camera.mdl shape)")
    func parsesRealMDLV17HeaderLayout() throws {
        var data = Data()
        data.append(contentsOf: Array("MDLV0017".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0xF))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(3 * MemoryLayout<Float>.size))
        data.appendLE(Float(1))
        data.appendLE(Float(2))
        data.appendLE(Float(3))
        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))

        let model = try WPEMdlParser.parse(data: data)
        let mesh = try #require(model.meshes.first)
        #expect(model.version == 17)
        #expect(model.meshes.count == 1)
        #expect(mesh.materialPath == "materials/test.json")
        #expect(mesh.vertices.count == 1)
        #expect(mesh.vertices[0].position == SIMD3<Float>(1, 2, 3))
    }

    @Test("Preserves MDLV vertex positions when MDLS skeleton metadata is present")
    func preservesVertexPositionsWithSkeletonMetadata() throws {
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithSkeleton())
        let mesh = try #require(model.meshes.first)

        #expect(model.bones.count == 1)
        #expect(mesh.vertices[0].position == SIMD3<Float>(10, 20, 0))
    }

    @Test("Parses consecutive real-layout MDLS skeleton records")
    func parsesConsecutiveSkeletonRecords() throws {
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithSkeletonTrailingMarker())

        #expect(model.bones.count == 2)
        #expect(model.bones[0].parentIndex == nil)
        #expect(model.bones[0].rawMatrix[12] == 5)
        #expect(model.bones[0].rawMatrix[13] == -7)
        #expect(model.bones[1].parentIndex == 0)
        #expect(model.bones[1].rawMatrix[12] == 12)
        #expect(model.bones[1].rawMatrix[13] == -34)
    }

    @Test("Retains distinct MDLS bone name, simulation type, and simulation JSON")
    func retainsBoneSimulationMetadata() throws {
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithBoneSimulationJSON())

        #expect(model.bones.count == 1)
        #expect(model.bones[0].name == "root")
        #expect(model.bones[0].simulationType == 1)
        #expect(model.bones[0].simulationJSON == #"{"tm":null,"tp":[1.0,2.0,3.0]}"#)
    }

    @Test("Retains MDLS0002 world binds without applying them to the raw bind")
    func retainsMDLS0002WorldBinds() throws {
        let worldBind: [Float] = [
            0.98, 0.19, 0, 0,
            -0.19, 0.98, 0, 0,
            0, 0, 1, 0,
            -84.644, 510.89, 0, 1
        ]
        let model = try WPEMdlParser.parse(data: makeSkinnedMDLV23WithSkeleton(worldBind: worldBind))
        let bone = try #require(model.bones.first)

        #expect(bone.rawMatrix[12] == 5)
        #expect(bone.rawMatrix[13] == -7)
        #expect(bone.worldBindMatrix == worldBind)
    }

    @Test("Recovers mesh geometry when the MDLS skeleton section is malformed")
    func recoversMeshGeometryWhenSkeletonSectionMalformed() throws {
        let model = try WPEMdlParser.parse(data: makeMDLV23WithCorruptSkeleton())
        let mesh = try #require(model.meshes.first)

        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[0].position == SIMD3<Float>(10, 20, 0))
        #expect(mesh.indices == [0, 1, 2])
        #expect(model.bones.isEmpty)
    }

    @Test("Parses MDLA0006 baked TRS animation channels")
    func parsesMDLA0006Animation() throws {
        let model = try WPEMdlParser.parse(data: makeMDLV23WithAnimation())
        let animation = try #require(model.animations.first)

        #expect(model.animations.count == 1)
        #expect(animation.id == 267)
        #expect(animation.name == "动画 1")
        #expect(animation.mode == "loop")
        #expect(animation.fps == 30)
        #expect(animation.frameCount == 1)
        #expect(animation.channels.count == 2)
        #expect(animation.channels[0].boneIndex == 0)
        #expect(animation.channels[0].keyframes.count == 2)
        #expect(animation.channels[0].keyframes[0].translation == SIMD3<Float>(1, 2, 3))
        #expect(animation.channels[0].keyframes[0].scale == SIMD3<Float>(1, 1, 1))
        #expect(animation.channels[0].keyframes[1].translation == SIMD3<Float>(4, 5, 6))
        #expect(animation.channels[1].boneIndex == 1)
        #expect(animation.channels[1].keyframes[0].translation == SIMD3<Float>(7, 8, 9))
        #expect(animation.channels[1].keyframes[1].euler == SIMD3<Float>(0, 0, 0))
        let tail = try #require(animation.tail)
        #expect(tail.mdlaVersion == 6)
        #expect(tail.blendCurves.hasCurves)
        #expect(tail.blendCurves.curves.map(\.values) == [[0.25, 0.75], [1, 1]])
        #expect(tail.scalarCurves?.hasCurves == true)
        #expect(tail.scalarCurves?.curves.map(\.values) == [[2, 2], [3, 4]])
        #expect(tail.unknownSegments.count == 3)
        #expect(animation.sourceRange?.upperBound == tail.sourceRange.upperBound)
        #expect(animation.sourceRange?.contains(tail.sourceRange.lowerBound) == true)
    }

    @Test("MDLA0005 ends at trailing events and has no scalar-curve discriminator")
    func parsesMDLA0005TailByVersion() throws {
        let model = try WPEMdlParser.parse(data: makeMDLV23WithAnimation(mdlaVersion: 5))
        let animation = try #require(model.animations.first)
        let tail = try #require(animation.tail)

        #expect(tail.mdlaVersion == 5)
        #expect(tail.blendCurves.hasCurves)
        #expect(tail.blendCurves.curves.count == 2)
        #expect(tail.scalarCurves == nil)
        #expect(tail.unknownSegments.count == 3)
        #expect(tail.unknownSegments.last?.bytes.suffix(3) == Data("{}\0".utf8))
    }

    @Test("Recovers mesh and animations when the skeleton is malformed but MDLA is valid")
    func recoversAnimationWhenSkeletonMalformed() throws {
        let model = try WPEMdlParser.parse(data: makeMDLV23WithCorruptSkeletonAndAnimation())

        #expect(model.bones.isEmpty)
        #expect(model.meshes.first?.indices == [0, 1, 2])
        #expect(model.animations.count == 1)
        #expect(model.animations.first?.channels.count == 2)
        #expect(
            model.animations.first?.channels[1].keyframes[1].translation == SIMD3<Float>(10, 11, 12)
        )
    }

    @Test("Preserves atlas target geometry when MDLE element matrices are present")
    func preservesAtlasTargetGeometryWithElementMatrices() throws {
        let model = try WPEMdlParser.parse(data: makeMDLV23WithElementMetadata())
        let mesh = try #require(model.meshes.first)

        #expect(mesh.vertices[0].position == SIMD3<Float>(0, 0, 0))
        #expect(mesh.vertices[1].position == SIMD3<Float>(10, 0, 0))
        #expect(mesh.vertices[2].position == SIMD3<Float>(0, 10, 0))
        #expect(model.bones[1].worldBindMatrix?[12] == 12)
        #expect(model.bones[1].worldBindMatrix?[13] == -30)
        #expect(model.bones[2].worldBindMatrix?[12] == 25)
        #expect(model.bones[2].worldBindMatrix?[13] == 5)
        #expect(mesh.vertices[3].position == SIMD3<Float>(20, 0, 0))
        #expect(mesh.vertices[4].position == SIMD3<Float>(30, 0, 0))
        #expect(mesh.vertices[5].position == SIMD3<Float>(20, 10, 0))
    }

    @Test(
        "Real Workshop MDLS and MDLE assets parse with authored metadata",
        .enabled(if: workshopCorpusAvailable)
    )
    func workshopSkeletonCorpusParses() throws {
        let fileManager = FileManager.default
        let folders = try fileManager.contentsOfDirectory(
            at: Self.workshopCorpusRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var mdlsModels = 0
        var mdleModels = 0
        for folder in folders {
            let packageURL = folder.appendingPathComponent("scene.pkg")
            guard fileManager.fileExists(atPath: packageURL.path) else { continue }
            let handle = try FileHandle(forReadingFrom: packageURL)
            defer { try? handle.close() }
            let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
            for entry in package.entries where entry.name.lowercased().hasSuffix(".mdl") {
                let data = try package.readEntry(entry, from: handle)
                guard data.range(of: Data("MDLS".utf8)) != nil else { continue }
                mdlsModels += 1
                let model = try WPEMdlParser.parse(data: data)
                #expect(!model.bones.isEmpty, "\(folder.lastPathComponent)/\(entry.name)")
                if data.range(of: Data("MDLE".utf8)) != nil {
                    mdleModels += 1
                    #expect(
                        model.bones.allSatisfy { $0.worldBindMatrix?.count == 16 },
                        "\(folder.lastPathComponent)/\(entry.name)"
                    )
                }
            }
        }
        #expect(mdlsModels > 0)
        #expect(mdleModels > 0)
    }

    @Test(
        "Real Workshop clip blocks resolve to bounded part-table indices",
        .enabled(if: workshopCorpusAvailable)
    )
    func workshopClipGroupsUsePartTableIndices() throws {
        let folders = try FileManager.default.contentsOfDirectory(
            at: Self.workshopCorpusRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var clipModels = 0
        for folder in folders {
            let packageURL = folder.appendingPathComponent("scene.pkg")
            guard FileManager.default.fileExists(atPath: packageURL.path) else { continue }
            let handle = try FileHandle(forReadingFrom: packageURL)
            defer { try? handle.close() }
            let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
            for entry in package.entries where entry.name.lowercased().hasSuffix(".mdl") {
                let data = try package.readEntry(entry, from: handle)
                guard data.range(of: Data("clipping_mask".utf8)) != nil else { continue }
                clipModels += 1
                let model = try WPEMdlParser.parse(data: data)
                #expect(model.meshes.contains { !$0.clipGroups.isEmpty }, "\(folder.lastPathComponent)/\(entry.name)")
                for mesh in model.meshes {
                    for group in mesh.clipGroups {
                        #expect(group.sourcePartIndices.allSatisfy(mesh.parts.indices.contains))
                        #expect(group.targetPartIndices.allSatisfy(mesh.parts.indices.contains))
                    }
                }
            }
        }
        #expect(clipModels > 0)
    }

    // MARK: - Hostile-count guards (crafted Workshop files must throw, not OOM-trap)

    @Test("Rejects a header claiming a huge mesh count instead of OOM-allocating")
    func rejectsHugeMeshCount() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0x01800009))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32.max)

        #expect(throws: WPEMdlParserError.implausibleCount(
            section: "MDLV meshCount", count: .max, limit: 4_096
        )) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Rejects a version tag missing its NUL terminator")
    func rejectsVersionTagWithoutTerminator() {
        var data = Data()
        data.append(contentsOf: Array("MDLV00170".utf8))
        data.appendLE(UInt32(0x01800009))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        #expect(throws: WPEMdlParserError.invalidHeader) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Rejects a header claiming a huge skin count instead of spinning")
    func rejectsHugeSkinCount() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0x01800009))
        data.appendLE(UInt32.max)
        data.appendLE(UInt32(1))

        #expect(throws: WPEMdlParserError.implausibleCount(
            section: "MDLV skinCount", count: .max, limit: 4_096
        )) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Rejects a vertex buffer byte count larger than the remaining file")
    func rejectsOversizedVertexBuffer() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        data.appendLE(UInt32(4_000_000_000))

        #expect(throws: WPEMdlParserError.invalidVertexBuffer(byteCount: 4_000_000_000, stride: 80)) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Rejects an index buffer byte count larger than the remaining file")
    func rejectsOversizedIndexBuffer() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(4_294_967_294))

        #expect(throws: WPEMdlParserError.invalidIndexBuffer(4_294_967_294)) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Rejects a part table byte count larger than the remaining file")
    func rejectsOversizedPartTable() {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(4_294_967_040))

        #expect(throws: WPEMdlParserError.invalidPartTable(4_294_967_040)) {
            _ = try WPEMdlParser.parse(data: data)
        }
    }

    @Test("Recovers the mesh when a skeleton claims a huge bone count, without OOM-allocating")
    func recoversFromHugeBoneCount() throws {
        var data = makeSingleVertexSkinnedMDLV23()
        data.append(contentsOf: Array("MDLS0004".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt16.max)
        data.appendLE(UInt16(0))

        let model = try WPEMdlParser.parse(data: data)
        #expect(model.bones.isEmpty)
        #expect(model.meshes.first?.vertices.count == 1)
    }

    private func makeSingleTriangleMDLV23() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(-10))
        data.appendLE(Float(-20))
        data.appendLE(Float(0))
        data.appendLE(Float(10))
        data.appendLE(Float(20))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(-10, -20, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(10, -20, 0), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(0, 20, 0), SIMD2<Float>(0.5, 0))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(16))
        data.appendLE(UInt32(7))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(3))

        return data
    }

    private func makeLargeMDLV23WithUInt32Indices() -> Data {
        let vertexCount = 65_537
        let vertexStride = 5 * MemoryLayout<Float>.size
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/large.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x8))
        data.appendLE(UInt32(vertexCount * vertexStride))
        data.append(Data(count: vertexCount * vertexStride))

        let indices: [UInt32] = [0, 65_535, 65_536]
        data.appendLE(UInt32(indices.count * MemoryLayout<UInt32>.size))
        for index in indices { data.appendLE(index) }
        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(16))
        data.appendLE(UInt32(9))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(3))
        data.appendLE(UInt32(0))
        return data
    }

    private func makeSkinnedMDLV23WithSkeleton(
        boneName: String = "root",
        simulationType: Int32 = 0,
        simulationJSON: String = "{}",
        worldBind: [Float]? = nil
    ) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        data.append(contentsOf: Array((worldBind == nil ? "MDLS0004" : "MDLS0002").utf8))
        data.append(UInt8(0))
        let sectionEndPatchOffset = data.count
        data.appendLE(UInt32(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(0))
        data.appendCString(boneName)
        data.appendLE(UInt32(bitPattern: simulationType))
        data.appendLE(UInt32.max)
        data.appendLE(UInt32(16 * 4))
        Data.appendMatrix(
            to: &data,
            rows: [
                [1, 0, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
                [5, -7, 0, 1]
            ]
        )
        data.appendCString(simulationJSON)
        if let worldBind {
            data.appendLE(UInt16(0))
            data.append(UInt8(1))
            for value in worldBind {
                data.appendLE(value)
            }
            data.append(contentsOf: repeatElement(UInt8(0), count: 8))
        } else {
            // MDLS v3+ fixed extras header followed by empty metadata trailer.
            data.appendLE(UInt16(0))
            data.append(UInt8(0))
            data.appendLE(UInt32(0))
            data.appendLE(UInt32(0))
            data.append(UInt8(0))
            data.append(UInt8(0))
            data.append(UInt8(0))
        }
        data.replaceLE(UInt32(data.count), at: sectionEndPatchOffset)

        return data
    }

    private func makeSkinnedMDLV23WithBoneSimulationJSON() -> Data {
        makeSkinnedMDLV23WithSkeleton(
            boneName: "root",
            simulationType: 1,
            simulationJSON: #"{"tm":null,"tp":[1.0,2.0,3.0]}"#
        )
    }

    private func makeMDLV23WithAnimation(mdlaVersion: Int = 6) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        appendMDLASection(version: mdlaVersion, to: &data)
        return data
    }

    private func appendMDLASection(version: Int = 6, to data: inout Data) {
        func appendKey(_ t: SIMD3<Float>, _ r: SIMD3<Float>, _ s: SIMD3<Float>) {
            for value in [t.x, t.y, t.z, r.x, r.y, r.z, s.x, s.y, s.z] {
                data.appendLE(value)
            }
        }
        let frameCount: UInt32 = 1
        let channelByteCount = (frameCount + 1) * UInt32(9 * MemoryLayout<Float>.size)

        data.append(contentsOf: Array(String(format: "MDLA%04d", version).utf8))
        data.append(UInt8(0))
        let sectionEndPatchOffset = data.count
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(267))
        data.appendLE(UInt32(0))
        data.appendCString("动画 1")
        data.appendCString("loop")
        data.appendLE(Float(30))
        data.appendLE(frameCount)
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(2))
        data.appendLE(UInt32(0))
        data.appendLE(channelByteCount)

        appendKey(SIMD3<Float>(1, 2, 3), SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        appendKey(SIMD3<Float>(4, 5, 6), SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        data.appendLE(UInt32(0))
        data.appendLE(channelByteCount)
        appendKey(SIMD3<Float>(7, 8, 9), SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        appendKey(SIMD3<Float>(10, 11, 12), SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))

        data.appendLE(UInt32(0))
        data.append(UInt8(1))
        let blendValues: [[Float]] = [[0.25, 0.75], [1, 1]]
        for values in blendValues {
            data.appendLE(UInt32(0))
            data.appendLE(UInt32(values.count * MemoryLayout<Float>.size))
            for value in values { data.appendLE(value) }
        }
        data.append(UInt8(0))
        let bounds: [Float] = [-1, -2, -3, 4, 5, 6]
        for value in bounds { data.appendLE(value) }
        if version == 6 {
            data.append(UInt8(1))
            let scalarValues: [[Float]] = [[2, 2], [3, 4]]
            for values in scalarValues {
                data.appendLE(UInt32(0))
                data.appendLE(UInt32(values.count * MemoryLayout<Float>.size))
                for value in values { data.appendLE(value) }
            }
            data.appendLE(UInt32(0))
        } else {
            data.appendLE(UInt32(1))
            data.appendLE(UInt32(7))
            data.appendCString("{}")
        }
        data.replaceLE(UInt32(data.count), at: sectionEndPatchOffset)
    }

    private func makeMDLV23WithCorruptSkeletonAndAnimation() -> Data {
        var data = makeMDLV23WithCorruptSkeleton()
        appendMDLASection(to: &data)
        return data
    }

    private func makeMDLV23WithCorruptSkeleton() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5)),
            (SIMD3<Float>(20, 20, 0), SIMD2<Float>(1, 0.5)),
            (SIMD3<Float>(10, 30, 0), SIMD2<Float>(0.5, 1))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))
        data.append(UInt8(0))
        data.append(UInt8(0))

        data.append(contentsOf: Array("MDLS0004".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(0))
        data.appendCString("root")
        data.appendLE(UInt32(0))
        data.appendLE(UInt32.max)
        data.appendLE(UInt32(10))
        data.append(contentsOf: [UInt8](repeating: 0, count: 10))
        return data
    }

    private func makeSingleVertexSkinnedMDLV23() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))

        var vertex = Data()
        vertex.appendLE(Float(149.086)); vertex.appendLE(Float(-686.59)); vertex.appendLE(Float(0))
        vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(1))
        vertex.appendLE(Float(1)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(1))
        vertex.appendLE(UInt32(7)); vertex.appendLE(UInt32(1)); vertex.appendLE(UInt32(1)); vertex.appendLE(UInt32(1))
        vertex.appendLE(Float(1)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0))
        vertex.appendLE(Float(0.65)); vertex.appendLE(Float(0.198))
        data.appendLE(UInt32(vertex.count))
        data.append(vertex)

        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        return data
    }

    private func makeSingleVertexSkinnedMDLV19() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0019".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))

        var vertex = Data()
        vertex.appendLE(Float(149.086)); vertex.appendLE(Float(-686.59)); vertex.appendLE(Float(0))
        vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(1))
        vertex.appendLE(Float(1)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(1))
        vertex.appendLE(UInt32(7)); vertex.appendLE(UInt32(1)); vertex.appendLE(UInt32(1)); vertex.appendLE(UInt32(1))
        vertex.appendLE(Float(1)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0)); vertex.appendLE(Float(0))
        vertex.appendLE(Float(0.65)); vertex.appendLE(Float(0.198))
        data.appendLE(UInt32(vertex.count))
        data.append(vertex)

        data.appendLE(UInt32(0))

        return data
    }

    private func makeSingleTriangleMDLV16SceneModel() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0016".utf8))
        data.appendLE(UInt32(0x00000f00))
        data.append(UInt8(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/models/Hollow Cylinder/diffuse_0.json")
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0x0000000f))

        var vertices = Data()
        vertices.appendSceneModelVertex(position: SIMD3<Float>(-1, -1, 0), uv: SIMD2<Float>(0, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(1, -1, 0), uv: SIMD2<Float>(1, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(0, 1, 0), uv: SIMD2<Float>(0.5, 0))
        data.appendLE(UInt32(vertices.count))
        data.append(vertices)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        return data
    }

    private func makeSkinnedMDLV23WithSkeletonTrailingMarker() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(10, 20, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        data.append(contentsOf: Array("MDLS0004".utf8))
        data.append(UInt8(0))
        let sectionEndPatchOffset = data.count
        data.appendLE(UInt32(0))
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(0))

        data.appendSkeletonRecord(parent: nil, translation: SIMD3<Float>(5, -7, 0))
        data.appendSkeletonRecord(parent: 0, translation: SIMD3<Float>(12, -34, 0))

        data.appendLE(UInt16(0))
        data.append(UInt8(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.append(UInt8(0))
        data.append(UInt8(0))
        data.append(UInt8(0))

        let sectionEnd = data.count
        data.replaceLE(UInt32(sectionEnd), at: sectionEndPatchOffset)
        data.append(contentsOf: Array("MDLA0006".utf8))

        return data
    }

    private func makeMDLV23WithElementMetadata() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/test.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(0, 0, 0), SIMD2<Float>(0, 0)),
            (SIMD3<Float>(10, 0, 0), SIMD2<Float>(1, 0)),
            (SIMD3<Float>(0, 10, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(20, 0, 0), SIMD2<Float>(0, 0)),
            (SIMD3<Float>(30, 0, 0), SIMD2<Float>(1, 0)),
            (SIMD3<Float>(20, 10, 0), SIMD2<Float>(0, 1))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)

        let indices: [UInt16] = [0, 1, 2, 2, 1, 0, 3, 4, 5, 5, 4, 3]
        data.appendLE(UInt32(indices.count * MemoryLayout<UInt16>.size))
        for index in indices {
            data.appendLE(index)
        }

        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(2 * 16))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(6))
        data.appendLE(UInt32(2))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(6))
        data.appendLE(UInt32(6))

        data.appendSkeleton([
            (parent: nil, translation: SIMD3<Float>(0, 0, 0)),
            (parent: 0, translation: SIMD3<Float>(10, 20, 0)),
            (parent: 0, translation: SIMD3<Float>(30, 40, 0))
        ])
        data.appendElementMatrices([
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(12, -30, 0),
            SIMD3<Float>(25, 5, 0)
        ])

        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(UInt8(0))
    }

    mutating func replaceLE(_ value: UInt32, at offset: Int) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) {
            replaceSubrange(offset..<(offset + MemoryLayout<UInt32>.size), with: $0)
        }
    }

    mutating func appendSkeletonRecord(parent: Int?, translation: SIMD3<Float>) {
        appendCString("bone")
        appendLE(UInt32(0))
        appendLE(parent.map(UInt32.init) ?? UInt32.max)
        appendLE(UInt32(16 * MemoryLayout<Float>.size))
        Data.appendMatrix(
            to: &self,
            rows: [
                [1, 0, 0, 0],
                [0, 1, 0, 0],
                [0, 0, 1, 0],
                [translation.x, translation.y, translation.z, 1]
            ]
        )
        appendCString("{}")
    }

    static func puppetVertices(_ vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)]) -> Data {
        var data = Data()
        for vertex in vertices {
            data.appendLE(vertex.position.x)
            data.appendLE(vertex.position.y)
            data.appendLE(vertex.position.z)
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(vertex.uv.x)
            data.appendLE(vertex.uv.y)
        }
        return data
    }

    mutating func appendSceneModelVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        appendLE(position.x)
        appendLE(position.y)
        appendLE(position.z)
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(Float(1))
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(uv.x)
        appendLE(uv.y)
    }

    static func appendMatrix(to data: inout Data, rows: [[Float]]) {
        for row in rows {
            for value in row {
                data.appendLE(value)
            }
        }
    }

    mutating func appendSkeleton(_ bones: [(parent: Int?, translation: SIMD3<Float>)]) {
        append(contentsOf: Array("MDLS0004".utf8))
        append(UInt8(0))
        let sectionEndPatchOffset = count
        appendLE(UInt32(0))
        appendLE(UInt16(bones.count))
        appendLE(UInt16(0))
        for (index, bone) in bones.enumerated() {
            appendCString("bone\(index)")
            appendLE(UInt32(0))
            appendLE(bone.parent.map(UInt32.init) ?? UInt32.max)
            appendLE(UInt32(16 * MemoryLayout<Float>.size))
            Data.appendMatrix(
                to: &self,
                rows: [
                    [1, 0, 0, 0],
                    [0, 1, 0, 0],
                    [0, 0, 1, 0],
                    [bone.translation.x, bone.translation.y, bone.translation.z, 1]
                ]
            )
            appendCString("{}")
        }
        appendLE(UInt16(0))
        append(UInt8(0))
        appendLE(UInt32(0))
        appendLE(UInt32(0))
        append(UInt8(0))
        append(UInt8(0))
        append(UInt8(0))
        replaceLE(UInt32(count), at: sectionEndPatchOffset)
    }

    mutating func appendElementMatrices(_ translations: [SIMD3<Float>]) {
        append(contentsOf: Array("MDLE0002".utf8))
        append(UInt8(0))
        let sectionEndPatchOffset = count
        appendLE(UInt32(0))
        appendLE(UInt32(translations.count * 16 * MemoryLayout<Float>.size))
        for translation in translations {
            Data.appendMatrix(
                to: &self,
                rows: [
                    [1, 0, 0, 0],
                    [0, 1, 0, 0],
                    [0, 0, 1, 0],
                    [translation.x, translation.y, translation.z, 1]
                ]
            )
        }
        replaceLE(UInt32(count), at: sectionEndPatchOffset)
    }
}
