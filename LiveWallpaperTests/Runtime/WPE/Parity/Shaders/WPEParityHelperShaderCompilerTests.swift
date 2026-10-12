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
