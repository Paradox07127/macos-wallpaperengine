#if !LITE_BUILD
import CryptoKit
import Foundation
import Testing
@testable import LiveWallpaper

/// `WPEShaderTranslationCache` keys disk entries on the SHADER SOURCE, not on
/// the code that translates it. Every file below feeds the generated MSL, and
/// none of them is in the key: change one without bumping `schemaVersion` and
/// every user with a warm cache keeps replaying the previous translator's
/// output forever. Nothing breaks loudly — the stale MSL still compiles and
/// still renders, just the way the old translator rendered it.
///
/// `WPEShaderPreprocessor` counts too even though it runs BEFORE the cache
/// lookup: `sourceHash` is taken over the RAW source, so a preprocessor change
/// alters the MSL while leaving the key untouched.
///
/// When this fails: confirm the edit changes generated MSL (a comment or a
/// rename does not), bump `WPEShaderTranslationCache.schemaVersion`, then paste
/// the fingerprint the failure prints.
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
        // Stage 3: `#include` expansion, prelude, implicit combo defines and the
        // `gl_FragColor` rewrite all happen HERE, before the preprocessor above ever
        // sees the source — so this file shapes the MSL just as directly. It was
        // missing from this list until 2026-09-01; a stage-3 edit would have
        // silently kept serving stale warm-cache translations.
        "LiveWallpaper/Runtime/Metal/WPERenderPipelineBuilder.swift",
    ]

    /// Bump together with `schemaVersion`.
    static let expectedSchemaVersion = 1
    /// 2026-08-30: comment-only compression across eight of the files above moved the
    /// fingerprint without touching a line of code, so the MSL is byte-identical and
    /// `schemaVersion` deliberately stayed at 1 — bumping it would have thrown away every
    /// user's warm cache to re-translate to the same output.
    /// 2026-09-01, MSL-neutral, so `schemaVersion` stays at 1: `WPEShaderPreprocessor`
    /// lost its never-reached include resolver and `gl_FragColor` branch (stage 3
    /// already handles both), and `WPERenderPipelineBuilder` joined `translatorSources`
    /// above — its memo wrapper is a pure cache. Both are proven byte-for-byte by
    /// `WPEPreprocessGoldenBaselineTests` against a 2342-entry corpus baseline: 0 diffs.
    static let expectedFingerprint = "be1b9ddd8d6cba06ebb120169b510a43c030ad29641b77d808edbd9e6f4606b7"

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
