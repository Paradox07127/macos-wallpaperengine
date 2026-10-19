#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

final class WPEParityHelperShaderCompilerTests: XCTestCase {
    private struct Binaries {
        let helper: URL
        let dxcompiler: URL
        let metalIRConverter: URL
    }

    private var workDirectory: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                         directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDirectory)
        super.tearDown()
    }

    func testCompilesCaptureProgramLikeThePrecompiledFixture() async throws {
        let compiler = try makeCompiler(binaries())
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        // Captures 1 and 2 are genericimage4's vertex and fragment stage.
        let program = try WPEHLSLProgram(
            vertex: Array(Data(contentsOf: root.appending(path: "hlsl/src_0x1.hlsl"))),
            fragment: Array(Data(contentsOf: root.appending(path: "hlsl/src_0x2.hlsl")))
        )
        let request = WPEParityShaderCompileRequest(program: program, compilerIdentity: compiler.compilerIdentity,
                                                    bindingABIVersion: 1)
        let start = ContinuousClock.now
        let compiled = try await compiler.compile(request)
        print("wpe-shaderc vertex + fragment (concurrent): \(ContinuousClock.now - start)")

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertEqual(Set(compiled.stages.keys), [.vertex, .fragment])
        for (stage, capture) in [(WPEParityShaderKey.Stage.vertex, 1), (.fragment, 2)] {
            let output = try XCTUnwrap(compiled.stages[stage])
            let reflection = try JSONDecoder().decode(WPEStageReflection.self, from: output.reflectionJSON)
            XCTAssertEqual(reflection.stage.rawValue, stage.rawValue)
            let library = try device.makeLibrary(data: output.metallib.withUnsafeBytes { DispatchData(bytes: $0) })
            XCTAssertNotNil(library.makeFunction(name: reflection.entry), "\(stage)")
            let fixture = try Data(contentsOf: root.appending(path: "compiled/\(capture).json"))
            XCTAssertEqual(output.reflectionJSON, fixture, "\(stage) reflection differs from compiled/\(capture).json")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDirectory.path), [])
    }

    /// 1400d5070.c:461-485: an unread COLOR0 is removed and the VS recompiled; an unread BLENDINDICES0 stays.
    func testUnreadVertexInputsArePrunedExceptBlendIndices() async throws {
        let compiler = try makeCompiler(binaries())
        let reflection = try await compileVertex("""
        struct VS_INPUT {
            float3 a_Position : POSITION0;
            float4 a_Color : COLOR0;
            uint4 a_BlendIndices : BLENDINDICES0;
        };
        float4 main(VS_INPUT IN) : SV_Position { return float4(IN.a_Position, 1); }
        """, compiler: compiler)
        XCTAssertEqual(reflection.vertexInputs.map(\.name), ["position0", "blendindices0"])
        XCTAssertEqual(reflection.unusedVertexInputs, ["BLENDINDICES0"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDirectory.path), [])
    }

    /// 1400d5070.c:475-481: when the pruned VS does not compile, the first compile's output is kept.
    func testFailedPrunedRecompileKeepsTheOriginalVertexStage() async throws {
        let compiler = try makeCompiler(binaries())
        // DXC proves the color unread, but the source still names it, so removing its declaration breaks the VS.
        let reflection = try await compileVertex("""
        struct VS_INPUT {
            float3 a_Position : POSITION0;
            float4 a_Color : COLOR0;
        };
        float4 main(VS_INPUT IN) : SV_Position {
            float4 position = float4(IN.a_Position, 1);
            if (false) { position += IN.a_Color; }
            return position;
        }
        """, compiler: compiler)
        XCTAssertEqual(reflection.vertexInputs.map(\.name), ["position0", "color0"])
        XCTAssertEqual(reflection.unusedVertexInputs, ["COLOR0"])
    }

    /// Captures 0x2a/0x2c and 0x55/0x57 are WPE's first and pruned second compile of the same vertex stage.
    func testCapturedVertexStagesCompileToTheEnginesPrunedInputs() async throws {
        let compiler = try makeCompiler(binaries())
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        for (first, second) in [(0x2A, 0x2C), (0x55, 0x57)] {
            func captured(_ number: Int) throws -> [UInt8] {
                try Array(Data(contentsOf: root.appending(path: "hlsl/src_0x\(String(number, radix: 16)).hlsl")))
            }
            let original = try captured(first)
            XCTAssertEqual(WPEHLSLRewriter.pruningVertexInputs(original, unusedSemantics: ["COLOR0"]),
                           try captured(second))
            let reflection = try await compileVertex(original, compiler: compiler)
            XCTAssertEqual(reflection.vertexInputs.map(\.name), ["position0"], "capture \(first)")
            XCTAssertNil(reflection.unusedVertexInputs, "capture \(first)")
        }
    }

    private func compileVertex(_ source: String,
                               compiler: WPEParityHelperShaderCompiler) async throws -> WPEStageReflection {
        try await compileVertex(Array(source.utf8), compiler: compiler)
    }

    private func compileVertex(_ source: [UInt8],
                               compiler: WPEParityHelperShaderCompiler) async throws -> WPEStageReflection {
        let request = WPEParityShaderCompileRequest(program: .init(vertex: source),
                                                    compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1)
        let compiled = try await compiler.compile(request)
        let output = try XCTUnwrap(compiled.stages[.vertex])
        let reflection = try JSONDecoder().decode(WPEStageReflection.self, from: output.reflectionJSON)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(data: output.metallib.withUnsafeBytes { DispatchData(bytes: $0) })
        XCTAssertNotNil(library.makeFunction(name: reflection.entry))
        return reflection
    }

    func testBrokenHLSLThrowsDXCMessage() async throws {
        let compiler = try makeCompiler(binaries())
        let program = WPEHLSLProgram(fragment: Array("float4 main() : SV_Target { return undeclared; }".utf8))
        let request = WPEParityShaderCompileRequest(program: program, compilerIdentity: compiler.compilerIdentity,
                                                    bindingABIVersion: 1)
        do {
            _ = try await compiler.compile(request)
            XCTFail("broken HLSL compiled")
        } catch {
            XCTAssertTrue(String(describing: error).contains("use of undeclared identifier 'undeclared'"), "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDirectory.path), [])
    }

    /// WPE's FXC expands macro arguments before `##`: `texSample2D(GRADIENT_SAMPLER, …)` pastes g_Texture4SamplerState.
    func testSamplerMacroArgumentExpandsBeforeTokenPaste() async throws {
        let compiler = try WPEParityShaderToolchain.makeCompiler().get()
        func compileFragment(_ gradient: String, _ shadow: String) async throws -> WPEStageReflection {
            let program = WPEHLSLProgram(fragment: Array("""
            #define texSample2D(s, u) s.Sample(s ## SamplerState, u)
            #define texSample2DLod(s, u, m) s.SampleLevel(s  ## SamplerState, u, m)
            #define texSample2DCompare(s, u, d) s.SampleCmpLevelZero(s ## SamplerComparisonState, u, d)
            #define GRADIENT_SAMPLER g_Texture4
            #define SHADOW_ATLAS_SAMPLER g_Texture6
            Texture2D g_Texture4:register(t4);
            SamplerState g_Texture4SamplerState:register(s4);
            Texture2D g_Texture6:register(t6);
            SamplerComparisonState g_Texture6SamplerComparisonState:register(s6);
            float4 main(float4 p : SV_Position) : SV_Target {
                return texSample2D(\(gradient), p.xy) * texSample2DLod(\(gradient), p.xy, 0.0)
                    * texSample2DCompare(\(shadow), p.xy, 0.5).r;
            }
            """.utf8))
            let compiled = try await compiler.compile(WPEParityShaderCompileRequest(
                program: program, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
            ))
            let output = try XCTUnwrap(compiled.stages[.fragment])
            return try JSONDecoder().decode(WPEStageReflection.self, from: output.reflectionJSON)
        }
        let expected: Set = ["g_Texture4", "g_Texture4SamplerState",
                             "g_Texture6", "g_Texture6SamplerComparisonState"]
        let direct = try await compileFragment("g_Texture4", "g_Texture6")
        XCTAssertEqual(Set(direct.resources.map(\.name)), expected)
        let viaMacro = try await compileFragment("GRADIENT_SAMPLER", "SHADOW_ATLAS_SAMPLER")
        XCTAssertEqual(Set(viaMacro.resources.map(\.name)), expected)
    }

    /// Exercise the actual HLSL Load through the helper and MSC; sampler clamping cannot satisfy this contract.
    /// https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-to-load
    func testDefaultCompilerPreservesOutOfBoundsLoadZero() async throws {
        let compiler = try makeCompiler(binaries())
        let program = WPEHLSLProgram(vertex: Array("""
        float4 main(uint id : SV_VertexID) : SV_Position {
            const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            return float4(p[id], 0, 1);
        }
        """.utf8), fragment: Array("""
        Texture2D<float4> tex : register(t0);
        float4 main(float4 position : SV_Position) : SV_Target {
            const int3 locations[8] = {int3(0,0,0), int3(-1,0,0), int3(2,0,0), int3(0,-1,0),
                                      int3(0,2,0), int3(0,0,1), int3(1,0,1), int3(0,0,2)};
            return tex.Load(locations[(uint)position.x]);
        }
        """.utf8))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: workDirectory.appending(path: "cache")
        ))
        let request = WPEParityShaderCompileRequest(program: program, compilerIdentity: compiler.compilerIdentity,
                                                    bindingABIVersion: 1)
        XCTAssertTrue(request.options.boundsCheck)
        let artifact = try await store.artifact(for: request)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let factory = WPEParityPipelineFactory(device: device)
        let pipeline = try factory.makePipeline(artifact: artifact, blend: .wpe(.normal, modifiers: .writeAlpha),
                                                colorPixelFormat: .rgba8Unorm)
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2,
                                                                       height: 2, mipmapped: true)
        let input = try XCTUnwrap(device.makeTexture(descriptor: inputDescriptor))
        let first: [UInt8] = [51, 102, 153, 204]
        let second: [UInt8] = [230, 128, 64, 255]
        input.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                      withBytes: first + first + first + first, bytesPerRow: 8)
        input.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 1, withBytes: second, bytesPerRow: 4)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8,
                                                                        height: 1, mipmapped: false)
        targetDescriptor.usage = .renderTarget
        targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let arena = try XCTUnwrap(WPEParityFrameArena(device: device, capacity: 65536))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try XCTUnwrap(arena.beginFrame(for: command))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var draw = try WPEParityDraw(
            pipeline: pipeline, depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared)),
            primitiveType: .triangle, vertexCount: 3
        )
        draw.textures = ["tex": input]
        try WPEParityDrawEncoder(factory: factory).encode(draw, frame: frame, hasDepthAttachment: false, on: encoder)
        encoder.endEncoding()
        command.commit()
        await command.completed()
        XCTAssertNil(command.error)
        var output = [UInt8](repeating: 255, count: 32)
        target.getBytes(&output, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 1), mipmapLevel: 0)
        let zero = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(output, first + zero + zero + zero + zero + second + zero + zero)
    }

    /// A helper before main indexes a float4[16] cbuffer array per element, as WPE's audio effects do; D3D11 reads
    /// 0 past the buffer. https://learn.microsoft.com/en-us/windows/win32/api/d3d11_1/nf-d3d11_1-id3d11devicecontext1-pssetconstantbuffers1
    func testCBufferArrayIndexedPastItsRegistersReadsZero() async throws {
        let compiler = try makeCompiler(binaries())
        let program = WPEHLSLProgram(vertex: Array("""
        float4 main(uint id : SV_VertexID) : SV_Position {
            const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            return float4(p[id], 0, 1);
        }
        """.utf8), fragment: Array("""
        cbuffer g_bufDynamic:register(b0)
        {
        const float4 g_Spectrum[16];
        }
        float4 spectrum(uint index) {
            return g_Spectrum[index];
        }
        float4 main(float4 position : SV_Position) : SV_Target {
            return spectrum((uint)position.x * 9);
        }
        """.utf8))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: workDirectory.appending(path: "cache")
        ))
        let request = WPEParityShaderCompileRequest(program: program, compilerIdentity: compiler.compilerIdentity,
                                                    bindingABIVersion: 1)
        XCTAssertTrue(request.options.boundsCheck)
        let artifact = try await store.artifact(for: request)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let factory = WPEParityPipelineFactory(device: device)
        let pipeline = try factory.makePipeline(artifact: artifact, blend: .wpe(.normal, modifiers: .writeAlpha),
                                                colorPixelFormat: .rgba8Unorm)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8,
                                                                        height: 1, mipmapped: false)
        targetDescriptor.usage = .renderTarget
        targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let arena = try XCTUnwrap(WPEParityFrameArena(device: device, capacity: 65536))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try XCTUnwrap(arena.beginFrame(for: command))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var draw = try WPEParityDraw(
            pipeline: pipeline, depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared)),
            primitiveType: .triangle, vertexCount: 3
        )
        let element = WPECBufferValue.vector([1, 0.6, 0.2, 1])
        draw.constants = [.fragment: ["g_Spectrum": .array(Array(repeating: element, count: 16))]]
        try WPEParityDrawEncoder(factory: factory).encode(draw, frame: frame, hasDepthAttachment: false, on: encoder)
        encoder.endEncoding()
        command.commit()
        await command.completed()
        XCTAssertNil(command.error)

        let entry = try XCTUnwrap(pipeline.fragment.bindingPlan.cbufferOffset(register: 0))
        let arenaRange = frame.buffer.gpuAddress ..< frame.buffer.gpuAddress + UInt64(frame.buffer.length)
        let contents = frame.buffer.contents()
        let lengths = stride(from: entry, to: frame.buffer.length - 24, by: WPEParityFrameArena.alignment).compactMap {
            arenaRange.contains(contents.loadUnaligned(fromByteOffset: $0, as: UInt64.self))
                ? contents.loadUnaligned(fromByteOffset: $0 + 16, as: UInt32.self) : nil
        }
        // Index 63 reads register 63, which ends at byte 1024.
        XCTAssertEqual(lengths, [1024], "cbuffer descriptor lengths")
        var output = [UInt8](repeating: 255, count: 32)
        target.getBytes(&output, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 1), mipmapLevel: 0)
        let inside: [UInt8] = [255, 153, 51, 255]
        XCTAssertEqual(output, inside + inside + [UInt8](repeating: 0, count: 24))
    }

    /// WPE packs `float g_AudioSpectrum64Left[64]` as float4[16]; the reflection must keep that packing.
    func testAudioSpectrumCBufferKeepsWPEPacking() async throws {
        let compiler = try makeCompiler(binaries())
        let program = WPEHLSLProgram(fragment: Array("""
        cbuffer g_bufDynamic:register(b1)
        {
        const float4 g_Texture0Resolution;
        const float4 g_AudioSpectrum64Left[16];
        const float4 g_AudioSpectrum64Right[16];
        }
        float getMirroredAudioValue(int index) {
            return (g_AudioSpectrum64Left[index].x + g_AudioSpectrum64Right[index].x) * 0.5;
        }
        float4 main(float4 position : SV_Position) : SV_Target {
            float accessArrayg_AudioSpectrum64Left[64] = (float[64])g_AudioSpectrum64Left;
            return float4(getMirroredAudioValue((int)position.x) * g_Texture0Resolution.x,
                          accessArrayg_AudioSpectrum64Left[(int)position.y], 0, 1);
        }
        """.utf8))
        let compiled = try await compiler.compile(WPEParityShaderCompileRequest(
            program: program, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let output = try XCTUnwrap(compiled.stages[.fragment])
        let reflection = try JSONDecoder().decode(WPEStageReflection.self, from: output.reflectionJSON)
        let cbuffer = try XCTUnwrap(reflection.cbuffers.first { $0.name == "g_bufDynamic" })
        XCTAssertEqual(cbuffer.size, 528)
        let right = try XCTUnwrap(cbuffer.variables.first { $0.name == "g_AudioSpectrum64Right" })
        XCTAssertEqual([right.offset, right.size, right.elements, right.columns], [272, 256, 16, 4])
        XCTAssertEqual(try WPECBufferLayout(cbuffer).boundLength, 1296)
    }

    func testIdentityFollowsLibraryBytesNotPath() throws {
        let binaries = try binaries()
        let original = try makeCompiler(binaries).compilerIdentity
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let copy = workDirectory.appending(path: "libdxcompiler.dylib")
        try FileManager.default.copyItem(at: binaries.dxcompiler, to: copy)
        let copied = try makeCompiler(Binaries(helper: binaries.helper, dxcompiler: copy,
                                               metalIRConverter: binaries.metalIRConverter)).compilerIdentity
        XCTAssertEqual(copied, original)

        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let modified = try makeCompiler(Binaries(helper: binaries.helper, dxcompiler: copy,
                                                 metalIRConverter: binaries.metalIRConverter)).compilerIdentity
        XCTAssertNotEqual(modified, original)
    }

    func testUnchangedToolchainIsHashedOnceAndRewrittenFileChangesIdentity() throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let files = Binaries(helper: workDirectory.appending(path: "helper"),
                             dxcompiler: workDirectory.appending(path: "dxcompiler"),
                             metalIRConverter: workDirectory.appending(path: "converter"))
        for url in [files.helper, files.dxcompiler, files.metalIRConverter] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        let first = try makeCompiler(files).compilerIdentity
        let second = try makeCompiler(files).compilerIdentity
        XCTAssertEqual(second, first)
        for url in [files.helper, files.dxcompiler, files.metalIRConverter] {
            XCTAssertEqual(WPEParityHelperShaderCompiler.fileHashCount(path: url.path), 1, url.lastPathComponent)
        }

        try Data("dxcompiler rewritten".utf8).write(to: files.dxcompiler)
        let rewritten = try makeCompiler(files).compilerIdentity
        XCTAssertNotEqual(rewritten, first)
        XCTAssertEqual(WPEParityHelperShaderCompiler.fileHashCount(path: files.dxcompiler.path), 2)
        XCTAssertEqual(WPEParityHelperShaderCompiler.fileHashCount(path: files.helper.path), 1)
    }

    func testDeadlineStopsSystemProcessAfterWaiterCancellation() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let invocation = WPEParityHelperShaderCompiler.Invocation(process: process, stage: .fragment, timeout: 0.25)
        let waiter = Task {
            try await withCheckedThrowingContinuation { invocation.start($0) }
        }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("The helper exceeded its independent deadline without failing")
        } catch let WPEParityHelperShaderCompiler.Failure.helperTimedOut(stage, seconds) {
            XCTAssertEqual(stage, .fragment)
            XCTAssertEqual(seconds, 0.25)
        }
        XCTAssertGreaterThan(process.processIdentifier, 0, "The system helper never started")
        XCTAssertFalse(process.isRunning, "The deadline returned before its helper exited")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }

    private func binaries() throws -> Binaries {
        let tools = try parityShaderToolchainURLs()
        return Binaries(helper: tools.helper, dxcompiler: tools.dxcompiler, metalIRConverter: tools.metalIRConverter)
    }

    private func makeCompiler(_ binaries: Binaries) throws -> WPEParityHelperShaderCompiler {
        try WPEParityHelperShaderCompiler(helper: binaries.helper, dxcompiler: binaries.dxcompiler,
                                          metalIRConverter: binaries.metalIRConverter, workDirectory: workDirectory)
    }
}
#endif
