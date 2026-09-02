import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

/// The two GLSL preprocess stages are memoized, and a memo is only as safe as
/// its key: drop one dimension and two different shaders silently share one
/// processed source, which renders the wrong thing without an error anywhere.
///
/// Every test below varies exactly ONE key dimension and asserts the second call
/// did not receive the first call's value. Each is therefore also the mutation
/// probe for its dimension — delete that dimension from the key and the matching
/// test fails, which is what proves the memo is live rather than a no-op.
@Suite("Shader program source fingerprint")
struct WPEShaderProgramFingerprintTests {
    @Test("Builtins skip the fingerprint; authored programs carry one")
    func builtinsSkipFingerprint() {
        // Builtins are guarded out of `makeCompileRequest`, so they never reach the
        // stage-4 memo and their fingerprint would never be read; the builder's own
        // `builtinProgram` memo keys on (name, combos) and needs no hash either.
        let builtin = WPEShaderProgram(
            name: "copy",
            vertexSource: "void main() {}",
            fragmentSource: "void main() {}",
            isBuiltin: true
        )
        #expect(builtin.sourceFingerprint == nil)

        let authored = WPEShaderProgram(
            name: "effects/blur",
            vertexSource: "void main() {}",
            fragmentSource: "void main() {}",
            isBuiltin: false
        )
        #expect(authored.sourceFingerprint != nil)
    }

    @Test("Differing sources fingerprint differently")
    func fingerprintTracksSources() {
        func program(_ fragment: String) -> WPEShaderProgram {
            WPEShaderProgram(
                name: "effects/blur",
                vertexSource: "void main() {}",
                fragmentSource: fragment,
                isBuiltin: false
            )
        }
        #expect(program("a").sourceFingerprint != program("b").sourceFingerprint)
        #expect(program("a").sourceFingerprint == program("a").sourceFingerprint)
    }
}

@Suite("WPE shader preprocess memo")
struct WPEShaderPreprocessMemoTests {
    // MARK: - Stage 4: WPEMetalRenderExecutor.makeCompileRequest

    @Test("Stage-4 memo key separates shader names")
    func stageFourKeyCoversShaderName() throws {
        let namespace = UUID().uuidString
        let first = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            shaderName: "effects/memo-name-a-\(namespace)"
        )))
        let second = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            shaderName: "effects/memo-name-b-\(namespace)"
        )))
        #expect(first.shaderName != second.shaderName)
        // `shaderName` is hashed into `sourceHash`, which becomes the disk-cache
        // identity — sharing it across names would poison that cache too.
        #expect(first.sourceHash != second.sourceHash)
    }

    @Test("Stage-4 memo key separates vertex sources")
    func stageFourKeyCoversVertexSource() throws {
        let namespace = UUID().uuidString
        let first = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            vertexBody: "float wpe_probe_a() { return 1.0; }"
        )))
        let second = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            vertexBody: "float wpe_probe_b() { return 2.0; }"
        )))
        #expect(first.processedVertexSource != second.processedVertexSource)
        #expect(first.processedVertexSource.contains("wpe_probe_a"))
        #expect(second.processedVertexSource.contains("wpe_probe_b"))
    }

    @Test("Stage-4 memo key separates fragment sources")
    func stageFourKeyCoversFragmentSource() throws {
        let namespace = UUID().uuidString
        let first = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            fragmentBody: "float wpe_probe_a() { return 1.0; }"
        )))
        let second = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            fragmentBody: "float wpe_probe_b() { return 2.0; }"
        )))
        #expect(first.processedFragmentSource != second.processedFragmentSource)
        #expect(first.processedFragmentSource.contains("wpe_probe_a"))
        #expect(second.processedFragmentSource.contains("wpe_probe_b"))
    }

    @Test("Stage-4 memo key separates combo values")
    func stageFourKeyCoversComboValues() throws {
        let namespace = UUID().uuidString
        let first = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            comboValues: ["WPEPROBE": 1]
        )))
        let second = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            comboValues: ["WPEPROBE": 2]
        )))
        #expect(first.comboValues["WPEPROBE"] == 1)
        #expect(second.comboValues["WPEPROBE"] == 2)
        #expect(first.processedFragmentSource.contains("#define WPEPROBE 1"))
        #expect(second.processedFragmentSource.contains("#define WPEPROBE 2"))
    }

    @Test("Stage-4 memo key separates material texture bindings")
    func stageFourKeyCoversMaterialTextureBindings() throws {
        let namespace = UUID().uuidString
        // Both are `.image`, so the premultiplied-alpha flags stay identical and
        // only the material binding differs.
        let first = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            textureBindings: [1: .image("materials/probe_a.tex")]
        )))
        let second = try #require(try Self.compileRequest(Self.probe(
            namespace: namespace,
            textureBindings: [1: .image("materials/probe_b.tex")]
        )))
        #expect(first.textureBindings[1] == "materials/probe_a.tex")
        #expect(second.textureBindings[1] == "materials/probe_b.tex")
        #expect(first.premultipliedInputSlots == second.premultipliedInputSlots)
    }

    @Test("Stage-4 memo returns a value identical to the uncached one")
    func stageFourMemoValueMatchesUncachedValue() throws {
        let namespace = UUID().uuidString
        let miss = try #require(try Self.compileRequest(Self.probe(namespace: namespace, passID: "pass.first")))
        // Different pass id, identical process inputs: the pass id is
        // deliberately NOT in the key, so this second call is served by the memo.
        let hit = try #require(try Self.compileRequest(Self.probe(namespace: namespace, passID: "pass.second")))
        #expect(miss.shaderName == hit.shaderName)
        #expect(miss.processedVertexSource == hit.processedVertexSource)
        #expect(miss.processedFragmentSource == hit.processedFragmentSource)
        #expect(miss.sourceHash == hit.sourceHash)
        #expect(miss.comboValues == hit.comboValues)
        #expect(miss.textureBindings == hit.textureBindings)
        #expect(miss.premultipliedInputSlots == hit.premultipliedInputSlots)
        #expect(miss.premultipliedOutput == hit.premultipliedOutput)
        #expect(miss == hit)
    }

    @Test("Premultiplied-alpha flags stay out of the stage-4 key and are applied after it")
    func stageFourPremultipliedAlphaAppliedAfterMemo() throws {
        let namespace = UUID().uuidString
        let straight = try #require(try Self.compileRequest(Self.probe(namespace: namespace, blending: "normal")))
        // Identical process inputs, so this is a memo hit — but the blend mode
        // is not a `process` input, so the flag must be re-applied on top of the
        // memoized value rather than inherited from it.
        let premultiplied = try #require(
            try Self.compileRequest(Self.probe(namespace: namespace, blending: "premultiplied"))
        )
        #expect(straight.premultipliedOutput == false)
        #expect(premultiplied.premultipliedOutput == true)
        #expect(straight.processedFragmentSource == premultiplied.processedFragmentSource)
        #expect(straight.sourceHash == premultiplied.sourceHash)
        #expect(straight.translationCacheKey != premultiplied.translationCacheKey)
    }

    @Test("Source fingerprint separates a re-cut vertex/fragment pair")
    func sourceFingerprintIsLengthPrefixed() {
        // A plain concatenation would give these two programs one fingerprint.
        let left = WPEShaderProgram(name: "probe", vertexSource: "ab", fragmentSource: "c", isBuiltin: false)
        let right = WPEShaderProgram(name: "probe", vertexSource: "a", fragmentSource: "bc", isBuiltin: false)
        #expect(left.sourceFingerprint != right.sourceFingerprint)
        let same = WPEShaderProgram(name: "other", vertexSource: "ab", fragmentSource: "c", isBuiltin: false)
        #expect(left.sourceFingerprint == same.sourceFingerprint)
    }

    // MARK: - Stage 3: WPEShaderSourceLoader.preprocess

    @Test("Stage-3 memo key separates raw sources")
    func stageThreeKeyCoversSource() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let first = try builder.preprocessShaderStageForTesting(
            source: "void main() { float wpe_probe_a = 1.0; }",
            logicalPath: "shaders/probe.vert",
            stage: .vertex,
            comboValues: [:]
        )
        let second = try builder.preprocessShaderStageForTesting(
            source: "void main() { float wpe_probe_b = 2.0; }",
            logicalPath: "shaders/probe.vert",
            stage: .vertex,
            comboValues: [:]
        )
        #expect(first.contains("wpe_probe_a"))
        #expect(second.contains("wpe_probe_b"))
        #expect(first != second)
    }

    @Test("Stage-3 memo key separates logical paths")
    func stageThreeKeyCoversLogicalPath() throws {
        // `#include "helper.h"` resolves against the requesting file's own
        // directory, so identical source text under two paths expands differently.
        let fixture = try Self.makeFixture(files: [
            "shaders/dir_a/helper.h": "#define WPE_HELPER_ID 1",
            "shaders/dir_b/helper.h": "#define WPE_HELPER_ID 2",
        ])
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let source = """
        #include "helper.h"
        void main() {}
        """
        let first = try builder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/dir_a/probe.vert",
            stage: .vertex,
            comboValues: [:]
        )
        let second = try builder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/dir_b/probe.vert",
            stage: .vertex,
            comboValues: [:]
        )
        #expect(first.contains("#define WPE_HELPER_ID 1"))
        #expect(second.contains("#define WPE_HELPER_ID 2"))
        #expect(first != second)
    }

    @Test("Stage-3 memo key separates stages")
    func stageThreeKeyCoversStage() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let source = "void main() { gl_FragColor = vec4(1.0); }"
        let vertex = try builder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/probe.glsl",
            stage: .vertex,
            comboValues: [:]
        )
        let fragment = try builder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/probe.glsl",
            stage: .fragment,
            comboValues: [:]
        )
        #expect(vertex.contains("gl_FragColor"))
        #expect(!vertex.contains("out_FragColor"))
        #expect(fragment.contains("out_FragColor"))
        #expect(!fragment.contains("gl_FragColor"))
    }

    @Test("Stage-3 memo key separates combo values")
    func stageThreeKeyCoversComboValues() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let source = "void main() {}"
        let first = try builder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/probe.vert",
            stage: .vertex,
            comboValues: ["WPEPROBE": 1]
        )
        let second = try builder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/probe.vert",
            stage: .vertex,
            comboValues: ["WPEPROBE": 2]
        )
        #expect(first.contains("#define WPEPROBE 1"))
        #expect(second.contains("#define WPEPROBE 2"))
        #expect(first != second)
    }

    @Test("Stage-3 memo returns a value identical to the uncached one")
    func stageThreeMemoValueMatchesUncachedValue() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let source = "void main() { float wpe_probe = 1.0; }"
        let miss = try builder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/probe.vert",
            stage: .vertex,
            comboValues: ["WPEPROBE": 3]
        )
        let hit = try builder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/probe.vert",
            stage: .vertex,
            comboValues: ["WPEPROBE": 3]
        )
        #expect(miss == hit)
        // A fresh builder has its own memo (the included headers' contents are
        // NOT in the key — only the per-scene resolver scope makes that sound).
        let coldBuilder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let cold = try coldBuilder.preprocessShaderStageForTesting(
            source: source,
            logicalPath: "shaders/probe.vert",
            stage: .vertex,
            comboValues: ["WPEPROBE": 3]
        )
        #expect(cold == miss)
    }

    /// Stage 4 (`WPEShaderPreprocessor`) does no `#include` resolution of its
    /// own; that is sound only while stage 3 hands it fully expanded source.
    @Test("Stage-3 output carries no #include line")
    func stageThreeOutputHasNoIncludeLines() throws {
        let fixture = try Self.makeFixture(files: [
            "shaders/helper.h": "#include \"nested.h\"\n#define WPE_HELPER_ID 1",
            "shaders/nested.h": "#define WPE_NESTED_ID 2",
        ])
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        for stage in [WPEShaderStage.vertex, .fragment] {
            let expanded = try builder.preprocessShaderStageForTesting(
                source: "#include \"common.h\"\n  #include \"helper.h\"\nvoid main() {}",
                logicalPath: "shaders/probe.glsl",
                stage: stage,
                comboValues: [:]
            )
            let includeLines = expanded
                .components(separatedBy: .newlines)
                .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#include") }
            #expect(includeLines.isEmpty, "\(stage): \(includeLines)")
            #expect(expanded.contains("#define WPE_HELPER_ID 1"))
            #expect(expanded.contains("#define WPE_NESTED_ID 2"))
        }
    }

    // MARK: - Builtin program memo: WPEShaderSourceLoader.builtinProgram

    @Test("Builtin memo returns the same program for the same (name, combos)")
    func builtinMemoHitsOnSameKey() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let combos = ["WPEPROBE": 1, "BLENDMODE": 2]
        let miss = try #require(builder.builtinProgramForTesting(shaderName: "genericimage2", combos: combos))
        let hit = try #require(builder.builtinProgramForTesting(shaderName: "genericimage2", combos: combos))
        #expect(miss.isBuiltin)
        #expect(miss.fragmentSource.contains("#define WPEPROBE 1"))
        #expect(miss == hit)
        // A fresh loader computes the same value: the memo is a pure-function cache.
        let cold = try #require(
            WPERenderPipelineBuilder(cacheRootURL: fixture.root)
                .builtinProgramForTesting(shaderName: "genericimage2", combos: combos)
        )
        #expect(cold == miss)
    }

    @Test("Builtin memo key separates combos and shader names")
    func builtinMemoKeyCoversCombosAndName() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let first = try #require(builder.builtinProgramForTesting(shaderName: "genericimage2", combos: ["WPEPROBE": 1]))
        let second = try #require(builder.builtinProgramForTesting(shaderName: "genericimage2", combos: ["WPEPROBE": 2]))
        #expect(first.fragmentSource.contains("#define WPEPROBE 1"))
        #expect(second.fragmentSource.contains("#define WPEPROBE 2"))
        #expect(first != second)

        let copy = try #require(builder.builtinProgramForTesting(shaderName: "copy", combos: ["WPEPROBE": 1]))
        #expect(copy.name == "copy")
        #expect(copy != first)

        // Workshop custom shaders are not builtins; nil is the (memoized) answer.
        #expect(builder.builtinProgramForTesting(shaderName: "effects/custom_probe", combos: [:]) == nil)
        #expect(builder.builtinProgramForTesting(shaderName: "effects/custom_probe", combos: [:]) == nil)
    }

    // MARK: - Fixtures

    private static func compileRequest(
        _ pass: WPEPreparedRenderPass
    ) throws -> WPEShaderCompileRequest? {
        try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false)
    }

    /// One probe pass. Every parameter that is not overridden is byte-identical
    /// across calls sharing a `namespace`, so a test varying one parameter is
    /// varying exactly one memo-key dimension. The namespace keeps each test's
    /// entries out of the other tests' — the stage-4 memo is process-global.
    private static func probe(
        namespace: String,
        passID: String = "memo.probe",
        shaderName: String? = nil,
        vertexBody: String = "float wpe_probe_default() { return 0.0; }",
        fragmentBody: String = "float wpe_probe_default() { return 0.0; }",
        comboValues: [String: Int] = [:],
        textureBindings: [Int: WPETextureReference] = [:],
        blending: String = "normal"
    ) -> WPEPreparedRenderPass {
        let name = shaderName ?? "effects/memo-probe-\(namespace)"
        let vertex = """
        attribute vec3 a_Position;
        \(vertexBody)
        void main() { gl_Position = vec4(a_Position, 1.0); }
        """
        let fragment = """
        \(fragmentBody)
        void main() { gl_FragColor = vec4(1.0); }
        """
        let pass = WPERenderPass(
            id: passID,
            phase: .effect(file: "effects/memo_probe/effect.json"),
            shader: name,
            source: .image("materials/base.tex"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: comboValues,
            blending: blending,
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        return WPEPreparedRenderPass(
            pass: pass,
            shader: WPEShaderProgram(
                name: name,
                vertexSource: vertex,
                fragmentSource: fragment,
                isBuiltin: false
            ),
            textureBindings: textureBindings,
            comboValues: comboValues,
            uniformValues: [:]
        )
    }

    private struct Fixture {
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func makeFixture(files: [String: String] = [:]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEShaderPreprocessMemoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: fileURL)
        }
        return Fixture(root: root)
    }
}
