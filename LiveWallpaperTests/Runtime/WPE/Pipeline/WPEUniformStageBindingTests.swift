#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Prepared uniform stage values preserve defaults and authored updates", .serialized)
struct WPEUniformStageBindingTests {
    private let vertex = """
    attribute vec3 a_Position;
    uniform vec2 shared; // {"material":"VSOffset","default":[0.25,0.5]}
    void main() { gl_Position = vec4(a_Position, 1); }
    """
    private let fragment = """
    uniform float shared; // {"material":"FSAlpha","default":0.75}
    void main() { gl_FragColor = vec4(shared); }
    """

    @Test func loaderDoesNotFeedFragmentDefaultToVertex() throws {
        let fixture = try prepared(constants: [:])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.pass.stageUniformBindings.count == 2)
        #expect(fixture.pass.stageUniformBindings.values.allSatisfy { $0.value == nil })
        try check(fixture.pass, expectedVertex: SIMD4<Float>(0.25, 0.5, 0, 0), expectedFragment: 0.75)
    }

    @Test func authoredMaterialAliasesAndLiveScriptUpdatesRemainIndependent() throws {
        let fixture = try prepared(constants: ["VSOffset": .vector([0.125, 0.375]), "FSAlpha": .number(0.875)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try check(fixture.pass, expectedVertex: SIMD4<Float>(0.125, 0.375, 0, 0), expectedFragment: 0.875)
        let updates: [String: WPESceneShaderConstantValue] = ["FSAlpha": .number(0.0625)]
        let bindings = WPEUniformStageBinding.resolved(fixture.pass.stageUniformBindings, at: 1, authoredUpdates: updates)
        let changed = WPEPreparedRenderPass(pass: fixture.pass.pass, shader: fixture.pass.shader,
                                            textureBindings: fixture.pass.textureBindings, comboValues: fixture.pass.comboValues,
                                            uniformValues: ["shared": .number(0.0625)], materialUniformNames: fixture.pass.materialUniformNames,
                                            stageUniformBindings: bindings)
        try check(changed, expectedVertex: SIMD4<Float>(0.125, 0.375, 0, 0), expectedFragment: 0.0625)
    }

    @Test func annotatedStageDefaultsStillBeatCanonicalFrameGlobals() throws {
        let fixture = try prepared(constants: [:],
                                   vertex: vertex.replacingOccurrences(of: "shared", with: "g_Brightness"),
                                   fragment: fragment.replacingOccurrences(of: "shared", with: "g_Brightness"))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frame = WPEFrameUniformContext(runtimeUniformValues: ["g_Brightness": .number(0.0625)],
                                           cameraUniformValues: [:], objectUniformValuesByPassID: [:])
        try check(fixture.pass, expectedVertex: SIMD4<Float>(0.25, 0.5, 0, 0), expectedFragment: 0.75, frame: frame)
    }

    @Test func inactiveConflictingDeclarationDoesNotCreateStageBindings() throws {
        let inactive = """
        #if DIFFERENT
        uniform float shared; // {"material":"FSAlpha","default":0.75}
        #else
        uniform vec2 shared; // {"material":"VSOffset","default":[0.25,0.5]}
        #endif
        void main() { gl_FragColor = vec4(shared,0,1); }
        """
        let fixture = try prepared(constants: [:], fragment: inactive)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.pass.stageUniformBindings.isEmpty)
    }

    private func check(_ pass: WPEPreparedRenderPass, expectedVertex: SIMD4<Float>, expectedFragment: Float, frame: WPEFrameUniformContext = .empty) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.frameUniformContext = frame
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
        let result = try executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredFullscreen))
        let vertex = try #require(result.vertexStage)
        let (vs, sources) = try executor.withUniformSourceTracing {
            try executor.packTranslatedUniforms(for: pass, layout: vertex.uniformLayout, stage: .vertex)
        }
        let fs = try executor.packTranslatedUniforms(for: pass, layout: result.uniformLayout)
        #expect(vs == [expectedVertex] && fs.first?.x == expectedFragment)
        #expect(sources?.count == 1)
    }

    private func prepared(constants: [String: WPESceneShaderConstantValue], vertex: String? = nil, fragment: String? = nil) throws -> (root: URL, pass: WPEPreparedRenderPass) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try (vertex ?? self.vertex).write(to: root.appendingPathComponent("shaders/stage_values.vert"), atomically: true, encoding: .utf8)
        try (fragment ?? self.fragment).write(to: root.appendingPathComponent("shaders/stage_values.frag"), atomically: true, encoding: .utf8)
        let pass = WPERenderPass(id: "stage_values.0", phase: .material, shader: "stage_values",
                                 source: .asset("unused"), target: .layerComposite(name: "a"), textures: [:], binds: [:],
                                 constants: constants, combos: ["DIFFERENT": 0], blending: "disabled", cullMode: "nocull",
                                 depthTest: "disabled", depthWrite: "disabled")
        let graph = WPERenderGraph(layers: [.init(objectID: "stage_values", objectName: "stage_values", imagePath: "unused", materialPath: nil,
                                                  geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass])])
        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: root).build(graph: graph)
        return try (root, #require(pipeline.layers.first?.passes.first))
    }
}
#endif
