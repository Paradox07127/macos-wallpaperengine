import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPE render flag registry")
struct WPERenderFlagRegistryTests {

    private static let rendererRoots = [
        "LiveWallpaper/Runtime",
        "LiveWallpaper/Infrastructure",
        "Packages/LiveWallpaperProWPE/Sources",
    ]

    private static let excludedKeys: [String: String] = [
        "WPEAudioDebugLog": "log-only toggle; never changes what renders",
        "WPEDumpLayerPasses": "dump/trace toggle; prints per-layer pass dumps only",
        "WPEDumpScenePasses": "dump/trace toggle; prints the scene pass structure only",
        "WPEFrameGPUTimingLog": "log-only toggle; per-frame GPU timing aggregates, never changes what renders",
        "WPEFrameOccupancyLog": "log-only toggle; GPU-object and JSC-crossing counters, never changes what renders",
        "WPEHoverCursorDebug": "log-only toggle; never changes what renders",
        "WPEImageUniformDebugLog": "log-only toggle; never changes what renders",
        "WPEMemoryAuditLog": "log-only toggle; prints the texture/JSContext census after a load",
        "WPEMetalCaptureScene": "dump/trace toggle; records canonical oracle traces only",
        "WPEOracleEnabled": "DEBUG-only render-oracle master toggle; inert in Release (seeds RNG + freezes the clock only for trace determinism)",
        "WPEOracleFreezeTime": "DEBUG-only oracle frozen scene time; inert in Release",
        "WPEOraclePerPassHashes": "DEBUG-only oracle per-pass hashing opt-in; inert in Release",
        "WPEOracleReplayTime": "DEBUG-only oracle fidelity-replay frame global; inert in Release",
        "WPEOracleReplayDaytime": "DEBUG-only oracle fidelity-replay frame global; inert in Release",
        "WPEOracleReplayPointerX": "DEBUG-only oracle fidelity-replay frame global; inert in Release",
        "WPEOracleReplayPointerY": "DEBUG-only oracle fidelity-replay frame global; inert in Release",
        "WPEPassGPUProfileReportEvery": "profiling report cadence; diagnostics only",
        "WPEPuppetSkinDebugLog": "breadcrumb logging only; never changes rendering",
        "WPESceneDebugArtifactsEnabled": "dump/trace toggle; writes debug artifacts and extra logs only",
    ]

    @Test("Every renderer defaults key is registered or explicitly excluded")
    func rendererKeysAreRegisteredOrExcluded() throws {
        let discovered = try Self.rendererDefaultsKeys()
        let registered = Self.registeredRenderFlagKeys()
        let missing = discovered.subtracting(registered).subtracting(Self.excludedKeys.keys)
        #expect(missing.isEmpty, Comment(rawValue: """
            The renderer stack reads defaults keys that \
            WPERenderDiagnosticEnvironment.renderFlagKeys does not surface in bug \
            reports. Add each render-behaviour flag there, or add it to \
            excludedKeys here with a one-line reason:
            \(missing.sorted().joined(separator: "\n"))
            """))
    }

    @Test("Registry and exclusion list track live keys only")
    func registryTracksLiveKeysOnly() throws {
        let discovered = try Self.rendererDefaultsKeys()
        let registered = Self.registeredRenderFlagKeys()

        let staleRegistered = registered.subtracting(discovered)
        #expect(staleRegistered.isEmpty, Comment(rawValue: """
            WPERenderDiagnosticEnvironment.renderFlagKeys lists keys the renderer \
            stack no longer reads — remove them (or teach the scan the new read idiom):
            \(staleRegistered.sorted().joined(separator: "\n"))
            """))

        let staleExcluded = Set(Self.excludedKeys.keys).subtracting(discovered)
        #expect(staleExcluded.isEmpty, Comment(rawValue: """
            excludedKeys lists keys the renderer stack no longer reads — remove them:
            \(staleExcluded.sorted().joined(separator: "\n"))
            """))

        let overlap = registered.intersection(Self.excludedKeys.keys)
        #expect(overlap.isEmpty, Comment(rawValue: """
            Keys cannot be both registered and excluded:
            \(overlap.sorted().joined(separator: "\n"))
            """))
    }

    // MARK: - Renderer source scanning

    private static func rendererDefaultsKeys() throws -> Set<String> {
        let defaultsKeyPatterns = [
            /forKey:\s*"(WPE[A-Za-z0-9.]+)"/,
            /[Dd]efaultsKey\s*=\s*"(WPE[A-Za-z0-9.]+)"/,
            /puppetDefaultsFlagOptional\(\s*"(WPE[A-Za-z0-9.]+)"/,
        ]
        var keys: Set<String> = []
        for root in rendererRoots {
            let rootURL = projectURL(root)
            let files = try swiftFiles(under: rootURL)
            #expect(!files.isEmpty, "Renderer root moved — update rendererRoots: \(root)")
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                    guard !line.drop(while: \.isWhitespace).hasPrefix("//") else { continue }
                    for pattern in defaultsKeyPatterns {
                        for match in line.matches(of: pattern) {
                            keys.insert(String(match.output.1))
                        }
                    }
                }
            }
        }
        try #require(!keys.isEmpty, "Scan found no defaults keys — the read patterns rotted")
        return keys
    }

    private static func registeredRenderFlagKeys() -> Set<String> {
        Set(WPERenderDiagnosticEnvironment.renderFlagKeys)
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        RepositoryRoot.swiftFiles(underURL: root)
    }

    private static func projectURL(_ relativePath: String) -> URL {
        RepositoryRoot.url(relativePath)
    }
}
