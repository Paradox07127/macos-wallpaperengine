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
    static let expectedSchemaVersion = 8
    /// 2026-08-30: comment-only compression across eight of the files above moved the
    /// fingerprint without touching a line of code, so the MSL is byte-identical and
    /// `schemaVersion` deliberately stayed at 1 — bumping it would have thrown away every
    /// user's warm cache to re-translate to the same output.
    /// 2026-09-01, MSL-neutral, so `schemaVersion` stays at 1: `WPEShaderPreprocessor`
    /// lost its never-reached include resolver and `gl_FragColor` branch (stage 3
    /// already handles both), and `WPERenderPipelineBuilder` joined `translatorSources`
    /// above — its memo wrapper is a pure cache. Both are proven byte-for-byte by
    /// `WPEPreprocessGoldenBaselineTests` against a 2342-entry corpus baseline: 0 diffs.
    /// 2026-09-05: schema 2 rejects invalid declarations before layout/MSL expansion.
    /// 2026-09-06: schema 3 rebuilds lens_distortion's `v_Distorsion` / `v_Transforms` /
    /// `v_TexCoord.zw` from its `.vert` instead of the screen-UV fallback, so every warm-cache
    /// entry for that shader holds the old, wrong MSL and must be discarded.
    /// 2026-09-06: schema 4 adds the same treatment for the 2798319181 depth-of-field chain,
    /// 3124095265 fade, 3082978660 audio bars and 3647393229 frame_builder.
    /// 2026-09-06: schema 5. Missing-uniform injection matches whole identifiers, so a
    /// shader carrying a look-alike name (`u_sizeFactor` beside a needed `u_size`) now
    /// gets the injection its cached MSL lacked (a declaration is what counts, not the name appearing anywhere); an audio `RESOLUTION` outside 16/32/64
    /// clamps to 32 instead of reading past the spectrum array.
    /// 2026-09-06: schema 6 injects the seven audio uniforms that `shake.vert` / `pulse.vert`
    /// declare inside `#if AUDIOPROCESSING`, so `v_AudioPulse` / `v_AudioShift` / `v_Pulse`
    /// rebuild the real response instead of a constant 0 (2370927443, issue #133); cached MSL
    /// for those shaders holds the deaf version.
    /// 2026-09-07: schema 7 rebuilds waterripple mask UVs from texture slot 1.
    /// 2026-09-09: schema 8 sizes each fragment signature to the texture/sampler slots the
    /// shader actually declares instead of a fixed 8, so a stock shader reaching
    /// `g_Texture8` (chroma4, fur4, genericimage4) compiles at all; cached MSL for every
    /// shader holds the fixed-8 signature and the payload gained the slot arity.
    static let expectedFingerprint = "5480cce0e3cece29e5edd7351f23d70039141135e4cbc0970aaff2556d169c03"

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
