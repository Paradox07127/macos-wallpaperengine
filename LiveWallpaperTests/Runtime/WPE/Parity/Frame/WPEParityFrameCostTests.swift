#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

/// What a frame allocates and re-plans: the per-frame arena against the bytes its draws encode, and a text change
/// against the draws it actually touches.
final class WPEParityFrameCostTests: XCTestCase {
    private static let textID = "5"
    private static let imageID = "1"

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-cost-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    // MARK: Arena

    func testArenaFitsSixHundredFramesOfScene3815666789() async throws {
        try await assertArena(captureRenderer("3815666789"), label: "scene 3815666789")
    }

    func testArenaFitsSixHundredFramesOfScene3660962877() async throws {
        try await assertArena(captureRenderer("3660962877") { $0["camerashake"] = false }, label: "scene 3660962877")
    }

    func testArenaFitsSixHundredFramesOfScene3647999330() async throws {
        try await assertArena(workshopRenderer("3647999330"), label: "scene 3647999330")
    }

    /// Every frame encodes without exhausting the arena (a non-particle draw that does not fit throws), and the
    /// non-particle share follows the argument bytes the draws take rather than a fixed allowance per draw.
    private func assertArena(_ renderer: WPEParityFrameRenderer, label: String) async throws {
        let initialArena = renderer.arenaBytes
        let initialShare = renderer.baseArenaBytes
        let dropped = renderer.droppedParticleBatches
        var most = 0
        for frame in 0 ..< 600 {
            guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: frame == 0 ? 0 : 1.0 / 60) else {
                return XCTFail("\(label) frame \(frame) was skipped")
            }
            let bytes = renderer.lastFrameDraws.reduce(0) { total, entry in
                renderer.particleRenderer(entry.operation) == nil ? total + entry.draw.pipeline.argumentBytes : total
            }
            most = max(most, bytes)
            await commandBuffer.completed()
            XCTAssertNil(commandBuffer.error, "\(label) frame \(frame)")
        }
        let planned = renderer.textPreparationState
        let casts = renderer.shadowLayout?.batches.count ?? 1
        let required = planned.frames.map { frame in
            planned.draws.reduce(0) { total, entry in
                guard let description = frame.draws[entry.key], renderer.particleRenderer(entry.key) == nil else {
                    return total
                }
                let shadow = if case let .scene(draw) = description {
                    draw.target == WPEParitySceneResource.shadowAtlas
                } else {
                    false
                }
                return total + entry.value.pipeline.argumentBytes * (shadow ? casts : 1)
            }
        }.max() ?? 0
        print("\(label): \(renderer.drawCount) draws; arena \(initialArena) -> \(renderer.arenaBytes) bytes, "
            + "non-particle share \(initialShare) -> \(renderer.baseArenaBytes); planned argument bytes \(required), "
            + "most one frame encoded \(most); particle batches dropped \(renderer.droppedParticleBatches - dropped)")
        XCTAssertLessThanOrEqual(most, renderer.baseArenaBytes, "\(label) encoded more than its non-particle share")
        XCTAssertEqual(renderer.baseArenaBytes, required + required / 4 + (1 << 16),
                       "\(label) does not size its non-particle share from its draws' argument bytes")
    }

    // MARK: Text replan

    /// A clock tick keeps the text's FBO and draw kinds, so the frame is not re-composed: only the text's own draws
    /// are re-planned, and every other draw keeps its plan.
    func testTextChangeKeepingTheFrameReplansOnlyThatTextsDraws() async throws {
        let (renderer, _) = try await syntheticTextRenderer()
        try await encode(renderer, label: "12:00")
        let before = renderer.textPreparationState
        XCTAssertEqual(renderer.skipped, [:])
        let textOperations = Set(before.frames[0].draws.compactMap { index, draw -> Int? in
            guard case let .scene(scene) = draw, scene.objectID == Self.textID else { return nil }
            return index
        })
        XCTAssertFalse(textOperations.isEmpty)
        XCTAssertTrue(before.draws.keys.contains { !textOperations.contains($0) }, "the scene needs another draw")
        let layouts = renderer.frameLayoutCalls

        renderer.state.setScriptField("text", of: Self.textID, to: .string("12:10"), invalidating: .textLayout)
        try await encode(renderer, label: "12:10")
        let after = renderer.textPreparationState
        let previous = try XCTUnwrap(before.texts[Self.textID])
        let current = try XCTUnwrap(after.texts[Self.textID])
        XCTAssertEqual(current.object.text, "12:10")
        XCTAssertEqual(current.layout.fboSize, previous.layout.fboSize, "the tick must keep the text's FBO")
        XCTAssertNotEqual(current.layout, previous.layout, "the tick must move glyphs")
        XCTAssertEqual(renderer.frameLayoutCalls, layouts, "the frame was re-composed for a text-only change")
        XCTAssertEqual(after.executorIDs, before.executorIDs, "the graphs were rebuilt")
        XCTAssertEqual(Set(after.draws.keys), Set(before.draws.keys))
        for (index, draw) in before.draws where !textOperations.contains(index) {
            let next = try XCTUnwrap(after.draws[index])
            XCTAssertTrue(next.pipeline.state === draw.pipeline.state, "operation \(index) pipeline")
            XCTAssertEqual(Self.geometryIdentity(next), Self.geometryIdentity(draw), "operation \(index) geometry")
            XCTAssertEqual(next.textures.map(Self.textureIdentities), draw.textures.map(Self.textureIdentities),
                           "operation \(index) textures")
        }
        let glyphs = try XCTUnwrap(textOperations.first { index in
            guard case let .scene(scene)? = after.frames[0].draws[index] else { return false }
            return scene.geometry == .textGlyphs(.mono)
        })
        let newGlyphs = try XCTUnwrap(after.draws[glyphs])
        let oldGlyphs = try XCTUnwrap(before.draws[glyphs])
        XCTAssertNotEqual(Self.geometryIdentity(newGlyphs), Self.geometryIdentity(oldGlyphs),
                          "the glyph draw needs new geometry")
        let encoded = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == glyphs }?.draw)
        XCTAssertEqual(encoded.indexCount, 30, "the encoded glyph draw is not the five-glyph 12:10")
    }

    // MARK: Fixtures

    private static func geometryIdentity(_ draw: WPEParityFrameDrawPlan) -> [ObjectIdentifier] {
        switch draw.geometry {
        case let .mesh(vertices, indices, _, _): [ObjectIdentifier(vertices), ObjectIdentifier(indices)]
        case let .modelData(shape): [ObjectIdentifier(shape)]
        case .particles: []
        }
    }

    private static func textureIdentities(_ table: [String: WPEParityFrameDrawPlan.TextureSource]) -> [String: String] {
        table.mapValues { source in
            switch source {
            case let .resource(id): id.rawValue
            case let .image(texture): "\(ObjectIdentifier(texture))"
            }
        }
    }

    private func encode(_ renderer: WPEParityFrameRenderer, label: String) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("\(label): frame skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error, label)
    }

    private func home() throws -> URL {
        // The sandboxed test host's home is its container; the WPE install lives in the account's real home.
        try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
    }

    private func wpeAssets(requiring path: String) throws -> URL {
        let install = try home().appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let assets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: assets.appending(path: path).path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (\(path))")
        }
        return assets
    }

    /// A white 64 pt clock text and a blue solid layer in a black orthographic scene without bloom.
    private func syntheticTextRenderer() async throws -> (WPEParityFrameRenderer, WPEParityFramePlan) {
        let wpeAssets = try wpeAssets(requiring: "fonts/NotoSans-Regular.ttf")
        let (width, height) = (1024, 512)
        let scene: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": width, "height": height], "clearcolor": "0 0 0",
                        "bloom": false],
            "objects": [
                ["id": Int(Self.imageID)!, "image": "models/util/solidlayer.json", "size": "128 128",
                 "origin": "128 128 0", "color": "0 0 1", "alpha": 1] as [String: Any],
                ["id": Int(Self.textID)!, "name": "clock", "text": "12:00", "font": "fonts/NotoSans-Regular.ttf",
                 "pointsize": 64, "color": "1 1 1", "origin": "\(width / 2) \(height / 2) 0"],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene),
                                                        userValues: [:])
        let assets = WPEParityProgramAssets(sceneDirectory: scratch, assetRoots: [wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                          width: width, height: height)
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let cache = FileManager.default.temporaryDirectory.appending(path: "parity-text-cache", directoryHint: .isDirectory)
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: XCTUnwrap(device.makeCommandQueue()),
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                bindingABIVersion: 1),
            particleSeed: 1
        )
        return (renderer, plan)
    }

    /// The capture machine's settings and shaders, as `WPEParityRealSceneTests` renders the scene.
    private func captureRenderer(_ sceneID: String,
                                 editGeneral: (inout [String: Any]) -> Void = { _ in }) async throws -> WPEParityFrameRenderer {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let wpeAssets = try wpeAssets(requiring: "materials/util")
        let sceneDirectory = root.appending(path: "scene-sources/\(sceneID)")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sceneDirectory.appending(path: "scene.json"))
        ) as? [String: Any])
        var general = json["general"] as? [String: Any] ?? [:]
        editGeneral(&general)
        json["general"] = general
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: json), userValues: [:]
        )
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets,
                                          settings: WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaaSampleCount: 2),
                                          width: 1920, height: 1080)
        let geometryCompiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.loadPrograms,
                                                     geometryCompiler: geometryCompiler,
                                                     uncapturedUtilityPrograms: WPEParityFixtureShaderCompiler.utilityPrograms(in: plan)),
            diskCache: WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "cache"))
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: XCTUnwrap(device.makeCommandQueue()),
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: "hlsl-capture-2026-10-12",
                                                bindingABIVersion: 1),
            particleSeed: 1
        )
    }

    private func workshopFolder(_ workshopID: String) throws -> (folder: URL, engineRoot: URL) {
        let steam = try home().appending(path: "Library/Application Support/Steam/steamapps")
        let folder = steam.appending(path: "workshop/content/431960/\(workshopID)", directoryHint: .isDirectory)
        let engineRoot = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? steam.appending(path: "common/wallpaper_engine")
        guard FileManager.default.fileExists(atPath: folder.appending(path: "scene.pkg").path),
              FileManager.default.fileExists(atPath: engineRoot.appending(path: "assets/materials/util").path) else {
            throw XCTSkip("Needs Workshop \(workshopID) and WPE's assets (or WPE_ASSETS_DIR)")
        }
        return (folder, engineRoot)
    }

    /// The scene compiled by wpe-shaderc, as `WPEParityRealSceneTests` renders Workshop 3647999330.
    private func workshopRenderer(_ workshopID: String) async throws -> WPEParityFrameRenderer {
        let (folder, engineRoot) = try workshopFolder(workshopID)
        let assets = try WPEParitySceneAssets.make(
            provider: WPEPackageSceneAssetProvider(packageURL: folder.appending(path: "scene.pkg")),
            projectRoot: folder, dependencyMounts: [], engineAssetsRootURL: engineRoot
        )
        let document = try WPESceneDocumentParser.parse(
            data: XCTUnwrap(assets.data("scene.json")), userValues: [:]
        )
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                          width: 1920, height: 1080)
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: XCTUnwrap(device.makeCommandQueue()),
            shaders: WPEParityFrameShaderSource(
                store: WPEParityShaderStore(compiler: compiler,
                                            diskCache: WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "cache"))),
                compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
            ),
            particleSeed: 1
        )
    }
}

#endif
