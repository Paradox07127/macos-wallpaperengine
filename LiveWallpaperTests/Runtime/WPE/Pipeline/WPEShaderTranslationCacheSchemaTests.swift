#if !LITE_BUILD
import CryptoKit
import Darwin
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

/// The disk cache keys on the SHADER SOURCE, not on the code that translates it, so
/// editing any file below without bumping `WPEShaderTranslationCache.schemaVersion`
/// keeps serving the previous translator's MSL — silently, since stale MSL still compiles.
@Suite("WPE shader translation cache schema")
struct WPEShaderTranslationCacheSchemaTests {
    static let translatorSources = [
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Vertex.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderStageLink.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderInterfaceParser.swift",
        "LiveWallpaper/Models/WPEShaderInterface.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Main.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Math.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Uniforms.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Helpers.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Preprocessor.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Render.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Substitutions.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Varyings.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspilerTypes.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderPreprocessor.swift",
        "LiveWallpaper/Runtime/Metal/WPESwiftShaderCompiler.swift",
        // The uniform ABI: `WPEUniformType` shapes the MSL accessors and `WPEUniformPacking` the CPU bytes
        // they read, so a cached MSL from either side's previous layout would misread the other.
        "LiveWallpaper/Runtime/Metal/WPEUniformType.swift",
        "LiveWallpaper/Runtime/Metal/WPEUniformPacking.swift",
        // Stage 3 lives here: `#include` expansion, prelude, implicit combo defines and the
        // `gl_FragColor` rewrite shape the MSL before the preprocessor above sees the source.
        "LiveWallpaper/Runtime/Metal/WPERenderPipelineBuilder.swift",
    ]

    static let expectedSchemaVersion = 37
    static let expectedFingerprint = "dcc90a74305e3cb7d156cf1c8df2be90bdd612e3645b162eec84a849b4ada2e5"

    @Test("Hosted shader cache defaults stay in the process configuration scratch tree")
    func defaultCacheRootIsIsolated() {
        #expect(NSClassFromString("XCTestCase") != nil)
        let expected = ConfigurationDirectory().root.appendingPathComponent("wpe-msl", isDirectory: true)
        #expect(WPEShaderTranslationCache.defaultRootURL == expected)
        let production = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wpe-msl", isDirectory: true)
        #expect(WPEShaderTranslationCache.defaultRootURL != production)
    }

    @Test("Schema 14 payload cannot bypass a fresh translation or poison warm replay")
    func priorSchemaPayloadRecompilesThenReplaysWarm() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WPEShaderTranslationCache(rootURL: root)
        let compiler = try WPESwiftShaderCompiler(device: #require(MTLCreateSystemDefaultDevice()), translationCache: cache)
        let request = WPEShaderCompileRequest(
            shaderName: "schema-migration", processedVertexSource: "",
            processedFragmentSource: "uniform int counter;\nvoid main() { gl_FragColor = vec4(float(counter)); }",
            sourceHash: "schema-migration-fixture", comboValues: [:], textureBindings: [:]
        )
        let fresh = try compiler.compile(request)
        let directory = root.appendingPathComponent("v\(WPEShaderTranslationCache.schemaVersion)")
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var old = try JSONDecoder().decode(WPEShaderTranslationCache.Payload.self, from: Data(contentsOf: file))
        old.schemaVersion = 14
        old.mslSource = "stale translator payload must not reach Metal"
        try JSONEncoder().encode(old).write(to: file)
        cache.dropMemoryForTesting()
        let repaired = try compiler.compile(request)
        #expect(repaired.mslSource == fresh.mslSource)
        #expect(cache.diskHitCountForTesting == 0)
        #expect(cache.storeCountForTesting == 2)
        cache.dropMemoryForTesting()
        #expect(try compiler.compile(request).mslSource == fresh.mslSource)
        #expect(cache.diskHitCountForTesting == 1)
        #expect(try compiler.compile(request).mslSource == fresh.mslSource)
        #expect(cache.memoryHitCountForTesting == 1)
        #expect(cache.storeCountForTesting == 2)
    }

    @Test("Integer remainder stays exact above Float32 precision; floating WPE remainder still renders",
          arguments: ["uint bucket = 5.5 % 3;", "float bucketHash = 5.5; uint bucket = bucketHash % 3;",
                      "float frequency = 5.5; uint bucket = frequency % RESOLUTION;",
                      "uint bucket = 16777217u % (3u);",
                      "uint bucketHash = 16777217; uint divisor = 3; uint bucket = ((bucketHash)) % ((divisor));",
                      "uint bucket = (5.5) % 3;",
                      "float bucketHash = 5.5; uint bucket = ((bucketHash)) % 3;",
                      "uint bucket = float(5.5) % 3;",
                      "uint bucket = uint(5.5) % 3;"])
    func unsignedModuloColdAndWarmGPU(statement: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WPEShaderTranslationCache(rootURL: root)
        let compiler = WPESwiftShaderCompiler(device: device, translationCache: cache)
        let request = WPEShaderCompileRequest(
            shaderName: "modulo-precision", processedVertexSource: "",
            processedFragmentSource: "#define RESOLUTION 3\nvoid main() { \(statement) gl_FragColor = vec4(float(bucket) / 2.0, 0.0, 0.0, 1.0); }",
            sourceHash: UUID().uuidString, comboValues: [:], textureBindings: [:]
        )
        let cold = try compiler.compile(request)
        let coldPixel = try moduloPixel(device: device, result: cold)
        #expect(coldPixel == 255)
        cache.dropMemoryForTesting()
        let warm = try compiler.compile(request)
        #expect(cache.diskHitCountForTesting == 1)
        #expect(warm.mslSource == cold.mslSource)
        let warmPixel = try moduloPixel(device: device, result: warm)
        #expect(warmPixel == 255)
    }

    private func moduloPixel(device: MTLDevice, result: WPEShaderCompileResult) throws -> UInt8 {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try #require(device.makeDefaultLibrary()?.makeFunction(name: result.vertexFunctionName))
        let fragment = try WPEMetalColorOutput.fragment(
            library: result.library, name: result.fragmentFunctionName, format: .rgba8Unorm
        )
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: textureDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        #expect(pixel[3] == 255)
        return pixel[0]
    }

    private func cachePayload(_ text: String) -> WPEShaderTranslationCache.Payload {
        .init(schemaVersion: WPEShaderTranslationCache.schemaVersion,
              vertexFunctionName: "vertex", fragmentFunctionName: "fragment",
              mslSource: text, uniformLayout: [], samplerNames: [], textureSlotCount: 0)
    }

    @Test("Count eviction promotes memory hits and restores evicted entries from disk")
    func memoryCountEvictionKeepsMostRecentlyUsed() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WPEShaderTranslationCache(rootURL: root, memoryEntryLimit: 2)
        let a = cachePayload("a"), b = cachePayload("b"), c = cachePayload("c")
        cache.store(a, for: "a"); cache.store(b, for: "b")
        #expect(cache.lookup("a") == a)
        cache.store(c, for: "c")
        #expect(cache.memoryUsageForTesting().entries == 2)
        #expect(cache.lookup("a") == a)
        #expect(cache.diskHitCountForTesting == 0)
        #expect(cache.lookup("b") == b)
        #expect(cache.diskHitCountForTesting == 1)
        #expect(cache.memoryUsageForTesting().entries == 2)
    }

    @Test("Byte budget skips oversized entries and replacement/removal release accounting")
    func memoryByteEvictionAndOversizeDiskFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let small = cachePayload("small")
        let cost = try JSONEncoder().encode(small).count
        let cache = WPEShaderTranslationCache(rootURL: root, memoryByteLimit: cost * 2)
        cache.store(small, for: "a"); cache.store(small, for: "b")
        cache.store(small, for: "c")
        #expect(cache.memoryUsageForTesting().entries == 2)
        #expect(cache.memoryUsageForTesting().bytes == cost * 2)
        let large = cachePayload(String(repeating: "x", count: cost * 3))
        cache.store(large, for: "large")
        #expect(cache.lookup("large") == large)
        #expect(cache.diskHitCountForTesting == 1)
        #expect(cache.memoryUsageForTesting().bytes == cost * 2)
        #expect(cache.lookup("b") == small)
        #expect(cache.diskHitCountForTesting == 1)
        cache.store(large, for: "b")
        #expect(cache.memoryUsageForTesting().entries == 1)
        #expect(cache.memoryUsageForTesting().bytes == cost)
        cache.remove("c")
        #expect(cache.memoryUsageForTesting().bytes == 0)
        #expect(cache.lookup("c") == nil)
        cache.store(small, for: "d")
        cache.dropMemoryForTesting()
        #expect(cache.memoryUsageForTesting().entries == 0)
        #expect(cache.memoryUsageForTesting().bytes == 0)
        #expect(cache.lookup("d") == small)
        for (bytes, entries) in [(0, 2), (cost * 2, 0)] {
            let diskOnly = WPEShaderTranslationCache(rootURL: root,
                                                     memoryByteLimit: bytes, memoryEntryLimit: entries)
            diskOnly.store(small, for: "disabled")
            #expect(diskOnly.lookup("disabled") == small)
            #expect(diskOnly.memoryUsageForTesting().entries == 0)
            #expect(diskOnly.memoryUsageForTesting().bytes == 0)
            #expect(diskOnly.diskHitCountForTesting == 1)
        }
    }

    @Test("Unsafe disk entries become cache misses and recompile", .timeLimit(.minutes(1)),
          arguments: ["fifo", "directory", "symlink", "oversized", "invalid-layout"])
    func unsafeDiskEntryRecompiles(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let initialCache = WPEShaderTranslationCache(rootURL: root)
        let request = WPEShaderCompileRequest(
            shaderName: "disk-admission", processedVertexSource: "",
            processedFragmentSource: "uniform int counter;\nvoid main() { gl_FragColor = vec4(float(counter)); }",
            sourceHash: "disk-admission-fixture", comboValues: [:], textureBindings: [:]
        )
        let initial = try WPESwiftShaderCompiler(device: device, translationCache: initialCache).compile(request)
        let directory = root.appendingPathComponent("v\(WPEShaderTranslationCache.schemaVersion)")
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: file)
        let external = root.appendingPathComponent("external.json")
        try FileManager.default.removeItem(at: file)
        switch kind {
        case "fifo":
            #expect(mkfifo(file.path, 0o600) == 0)
        case "directory":
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        case "symlink":
            try data.write(to: external)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        case "oversized":
            try Data(repeating: 0, count: data.count + 1).write(to: file)
        default:
            var payload = try JSONDecoder().decode(WPEShaderTranslationCache.Payload.self, from: data)
            payload.vertexMSLSource = "cache must reject this before vertex slot arithmetic"
            payload.vertexUniformLayout = [.init(name: "bad", glslType: "float", slot: Int.max, slotCount: 1)]
            payload.vertexSamplerNames = []
            payload.vertexTextureSlotCount = 0
            try JSONEncoder().encode(payload).write(to: file)
        }
        let cache = WPEShaderTranslationCache(rootURL: root,
                                              diskByteLimit: kind == "oversized" ? data.count : WPEShaderTranslationCache.maximumDiskBytes)
        let repaired = try WPESwiftShaderCompiler(device: device, translationCache: cache).compile(request)
        #expect(repaired.mslSource == initial.mslSource)
        #expect(cache.diskHitCountForTesting == 0)
        #expect(cache.storeCountForTesting == 1)
        if kind == "symlink" {
            #expect(try Data(contentsOf: external) == data)
        }
    }

    @Test("Disk admission preserves a payload beyond the memory budget")
    func diskBudgetExceedsMemoryEntryBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = cachePayload("larger than this test's memory budget")
        let cache = WPEShaderTranslationCache(rootURL: root, memoryByteLimit: 1)
        cache.store(payload, for: "disk-only")
        #expect(cache.memoryUsageForTesting().entries == 0)
        #expect(cache.lookup("disk-only") == payload)
        #expect(cache.diskHitCountForTesting == 1)
        #expect(WPEShaderTranslationCache.maximumDiskBytes > WPEShaderTranslationCache.maximumMemoryBytes)
        let limit = try JSONEncoder().encode(payload).count - 1
        let noDisk = WPEShaderTranslationCache(rootURL: root, memoryByteLimit: 0, diskByteLimit: limit)
        noDisk.store(payload, for: "too-large")
        #expect(noDisk.lookup("too-large") == nil)
    }

    @Test("A translator edit forces a cache schema bump")
    func translatorFingerprintMatchesSchemaVersion() throws {
        var hasher = SHA256()
        for path in Self.translatorSources {
            let source = try RepositoryRoot.source(path)
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data(source.utf8))
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        #expect(WPEShaderTranslationCache.schemaVersion == Self.expectedSchemaVersion)
        #expect(
            fingerprint == Self.expectedFingerprint,
            Comment(rawValue: """
            The GLSL→MSL translator changed. A warm disk cache would keep \
            serving the previous translator's MSL, so bump \
            `WPEShaderTranslationCache.schemaVersion` (and \
            `expectedSchemaVersion` here), then record:
                static let expectedFingerprint = "\(fingerprint)"
            """)
        )
    }
}
#endif
