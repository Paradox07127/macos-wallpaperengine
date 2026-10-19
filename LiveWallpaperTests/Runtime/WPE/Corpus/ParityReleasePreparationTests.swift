#if !LITE_BUILD && !DEBUG
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

/// Opt-in preparation measurement of the ordinary Release driver, without presenting or DEBUG instrumentation.
/// Root verifies the app/test compiler flags are -O and runs each A/B trial in a fresh test-host process.
final class ParityReleasePreparationTests: XCTestCase {
    private struct Config: Decodable {
        struct CompilerPaths: Decodable {
            let helper: String
            let dxcompiler: String
            let metalIRConverter: String
        }

        let corpusRoot: String
        let engineAssetsRoot: String
        let scenes: [String]
        let resolution: [Int]
        let replanResolution: [Int]
        let compilerPaths: CompilerPaths
        let shaderCacheRoot: String
        /// Populate this toolchain's cache before formal fresh-process trials; these results are not measurements.
        let prewarmOnly: Bool?
        let seed: UInt32
        let shadowQuality: Int32
        let propertyOverridesByScene: [String: [String: WallpaperEngineProjectPropertyValue]]?
    }

    func testWarmShaderCacheLoadAndTwoSizeReplans() async throws {
        guard let configURL = TestScratch.externalFixtureURL(pathKey: "WPE_PARITY_RELEASE_PREPARATION_CONFIG") else {
            throw XCTSkip("Opt in with external fixtures and WPE_PARITY_RELEASE_PREPARATION_CONFIG")
        }
        let output = try XCTUnwrap(TestScratch.externalFixtureURL(pathKey: "WPE_PARITY_RELEASE_PREPARATION_OUTPUT"))
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Config.self, from: configData)
        for size in [config.resolution, config.replanResolution] {
            _ = try XCTUnwrap(size.count == 2 && size.allSatisfy { (1 ... 16384).contains($0) } ? true : nil,
                              "A positive two-dimensional target is required")
        }
        _ = try XCTUnwrap(config.resolution != config.replanResolution && !config.scenes.isEmpty
            && Set(config.scenes).count == config.scenes.count ? true : nil, "Distinct sizes and unique scenes required")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let work = FileManager.default.temporaryDirectory.appending(path: "parity-release-prepare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let compiler = try WPEParityHelperShaderCompiler(
            helper: URL(fileURLWithPath: config.compilerPaths.helper),
            dxcompiler: URL(fileURLWithPath: config.compilerPaths.dxcompiler),
            metalIRConverter: URL(fileURLWithPath: config.compilerPaths.metalIRConverter), workDirectory: work
        )
        let diskCache = WPEParityShaderDiskCache(cachesURL: URL(fileURLWithPath: config.shaderCacheRoot))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        for id in config.scenes {
            _ = try XCTUnwrap(!id.isEmpty && id.allSatisfy(\.isNumber) ? true : nil, "Workshop ID must be numeric")
            let row = try await prepare(id: id, config: config, device: device, compiler: compiler, diskCache: diskCache)
            results.append(row)
            let receipt: [String: Any] = [
                "configuration": "Release (!DEBUG); verify -O in root build log",
                "pid": ProcessInfo.processInfo.processIdentifier, "compilerIdentity": compiler.compilerIdentity,
                "configSHA256": SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined(),
                "shaderCacheRoot": config.shaderCacheRoot, "scenes": results,
                "phase": config.prewarmOnly == true ? "prewarm-only" : "warm-cache-measurement",
                "scope": "Preparation wall time and RUSAGE_SELF CPU deltas; no present, screenshot or GPU timing",
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appending(path: "preparation.json"), options: .atomic)
        }
        XCTAssertEqual(results.count, config.scenes.count)
    }

    private func prepare(id: String, config: Config, device: MTLDevice, compiler: WPEParityHelperShaderCompiler,
                         diskCache: WPEParityShaderDiskCache) async throws -> [String: Any] {
        let folder = URL(fileURLWithPath: config.corpusRoot).appending(path: id, directoryHint: .isDirectory)
        let project = try WallpaperEngineProject.read(from: folder)
        _ = try XCTUnwrap(project.type == .scene ? true : nil, "Requested input must be a scene")
        let package = folder.appending(path: project.packageFileName(in: folder))
        let hasPackage = FileManager.default.fileExists(atPath: package.path)
        let provider: any WPESceneAssetProvider = if hasPackage {
            try WPEPackageSceneAssetProvider(packageURL: package)
        } else {
            WPEDirectorySceneAssetProvider(rootURL: folder)
        }
        let descriptor = SceneDescriptor(workshopID: id, cacheRelativePath: "parity-release-prepare/\(id)",
                                         entryFile: project.entryFile.isEmpty ? "scene.json" : project.entryFile,
                                         capabilityTier: .degraded, propertyOverrides: config.propertyOverridesByScene?[id] ?? [:])
        let values = WallpaperEngineProjectPropertySchema.effectiveSceneValues(descriptor: descriptor, cacheRootURL: folder)
        let entry = try provider.data(atRelativePath: descriptor.entryFile)
        let repaired = (try? WallpaperEngineProjectPropertySchema.read(from: folder, includeSchemeColor: true))
            .map { WPESceneParallaxBindingInference.applying(to: entry, schema: $0) } ?? entry
        let document = try WPESceneDocumentParser.parse(data: repaired, userValues: values)
        let assets = WPEParitySceneAssets.make(provider: provider, projectRoot: folder, dependencyMounts: [],
                                               engineAssetsRootURL: URL(fileURLWithPath: config.engineAssetsRoot),
                                               userValues: values)
        var settings = try WPEParityProductSettings.make(descriptor: descriptor, device: device)
        settings.shadowQuality = config.shadowQuality
        var host = WPEParitySceneScript.Host(userPropertiesJSON: WPEParitySceneScript.userPropertiesJSON(
            projectRoot: folder, values: values
        ))
        host.dateEpochMillis = 1_700_000_000_000
        let size = CGSize(width: config.resolution[0], height: config.resolution[1])
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        let packageSHA: Any = try hasPackage
            ? SHA256.hash(data: Data(contentsOf: package, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined() as Any
            : NSNull()
        let loadCPU = try Self.cpuSeconds()
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await driver.load(document: document, assets: assets, settings: settings, drawableSize: size,
                              pixelFormat: WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: false),
                              compiler: compiler, diskCache: diskCache,
                              requireCompleteShaders: true, renderScaleOverride: 1, textureCompression: nil,
                              workshopID: id, scriptHost: host, particleSeed: config.seed)
        let loadElapsed = ProcessInfo.processInfo.systemUptime - loadStart
        let loadCPUSeconds = try Self.cpuSeconds() - loadCPU
        _ = try XCTUnwrap(driver.didLoad && driver.loadDiagnostics == nil ? true : nil, "Scene must really load")
        _ = try XCTUnwrap(driver.shaderErrorSummary.count == 0 ? true : nil, "No skipped shaders allowed")
        var replans: [[String: Any]] = []
        for target in [config.replanResolution, config.resolution] {
            driver.updateSurfaceGeometry(drawableSize: CGSize(width: target[0], height: target[1]))
            _ = try XCTUnwrap(driver.needsReplan ? true : nil, "Target must cause a real resize")
            let cpu = try Self.cpuSeconds()
            let start = ProcessInfo.processInfo.systemUptime
            let succeeded = await driver.replan()
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let cpuElapsed = try Self.cpuSeconds() - cpu
            _ = try XCTUnwrap(succeeded && !driver.needsReplan && driver.didLoad ? true : nil, "Replan must publish")
            _ = try XCTUnwrap(driver.runtimeFailure == nil ? true : nil, "Replan must keep the runtime healthy")
            replans.append(["resolution": target, "elapsedSeconds": elapsed, "selfCPUSeconds": cpuElapsed])
        }
        let cache = try XCTUnwrap(driver.diagnostics?.shaderCache)
        _ = try XCTUnwrap((config.prewarmOnly == true || cache.compilations == 0) && cache.compilationFailures == 0 ? true : nil,
                          "This measurement requires a prewarmed shader cache; helpers must do no compilation")
        return ["workshopID": id, "scenePackageSHA256": packageSHA, "reusesPreparedScene": driver.reusesPreparedScene,
                "programSettings": String(describing: settings), "loadElapsedSeconds": loadElapsed,
                "loadSelfCPUSeconds": loadCPUSeconds, "replans": replans,
                "shaderCache": ["requests": cache.requests, "memoryHits": cache.memoryHits,
                                "joinedRequests": cache.joinedRequests, "diskHits": cache.diskHits,
                                "compilations": cache.compilations]]
    }

    private static func cpuSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
