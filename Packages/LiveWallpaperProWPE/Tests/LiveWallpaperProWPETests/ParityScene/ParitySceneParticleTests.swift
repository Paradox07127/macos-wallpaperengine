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
            F.layer("P", effects: [F.effect("pe")]),
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
        try ParticleSceneFiles.withScene(objects, files: files) { scene in
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

    @Test func childThatNamesItsOwnFileEndsWithADiagnostic() throws {
        let files: [String: Any] = [
            "particles/loop.json": ["material": "materials/particle.json", "renderer": [["name": "sprite"]],
                                    "children": [["name": "particles/loop.json"]]],
            "materials/particle.json": ["passes": [["shader": "genericparticle"]]],
        ]
        try ParticleSceneFiles.withScene([["id": 5, "name": "loop", "particle": "particles/loop.json"]],
                                         files: files) { scene in
            #expect(scene.scene.diagnostics == [.particleChildOmitted(objectID: "5", path: "particles/loop.json")])
            #expect(Self.draws(scene, "5").map(\.key) == [WPEParityParticleDrawKey(objectID: "5", renderer: 0)])
        }
    }

    @Test func ropeAndRopeTrailEntriesDrawWithTheRopeShaderNextToASprite() throws {
        let files: [String: Any] = [
            "particles/mixed.json": ["material": "materials/particle.json",
                                     "renderer": [["name": "sprite"], ["name": "ropetrail"], ["name": "rope"]]],
            "materials/particle.json": ["passes": [["shader": "genericparticle"]]],
        ]
        try ParticleSceneFiles.withScene([["id": 5, "name": "mixed", "particle": "particles/mixed.json"]],
                                         files: files) { scene in
            #expect(Self.draws(scene, "5").map(\.shader) == ["genericparticle", "genericropeparticle",
                                                             "genericropeparticle"])
        }
    }
}

/// A wallpaper directory that lives until `body` returns, so draws can still read their materials and shaders.
private enum ParticleSceneFiles {
    static func withScene(_ objects: [[String: Any]], files: [String: Any],
                          _ body: (WPEParityProgramScene) throws -> Void) throws {
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
                                       settings: WPEParityProgramSettings()))
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
