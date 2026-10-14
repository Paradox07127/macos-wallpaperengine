import Darwin
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityProgramSettingsTests: XCTestCase {
    /// Real MDL meshes, rather than a JSON key named `model`, select Main's BACKBUFFER_MS route.
    func testLoadedMDLModelsUseOneSampleCountForCombosSceneAndPost() throws {
        let (document, assets) = try modelFixture()
        for requested in [1, 2, 4, 8, 3, 16] {
            let scene = WPEParityProgramScene(document: document, assets: assets,
                                              settings: .init(bloom: false, msaaSampleCount: requested,
                                                              colorCorrection: .init(wecE: true, wecBrs: 75)))
            XCTAssertEqual(scene.models["112"]?.meshes.count, 1, "fixture must load Earth's MDL")
            XCTAssertEqual(scene.models["114"]?.meshes.count, 1, "fixture must load the cloud MDL")
            let expected = [2, 4, 8].contains(requested) ? requested : 1
            try assertSampleRoute(scene, expected: expected)
        }
    }

    func testSerializedNullModelDoesNotEnableMSAAForAnImageLayer() throws {
        for requested in [2, 4, 8] {
            let layer = ParitySceneDocuments.layer(json: ["model": NSNull()])
            let scene = try ParitySceneDocuments.programScene(
                [layer], settings: .init(bloom: false, msaaSampleCount: requested,
                                         colorCorrection: .init(wecE: true, wecBrs: 75))
            )
            XCTAssertEqual(scene.scene.objects.first?.kind, .image)
            XCTAssertTrue(scene.models.isEmpty)
            try assertSampleRoute(scene, expected: 1)
        }
    }

    func testHDRQualityStillRequiresSceneBloomAndHDRFlags() throws {
        for bloom in [false, true] {
            for hdr in [false, true] {
                for quality in [false, true] {
                    let scene = try ParitySceneDocuments.programScene(
                        [ParitySceneDocuments.layer()], general: ["bloom": bloom, "hdr": hdr],
                        settings: .init(bloom: false, hdrPostProcessing: quality)
                    )
                    let expected = bloom && hdr && quality
                    XCTAssertEqual(scene.engineFlags.hdr, expected)
                    XCTAssertEqual(scene.postProcess.hdrEnabled, expected)
                    XCTAssertEqual(scene.scene.backbufferFormat, expected ? "rgba16float" : "rgba8unorm")
                    let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess,
                                                                   frameIndex: 0)
                    let terminals = frame.draws.values.compactMap { draw -> String? in
                        guard case let .post(post) = draw else { return nil }
                        return post.shader
                    }
                    XCTAssertEqual(terminals, expected ? ["combine_srgb"] : [])
                }
            }
        }
    }

    func testLegacyMSAASwitchMutatesTheStoredSampleCount() {
        var settings = WPEParityProgramSettings(msaaSampleCount: 8)
        settings.msaa = false
        XCTAssertEqual(settings.msaaSampleCount, 1)
        settings.msaa = true
        XCTAssertEqual(settings.msaaSampleCount, 2)
        settings.msaaSampleCount = 4
        settings.msaa = true
        XCTAssertEqual(settings.msaaSampleCount, 4)
    }

    private func assertSampleRoute(_ scene: WPEParityProgramScene, expected: Int,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(scene.engineFlags.backbufferMSAA, expected > 1, file: file, line: line)
        XCTAssertEqual(scene.scene.msaaSamples, expected, file: file, line: line)
        XCTAssertEqual(scene.postProcess.msaaSampleCount, expected, file: file, line: line)
        let combos = WPEComboResolver.resolve(passJSONCombos: [], blendingMode: 0,
                                              vertexSource: "", fragmentSource: "",
                                              engineFlags: scene.engineFlags, boundTextures: [:])
        XCTAssertEqual(combos.first { $0.name == "BACKBUFFER_MS" }?.value,
                       expected > 1 ? "1" : nil, file: file, line: line)
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess, frameIndex: 0)
        let resources = Dictionary(uniqueKeysWithValues: frame.resources.map { ($0.id, $0) })
        XCTAssertEqual(resources["backbuffer"]?.sampleCount, 1, file: file, line: line)
        XCTAssertEqual(resources["backbufferDepth"]?.sampleCount, 1, file: file, line: line)
        let multisampled: WPEResourceID = "_rt_FullFrameBufferMultiSampled"
        let multisampledDepth: WPEResourceID = "_rt_FullFrameBufferMultiSampledDepth"
        XCTAssertEqual(resources[multisampled]?.sampleCount, expected > 1 ? expected : nil,
                       file: file, line: line)
        XCTAssertEqual(resources[multisampledDepth]?.sampleCount, expected > 1 ? expected : nil,
                       file: file, line: line)
        let resolves = frame.operations.compactMap { operation -> [WPEResourceID]? in
            guard case let .resolve(source, destination) = operation.kind else { return nil }
            return [source, destination]
        }
        if expected > 1 {
            XCTAssertEqual(resolves.filter { $0[1] == "backbuffer" }, [[multisampled, "backbuffer"]],
                           file: file, line: line)
            XCTAssertEqual(resolves.last, [multisampled, "backbuffer"], file: file, line: line)
            // Native FFB/reflection snapshots can resolve the same scene before its terminal resolve.
            for transfer in resolves {
                XCTAssertEqual(transfer[0], multisampled, file: file, line: line)
                XCTAssertEqual(resources[transfer[0]]?.sampleCount, expected, file: file, line: line)
                XCTAssertEqual(resources[transfer[1]]?.sampleCount, 1, file: file, line: line)
            }
        } else {
            XCTAssertTrue(resolves.isEmpty, file: file, line: line)
        }
        var targets: [WPETextureView] = []
        var postDraws = 0
        for (index, operation) in frame.operations.enumerated() {
            if case let .setTargets(color, _) = operation.kind {
                targets = color
            }
            guard let draw = frame.draws[index], case .post = draw else { continue }
            postDraws += 1
            XCTAssertEqual(targets.map(\.resource), ["backbuffer"], file: file, line: line)
            XCTAssertEqual(targets.compactMap { resources[$0.resource]?.sampleCount }, [1], file: file, line: line)
        }
        XCTAssertGreaterThan(postDraws, 0, "fixture must exercise the post target after resolve", file: file, line: line)
    }

    private func modelFixture() throws -> (WPESceneDocument, WPEParityProgramAssets) {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appendingPathComponent("Library/Application Support/Steam/steamapps")
        let package = steam.appendingPathComponent("workshop/content/431960/3437487219/scene.pkg")
        let engine = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? steam.appendingPathComponent("common/wallpaper_engine/assets")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: engine.appendingPathComponent("materials/util").path) else {
            throw XCTSkip("Needs Workshop 3437487219 and original WPE assets (WPE_ASSETS_DIR)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-settings-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try ParityProgramPuppetTests.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoSettingsScripts() })
        return (document, WPEParityProgramAssets(sceneDirectory: root, assetRoots: [engine]))
    }
}

private struct NoSettingsScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
