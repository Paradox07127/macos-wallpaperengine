#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import XCTest

/// The probe frames a plan prepares pipelines for, and its `_rt_MipMappedFrameBuffer` request, stay exactly what
/// they were for real scenes: every frame, program and skip is folded into a digest that does not depend on hashing seeds.
final class WPEParityFramePlanProbeSnapshotTests: XCTestCase {
    private struct Snapshot: Equatable, CustomStringConvertible {
        let probes: Int
        let mipRequested: Bool
        let digest: String

        var description: String {
            "Snapshot(probes: \(probes), mipRequested: \(mipRequested), digest: \"\(digest)\")"
        }
    }

    func testScene2955378002ProbesTheSameFramesAndMipRequest() async throws {
        try await assertWorkshop("2955378002", Snapshot(
            probes: 28, mipRequested: false, digest: "d2e48266d587d2c7301b4804f01a267e50b3f08df37bf9c9ff52844ca9663a24"
        ))
    }

    func testScene3226487183ProbesTheSameFramesAndMipRequest() async throws {
        try await assertWorkshop("3226487183", Snapshot(
            probes: 52, mipRequested: false, digest: "66ff75252329dc5e94206aff417724c425464c7768396fe53561a74ccab58825"
        ))
    }

    func testScene3808922316ProbesTheSameFramesAndMipRequest() async throws {
        try await assertWorkshop("3808922316", Snapshot(
            probes: 20, mipRequested: false, digest: "aabe4ef3bef29f73f854feb28098b7d1241d40c9fb42a3baffb8efeea2622848"
        ))
    }

    func testScene3798688689ProbesTheSameFramesAndMipRequest() async throws {
        try await assertWorkshop("3798688689", Snapshot(
            probes: 16, mipRequested: false, digest: "12c39fefce1f5337d08290ae67aee3c9faaceb09c4d88e347472fbbc06a00061"
        ))
    }

    func testCaptureScene3660962877ProbesTheSameFramesAndMipRequest() async throws {
        try await assertCapture("3660962877", Snapshot(
            probes: 12, mipRequested: false, digest: "d51a699794cc27ecf973eb03bd0234ca00803643c32ebe34f8a6047005ca48eb"
        ))
    }

    func testCaptureScene3815666789ProbesTheSameFramesAndMipRequest() async throws {
        try await assertCapture("3815666789", Snapshot(
            probes: 8, mipRequested: false, digest: "e3be672e34a796f8f7e6d81f71e07321040712340f4dae73568aa6802c9e6573"
        ))
    }

    private func assertCapture(_ id: String, _ expected: Snapshot) async throws {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let directory = root.appending(path: "scene-sources/\(id)")
        let document = try WPESceneDocumentParser.parse(
            data: Data(contentsOf: directory.appending(path: "scene.json")), userValues: [:]
        )
        let assets = WPEParityProgramAssets(sceneDirectory: directory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets,
                                          settings: WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true),
                                          width: 1920, height: 1080)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "probe-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.loadPrograms),
            diskCache: WPEParityShaderDiskCache(cachesURL: scratch)
        )
        let shaders = WPEParityFrameShaderSource(store: store, compilerIdentity: "hlsl-capture-2026-10-12",
                                                 bindingABIVersion: 1)
        let actual = try await Self.snapshot(plan, shaders: shaders)
        XCTAssertEqual(actual, expected, "capture scene \(id)")
    }

    private func assertWorkshop(_ id: String, _ expected: Snapshot) async throws {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appending(path: "Library/Application Support/Steam/steamapps")
        let folder = steam.appending(path: "workshop/content/431960/\(id)", directoryHint: .isDirectory)
        let engineRoot = steam.appending(path: "common/wallpaper_engine")
        guard FileManager.default.fileExists(atPath: folder.appending(path: "scene.pkg").path),
              FileManager.default.fileExists(atPath: engineRoot.appending(path: "assets/materials/util").path) else {
            throw XCTSkip("Needs Workshop \(id) and WPE's assets")
        }
        let projectRoot = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "project.json")))
            as? [String: Any] ?? [:]
        let entry = projectRoot["file"] as? String ?? "scene.json"
        let schema = try? WallpaperEngineProjectPropertySchema.read(from: folder, includeSchemeColor: true)
        let values = schema?.effectiveValues(overrides: [:]) ?? [:]
        let assets = try WPEParitySceneAssets.make(
            provider: WPEPackageSceneAssetProvider(packageURL: folder.appending(path: "scene.pkg")),
            projectRoot: folder, dependencyMounts: [], engineAssetsRootURL: engineRoot, userValues: values
        )
        let data = try XCTUnwrap(assets.data(entry), "entry \(entry) unreadable")
        let repaired = schema.map { WPESceneParallaxBindingInference.applying(to: data, schema: $0) } ?? data
        let document = try WPESceneDocumentParser.parse(data: repaired, userValues: values)
        let settings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaaSampleCount: 1,
                                                mipMappedFrameBufferEnabled: true)
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: settings,
                                          width: 1920, height: 1080)
        // Kept across runs: the shader cache is keyed by compiler identity.
        let cache = FileManager.default.temporaryDirectory.appending(path: "wpe-parity-workshop-\(id)",
                                                                     directoryHint: .isDirectory)
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: cache.appending(path: "shaderc"))
        let store = WPEParityShaderStore(compiler: compiler,
                                         diskCache: WPEParityShaderDiskCache(cachesURL: cache.appending(path: "shaders")))
        let shaders = WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                 bindingABIVersion: 1)
        let actual = try await Self.snapshot(plan, shaders: shaders)
        XCTAssertEqual(actual, expected, "workshop scene \(id)")
    }

    private static func snapshot(_ plan: WPEParityFramePlan, shaders: WPEParityFrameShaderSource) async throws -> Snapshot {
        let artifacts = await withTaskGroup(
            of: (WPEHLSLProgram, Result<WPEParityShaderArtifact, WPEParityFrameSkip>).self
        ) { group in
            for program in plan.loadPrograms {
                group.addTask {
                    do {
                        return try await (program.hlsl, .success(shaders.artifact(for: program)))
                    } catch {
                        return (program.hlsl, .failure(.noShader("\(program.shader): \(error)")))
                    }
                }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        let probes = try plan.probeFrames()
        let mipRequested = plan.requestsMipMappedFrameBuffer(in: probes, artifacts: artifacts)
        var digest = SHA256()
        var memo: [AnyHashable: String] = [:]
        var programs: [WPEHLSLProgram: String] = [:]
        func cached(_ value: some Hashable) -> String {
            if let text = memo[AnyHashable(value)] {
                return text
            }
            let text = describe(value)
            memo[AnyHashable(value)] = text
            return text
        }
        for probe in probes {
            var lines = ["probe"]
            lines += probe.frame.operations.map { cached($0) }
            lines += probe.frame.resources.map { cached($0) }
            lines += probe.frame.draws.sorted { $0.key < $1.key }.map { "\($0.key)=\(cached($0.value))" }
            lines.append(describe(probe.frame.samplers))
            lines.append(describe(probe.frame.owners))
            lines.append(describe(probe.frame.particleBlocks))
            lines.append(describe(probe.frame.logicalSizes))
            lines += probe.programs.sorted { $0.key < $1.key }.map { index, program in
                let text = programs[program.hlsl] ?? {
                    let stages = [program.hlsl.vertex, program.hlsl.geometry, program.hlsl.fragment]
                        .map { $0.map { Data(SHA256.hash(data: Data($0))).base64EncodedString() } ?? "-" }
                    return ([program.shader, program.dxsKey()] + stages).joined(separator: "|")
                }()
                programs[program.hlsl] = text
                return "program \(index)=\(text)"
            }
            lines += probe.skipped.sorted { $0.key < $1.key }.map { "skip \($0.key)=\($0.value)" }
            digest.update(data: Data(lines.joined(separator: "\n").utf8))
        }
        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return Snapshot(probes: probes.count, mipRequested: mipRequested, digest: hex)
    }

    /// Dictionaries and sets in a stable order, so the text is the same in every process.
    private static func describe(_ value: Any) -> String {
        if let bytes = value as? [UInt8] {
            return "bytes:" + Data(SHA256.hash(data: Data(bytes))).base64EncodedString()
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .dictionary?:
            let entries = mirror.children.map { child -> String in
                let pair = Array(Mirror(reflecting: child.value).children)
                return describe(pair[0].value) + ":" + describe(pair[1].value)
            }
            return "[" + entries.sorted().joined(separator: ",") + "]"
        case .set?:
            return "{" + mirror.children.map { describe($0.value) }.sorted().joined(separator: ",") + "}"
        case .optional?:
            return mirror.children.first.map { describe($0.value) } ?? "nil"
        default:
            guard !mirror.children.isEmpty else { return String(describing: value) }
            return "\(mirror.subjectType)(" + mirror.children.map { "\($0.label ?? ""):\(describe($0.value))" }
                .joined(separator: ",") + ")"
        }
    }
}
#endif
