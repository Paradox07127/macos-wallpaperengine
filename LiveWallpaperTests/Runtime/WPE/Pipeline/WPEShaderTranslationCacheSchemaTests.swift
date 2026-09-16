#if !LITE_BUILD
import CryptoKit
import Foundation
import Testing
@testable import LiveWallpaper

/// The disk cache keys on the SHADER SOURCE, not on the code that translates it, so
/// editing any file below without bumping `WPEShaderTranslationCache.schemaVersion`
/// keeps serving the previous translator's MSL — silently, since stale MSL still compiles.
@Suite("WPE shader translation cache schema")
struct WPEShaderTranslationCacheSchemaTests {

    static let translatorSources = [
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Main.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Helpers.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Preprocessor.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Render.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Substitutions.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspiler+Varyings.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderTranspilerTypes.swift",
        "LiveWallpaper/Runtime/Metal/WPEShaderPreprocessor.swift",
        "LiveWallpaper/Runtime/Metal/WPESwiftShaderCompiler.swift",
        // Stage 3 lives here: `#include` expansion, prelude, implicit combo defines and the
        // `gl_FragColor` rewrite shape the MSL before the preprocessor above sees the source.
        "LiveWallpaper/Runtime/Metal/WPERenderPipelineBuilder.swift",
    ]

    static let expectedSchemaVersion = 13
    static let expectedFingerprint = "e9cfb10130784fc8ff26dd1be061c21eb08c101f822388db0a401132bc662f0c"

    @Test("Hosted shader cache defaults stay in the process configuration scratch tree")
    func defaultCacheRootIsIsolated() {
        #expect(NSClassFromString("XCTestCase") != nil)
        let expected = ConfigurationDirectory().root.appendingPathComponent("wpe-msl", isDirectory: true)
        #expect(WPEShaderTranslationCache.defaultRootURL == expected)
        let production = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wpe-msl", isDirectory: true)
        #expect(WPEShaderTranslationCache.defaultRootURL != production)
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
