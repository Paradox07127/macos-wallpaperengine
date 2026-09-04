import Foundation
import LiveWallpaperProWPE
import Testing
import simd
@testable import LiveWallpaper

@Suite("WPE puppet clip-role detection")
struct WPEPuppetClipRoleTests {
    private static var realPuppetModelPath: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["WPE_REAL_PUPPET_MODEL_PATH"],
            NSHomeDirectory()
                + "/Library/Application Support/Steam/steamapps/workshop/content/431960/3704273480/"
                + "scene-unpacked/models/身体---拆分_puppet.mdl",
            "/private/tmp/wpe-3704273480-unpacked/3704273480/models/身体---拆分_puppet.mdl",
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func identityColumnMajor() -> [Float] {
        [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    }

    private func quad(bone: Int32, minX: Float, maxX: Float, minY: Float, maxY: Float) -> [WPEPuppetVertex] {
        [
            (minX, minY), (maxX, minY), (maxX, maxY), (minX, maxY)
        ].map { corner in
            WPEPuppetVertex(
                position: SIMD3<Float>(corner.0, corner.1, 0),
                uv: SIMD2<Float>(0, 0),
                skinBlendIndices: SIMD4<Int32>(bone, 0, 0, 0),
                skinBlendWeights: SIMD4<Float>(1, 0, 0, 0)
            )
        }
    }

    private func quadIndices(base: UInt32) -> [UInt32] {
        [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    private func channel(bone: Int, closedScaleY: Float, frameCount: Int, closedFrame: Int? = nil) -> WPEPuppetAnimChannel {
        let closed = closedFrame ?? frameCount / 2
        let keyframes = (0..<frameCount).map { frame -> WPEPuppetAnimKey in
            let scaleY = frame == closed ? closedScaleY : 1
            return WPEPuppetAnimKey(
                frame: frame,
                translation: .zero,
                euler: .zero,
                scale: SIMD3<Float>(1, scaleY, 1)
            )
        }
        return WPEPuppetAnimChannel(boneIndex: bone, keyframes: keyframes)
    }

    @Test("Pupil that stays open is clipped to the enclosing eye-white that squishes shut")
    func detectsEyeWhitePupilPair() {
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
            + quad(bone: 2, minX: -10, maxX: 10, minY: 8, maxY: 12)
        let indices = quadIndices(base: 0) + quadIndices(base: 4) + quadIndices(base: 8)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 13, start: 12, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 2, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<3).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.count == 1)
        #expect(pairs.first?.source == 1)
        #expect(pairs.first?.target == 2)
    }

    @Test("A pure-squish eye (no part stays open) yields no clip pair")
    func pureSquishHasNoPair() {
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
        let indices = quadIndices(base: 0) + quadIndices(base: 4)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 0.2, frameCount: frameCount)
            ]
        )
        let bones = (0..<2).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.isEmpty)
    }

    @Test("Most-closed pose on the final loop frame is still detected (no duration wrap-around)")
    func detectsFinalFrameClosure() {
        let frameCount = 16
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
        let indices = quadIndices(base: 0) + quadIndices(base: 4)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount, closedFrame: frameCount - 1),
                channel(bone: 1, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<2).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.count == 1)
        #expect(pairs.first?.source == 1)
        #expect(pairs.first?.target == 2)
    }

    @Test("Multiple closing eye silhouettes clip later open targets enclosed by each silhouette")
    func detectsMultipleSourcesWithLaterTargets() {
        let vertices = quad(bone: 0, minX: 20, maxX: 60, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -60, maxX: -20, minY: -5, maxY: 5)
            + quad(bone: 2, minX: -45, maxX: -35, minY: -3, maxY: 3)
            + quad(bone: 3, minX: 35, maxX: 45, minY: -3, maxY: 3)
            + quad(bone: 4, minX: 70, maxX: 90, minY: 10, maxY: 15)
        let indices = quadIndices(base: 0) + quadIndices(base: 4) + quadIndices(base: 8)
            + quadIndices(base: 12) + quadIndices(base: 16)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 3, start: 12, count: 6),
                WPEPuppetMeshPart(id: 4, start: 18, count: 6),
                WPEPuppetMeshPart(id: 5, start: 24, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.02, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 0.04, frameCount: frameCount),
                channel(bone: 2, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 3, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 4, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<5).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.count == 2)
        #expect(pairs.contains { $0.source == 1 && $0.target == 4 })
        #expect(pairs.contains { $0.source == 2 && $0.target == 3 })
    }

    @Test("Repeated authored part IDs keep distinct eye clip routes")
    func duplicatePartIDsKeepDistinctRoutes() {
        let vertices = quad(bone: 0, minX: -60, maxX: -20, minY: -5, maxY: 5)
            + quad(bone: 1, minX: 20, maxX: 60, minY: -5, maxY: 5)
            + quad(bone: 2, minX: -45, maxX: -35, minY: -3, maxY: 3)
            + quad(bone: 3, minX: 35, maxX: 45, minY: -3, maxY: 3)
        let indices = quadIndices(base: 0) + quadIndices(base: 4)
            + quadIndices(base: 8) + quadIndices(base: 12)
        let mesh = WPEPuppetMesh(
            materialPath: "eyes",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 50, start: 12, count: 6),
                WPEPuppetMeshPart(id: 50, start: 18, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.04, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 0.04, frameCount: frameCount),
                channel(bone: 2, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 3, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<4).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairsWithIndices(
            mesh: mesh, animationLayers: layers, bones: bones)

        #expect(pairs.count == 2)
        #expect(pairs.contains {
            $0.sourceIndex == 0 && $0.targetIndex == 2 && $0.sourceID == 1 && $0.targetID == 50
        })
        #expect(pairs.contains {
            $0.sourceIndex == 1 && $0.targetIndex == 3 && $0.sourceID == 2 && $0.targetID == 50
        })
    }

    @Test("Authored clip groups route by part-table index without animation inference")
    func authoredClipGroupsAreAuthoritative() {
        let vertices = quad(bone: 0, minX: -60, maxX: -20, minY: -5, maxY: 5)
            + quad(bone: 1, minX: 20, maxX: 60, minY: -5, maxY: 5)
            + quad(bone: 2, minX: -45, maxX: -35, minY: -3, maxY: 3)
            + quad(bone: 3, minX: 35, maxX: 45, minY: -3, maxY: 3)
        let mesh = WPEPuppetMesh(
            materialPath: "eyes",
            vertices: vertices,
            indices: quadIndices(base: 0) + quadIndices(base: 4)
                + quadIndices(base: 8) + quadIndices(base: 12),
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 50, start: 12, count: 6),
                WPEPuppetMeshPart(id: 50, start: 18, count: 6),
            ],
            clipMaskName: "masks/left",
            clipGroups: [
                WPEPuppetClipGroup(
                    maskName: "masks/left", sourcePartIndices: [0], targetPartIndices: [2]),
                WPEPuppetClipGroup(
                    maskName: "masks/right", sourcePartIndices: [1], targetPartIndices: [3]),
            ]
        )

        let pairs = WPEMetalRenderExecutor._testDetectClipPairsWithIndices(
            mesh: mesh, animationLayers: [], bones: []
        )
        #expect(pairs.map { "\($0.sourceIndex)→\($0.targetIndex)" } == ["0→2", "1→3"])
    }

    @Test("A clip group with two sources clips its target against both of them")
    func authoredClipGroupUnionsEverySource() {
        // Every eye rig in the corpus (3558034522, 3578699777) authors one target and two sources
        // per group: the iris is clipped by BOTH eye-whites. Pairing the two lists positionally
        // dropped the whole group and left the irises unclipped through a blink.
        let vertices = quad(bone: 0, minX: 20, maxX: 60, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -60, maxX: -20, minY: -5, maxY: 5)
            + quad(bone: 2, minX: -45, maxX: -35, minY: -3, maxY: 3)
            + quad(bone: 3, minX: 35, maxX: 45, minY: -3, maxY: 3)
        let mesh = WPEPuppetMesh(
            materialPath: "eyes",
            vertices: vertices,
            indices: quadIndices(base: 0) + quadIndices(base: 4)
                + quadIndices(base: 8) + quadIndices(base: 12),
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 3, start: 12, count: 6),
                WPEPuppetMeshPart(id: 4, start: 18, count: 6),
            ],
            clipMaskName: "masks/clipping_mask_e5b07ba8",
            clipGroups: [
                WPEPuppetClipGroup(
                    maskName: "masks/clipping_mask_e5b07ba8",
                    sourcePartIndices: [0, 1],
                    targetPartIndices: [2]
                ),
                WPEPuppetClipGroup(
                    maskName: "masks/clipping_mask_e5b07ba8",
                    sourcePartIndices: [0, 1],
                    targetPartIndices: [3]
                ),
            ]
        )

        let pairs = WPEMetalRenderExecutor._testDetectClipPairsWithIndices(
            mesh: mesh, animationLayers: [], bones: []
        )
        #expect(pairs.map { "\($0.sourceIndex)→\($0.targetIndex)" } == [
            "0→2", "1→2", "0→3", "1→3",
        ])

        let routing = WPEMetalRenderExecutor._testClipRouting(mesh: mesh)
        #expect(routing.sourceGroups == [[0, 1], [0, 1]])
        #expect(routing.routeForTarget == [2: 0, 3: 1])
    }

    @Test("Each clip target routes to one silhouette built from its whole source set")
    func clipRoutingKeepsOneRoutePerTarget() {
        let vertices = quad(bone: 0, minX: -60, maxX: -20, minY: -5, maxY: 5)
            + quad(bone: 1, minX: 20, maxX: 60, minY: -5, maxY: 5)
            + quad(bone: 2, minX: -45, maxX: -35, minY: -3, maxY: 3)
            + quad(bone: 3, minX: 35, maxX: 45, minY: -3, maxY: 3)
        let mesh = WPEPuppetMesh(
            materialPath: "eyes",
            vertices: vertices,
            indices: quadIndices(base: 0) + quadIndices(base: 4)
                + quadIndices(base: 8) + quadIndices(base: 12),
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 3, start: 12, count: 6),
                WPEPuppetMeshPart(id: 4, start: 18, count: 6),
            ],
            clipMaskName: "masks/left",
            clipGroups: [
                WPEPuppetClipGroup(
                    maskName: "masks/left", sourcePartIndices: [0], targetPartIndices: [2]),
                WPEPuppetClipGroup(
                    maskName: "masks/right", sourcePartIndices: [1], targetPartIndices: [3]),
            ]
        )

        let routing = WPEMetalRenderExecutor._testClipRouting(mesh: mesh)
        #expect(routing.sourceGroups == [[0], [1]])
        #expect(routing.routeForTarget == [2: 0, 3: 1])
    }

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

    @Test(
        "No authored clip group in the Workshop corpus is silently dropped",
        .enabled(if: workshopCorpusAvailable)
    )
    func workshopClipGroupsAllProduceRoutes() throws {
        let fileManager = FileManager.default
        let folders = try fileManager.contentsOfDirectory(
            at: Self.workshopCorpusRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var groupCount = 0
        for folder in folders {
            let packageURL = folder.appendingPathComponent("scene.pkg")
            guard fileManager.fileExists(atPath: packageURL.path) else { continue }
            let handle = try FileHandle(forReadingFrom: packageURL)
            defer { try? handle.close() }
            let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
            for entry in package.entries where entry.name.lowercased().hasSuffix(".mdl") {
                let data = try package.readEntry(entry, from: handle)
                guard data.range(of: Data("clipping_mask".utf8)) != nil else { continue }
                let model = try WPEMdlParser.parse(data: data)
                for mesh in model.meshes where !mesh.clipGroups.isEmpty {
                    let routing = WPEMetalRenderExecutor._testClipRouting(mesh: mesh)
                    for (groupIndex, group) in mesh.clipGroups.enumerated() {
                        groupCount += 1
                        let label = "\(folder.lastPathComponent)/\(entry.name) group \(groupIndex)"
                        // Every authored target must reach a silhouette built from the whole source
                        // list. A dropped group renders as an unclipped part — 3558034522's irises
                        // stayed visible through a blink because both its groups were discarded.
                        for target in group.targetPartIndices where mesh.parts[target].count > 0 {
                            let route = try #require(routing.routeForTarget[target], "\(label) target \(target)")
                            #expect(
                                routing.sourceGroups[route]
                                    == group.sourcePartIndices.filter { mesh.parts[$0].count > 0 }.sorted(),
                                "\(label) target \(target)"
                            )
                        }
                    }
                }
            }
        }
        #expect(groupCount > 0)
    }

    @Test(
        "Real 3704273480 uses six authored clip routes and never clips the coat",
        .enabled(if: realPuppetModelPath != nil)
    )
    func realDuplicateEyeRangesKeepDistinctRoutes() throws {
        let path = try #require(Self.realPuppetModelPath)
        let model = try WPEMdlParser.parse(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let mesh = try #require(model.meshes.first)
        #expect(mesh.clipGroups == [
            WPEPuppetClipGroup(
                maskName: "masks/clipping_mask_5a7bb3eb",
                sourcePartIndices: [44, 51, 52],
                targetPartIndices: [54, 57, 58]
            ),
            WPEPuppetClipGroup(
                maskName: "masks/clipping_mask_1bff128a",
                sourcePartIndices: [43, 49, 50],
                targetPartIndices: [53, 55, 56]
            ),
        ])

        let pairs = WPEMetalRenderExecutor._testDetectClipPairsWithIndices(
            mesh: mesh, animationLayers: [], bones: model.bones
        )
        // Set→set, not positional: each target is clipped by the union of the group's sources.
        #expect(pairs.map { "\($0.sourceIndex)→\($0.targetIndex)" } == [
            "44→54", "51→54", "52→54", "44→57", "51→57", "52→57", "44→58", "51→58", "52→58",
            "43→53", "49→53", "50→53", "43→55", "49→55", "50→55", "43→56", "49→56", "50→56",
        ])
        #expect(!pairs.contains { $0.sourceIndex == 64 && $0.targetIndex == 65 })
    }

    @Test("Character-sheet clip roles use the assembled frame-zero pose")
    func characterSheetUsesFrameZeroReference() {
        // The raw atlas keeps the source far from its target. Frame 0 assembles the source around
        // the target; frame 1 then squishes it shut. Raw-MDL containment therefore proves no route,
        // while the authored frame-zero reference proves exactly one.
        let vertices = quad(bone: 0, minX: -100, maxX: -80, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
        let mesh = WPEPuppetMesh(
            materialPath: "assembled-eye",
            vertices: vertices,
            indices: quadIndices(base: 0) + quadIndices(base: 4),
            parts: [
                WPEPuppetMeshPart(id: 10, start: 0, count: 6),
                WPEPuppetMeshPart(id: 11, start: 6, count: 6),
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let sourceKeys = [
            WPEPuppetAnimKey(
                frame: 0, translation: SIMD3<Float>(95, 0, 0), euler: .zero,
                scale: SIMD3<Float>(1, 1, 1)),
            WPEPuppetAnimKey(
                frame: 1, translation: SIMD3<Float>(95, 0, 0), euler: .zero,
                scale: SIMD3<Float>(1, 0.1, 1)),
            WPEPuppetAnimKey(
                frame: 2, translation: SIMD3<Float>(95, 0, 0), euler: .zero,
                scale: SIMD3<Float>(1, 1, 1)),
        ]
        let targetKeys = (0...2).map { frame in
            WPEPuppetAnimKey(
                frame: frame, translation: .zero, euler: .zero,
                scale: SIMD3<Float>(repeating: 1))
        }
        let animation = WPEPuppetAnimation(
            id: 1, name: "assemble-and-blink", mode: "loop", fps: 30, frameCount: 2,
            channels: [
                WPEPuppetAnimChannel(boneIndex: 0, keyframes: sourceKeys),
                WPEPuppetAnimChannel(boneIndex: 1, keyframes: targetKeys),
            ]
        )
        let bones = (0..<2).map {
            WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor())
        }
        let layers = [WPEPuppetAnimationLayer(
            animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(
            mesh: mesh, animationLayers: layers, bones: bones)

        #expect(pairs.count == 1)
        #expect(pairs.first?.source == 10)
        #expect(pairs.first?.target == 11)
    }

    @Test("No clip when the first part doesn't close (convention guard rejects)")
    func firstPartMustClose() {
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
        let indices = quadIndices(base: 0) + quadIndices(base: 4)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 0.18, frameCount: frameCount)
            ]
        )
        let bones = (0..<2).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.isEmpty)
    }

    @Test("Later enclosed open targets are clipped to the same silhouette")
    func emitsLaterEnclosedTargets() {
        let vertices = quad(bone: 0, minX: -10, maxX: 10, minY: -5, maxY: 5)
            + quad(bone: 1, minX: -3, maxX: 3, minY: -3, maxY: 3)
            + quad(bone: 2, minX: -2, maxX: 2, minY: -2, maxY: 2)
        let indices = quadIndices(base: 0) + quadIndices(base: 4) + quadIndices(base: 8)
        let mesh = WPEPuppetMesh(
            materialPath: "eye",
            vertices: vertices,
            indices: indices,
            parts: [
                WPEPuppetMeshPart(id: 1, start: 0, count: 6),
                WPEPuppetMeshPart(id: 2, start: 6, count: 6),
                WPEPuppetMeshPart(id: 5, start: 12, count: 6)
            ],
            clipMaskName: "masks/clipping_mask_test"
        )
        let frameCount = 12
        let animation = WPEPuppetAnimation(
            id: 1, name: "blink", mode: "loop", fps: 30, frameCount: frameCount,
            channels: [
                channel(bone: 0, closedScaleY: 0.18, frameCount: frameCount),
                channel(bone: 1, closedScaleY: 1, frameCount: frameCount),
                channel(bone: 2, closedScaleY: 1, frameCount: frameCount)
            ]
        )
        let bones = (0..<3).map { WPEPuppetBone(index: $0, parentIndex: nil, rawMatrix: identityColumnMajor()) }
        let layers = [WPEPuppetAnimationLayer(animation: animation, rate: 1, additive: false, blend: 1)]

        let pairs = WPEMetalRenderExecutor._testDetectClipPairs(mesh: mesh, animationLayers: layers, bones: bones)
        #expect(pairs.count == 2)
        #expect(pairs.contains { $0.source == 1 && $0.target == 2 })
        #expect(pairs.contains { $0.source == 1 && $0.target == 5 })
    }
}

@Suite("WPE puppet effect-chain detection")
struct WPEPuppetEffectChainTests {
    @Test("Material pass alone is not an effect chain")
    func materialOnly() {
        #expect(WPEMetalRenderExecutor.hasEffectChain(passPhases: [.material]) == false)
    }

    @Test("Material plus the final scene-copy command is not an effect chain")
    func materialPlusSceneCopy() {
        #expect(WPEMetalRenderExecutor.hasEffectChain(
            passPhases: [.material, .command(file: "materials/util/copy.json")]) == false)
    }

    @Test("A material-kind effect pass is an effect chain")
    func materialEffect() {
        #expect(WPEMetalRenderExecutor.hasEffectChain(
            passPhases: [.material, .effect(file: "effects/bloom/effect.json")]) == true)
    }

    @Test("A command-kind effect pass is an effect chain (not just .effect)")
    func commandEffect() {
        #expect(WPEMetalRenderExecutor.hasEffectChain(
            passPhases: [.material, .command(file: "effects/blur/effect.json"),
                         .command(file: "materials/util/copy.json")]) == true)
    }
}
