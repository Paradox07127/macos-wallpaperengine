#if !LITE_BUILD
import CryptoKit
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

    static let expectedSchemaVersion = 25
    static let expectedFingerprint = "82ad0c7a39f9dc1bebc14cdd06afe2a4beb37c8538f74c1757e6069305b67831"

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
