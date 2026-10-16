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

    private func binaries() throws -> Binaries {
        let environment = ProcessInfo.processInfo.environment
        func path(_ key: String, _ fallback: String) -> URL {
            URL(fileURLWithPath: environment[key] ?? fallback)
        }
        let binaries = Binaries(
            helper: path("WPE_SHADERC", "/Users/example/Developer/wpe-shaderc-build/wpe-shaderc"),
            dxcompiler: path("WPE_DXCOMPILER",
                             "/Users/example/Developer/DirectXShaderCompiler/build-14.6/lib/libdxcompiler.dylib"),
            metalIRConverter: path("WPE_METALIRCONVERTER", "/usr/local/lib/libmetalirconverter.dylib")
        )
        for url in [binaries.helper, binaries.dxcompiler, binaries.metalIRConverter]
            where !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("Missing \(url.path); set WPE_SHADERC, WPE_DXCOMPILER and WPE_METALIRCONVERTER")
        }
        return binaries
    }

    private func makeCompiler(_ binaries: Binaries) throws -> WPEParityHelperShaderCompiler {
        try WPEParityHelperShaderCompiler(helper: binaries.helper, dxcompiler: binaries.dxcompiler,
                                          metalIRConverter: binaries.metalIRConverter, workDirectory: workDirectory)
    }
}
#endif
