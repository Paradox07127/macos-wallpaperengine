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
        let runtimeFrames: Int?
        let runtimeWarmupFrames: Int?
        let textReplanDiagnostics: Bool?
        let expectedDirectTextExtentReuse: Bool?
        let interleavedTextExtentRuntime: Bool?
        let interleavedStartWithOptimized: Bool?
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
        let scene = try sceneInputs(id: id, config: config, device: device)
        let (document, assets, settings, host) = (scene.document, scene.assets, scene.settings, scene.host)
        let size = CGSize(width: config.resolution[0], height: config.resolution[1])
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        let packageSHA: Any = scene.packageSHA.map { $0 as Any } ?? NSNull()
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
                "programSettings": String(describing: settings), "replayRandomSeed": config.seed, "loadElapsedSeconds": loadElapsed,
                "loadSelfCPUSeconds": loadCPUSeconds, "replans": replans,
                "shaderCache": ["requests": cache.requests, "memoryHits": cache.memoryHits,
                                "joinedRequests": cache.joinedRequests, "diskHits": cache.diskHits,
                                "compilations": cache.compilations]]
    }

    private struct SceneInput {
        let document: WPESceneDocument
        let assets: WPEParityProgramAssets
        let settings: WPEParityProgramSettings
        let host: WPEParitySceneScript.Host
        let packageSHA: String?
    }

    private func sceneInputs(id: String, config: Config, device: MTLDevice) throws -> SceneInput {
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
        host.randomSeed = config.seed
        let packageSHA = try hasPackage
            ? SHA256.hash(data: Data(contentsOf: package, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            : nil
        return SceneInput(document: document, assets: assets, settings: settings, host: host, packageSHA: packageSHA)
    }

    /// Fixed successful scene frames; serial GPU completion, no present or video decoder timing.
    func testFixedFrameRuntime() async throws {
        guard let configURL = TestScratch.externalFixtureURL(pathKey: "WPE_PARITY_RELEASE_RUNTIME_CONFIG") else {
            throw XCTSkip("Opt in with external fixtures and WPE_PARITY_RELEASE_RUNTIME_CONFIG")
        }
        let output = try XCTUnwrap(TestScratch.externalFixtureURL(pathKey: "WPE_PARITY_RELEASE_RUNTIME_OUTPUT"))
        let bytes = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Config.self, from: bytes)
        let count = config.runtimeFrames ?? 240
        let warmup = config.runtimeWarmupFrames ?? 60
        _ = try XCTUnwrap((1 ... 6000).contains(count) && (0 ... 6000).contains(warmup)
            && config.prewarmOnly != true && config.resolution.count == 2
            && config.resolution.allSatisfy { (1 ... 16384).contains($0) }
            && !config.scenes.isEmpty && Set(config.scenes).count == config.scenes.count ? true : nil,
            "Runtime measurement requires bounded frame counts, unique scenes and no prewarm-only phase")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let work = FileManager.default.temporaryDirectory.appending(path: "parity-release-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let compiler = try WPEParityHelperShaderCompiler(
            helper: URL(fileURLWithPath: config.compilerPaths.helper),
            dxcompiler: URL(fileURLWithPath: config.compilerPaths.dxcompiler),
            metalIRConverter: URL(fileURLWithPath: config.compilerPaths.metalIRConverter), workDirectory: work
        )
        let cache = WPEParityShaderDiskCache(cachesURL: URL(fileURLWithPath: config.shaderCacheRoot))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for id in config.scenes {
            _ = try XCTUnwrap(!id.isEmpty && id.allSatisfy(\.isNumber) ? true : nil, "Workshop ID must be numeric")
            try await rows.append(runtime(id: id, config: config, count: count, warmup: warmup,
                                          device: device, compiler: compiler, diskCache: cache))
            let receipt: [String: Any] = [
                "phase": "runtime-fixed-frames-no-video", "pid": ProcessInfo.processInfo.processIdentifier,
                "configuration": "Release (!DEBUG), verify -O with testability in build receipt",
                "configSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "compilerIdentity": compiler.compilerIdentity, "scenes": rows,
                "scope": "Exactly N successful serial scene command buffers; excludes display/present, driver sound, video and WindowServer. Not Air/refresh/FPS or realtime throughput.",
                "cpuScope": "RUSAGE_SELF all host threads, including background tasks; excludes child/helper/XPC/GPU. Per-encode bracket excludes GPU wait; whole batch includes waits and equal harness bookkeeping. No overhead subtraction.",
                "memoryScope": "proc_pid_rusage v0 footprint/resident endpoints and device.currentAllocatedSize, not peak/residency or framework-only ownership. Exact byte fields are decimal strings.",
                "gpuScope": "Each scene command buffer gpuEndTime-gpuStartTime after completion; serial, not device utilization or shader-only time. Readback is outside measured brackets.",
                "timeZone": TimeZone.current.identifier,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appending(path: "runtime.json"), options: .atomic)
        }
    }

    /// Two real renderers coexist, so nearby alternating blocks can distinguish a mode effect from trial drift.
    /// All async loads precede synchronous warmup/measurement; this is a benchmark, not desktop frame pacing.
    func testInterleavedTextExtentRuntime() async throws {
        guard let configURL = TestScratch.externalFixtureURL(pathKey: "WPE_PARITY_RELEASE_RUNTIME_CONFIG") else {
            throw XCTSkip("Opt in with external fixtures and WPE_PARITY_RELEASE_RUNTIME_CONFIG")
        }
        let bytes = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Config.self, from: bytes)
        guard config.interleavedTextExtentRuntime == true else {
            throw XCTSkip("Set interleavedTextExtentRuntime in the explicit Release runtime config")
        }
        let output = try XCTUnwrap(TestScratch.externalFixtureURL(pathKey: "WPE_PARITY_RELEASE_RUNTIME_OUTPUT"))
        let count = config.runtimeFrames ?? 1200
        let warmup = config.runtimeWarmupFrames ?? 600
        let blockSize = 100
        _ = try XCTUnwrap((200 ... 6000).contains(count) && count % (blockSize * 2) == 0
            && (0 ... 6000).contains(warmup) && warmup % (blockSize * 2) == 0
            && config.textReplanDiagnostics != false && config.prewarmOnly != true
            && config.resolution.count == 2 && config.resolution.allSatisfy { (1 ... 16384).contains($0) }
            && !config.scenes.isEmpty && Set(config.scenes).count == config.scenes.count ? true : nil,
            "Interleaving requires even bounded 100-frame rounds, diagnostics and distinct real scenes")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let work = FileManager.default.temporaryDirectory.appending(path: "parity-release-interleaved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let compiler = try WPEParityHelperShaderCompiler(
            helper: URL(fileURLWithPath: config.compilerPaths.helper),
            dxcompiler: URL(fileURLWithPath: config.compilerPaths.dxcompiler),
            metalIRConverter: URL(fileURLWithPath: config.compilerPaths.metalIRConverter), workDirectory: work
        )
        let diskCache = WPEParityShaderDiskCache(cachesURL: URL(fileURLWithPath: config.shaderCacheRoot))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        for id in config.scenes {
            _ = try XCTUnwrap(!id.isEmpty && id.allSatisfy(\.isNumber) ? true : nil, "Workshop ID must be numeric")
            try await rows.append(interleavedRuntime(id: id, config: config, count: count, warmup: warmup,
                                                     blockSize: blockSize, device: device, compiler: compiler, diskCache: diskCache))
            let receipt: [String: Any] = [
                "phase": "same-process-interleaved-text-extent", "pid": ProcessInfo.processInfo.processIdentifier,
                "configuration": "Release (!DEBUG); verify -O in root build log",
                "compilerIdentity": compiler.compilerIdentity,
                "configSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "startWithOptimized": config.interleavedStartWithOptimized ?? false,
                "cpuScope": "RUSAGE_SELF per synchronous 100-frame block; includes serial completion/helper overhead and all process threads",
                "gpuScope": "actual completed scene command buffers, serialized across both arms; no display/present workload",
                "memoryScope": "global process/device endpoints with TWO coexisting renderers; not per-arm or production wallpaper RSS",
                "scenes": rows,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appending(path: "interleaved-text-runtime.json"), options: .atomic)
        }
        XCTAssertEqual(rows.count, config.scenes.count)
    }

    private func interleavedRuntime(id: String, config: Config, count: Int, warmup: Int, blockSize: Int,
                                    device: MTLDevice, compiler: WPEParityHelperShaderCompiler,
                                    diskCache: WPEParityShaderDiskCache) async throws -> [String: Any] {
        let scene = try sceneInputs(id: id, config: config, device: device)
        let startsOptimized = config.interleavedStartWithOptimized ?? false
        let initialOrder = startsOptimized ? [1, 0] : [0, 1]
        var loading: [WPEParitySceneDriver?] = [nil, nil]
        defer { for driver in loading {
            driver?.cleanup()
        } }
        for arm in initialOrder {
            let driver = try WPEParitySceneDriver(device: device)
            loading[arm] = driver
            driver.setAudioMuted(true)
            try await driver.load(document: scene.document, assets: scene.assets, settings: scene.settings,
                                  drawableSize: CGSize(width: config.resolution[0], height: config.resolution[1]),
                                  pixelFormat: WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: false),
                                  compiler: compiler, diskCache: diskCache, requireCompleteShaders: true,
                                  renderScaleOverride: 1, textureCompression: nil, workshopID: id,
                                  scriptHost: scene.host, particleSeed: config.seed,
                                  reuseDirectTextExtentLayouts: arm == 1)
            _ = try XCTUnwrap(driver.didLoad && driver.loadDiagnostics == nil && driver.shaderErrorSummary.count == 0 ? true : nil,
                              "Both interleaved arms must load without skipped shaders")
        }
        let drivers = try loading.map { try XCTUnwrap($0) }
        let renderers = try drivers.map { try XCTUnwrap($0.renderer) }
        for arm in 0 ..< 2 {
            XCTAssertEqual(renderers[arm].reusesDirectTextExtentLayouts, arm == 1)
            _ = try XCTUnwrap(renderers[arm].videoSourceCount == 0 ? true : nil, "No actual decoder in this benchmark")
            renderers[arm].startTextReplanDiagnostics()
        }
        let input = WPEParityFrameInput(cursor: SIMD2(Float(config.resolution[0]) * 0.5, Float(config.resolution[1]) * 0.5),
                                        date: Date(timeIntervalSince1970: 1_700_000_000))
        func order(_ round: Int) -> [Int] {
            round.isMultiple(of: 2) ? initialOrder : Array(initialOrder.reversed())
        }
        var thermal: Set<String> = [Self.thermalState()]
        for round in 0 ..< warmup / blockSize {
            for arm in order(round) {
                for _ in 0 ..< blockSize {
                    _ = try runtimeFrame(renderers[arm], input: input)
                }
                thermal.insert(Self.thermalState())
            }
        }
        func textSnapshot(_ renderer: WPEParityFrameRenderer) throws -> Any {
            let value = try XCTUnwrap(renderer.textReplanDiagnostics, "Both arms require actual text diagnostics")
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        let beforeText = try renderers.map(textSnapshot)
        let beforePixels = try renderers.map { try Self.backbufferHash($0.backbuffer, device: device) }
        _ = try XCTUnwrap(beforePixels[0] == beforePixels[1] ? true : nil, "Warmup arm pixels must match before timing")
        let dropped = renderers.map(\.droppedParticleBatches)
        let beforeMemory = try Self.memorySnapshot(device)
        var samples = [[FrameSample](), [FrameSample]()]
        for arm in 0 ..< 2 {
            samples[arm].reserveCapacity(count)
        }
        var blockCPU = [0.0, 0.0], blockWall = [0.0, 0.0]
        var blocks: [[String: Any]] = []
        blocks.reserveCapacity(count / blockSize * 2)
        for round in 0 ..< count / blockSize {
            for (position, arm) in order(round).enumerated() {
                let thermalBefore = Self.thermalState()
                let cpuStart = try Self.cpuSeconds()
                let wallStart = ProcessInfo.processInfo.systemUptime
                for _ in 0 ..< blockSize {
                    try samples[arm].append(runtimeFrame(renderers[arm], input: input))
                }
                let wall = ProcessInfo.processInfo.systemUptime - wallStart
                let cpu = try Self.cpuSeconds() - cpuStart
                let thermalAfter = Self.thermalState()
                blockCPU[arm] += cpu
                blockWall[arm] += wall
                thermal.formUnion([thermalBefore, thermalAfter])
                blocks.append(["round": round, "position": position, "arm": arm == 0 ? "baseline" : "optimized",
                               "frameStart": round * blockSize, "frameCount": blockSize,
                               "blockSelfCPUSeconds": cpu, "blockWallSeconds": wall,
                               "thermalBefore": thermalBefore, "thermalAfter": thermalAfter])
            }
        }
        let afterMemory = try Self.memorySnapshot(device)
        let afterText = try renderers.map(textSnapshot)
        let afterPixels = try renderers.map { try Self.backbufferHash($0.backbuffer, device: device) }
        _ = try XCTUnwrap(afterPixels[0] == afterPixels[1] ? true : nil, "Final interleaved arm pixels must match")
        let draws = samples.map { $0.map(\.draws) }
        _ = try XCTUnwrap(draws[0] == draws[1] && draws[0].reduce(0, +) > 0 ? true : nil,
                          "Every frame's actual draw count must match")
        _ = try XCTUnwrap(samples[0].map(\.copyEncoded) == samples[1].map(\.copyEncoded) ? true : nil,
                          "Every frame's actual copy count must match")
        var arms: [[String: Any]] = []
        for arm in 0 ..< 2 {
            let renderer = renderers[arm]
            _ = try XCTUnwrap(renderer.droppedParticleBatches == dropped[arm] ? true : nil, "No dropped particle batch")
            let shader = try XCTUnwrap(drivers[arm].diagnostics?.shaderCache)
            _ = try XCTUnwrap(shader.compilations == 0 && shader.compilationFailures == 0 ? true : nil,
                              "Prewarm both interleaved loads before a formal run")
            let drawBytes = try JSONEncoder().encode(draws[arm])
            arms.append([
                "arm": arm == 0 ? "baseline" : "optimized", "reusesDirectTextExtentLayouts": renderer.reusesDirectTextExtentLayouts,
                "warmupFrames": warmup, "measuredAttempts": count, "successfulSceneCommandBuffers": samples[arm].count,
                "skippedFrames": 0, "failedCommandBuffers": 0, "videoSourceCount": renderer.videoSourceCount,
                "batchSelfCPUSeconds": blockCPU[arm], "batchWallSeconds": blockWall[arm],
                "encodeSelfCPUSeconds": Self.distribution(samples[arm].map(\.encodeCPU)),
                "encodeWallSeconds": Self.distribution(samples[arm].map(\.encodeWall)),
                "sceneCommandBufferGPUSeconds": Self.distribution(samples[arm].map(\.gpu)),
                "frameEncodeSelfCPUSeconds": samples[arm].map(\.encodeCPU), "frameEncodeWallSeconds": samples[arm].map(\.encodeWall),
                "frameCommandBufferGPUSeconds": samples[arm].map(\.gpu), "frameDrawCounts": draws[arm],
                "frameCopyCounts": samples[arm].map(\.copyEncoded), "copyEncoded": samples[arm].reduce(0) { $0 + $1.copyEncoded },
                "encodedDrawSequenceSHA256": SHA256.hash(data: drawBytes).map { String(format: "%02x", $0) }.joined(),
                "warmupBackbufferSHA256": beforePixels[arm], "finalBackbufferSHA256": afterPixels[arm],
                "textReplanDiagnosticsBefore": beforeText[arm], "textReplanDiagnosticsAfter": afterText[arm],
                "shaderCache": ["requests": shader.requests, "diskHits": shader.diskHits, "memoryHits": shader.memoryHits,
                                "compilations": shader.compilations, "compilationFailures": shader.compilationFailures],
            ])
        }
        return [
            "workshopID": id, "scenePackageSHA256": scene.packageSHA.map { $0 as Any } ?? NSNull(),
            "programSettings": String(describing: scene.settings), "particleSeed": config.seed, "replayRandomSeed": config.seed,
            "elapsedPerFrameSeconds": 1.0 / 60, "dateEpochSeconds": 1_700_000_000, "blockSize": blockSize,
            "startWithOptimized": startsOptimized, "initialLoadOrder": initialOrder.map { $0 == 0 ? "baseline" : "optimized" },
            "backbufferSize": [renderers[0].backbuffer.width, renderers[0].backbuffer.height],
            "pixelFormat": renderers[0].backbuffer.pixelFormat.rawValue, "textureCompression": false,
            "thermalStates": thermal.sorted(), "thermalScope": "warmup block ends and measured block entry/exit, not continuous duration",
            "coexistingMemoryBefore": beforeMemory, "coexistingMemoryAfter": afterMemory,
            "memoryScope": "global endpoints with two retained renderers; cannot assign bytes to an individual arm",
            "blocks": blocks, "arms": arms,
        ]
    }

    private struct FrameSample {
        let encodeWall: Double
        let encodeCPU: Double
        let gpu: Double
        let draws: Int
        let copyEncoded: Int
    }

    private func runtime(id: String, config: Config, count: Int, warmup: Int, device: MTLDevice,
                         compiler: WPEParityHelperShaderCompiler, diskCache: WPEParityShaderDiskCache) async throws -> [String: Any] {
        let scene = try sceneInputs(id: id, config: config, device: device)
        let driver = try WPEParitySceneDriver(device: device)
        driver.setAudioMuted(true)
        defer { driver.cleanup() }
        try await driver.load(document: scene.document, assets: scene.assets, settings: scene.settings,
                              drawableSize: CGSize(width: config.resolution[0], height: config.resolution[1]),
                              pixelFormat: WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: false),
                              compiler: compiler, diskCache: diskCache, requireCompleteShaders: true,
                              renderScaleOverride: 1, textureCompression: nil, workshopID: id,
                              scriptHost: scene.host, particleSeed: config.seed)
        let renderer = try XCTUnwrap(driver.renderer)
        if let expected = config.expectedDirectTextExtentReuse {
            XCTAssertEqual(renderer.reusesDirectTextExtentLayouts, expected,
                           "The measured renderer must use the requested extent-layout arm")
        }
        if config.textReplanDiagnostics == true {
            renderer.startTextReplanDiagnostics()
        }
        _ = try XCTUnwrap(renderer.videoSourceCount == 0 ? true : nil,
                          "Release fixed-frame comparison rejects actual video owners; use the separate Debug frozen-video capture")
        let input = WPEParityFrameInput(cursor: SIMD2(Float(renderer.backbuffer.width) * 0.5,
                                                      Float(renderer.backbuffer.height) * 0.5),
                                        date: Date(timeIntervalSince1970: 1_700_000_000))
        var thermal: Set<String> = [Self.thermalState()]
        for _ in 0 ..< warmup {
            _ = try runtimeFrame(renderer, input: input)
            thermal.insert(Self.thermalState())
        }
        let droppedBefore = renderer.droppedParticleBatches
        let beforeHash = try Self.backbufferHash(renderer.backbuffer, device: device)
        let atlasBefore: Any = if config.textReplanDiagnostics == true {
            Self.textAtlasCPUSnapshot(renderer)
        } else {
            NSNull()
        }
        let beforeMemory = try Self.memorySnapshot(device)
        let textBefore: Any = if let diagnostics = renderer.textReplanDiagnostics {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics))
        } else {
            NSNull()
        }
        if config.textReplanDiagnostics == true {
            _ = try XCTUnwrap(renderer.textReplanDiagnostics, "Requested text replan diagnostics must be available")
        }
        var samples: [FrameSample] = []
        samples.reserveCapacity(count)
        let cpuBefore = try Self.cpuSeconds()
        let wallBefore = ProcessInfo.processInfo.systemUptime
        for _ in 0 ..< count {
            try samples.append(runtimeFrame(renderer, input: input))
            thermal.insert(Self.thermalState())
        }
        let wall = ProcessInfo.processInfo.systemUptime - wallBefore
        let cpu = try Self.cpuSeconds() - cpuBefore
        let afterMemory = try Self.memorySnapshot(device)
        let atlasAfter: Any = if config.textReplanDiagnostics == true {
            Self.textAtlasCPUSnapshot(renderer)
        } else {
            NSNull()
        }
        let textAfter: Any = if let diagnostics = renderer.textReplanDiagnostics {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics))
        } else {
            NSNull()
        }
        let afterHash = try Self.backbufferHash(renderer.backbuffer, device: device)
        thermal.insert(Self.thermalState())
        _ = try XCTUnwrap(renderer.droppedParticleBatches == droppedBefore ? true : nil, "No particle batches may be dropped")
        let shader = try XCTUnwrap(driver.diagnostics?.shaderCache)
        _ = try XCTUnwrap(shader.compilations == 0 && shader.compilationFailures == 0 ? true : nil,
                          "Prewarm this compiler identity before formal fixed-frame trials")
        let draws = samples.map(\.draws)
        _ = try XCTUnwrap(draws.reduce(0, +) > 0 ? true : nil, "The measured scene must actually draw")
        let drawBytes = try JSONEncoder().encode(draws)
        return [
            "workshopID": id, "scenePackageSHA256": scene.packageSHA.map { $0 as Any } ?? NSNull(),
            "programSettings": String(describing: scene.settings), "particleSeed": config.seed, "replayRandomSeed": config.seed,
            "elapsedPerFrameSeconds": 1.0 / 60, "dateEpochSeconds": 1_700_000_000,
            "warmupFrames": warmup, "measuredAttempts": count, "successfulSceneCommandBuffers": samples.count,
            "skippedFrames": 0, "failedCommandBuffers": 0, "videoSourceCount": renderer.videoSourceCount,
            "batchWallSeconds": wall, "batchSelfCPUSeconds": cpu,
            "encodeWallSeconds": Self.distribution(samples.map(\.encodeWall)),
            "encodeSelfCPUSeconds": Self.distribution(samples.map(\.encodeCPU)),
            "sceneCommandBufferGPUSeconds": Self.distribution(samples.map(\.gpu)),
            "encodedDrawCounts": Self.distribution(draws.map(Double.init)),
            "encodedDrawSequenceSHA256": SHA256.hash(data: drawBytes).map { String(format: "%02x", $0) }.joined(),
            "copyEncoded": samples.reduce(0) { $0 + $1.copyEncoded },
            "reusesPreparedScene": driver.reusesPreparedScene, "thermalStates": thermal.sorted(),
            "reusesDirectTextExtentLayouts": renderer.reusesDirectTextExtentLayouts,
            "textReplanDiagnosticsBefore": textBefore, "textReplanDiagnosticsAfter": textAfter,
            "cpuAtlasCacheAfterWarmup": atlasBefore, "cpuAtlasCacheAfterMeasuredFrames": atlasAfter,
            "memoryBefore": beforeMemory, "memoryAfter": afterMemory,
            "backbufferSize": [renderer.backbuffer.width, renderer.backbuffer.height],
            "pixelFormat": renderer.backbuffer.pixelFormat.rawValue, "textureCompression": false,
            "warmupBackbufferSHA256": beforeHash, "finalBackbufferSHA256": afterHash,
            "shaderCache": ["requests": shader.requests, "diskHits": shader.diskHits, "memoryHits": shader.memoryHits,
                            "compilations": shader.compilations, "compilationFailures": shader.compilationFailures],
        ]
    }

    private func runtimeFrame(_ renderer: WPEParityFrameRenderer, input: WPEParityFrameInput) throws -> FrameSample {
        try autoreleasepool {
            let cpu = try Self.cpuSeconds()
            let start = ProcessInfo.processInfo.systemUptime
            let submitted = try renderer.encodeFrame(elapsed: 1.0 / 60, input: input)
            let encodeWall = ProcessInfo.processInfo.systemUptime - start
            let encodeCPU = try Self.cpuSeconds() - cpu
            guard case let .committed(command) = submitted else {
                throw NSError(domain: "ParityRuntimeSkippedFrame", code: 1)
            }
            command.waitUntilCompleted()
            _ = try XCTUnwrap(command.status == .completed && command.error == nil ? true : nil,
                              "Every measured scene command buffer must complete successfully")
            _ = try XCTUnwrap(command.gpuStartTime.isFinite && command.gpuEndTime.isFinite
                && command.gpuEndTime > command.gpuStartTime ? true : nil, "Actual scene GPU timing must be available")
            _ = try XCTUnwrap(renderer.videoSourceCount == 0 && renderer.skipped.isEmpty ? true : nil,
                              "No video source or skipped draw may enter this controlled comparison")
            let copies = try XCTUnwrap(renderer.lastFrameCopyCount)
            return FrameSample(encodeWall: encodeWall, encodeCPU: encodeCPU, gpu: command.gpuEndTime - command.gpuStartTime,
                               draws: renderer.lastFrameDrawCount, copyEncoded: copies)
        }
    }

    private static func textAtlasCPUSnapshot(_ renderer: WPEParityFrameRenderer) -> [String: Any] {
        let atlases = renderer.textAtlases
        let readers = Set(renderer.texts.values.map(\.atlasKey))
        var monoBytes = 0, colorBytes = 0, companionBytes = 0
        var activeBytes = 0, coldBytes = 0, colorGroups = 0, activeGroups = 0
        var rows: [[String: Any]] = []
        for key in atlases.keys.sorted() {
            guard let instance = atlases[key] else { continue }
            let mono = instance.mono.pixels.count
            var color = 0
            var companion = instance.mono.companionPixels?.count ?? 0
            var groups: [[String: Any]] = []
            for scale in instance.colorGroups.keys.sorted() {
                guard let group = instance.colorGroups[scale] else { continue }
                let primary = group.pixels.count, paired = group.companionPixels?.count ?? 0
                color += primary
                companion += paired
                groups.append([
                    "scale": scale, "width": group.width, "height": group.height,
                    "primaryLogicalPixelBytes": primary, "companionLogicalPixelBytes": paired,
                    "contentGeneration": String(group.contentGeneration),
                ])
            }
            let active = readers.contains(key), total = mono + color + companion
            monoBytes += mono
            colorBytes += color
            companionBytes += companion
            colorGroups += groups.count
            if active {
                activeGroups += 1
                activeBytes += total
            } else {
                coldBytes += total
            }
            rows.append([
                "atlasKey": key, "hasCurrentTextReader": active,
                "glyphMode": instance.glyphMode == .bitmap ? "bitmap" : "distanceField",
                "monoWidth": instance.mono.width, "monoHeight": instance.mono.height,
                "monoLogicalPixelBytes": mono,
                "monoContentGeneration": String(instance.mono.contentGeneration),
                "colorGroups": groups, "logicalPixelBytes": total,
            ])
        }
        return [
            "scope": "current renderer CPU atlas values; logical array lengths, not physical backing/RSS",
            "cacheGroupCount": atlases.count, "colorGroupCount": colorGroups,
            "activeCachedGroupCount": activeGroups, "coldCachedGroupCount": atlases.count - activeGroups,
            "currentTextReaderKeyCount": readers.count,
            "activeReaderKeysWithoutCachedAtlas": readers.subtracting(atlases.keys).sorted(),
            "monoLogicalPixelBytes": monoBytes, "colorLogicalPixelBytes": colorBytes,
            "companionLogicalPixelBytes": companionBytes,
            "totalLogicalPixelBytes": monoBytes + colorBytes + companionBytes,
            "activeLogicalPixelBytes": activeBytes, "coldLogicalPixelBytes": coldBytes,
            "cachedAtlasKeys": atlases.keys.sorted(), "currentTextReaderKeys": readers.sorted(),
            "groups": rows,
        ]
    }

    private static func memorySnapshot(_ device: MTLDevice) throws -> [String: String] {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0)
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return ["physFootprintBytes": String(info.ri_phys_footprint), "residentBytes": String(info.ri_resident_size),
                "deviceAllocatedBytes": String(device.currentAllocatedSize)]
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func distribution(_ values: [Double]) -> [String: Double] {
        let ordered = values.sorted()
        func percentile(_ p: Double) -> Double {
            ordered[min(ordered.count - 1, Int(Double(ordered.count - 1) * p))]
        }
        return ["count": Double(values.count), "sum": values.reduce(0, +), "min": ordered[0],
                "max": ordered[ordered.count - 1], "p50": percentile(0.5), "p95": percentile(0.95), "p99": percentile(0.99)]
    }

    private static func backbufferHash(_ texture: MTLTexture, device: MTLDevice) throws -> String {
        try autoreleasepool {
            _ = try XCTUnwrap([MTLPixelFormat.bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb, .rgba16Float]
                .contains(texture.pixelFormat) ? true : nil, "Readback supports only the renderer's RGBA/BGRA outputs")
            let bytesPerPixel = texture.pixelFormat == .rgba16Float ? 8 : 4
            let rowBytes = texture.width * bytesPerPixel
            let stride = (rowBytes + 255) / 256 * 256
            let buffer = try XCTUnwrap(device.makeBuffer(length: stride * texture.height, options: .storageModeShared))
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                      destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * texture.height)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            _ = try XCTUnwrap(command.status == .completed && command.error == nil ? true : nil, "Readback must complete")
            var hash = SHA256()
            for row in 0 ..< texture.height {
                hash.update(data: Data(bytes: buffer.contents().advanced(by: row * stride), count: rowBytes))
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func cpuSeconds() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
