import Foundation
@testable import LiveWallpaperProWPE
import Testing

private typealias F = ParitySceneFixtures

struct ParitySceneParticleTests {
    private static func draw(_ objectID: String, node: [Int] = [], renderer: Int = 0,
                             refract: Bool = false) -> WPEParitySceneParticleDraw {
        WPEParitySceneParticleDraw(
            key: WPEParityParticleDrawKey(objectID: objectID, node: node, renderer: renderer),
            shader: "genericparticle", source: WPEParitySceneMaterialSource(materialPath: "materials/p.json"),
            blend: .additive, materialState: WPEParitySceneMaterialState(depthTest: false, depthWrite: false),
            readsFullFrameBuffer: refract
        )
    }

    private static func particle(_ id: String, parentID: String? = nil,
                                 draws: [WPEParitySceneParticleDraw]) -> WPEParitySceneObject {
        WPEParitySceneObject(id: id, kind: .particle(WPEParitySceneParticle(draws: draws)), width: 0, height: 0,
                             parentID: parentID)
    }

    private static func draws(_ scene: WPEParityProgramScene, _ id: String) -> [WPEParitySceneParticleDraw] {
        guard case let .particle(particle)? = scene.scene.objects.first(where: { $0.id == id })?.kind else { return [] }
        return particle.draws
    }

    @Test func particleUnderACompositedParentDrawsInsideItsComposite() {
        let frame = WPEParitySceneFrameBuilder.build(F.scene([
            F.layer("P", passthrough: true, effects: [F.effect("pe")]),
            Self.particle("S", parentID: "P", draws: [Self.draw("S")]),
        ]))
        let draw = frame.draws["S/particle/r0"]
        #expect(draw?.compositeOwnerID == "P")
        #expect(draw?.target == WPEResourceID(F.bc0))
        #expect(draw?.geometry == .particles(WPEParityParticleDrawKey(objectID: "S", renderer: 0)))
    }

    @Test func refractObjectCopiesTheFullFrameOnceBeforeItsFirstRefractDraw() {
        let lines = F.lines(F.scene([Self.particle("S", draws: [
            Self.draw("S"), Self.draw("S", renderer: 1, refract: true), Self.draw("S", node: [0], refract: true),
        ])]))
        #expect(Array(lines.dropFirst(3)) == [
            F.sceneBind, "draw genericparticle [] additive rgb particles",
            "copy backbuffer->_rt_FullFrameBuffer",
            F.sceneBind, "draw genericparticle [_rt_FullFrameBuffer] additive rgb particles",
            F.sceneBind, "draw genericparticle [_rt_FullFrameBuffer] additive rgb particles",
        ])
    }

    @Test func documentParticleDrawsFollowEntriesThenStaticChildrenThenEventGroups() throws {
        var texture = Array("TEXV0005\0TEXI0001\0".utf8)
        // RG88, spritesheet, 64×64 texture holding a 48×48 image.
        for value: UInt32 in [8, 4, 64, 64, 48, 48] {
            withUnsafeBytes(of: value.littleEndian) { texture.append(contentsOf: $0) }
        }
        let files: [String: Any] = [
            "models/7.json": ["material": "materials/layer.json"],
            "materials/layer.json": ["passes": [["shader": "genericimage2"]]],
            "particles/fx.json": [
                "material": "materials/particle.json", "flags": 5,
                "renderer": [["name": "sprite"], ["name": "spritetrail"]],
                "children": [["name": "particles/glow.json", "type": "eventdeath"], ["name": "particles/rope.json"]],
            ],
            "particles/rope.json": ["material": "materials/particle.json", "renderer": [["name": "rope"]]],
            "particles/glow.json": ["material": "materials/refract.json", "renderer": [["name": "sprite"]]],
            "materials/particle.json": ["passes": [[
                "shader": "genericparticle", "blending": "additive", "depthtest": "disabled",
                "depthwrite": "disabled", "cullmode": "nocull", "textures": ["particle/dot"],
            ]]],
            "materials/refract.json": ["passes": [["shader": "genericparticle", "blending": "translucent",
                                                   "combos": ["REFRACT": 1]]]],
            "materials/particle/dot.tex": Data(texture),
            "shaders/genericparticle.vert": "void main() {}\n",
            "shaders/genericparticle.frag": """
            uniform sampler2D g_Texture0; // {"default":"util/white"}
            uniform sampler2D g_Texture3; // {"default":"_rt_FullFrameBuffer","hidden":true}
            void main() {}

            """,
        ]
        let objects: [[String: Any]] = [
            ["id": 7, "name": "7", "image": "models/7.json", "size": "400 200"],
            ["id": 5, "name": "fx", "particle": "particles/fx.json"],
        ]
        try ParticleSceneFiles.withScene(objects, files: files) { scene, _ in
            let sheet = ["THICKFORMAT": 1, "SPRITESHEET": 1, "SPRITESHEETBLEND": 1, "SPRITESHEETBLENDNPOT": 1,
                         "TEX0FORMAT": 8]
            let draws = Self.draws(scene, "5")
            #expect(draws.map(\.key) == [
                WPEParityParticleDrawKey(objectID: "5", renderer: 0),
                WPEParityParticleDrawKey(objectID: "5", renderer: 1),
                WPEParityParticleDrawKey(objectID: "5", node: [0], renderer: 0),
                WPEParityParticleDrawKey(objectID: "5", renderer: 0, eventGroup: 0),
            ])
            #expect(draws.map(\.source) == [
                WPEParitySceneMaterialSource(materialPath: "materials/particle.json", combos: sheet),
                WPEParitySceneMaterialSource(materialPath: "materials/particle.json",
                                             combos: sheet.merging(["TRAILRENDERER": 1]) { $1 }),
                WPEParitySceneMaterialSource(materialPath: "materials/particle.json",
                                             combos: ["THICKFORMAT": 1, "TRAILSUBDIVISION": 4, "ORIENTATION": 0,
                                                      "TEX0FORMAT": 8],
                                             shader: "genericropeparticle"),
                WPEParitySceneMaterialSource(materialPath: "materials/refract.json"),
            ])
            #expect(draws.map(\.shader) == ["genericparticle", "genericparticle", "genericropeparticle",
                                            "genericparticle"])
            #expect(draws.map(\.readsFullFrameBuffer) == [false, false, false, true])
            #expect(draws.map(\.worldSpace) == [true, true, false, false])
            #expect(draws.map(\.perspective) == [true, true, false, false])
            #expect(draws[0].blend == .additive && draws[3].blend == .translucent)
            #expect(draws[0].materialState == WPEParitySceneMaterialState(depthTest: false, depthWrite: false,
                                                                          cullsBackFaces: false))

            let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess, frameIndex: 0)
            let sceneDraws = frame.draws.sorted { $0.key < $1.key }.compactMap { index, draw -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = draw else { return nil }
                return (index, draw)
            }
            #expect(sceneDraws.map(\.1.pass) == ["7/albedo", "5/particle/r0", "5/particle/r1", "5/particle/0/r0",
                                                 "5/particle/e0/r0"])
            #expect(frame.operations.count { $0.pass == "5/particle/snapshot" } == 1)
            #expect(scene.material(for: sceneDraws[3].1)?.shader == "genericropeparticle")
            let bindings = WPEParityProgramBuilder.bindings(frame: frame, scene: scene)
            let refract = bindings[sceneDraws[4].0]?.textures
            #expect(refract?[0] == .asset("util/white"))
            #expect(refract?[3] == .resource(WPEParitySceneResource.fullFrameBuffer))
        }
    }

    @Test func selfResourceChildrenResolveRootAndTenDescendantsThenDiagnoseTheNextEdge() throws {
        let files: [String: Any] = [
            "particles/loop.json": ["material": "materials/particle.json", "renderer": [["name": "sprite"]],
                                    "children": [["name": "particles/loop.json"]]],
            "materials/particle.json": ["passes": [["shader": "genericparticle"]]],
        ]
        try ParticleSceneFiles.withScene([["id": 5, "name": "loop", "particle": "particles/loop.json"]],
                                         files: files) { scene, document in
            // Original 2293a0 starts at depth 0; 22ebe0/22f890 create children through depth 10.
            // Repeating a resource path does not remove any of those distinct instances.
            let paths = (0 ... 10).map { Array(repeating: WPEParityParticlePathElement.staticChild(0), count: $0) }
            #expect(scene.scene.diagnostics == [.particleChildOmitted(objectID: "5", path: "particles/loop.json")])
            #expect(Self.draws(scene, "5").map(\.key) == paths.map {
                WPEParityParticleDrawKey(objectID: "5", path: $0, renderer: 0)
            })
            let probes = WPEParityParticleScene.materialProbes(document: document, assets: scene.assets,
                                                               engineFlags: scene.engineFlags)
            #expect(probes.map(\.path) == paths)
            #expect(paths.allSatisfy {
                WPEParityParticleScene.prototype(for: .init(objectID: "5", path: $0, renderer: 0),
                                                 document: document, assets: scene.assets) != nil
            })
            #expect(WPEParityParticleScene.prototype(
                for: .init(objectID: "5", path: paths[10] + [.staticChild(0)], renderer: 0),
                document: document, assets: scene.assets
            ) == nil)
        }
    }

    @Test func ropeAndRopeTrailEntriesDrawWithTheRopeShaderNextToASprite() throws {
        let files: [String: Any] = [
            "particles/mixed.json": ["material": "materials/particle.json",
                                     "renderer": [["name": "sprite"], ["name": "ropetrail"], ["name": "rope"]]],
            "materials/particle.json": ["passes": [["shader": "genericparticle"]]],
        ]
        try ParticleSceneFiles.withScene([["id": 5, "name": "mixed", "particle": "particles/mixed.json"]],
                                         files: files) { scene, _ in
            #expect(Self.draws(scene, "5").map(\.shader) == ["genericparticle", "genericropeparticle",
                                                             "genericropeparticle"])
        }
    }

    @Test func acceptedChildIndexesMatchProgramProbeAndSimulationIncludingLocalStaticEventDescendants() throws {
        let objects: [[String: Any]] = [["id": 5, "name": "fx", "particle": "particles/fx.json",
                                         "instanceoverride": ["count": 2]]]
        let files: [String: Any] = [
            "materials/particle.json": ["passes": [["shader": "genericparticle"]]],
            "particles/fx.json": [
                "maxcount": 3, "material": "materials/particle.json", "renderer": [["name": "sprite"]],
                "children": [
                    ["name": "particles/missing.json"],
                    ["name": "particles/missing-event.json", "type": "eventspawn"],
                    ["name": "particles/static.json", "type": "eventfollow"],
                    ["name": "particles/event.json", "type": "eventdeath"],
                    ["name": "particles/static.json"],
                ],
            ],
            "particles/static.json": [
                "maxcount": 2, "material": "materials/particle.json", "renderer": [["name": "sprite"]],
                "children": [["name": "particles/leaf.json", "type": "eventspawn"]],
            ],
            "particles/event.json": [
                "maxcount": 4, "material": "materials/particle.json", "renderer": [["name": "spritetrail"]],
                "children": [["name": "particles/leaf.json"], ["name": "particles/unknown-flags.json"]],
            ],
            "particles/leaf.json": ["maxcount": 5, "material": "materials/particle.json",
                                    "renderer": [["name": "sprite"]]],
            "particles/unknown-flags.json": ["flags": 16, "material": "materials/particle.json",
                                             "renderer": [["name": "sprite"]]],
        ]
        try ParticleSceneFiles.withScene(objects, files: files) { program, document in
            let keys = Self.draws(program, "5").map(\.key)
            #expect(keys == [
                .init(objectID: "5", path: [], renderer: 0),
                .init(objectID: "5", path: [.staticChild(0)], renderer: 0),
                .init(objectID: "5", path: [.staticChild(0), .eventGroup(0)], renderer: 0),
                .init(objectID: "5", path: [.eventGroup(0)], renderer: 0),
                .init(objectID: "5", path: [.eventGroup(0), .eventGroup(0)], renderer: 0),
                .init(objectID: "5", path: [.eventGroup(1)], renderer: 0),
                .init(objectID: "5", path: [.eventGroup(1), .staticChild(0)], renderer: 0),
            ])
            #expect(keys.map(\.passIdentity) == ["5/particle/r0", "5/particle/0/r0", "5/particle/0/e0/r0",
                                                 "5/particle/e0/r0", "5/particle/e0/e0/r0", "5/particle/e1/r0",
                                                 "5/particle/e1/0/r0"])
            let materials = WPEParityParticleScene.materialProbes(document: document, assets: program.assets,
                                                                  engineFlags: program.engineFlags)
            #expect(materials.map(\.objectID) == ["5", "5", "5", "5", "5", "5", "5"])
            #expect(materials.map(\.path) == keys.map(\.path))
            let probes = keys.compactMap {
                WPEParityParticleScene.prototype(for: $0, document: document, assets: program.assets)
            }
            #expect(probes.count == 7)
            // count scales emission only; every system keeps maxcount slots (ebe0.c:355).
            #expect(probes.map(\.slotCount) == [3, 2, 5, 2, 5, 4, 5])
            #expect(probes.flatMap(\.renderers).map(\.kind) == [.sprite, .sprite, .sprite, .sprite, .sprite,
                                                                .spriteTrail, .sprite])
            let scene = WPEParityParticleScene(document: document, assets: program.assets,
                                               engineFlags: program.engineFlags, seed: 7)
            let root = try #require(scene.objects.first?.system)
            #expect(root.capacity == 3)
            #expect(root.children.count == 1)
            let child = try #require(root.children.first)
            #expect(child.capacity == 2)
            #expect(child.eventChildren.count == 1)
            #expect(root.eventChildren.count == 2)
            #expect(root.config.children.filter { $0.trigger != .always }.map(\.trigger) == [.follow, .death])
            #expect(root.config.children.filter { $0.trigger != .always }.map(\.config.maxCount) == [2, 4])
            // 2378a0 constructs the follow instance's event metadata; 2308a0 and 2366f0 recurse its own groups.
            let follow = try #require(root.config.children.first { $0.trigger == .follow })
            #expect(follow.config.children.map(\.trigger) == [.spawn])
            #expect(follow.config.children.map(\.config.maxCount) == [5])
            #expect(program.scene.diagnostics.contains { diagnostic in
                if case let .particleChildUnsupported(id, path, asset, field, _) = diagnostic {
                    return id == "5" && path == [.eventGroup(1), .staticChild(1)]
                        && asset == "particles/unknown-flags.json" && field == "flags"
                }
                return false
            })
            #expect(!program.scene.diagnostics.contains { diagnostic in
                if case let .particleChildUnsupported(_, path, _, field, _) = diagnostic {
                    return path == [.eventGroup(0), .eventGroup(0)] && field == "type"
                }
                return false
            })
            #expect(WPEParityParticleScene.prototype(
                for: .init(objectID: "5", path: [.eventGroup(1), .staticChild(0)], renderer: 0),
                document: document, assets: program.assets
            )?.slotCount == 5)
            #expect(WPEParityParticleScene.prototype(
                for: .init(objectID: "5", path: [.eventGroup(1), .staticChild(1)], renderer: 0),
                document: document, assets: program.assets
            ) == nil)
            #expect(WPEParityParticleScene.prototype(
                for: .init(objectID: "5", path: [.staticChild(1)], renderer: 0),
                document: document, assets: program.assets
            ) == nil)
        }
    }

    @Test func unsupportedNestedBranchProjectsItsFieldAndPreservesHealthyProgramPaths() throws {
        let files: [String: Any] = [
            "materials/particle.json": ["passes": [["shader": "genericparticle"]]],
            "particles/fx.json": ["maxcount": 1, "material": "materials/particle.json",
                                  "children": [["name": "legacy"], ["name": "event", "type": "eventdeath"]]],
            "legacy": ["maxcount": 1, "material": "materials/particle.json"],
            "event": ["maxcount": 1, "material": "materials/particle.json", "renderer": [],
                      "children": [["name": "bad"], ["name": "healthy"]]],
            // CP history now has consumers; periodic emission still requires native verification before admission.
            "bad": ["maxcount": 1, "material": "materials/particle.json",
                    "emitter": [["name": "boxrandom", "flags": 4]]],
            "healthy": ["maxcount": 1, "material": "materials/particle.json"],
        ]
        try ParticleSceneFiles.withScene([["id": 5, "name": "fx", "particle": "particles/fx.json"]], files: files) { program, document in
            let keys = Self.draws(program, "5").map(\.key)
            #expect(keys.map(\.path) == [[], [.staticChild(0)], [.eventGroup(0), .staticChild(0)]])
            #expect(program.scene.diagnostics.contains { diagnostic in
                if case let .particleChildUnsupported(id, path, asset, field, reason) = diagnostic {
                    return id == "5" && path == [.eventGroup(0), .staticChild(0)] && asset == "bad"
                        && field == "emitter[0].flags" && !reason.isEmpty
                }
                return false
            })
            let probes = WPEParityParticleScene.materialProbes(document: document, assets: program.assets,
                                                               engineFlags: program.engineFlags)
            #expect(probes.map(\.path) == [[], [.staticChild(0)], [.eventGroup(0)], [.eventGroup(0), .staticChild(0)]])
            #expect(keys.allSatisfy { WPEParityParticleScene.prototype(for: $0, document: document, assets: program.assets) != nil })
        }
    }

    @Test func baseMaterialProbesKeepAuthoredCombosSystemShaderAndResolvedSamplerNames() throws {
        let objects: [[String: Any]] = [
            ["id": 5, "name": "trail", "particle": "particles/trail.json"],
            ["id": 6, "name": "rope", "particle": "particles/rope.json"],
            ["id": 7, "name": "ropeTrail", "particle": "particles/rope-trail.json"],
            ["id": 8, "name": "missing material", "particle": "particles/no-material.json"],
            ["id": 9, "name": "missing shader", "particle": "particles/no-shader.json"],
            ["id": 10, "name": "missing system", "particle": "particles/missing.json"],
        ]
        let files: [String: Any] = [
            "particles/trail.json": ["material": "materials/custom.json", "renderer": [["name": "spritetrail"]]],
            "particles/rope.json": ["material": "materials/custom.json", "renderer": [["name": "rope"]]],
            "particles/rope-trail.json": ["material": "materials/custom.json", "renderer": [["name": "ropetrail"]]],
            "particles/no-material.json": ["renderer": [["name": "sprite"]]],
            "particles/no-shader.json": ["material": "materials/broken.json", "renderer": [["name": "sprite"]]],
            "materials/custom.json": ["passes": [["shader": "custom", "combos": ["AUTHORED": 7, "REFRACT": 0],
                                                  "textures": ["p/bound"]]]],
            "materials/broken.json": ["passes": [["shader": "missing"]]],
            "shaders/custom.vert": "void main() {\n\tgl_Position = vec4(0.0);\n}\n",
            "shaders/custom.frag": """
            uniform sampler2D g_Texture0; // {"default":"util/white"}
            uniform sampler2D g_Texture3; // {"default":"_rt_FullFrameBuffer"}
            void main() {
                gl_FragColor = vec4(1.0);
            }

            """,
            "shaders/genericropeparticle.vert": "void main() {\n\tgl_Position = vec4(0.0);\n}\n",
            "shaders/genericropeparticle.frag": """
            uniform sampler2D g_Texture0; // {"default":"rope/white"}
            uniform sampler2D g_Texture5; // {"default":"rope/default"}
            void main() {
                gl_FragColor = vec4(1.0);
            }

            """,
        ]
        try ParticleSceneFiles.withScene(objects, files: files) { scene, document in
            let probes = WPEParityParticleScene.materialProbes(document: document, assets: scene.assets,
                                                               engineFlags: scene.engineFlags)
            #expect(probes.map(\.objectID) == ["5", "6", "7", "8", "9", "10"])
            let pathsAreRoots = probes.allSatisfy(\.path.isEmpty)
            #expect(pathsAreRoots)
            var shaders: [String] = []
            var names: [[Int32: String]] = []
            var failures: [String] = []
            for probe in probes {
                switch probe.material {
                case let .ready(program, textures):
                    shaders.append(program.shader)
                    names.append(textures)
                    #expect(program.combos.first { $0.name == "AUTHORED" }?.value == "7")
                    #expect(program.combos.first { $0.name == "REFRACT" }?.value == "0")
                    // Native base materials have no entry's THICKFORMAT/TRAIL/ORIENTATION overrides.
                    #expect(!program.combos.contains { ["THICKFORMAT", "TRAILRENDERER", "ORIENTATION"].contains($0.name) })
                case let .unavailable(reason):
                    failures.append(reason)
                }
            }
            #expect(shaders == ["custom", "genericropeparticle", "custom"])
            #expect(names == [[0: "p/bound", 3: "_rt_FullFrameBuffer"],
                              [0: "p/bound", 5: "rope/default"],
                              [0: "p/bound", 3: "_rt_FullFrameBuffer"]])
            #expect(failures.count == 3)
            #expect(failures.contains { $0.contains("particle 8") && $0.contains("<missing>") })
            #expect(failures.contains { $0.contains("particle 9") && $0.contains("materials/broken.json") })
            #expect(failures.contains { $0.contains("particle 10") && $0.contains("particles/missing.json") })
        }
    }
}

/// A wallpaper directory that lives until `body` returns, so draws can still read their materials and shaders.
private enum ParticleSceneFiles {
    static func withScene(_ objects: [[String: Any]], files: [String: Any],
                          _ body: (WPEParityProgramScene, WPESceneDocument) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-particles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scene: [String: Any] = ["camera": ["center": "0 0 0"],
                                    "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
                                    "objects": objects]
        for (path, content) in files.merging(["scene.json": scene], uniquingKeysWith: { $1 }) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try (content as? Data) ?? (content as? String).map { Data($0.utf8) }
                ?? JSONSerialization.data(withJSONObject: content)
            try data.write(to: url)
        }
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        try body(WPEParityProgramScene(document: document,
                                       assets: WPEParityProgramAssets(sceneDirectory: root, assetRoots: []),
                                       settings: WPEParityProgramSettings()), document)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
