import CoreGraphics
import LiveWallpaperProWPE
import Testing

private typealias F = ParitySceneFixtures

/// Minimal render-graph layers for the document conversion.
private enum Graph {
    static func pass(_ shader: String, object: String = "7", effect: String = "1", index: Int = 0,
                     phase: WPERenderPassPhase = .effect(file: "1.json"),
                     target: WPERenderTarget = .layerComposite(name: "x"),
                     textures: [Int: WPETextureReference] = [:]) -> WPERenderPass {
        let identity = WPERenderEffectPassIdentity(objectID: object, authoredEffectID: effect,
                                                   authoredEffectPath: "\(effect).json", effectPassIndex: index,
                                                   authoredOverrideID: nil)
        return WPERenderPass(id: "\(object).\(index)", phase: phase, shader: shader, source: .previous, target: target,
                             textures: textures, binds: [:], constants: [:], combos: [:],
                             authoredJSON: WPERenderPassAuthoredJSON(effectIdentity: identity),
                             blending: "translucent", cullMode: "nocull", depthTest: "disabled",
                             depthWrite: "disabled")
    }

    static func layer(_ id: String = "7", width: Double = 400, height: Double = 200, fbos: [WPERenderFBO] = [],
                      passes: [WPERenderPass]) -> WPERenderLayer {
        let size = CGSize(width: width, height: height)
        return WPERenderLayer(objectID: id, objectName: id, imagePath: "models/\(id).json", materialPath: nil,
                              geometry: WPERenderLayerGeometry(origin: .zero, scale: .one, angles: .zero,
                                                               alignment: .center, size: size, alpha: 1,
                                                               color: .one, brightness: 1),
                              compositeA: "a", compositeB: "b", localFBOs: fbos, passes: passes)
    }

    static func convert(_ layers: [WPERenderLayer]) throws -> WPEParitySceneDescription {
        let general = WPESceneGeneral(clearColor: .zero,
                                      orthogonalProjection: WPESceneOrthogonalProjection(width: 1920, height: 1080,
                                                                                         auto: false),
                                      clearEnabled: WPESceneAuthoredField(seed: true))
        let document = WPESceneDocument(camera: .defaultCamera, general: general, imageObjects: [], diagnostics: [])
        return try WPEParitySceneDescription(document: document, graph: WPERenderGraph(layers: layers))
    }

    /// The converted FBOs of the single effect that writes `fbo`.
    static func converted(_ fbo: WPERenderFBO, width: Double = 400, height: Double = 200) throws
        -> [WPEParitySceneFBO] {
        let layer = layer(width: width, height: height, fbos: [fbo],
                          passes: [pass("p", target: .fbo(name: fbo.name))])
        return try convert([layer]).objects[0].effects[0].fbos
    }
}

struct ParitySceneLastEffectRoutingTests {
    @Test func onlyTheFinalPassOfTheLastEffectDrawsIntoTheDestination() throws {
        let last = WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "p0", compose: true), WPEParityScenePass(shader: "p1"),
        ])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [last])]))
        #expect(Array(F.lines(frame).dropFirst(3)) == [
            "bind \(F.br1)",
            "draw genericimage2 [L/image] normal rgba quad",
            "bind \(F.br0)",
            "draw p0 [\(F.br1)] normal rgba quad",
            F.sceneBind,
            "draw p1 [\(F.br0)] translucent rgb mesh",
        ])
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        #expect(Self.compositeReadsBeforeWrite(frame) == [])
    }

    /// Draws that sample a pooled composite nothing has written earlier in the frame.
    private static func compositeReadsBeforeWrite(_ frame: WPEParitySceneFrame) -> [String] {
        var written: Set<WPEResourceID> = []
        var unwritten: [String] = []
        for operation in frame.operations {
            switch operation.kind {
            case .draw:
                guard let draw = frame.draws[operation.pass] else { continue }
                unwritten += draw.reads.filter { $0.rawValue.hasPrefix("sc.") && !written.contains($0) }
                    .map { "\(operation.pass.rawValue) reads \($0)" }
                written.insert(draw.target)
            case let .copy(_, destination), let .resolve(_, destination):
                written.insert(destination)
            case let .clearColor(view, _):
                written.insert(view.resource)
            default:
                break
            }
        }
        return unwritten
    }
}

struct ParitySceneFBOConversionTests {
    @Test func fboFormatMapsToMetalNames() throws {
        let expected = [
            "rgba8888": "rgba8unorm", "RGBA16F": "rgba16float", "rgba_half": "rgba16float",
            "rgba16161616f": "rgba16float", "r8": "r8unorm", "rg88": "rg8unorm", "r16f": "r16float",
            "rg1616f": "rg16float",
        ]
        for (authored, metal) in expected {
            let fbos = try Graph.converted(WPERenderFBO(name: "f", scale: 1, format: authored))
            #expect(fbos.map(\.format) == [metal], "\(authored)")
        }
    }

    @Test func unknownFBOFormatThrows() {
        #expect(throws: WPEParitySceneConversionError.unknownFBOFormat("bogus")) {
            try Graph.converted(WPERenderFBO(name: "f", scale: 1, format: "bogus"))
        }
    }

    @Test func fboExtentFollowsPixelSizeThenFitThenScale() throws {
        func extent(scale: Double, fit: Double? = nil, pixelSize: CGSize? = nil) throws -> [Int] {
            let fbo = WPERenderFBO(name: "f", scale: scale, fit: fit, format: "rgba8888", pixelSize: pixelSize)
            return try Graph.converted(fbo).flatMap { [$0.width, $0.height] }
        }
        #expect(try extent(scale: 2) == [200, 100])
        // catsout truncates the divided extent and parses `scale` as an integer.
        #expect(try extent(scale: 3) == [133, 66])
        #expect(try extent(scale: 2.5) == [200, 100])
        // A scale below 1 parses to 0 in catsout, which it resets to 1: no enlargement.
        #expect(try extent(scale: 0.5) == [400, 200])
        // Longest edge = fit, aspect kept, both edges rounded; `scale` no longer applies.
        #expect(try extent(scale: 2, fit: 64) == [64, 32])
        #expect(try extent(scale: 1, fit: 75) == [75, 38])
        // An explicit pixel size replaces the layer extent and is divided by `scale`; `fit` does not apply.
        #expect(try extent(scale: 2, fit: 64, pixelSize: CGSize(width: 300, height: 150)) == [150, 75])
    }
}

struct ParitySceneEffectCommandTests {
    @Test func copyCommandIsConvertedInPassOrder() throws {
        let layer = Graph.layer(fbos: [WPERenderFBO(name: "history", scale: 1, format: "rgba8888")], passes: [
            Graph.pass("commands/copy", phase: .command(file: "1.json"), target: .fbo(name: "history"),
                       textures: [0: .previous]),
            Graph.pass("trail", index: 1, textures: [1: .fbo("history")]),
        ])
        let effect = try Graph.convert([layer]).objects[0].effects[0]
        #expect(effect.passes == [
            WPEParityScenePass(shader: "commands/copy", target: "history", kind: .copy(source: nil)),
            WPEParityScenePass(shader: "trail", binds: ["history"], blend: .translucent),
        ])
        #expect(effect.fbos.map(\.name) == ["history"])
    }

    @Test func copyCommandEmitsACopyOperation() throws {
        let effect = WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "commands/copy", target: "history", kind: .copy(source: nil)),
            WPEParityScenePass(shader: "trail", binds: ["history"]),
        ], fbos: [WPEParitySceneFBO(name: "history", width: 512, height: 256)])
        let frame = WPEParitySceneFrameBuilder.build(F.scene([F.layer(effects: [effect])]))
        #expect(Array(F.lines(frame).dropFirst(3)) == [
            "bind \(F.br0)",
            "draw genericimage2 [L/image] normal rgba quad",
            "copy \(F.br0)->L/e/history",
            F.sceneBind,
            "draw trail [\(F.br0),L/e/history] translucent rgb mesh",
        ])
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }

    @Test func swapPartnerIsConverted() throws {
        let layer = Graph.layer(fbos: [
            WPERenderFBO(name: "a", scale: 1, format: "rgba8888", swapPartner: "b"),
            WPERenderFBO(name: "b", scale: 1, format: "rgba8888", swapPartner: "a"),
        ], passes: [Graph.pass("step", target: .fbo(name: "a"), textures: [1: .fbo("b")])])
        let fbos = try Graph.convert([layer]).objects[0].effects[0].fbos
        #expect(fbos.map(\.swapPartner) == ["b", "a"])
    }

    @Test func swapExchangesBindingsEveryFrameAndKeepsContents() throws {
        let effect = WPEParitySceneEffect(id: "e", passes: [
            WPEParityScenePass(shader: "step", target: "a", binds: ["b"]),
            WPEParityScenePass(shader: "show", binds: ["a"]),
        ], fbos: [
            WPEParitySceneFBO(name: "a", width: 512, height: 256, swapPartner: "b"),
            WPEParitySceneFBO(name: "b", width: 512, height: 256, swapPartner: "a"),
        ])
        let scene = F.scene([F.layer(effects: [effect])])
        let expected: [[WPEResourceID]] = [["L/e/a", "L/e/b"], ["L/e/b", "L/e/a"]]
        for (frameIndex, pair) in expected.enumerated() {
            let frame = WPEParitySceneFrameBuilder.build(scene, frameIndex: frameIndex)
            #expect(frame.draws["L/e/0"]?.target == pair[0], "frame \(frameIndex)")
            #expect(frame.draws["L/e/0"]?.reads == [WPEResourceID(F.br0), pair[1]], "frame \(frameIndex)")
            #expect(frame.draws["L/e/1"]?.reads == [WPEResourceID(F.br0), pair[0]], "frame \(frameIndex)")
            let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
            for id in pair {
                #expect(graph.resources[id]?.lifetime == .persistent, "\(id) frame \(frameIndex)")
                #expect(graph.storage[id] == .dedicated, "\(id) frame \(frameIndex)")
            }
        }
    }
}

struct ParitySceneCrossLayerFBOTests {
    @Test func readOfAnotherLayersFBOResolvesToOneSharedResource() throws {
        let writer = Graph.layer("7", width: 800, height: 400,
                                 fbos: [WPERenderFBO(name: "glow", scale: 2, format: "rgba8888")],
                                 passes: [Graph.pass("emit", target: .fbo(name: "glow"))])
        let reader = Graph.layer("8", passes: [Graph.pass("use", object: "8", textures: [1: .fbo("glow")])])
        let description = try Graph.convert([writer, reader])
        let shared = WPEParitySceneFBO(name: "glow", width: 400, height: 200, shared: true)
        #expect(description.objects[0].effects[0].fbos == [shared])
        #expect(description.objects[1].effects[0].fbos == [shared])
        #expect(description.objects[1].effects[0].passes.map(\.binds) == [["glow"]])

        let frame = WPEParitySceneFrameBuilder.build(description)
        #expect(frame.draws["7/1/0"]?.target == WPEParitySceneResource.sharedFBO("glow"))
        #expect(frame.draws["8/1/0"]?.reads.contains(WPEParitySceneResource.sharedFBO("glow")) == true)
        #expect(frame.resources.count(where: { $0.id.rawValue.hasSuffix("glow") }) == 1)
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }
}
