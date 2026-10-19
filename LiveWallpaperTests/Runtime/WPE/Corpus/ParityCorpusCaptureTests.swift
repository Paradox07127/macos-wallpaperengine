#if !LITE_BUILD && DEBUG
import AppKit
import CryptoKit
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

/// Renders local workshop scenes on the parity renderer through `WPEParitySceneDriver` with frozen inputs and writes
/// the last presented frame as a PNG, for comparison against Windows WPE and `OracleCorpusCaptureTests`.
final class ParityCorpusCaptureTests: XCTestCase {
    private struct Config: Decodable {
        let corpusRoot: String
        let engineAssetsRoot: String?
        let scenes: [String]?
        let resolution: [Int]
        let frames: Int
        let frameStepSeconds: Double
        /// time/daytime/pointerX/pointerY/epoch; a missing field takes 0, 0.5, 0.5, 0.5, the load's wall clock.
        let replayFrame: [String: Double]
        let propertyOverridesByScene: [String: [String: WallpaperEngineProjectPropertyValue]]
        let seed: UInt32
        /// WPE's shadow quality 0–4; nil = the product default.
        let shadowQuality: Int32?

        private enum CodingKeys: String, CodingKey {
            case corpusRoot, engineAssetsRoot, scenes, resolution, frames, frameStepSeconds, replayFrame
            case propertyOverridesByScene, seed, shadowQuality
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corpusRoot = try container.decode(String.self, forKey: .corpusRoot)
            engineAssetsRoot = try container.decodeIfPresent(String.self, forKey: .engineAssetsRoot)
            scenes = try container.decodeIfPresent([String].self, forKey: .scenes)
            resolution = try container.decodeIfPresent([Int].self, forKey: .resolution) ?? [1920, 1080]
            frames = try container.decodeIfPresent(Int.self, forKey: .frames) ?? 1
            frameStepSeconds = try container.decodeIfPresent(Double.self, forKey: .frameStepSeconds) ?? (1.0 / 60.0)
            replayFrame = try container.decodeIfPresent([String: Double].self, forKey: .replayFrame) ?? [:]
            propertyOverridesByScene = try container.decodeIfPresent(
                [String: [String: WallpaperEngineProjectPropertyValue]].self, forKey: .propertyOverridesByScene
            ) ?? [:]
            seed = try container.decodeIfPresent(UInt32.self, forKey: .seed) ?? 1
            shadowQuality = try container.decodeIfPresent(Int32.self, forKey: .shadowQuality)
        }
    }

    /// The frozen per-frame inputs. `pointer` is backbuffer UV with a top-left origin, as the driver takes it.
    private struct Replay {
        let time: Double
        let date: Date
        let pointer: SIMD2<Double>
        /// Unix seconds that script `Date.now()` reads at scene time 0; nil = the wall clock at load.
        let epoch: Double?
        let fields: [String: Double]

        init(_ fields: [String: Double]) {
            time = fields["time"] ?? 0
            let daytime = fields["daytime"] ?? 0.5
            // g_Daytime reads the local wall clock, so a fixed local midnight plus the fraction pins it.
            date = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
                .addingTimeInterval(daytime * 86400)
            pointer = SIMD2(fields["pointerX"] ?? 0.5, fields["pointerY"] ?? 0.5)
            epoch = fields["epoch"]
            self.fields = ["time": time, "daytime": daytime, "pointerX": pointer.x, "pointerY": pointer.y]
                .merging(epoch.map { ["epoch": $0] } ?? [:]) { $1 }
        }
    }

    func testCaptureCorpus() async throws {
        guard let configURL = TestScratch.externalFixtureURL(pathKey: "WPE_PARITY_CAPTURE_CONFIG") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_PARITY_CAPTURE_CONFIG=<config.json>")
        }
        let outDir = try XCTUnwrap(TestScratch.externalFixtureURL(pathKey: "WPE_PARITY_CAPTURE_OUTPUT"),
                                   "Set WPE_PARITY_CAPTURE_OUTPUT=<output directory>")
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        let size = config.resolution
        let replay = Replay(config.replayFrame)
        // Each frame's scene step is its timestamp difference; WPEParityClock clamps a step to maximumStep.
        guard size.count == 2, size.allSatisfy({ $0 > 0 && $0 <= 16384 }), config.frames > 0,
              config.frameStepSeconds > 0, config.frameStepSeconds <= Double(WPEParityClock.maximumStep),
              replay.time.isFinite, replay.time >= 0 else {
            return XCTFail("Invalid resolution/frames/frameStepSeconds/replayFrame.time in \(configURL.path)")
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let compiler = try WPEParityShaderToolchain.makeCompiler().get()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: "parity-capture-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let diskCache = WPEParityShaderDiskCache(cachesURL: cacheRoot)
        let engineAssetsRoot = config.engineAssetsRoot.map { URL(fileURLWithPath: $0) }
            ?? TestScratch.externalFixtureURL(pathKey: "WPE_COVERAGE_ENGINE_ASSETS_ROOT")
        print("[parity-capture] corpusRoot=\(config.corpusRoot) scenes=\(config.scenes ?? ["<all>"]) "
            + "engineAssetsRoot=\(engineAssetsRoot?.path ?? "<nil>") compilerIdentity=\(compiler.compilerIdentity)")

        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: config.corpusRoot), includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let filter = config.scenes.map(Set.init)
        var captured = 0, skipped = 0, failed = 0
        for folder in folders {
            let id = folder.lastPathComponent
            if let filter, !filter.contains(id) {
                continue
            }
            guard let project = try? WallpaperEngineProject.read(from: folder), project.type == .scene else {
                skipped += 1
                continue
            }
            let package = folder.appending(path: project.packageFileName(in: folder))
            let hasPackage = FileManager.default.fileExists(atPath: package.path)
            let packageSHA256: Any = try hasPackage ? Self.sha256(of: package) as Any : NSNull()
            var record: [String: Any] = [
                "workshopID": id, "renderer": "parity", "resolution": size, "seed": config.seed,
                "frames": config.frames, "frameStepSeconds": config.frameStepSeconds, "replayFrame": replay.fields,
                "compilerIdentity": compiler.compilerIdentity, "scenePackageSHA256": packageSHA256,
            ]
            do {
                let descriptor = SceneDescriptor(
                    workshopID: id, cacheRelativePath: "parity-capture/\(id)",
                    entryFile: project.entryFile.isEmpty ? "scene.json" : project.entryFile, capabilityTier: .degraded,
                    propertyOverrides: config.propertyOverridesByScene[id] ?? [:]
                )
                let provider: any WPESceneAssetProvider = if hasPackage {
                    try WPEPackageSceneAssetProvider(packageURL: package)
                } else {
                    WPEDirectorySceneAssetProvider(rootURL: folder)
                }
                let result = try await capture(
                    descriptor: descriptor, provider: provider, projectRoot: folder, engineAssetsRoot: engineAssetsRoot,
                    compiler: compiler, diskCache: diskCache, device: device, size: CGSize(width: size[0], height: size[1]),
                    frames: config.frames, step: config.frameStepSeconds, replay: replay, seed: config.seed,
                    shadowQuality: config.shadowQuality, png: outDir.appending(path: "\(id).png"), record: &record
                )
                record.merge(result) { $1 }
                captured += 1
                print("[parity-capture] [\(id)] png → \(id).png channelRange=\(result["channelRange"] ?? "")")
            } catch {
                record["error"] = String(describing: error)
                failed += 1
                print("[parity-capture] [\(id)] failed: \(String(describing: error).prefix(300))")
            }
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: outDir.appending(path: "\(id).json"), options: .atomic)
        }
        print("=== parity-capture: captured=\(captured) skipped=\(skipped) failed=\(failed) → \(outDir.path) ===")
        XCTAssertGreaterThan(captured, 0, "no scene was captured; check corpusRoot / engineAssetsRoot")
        XCTAssertEqual(failed, 0, "one or more requested scenes failed")
        if let filter {
            XCTAssertTrue(captured == filter.count && skipped == 0, "requested scene coverage is incomplete")
        }
    }

    /// The driver's seed reaches the particle scene: one colorrandom sprite covers the centre with an mt19937 colour.
    func testDriverParticleSeedSelectsTheParticleStream() async throws {
        let first = try await syntheticParticleFrame(seed: 7)
        let repeated = try await syntheticParticleFrame(seed: 7)
        let other = try await syntheticParticleFrame(seed: 8)
        XCTAssertEqual(first, repeated, "the same seed rendered different frames")
        XCTAssertNotEqual(first, other, "a different seed rendered the same frame")
    }

    /// Loads `descriptor` as `AmbientWallpaperSessionBuilder` prepares a parity scene, presents the schedule's frames
    /// and writes the last drawable to `png`. Draw and program skips land in `record` even when a frame fails.
    private func capture(descriptor: SceneDescriptor, provider: any WPESceneAssetProvider, projectRoot: URL,
                         engineAssetsRoot: URL?, compiler: WPEParityHelperShaderCompiler,
                         diskCache: WPEParityShaderDiskCache, device: MTLDevice,
                         size: CGSize, frames: Int, step: Double, replay: Replay, seed: UInt32,
                         shadowQuality: Int32?, png: URL,
                         record: inout [String: Any]) async throws -> [String: Any] {
        let layer = WPEParitySceneDriverTests.RecordingLayer()
        layer.device = device
        layer.pixelFormat = WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: false)
        layer.drawableSize = size
        layer.framebufferOnly = false
        var settings = try WPEParityProductSettings.make(descriptor: descriptor, device: device)
        if let shadowQuality {
            settings.shadowQuality = shadowQuality
        }
        let inputs = try WPEParitySceneInputs(
            descriptor: descriptor,
            entryResolver: SceneResourceResolver(provider: provider, cacheRootURL: projectRoot),
            projectRoot: projectRoot,
            assets: WPEParitySceneAssets.make(
                provider: provider, projectRoot: projectRoot, dependencyMounts: [], engineAssetsRootURL: engineAssetsRoot,
                userValues: WallpaperEngineProjectPropertySchema.effectiveSceneValues(descriptor: descriptor,
                                                                                      cacheRootURL: projectRoot)
            ),
            settings: settings,
            compiler: compiler, device: device, presentLayer: WPEPresentLayer(layer: layer),
            mailbox: WPEPointerMailbox(), surfaceControl: IdleSurfaceControl(), drawableSize: size,
            pixelFormat: layer.pixelFormat
        )
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        var scriptHost = inputs.scriptHost(userPropertiesJSON: inputs.scriptUserProperties())
        scriptHost.dateEpochMillis = (replay.epoch ?? Date().timeIntervalSince1970) * 1000
        record["shadowQuality"] = settings.shadowQuality
        try await driver.load(document: inputs.makeDocument(), assets: inputs.assets, settings: inputs.settings,
                              drawableSize: size, pixelFormat: inputs.pixelFormat, compiler: compiler,
                              diskCache: diskCache, workshopID: descriptor.workshopID,
                              scriptHost: scriptHost, particleSeed: seed)
        record["skippedDraws"] = driver.diagnostics?.skippedDraws ?? [:]
        record["skippedPrograms"] = driver.shaderErrorSummary.entries.map { ["shader": $0.shader, "reason": $0.reason] }
        record["loadDiagnostics"] = driver.loadDiagnostics.map { String(describing: $0) as Any } ?? NSNull()
        let renderer = try XCTUnwrap(driver.renderer)
        // The driver steps the first frame by zero; warm-up frames carry the clock to replay.time in `step`s.
        let warmup = Int((replay.time / step).rounded(.up))
        let timestamps = (0 ..< warmup).map { Double($0) * step } + (0 ..< frames).map { replay.time + Double($0) * step }
        var times: [Double] = []
        for (index, timestamp) in timestamps.enumerated() {
            // Videos otherwise play from the AVPlayer wall clock, which the synthetic steps outrun.
            if index >= warmup {
                await renderer.seekVideosForCapture(to: timestamp)
            }
            let commandBuffer = try XCTUnwrap(driver.renderAndPresentFrame(
                layer: layer, timestamp: timestamp, pointer: replay.pointer, date: replay.date
            ), "frame \(index) was not presented")
            await commandBuffer.completed()
            if let error = commandBuffer.error {
                throw error
            }
            if index >= warmup {
                times.append(renderer.clock.time)
            }
        }
        let (image, pixels) = try Self.image(of: XCTUnwrap(layer.lastTexture))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), png.path)
        var range: [String: [UInt8]] = [:]
        for (channel, name) in ["red", "green", "blue"].enumerated() {
            let values = stride(from: channel, to: pixels.count, by: 4).map { pixels[$0] }
            range[name] = [values.min() ?? 0, values.max() ?? 0]
        }
        return ["warmupFrames": warmup, "times": times, "png": png.path, "channelRange": range,
                "drawablePixelFormat": layer.pixelFormat.rawValue]
    }

    private func syntheticParticleFrame(seed: UInt32) async throws -> [UInt8] {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        guard FileManager.default.fileExists(atPath: engine.appending(path: "shaders/genericparticle.vert").path) else {
            throw XCTSkip("Needs WPE's assets (or WPE_ASSETS_DIR) for genericparticle")
        }
        let compiler: WPEParityHelperShaderCompiler
        do {
            compiler = try WPEParityShaderToolchain.makeCompiler().get()
        } catch {
            throw XCTSkip("\(error)")
        }
        let particle: [String: Any] = [
            "maxcount": 1, "material": "materials/plain.json", "renderer": [["name": "sprite"]],
            "emitter": [["name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10],
                            ["name": "sizerandom", "min": 32, "max": 32],
                            ["name": "colorrandom", "min": "0 0 0", "max": "1 1 1"]],
        ]
        let material: [String: Any] = ["passes": [["shader": "genericparticle", "blending": "normal",
                                                   "textures": ["white"]]]]
        // A 1x1 RGBA8888 TEXV0004 container holding one white texel.
        var white = Data("TEXV0004\0".utf8)
        for value: UInt32 in [0, 0, 1, 1, 1, 1, 1, 1, 1, 4] {
            withUnsafeBytes(of: value.littleEndian) { white.append(contentsOf: $0) }
        }
        white.append(contentsOf: [255, 255, 255, 255])
        let files = try [
            "particles/root.json": JSONSerialization.data(withJSONObject: particle),
            "materials/plain.json": JSONSerialization.data(withJSONObject: material),
            "materials/white.tex": white,
        ]
        let root = FileManager.default.temporaryDirectory.appending(path: "parity-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = WPEParityProgramAssets(sources: [.lookup(root) { files[$0] }, .directory(engine)])
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "particle": "particles/root.json", "origin": "32 32 0"]],
        ]), userValues: [:], makeTransformScriptResolver: { _, _ in WPEParitySceneDriverTests.NoScripts() })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = CGSize(width: 64, height: 64)
        let layer = WPEParitySceneDriverTests.RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.drawableSize = size
        layer.framebufferOnly = false
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: WPEParityProgramSettings(bloom: false),
                              drawableSize: size, pixelFormat: layer.pixelFormat, compiler: compiler,
                              diskCache: WPEParityShaderDiskCache(cachesURL: root), particleSeed: seed)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
        let commandBuffer = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 0,
                                                                       pointer: SIMD2(0.5, 0.5)))
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error)
        return try Self.image(of: XCTUnwrap(layer.lastTexture)).pixels
    }

    /// The texture through the product snapshot readback: an sRGB CGImage and its RGBA8 bytes.
    private static func image(of texture: MTLTexture) throws -> (image: CGImage, pixels: [UInt8]) {
        let image = try XCTUnwrap(WPEMetalTextureSnapshotter.shared.snapshot(from: texture)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        return (image, Array(data))
    }

    private static func sha256(of file: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class IdleSurfaceControl: WPESurfaceControl {
    func applyPacing(_: WPERenderPacingUpdate) {}

    func setNeedsRedraw() {}

    func drawImmediately() {}

    func releaseDrawables() {}

    func detach() {}

    func setClickCaptureEnabled(_: Bool) {}
}
#endif
