#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import os
import simd
import XCTest

/// The parity SceneScript engine inside the frame: same-frame write-back, next-frame camera, effect toggles, cursor
/// clicks into the usershortcut link, and a real 252-script scene.
final class WPEParityScriptWiringTests: XCTestCase {
    private static let width = 1920
    private static let height = 1080
    private static let settings = WPEParityProgramSettings(bloom: true, hdrPostProcessing: true, msaa: true)
    private static let counter = "let n = 0;\nexport function update(value) {\n  n += 1;\n  return %@;\n}"

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-script-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testScriptAlphaReachesTheDrawOfTheSameFrame() async throws {
        let fixture = try await makeFixture("3815666789") { json in
            Self.edit(&json, object: 17) {
                $0["alpha"] = ["value": 1, "script": String(format: Self.counter, "n")]
            }
        }
        let script = try attachScript(fixture)
        let operation = try XCTUnwrap(Self.operation(fixture.plan, object: "17") { $0.fillsComposite })
        for frame in 1 ... 5 {
            try await encode(fixture.renderer)
            let draw = try XCTUnwrap(fixture.renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
            XCTAssertEqual(Self.float(draw.constants[.fragment]?["g_Alpha"]), Float(frame), "frame \(frame)")
        }
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    func testScriptCameraFovShowsOneFrameLater() async throws {
        let fixture = try await makeFixture("3815666789") { json in
            var objects = json["objects"] as? [[String: Any]] ?? []
            objects.append(["id": 901, "name": "camera", "camera": "camera", "origin": "0 0 0", "angles": "0 0 0",
                            "scale": "1 1 1", "fov": ["value": 50, "script": String(format: Self.counter, "10 + n")]])
            json["objects"] = objects
        }
        let script = try attachScript(fixture)
        XCTAssertEqual(script.cameraIDs, ["901"])
        let loaded = fixture.renderer.pathCamera.perspectiveFOV
        var seen: [Float] = []
        for frame in 1 ... 4 {
            try await encode(fixture.renderer)
            XCTAssertEqual(fixture.renderer.state.scriptField("fov", of: "901"), .vector(SIMD4(10 + Float(frame), 0, 0, 0)))
            seen.append(fixture.renderer.pathCamera.perspectiveFOV)
        }
        XCTAssertEqual(seen, [loaded, 11, 12, 13])
    }

    func testScriptEffectToggleChangesTheDrawsOfThatFrame() async throws {
        let fixture = try await makeFixture("3815666789") { json in
            Self.edit(&json, object: 17) { object in
                var effects = object["effects"] as? [[String: Any]] ?? []
                effects[1]["visible"] = ["value": true, "script": String(format: Self.counter, "n < 3")]
                object["effects"] = effects
            }
        }
        let script = try attachScript(fixture)
        var counts: [Int] = []
        for _ in 1 ... 4 {
            try await encode(fixture.renderer)
            counts.append(fixture.renderer.lastFrameDraws.count)
        }
        print("effect toggle by script: draws per frame \(counts)")
        XCTAssertEqual(counts[0], counts[1])
        XCTAssertLessThan(counts[2], counts[1])
        XCTAssertEqual(counts[3], counts[2])
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    func testCursorClickRunsTheBoundUserShortcut() async throws {
        let fixture = try await makeFixture("3815666789") { json in
            Self.edit(&json, object: 17) {
                $0["solid"] = true
                $0["alpha"] = ["value": 1, "script": """
                export function cursorClick(event) {
                  engine.openUserShortcut('shortcut1');
                }
                """]
            }
        }
        let bridge = WPEUserShortcutScriptBridge()
        bridge.setBindings(declared: ["shortcut1"],
                           bound: ["shortcut1": .init(commandType: "cmd", displayName: "Shortcut", revision: 7)])
        let launched = OSAllocatedUnfairLock<[String]>(initialState: [])
        bridge.setLauncher { key, revision in launched.withLock { $0.append("\(key)@\(revision)") } }
        let script = try attachScript(fixture, host: .init(openUserShortcut: { bridge.requestLaunch($0) }))
        let corners = try XCTUnwrap(fixture.renderer.cursorQuad("17", camera: fixture.renderer.pathCamera))
        let centre = (corners.0 + corners.1 + corners.2 + corners.3) / 4
        for down in [false, true, false] {
            try await encode(fixture.renderer, input: WPEParityFrameInput(cursor: centre, buttonDown: down))
        }
        XCTAssertEqual(script.engine.dispatchCount(.cursorClick), 1)
        XCTAssertEqual(launched.withLock { $0 }, ["shortcut1@7"])
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    /// 120 frames of workshop 3660962877 with its 252 scripts; prints the encodeFrame CPU mean with and without them.
    func testRealSceneRendersWithItsScripts() async throws {
        var means: [Bool: Double] = [:]
        for scripted in [true, false] {
            let fixture = try await makeFixture("3660962877")
            let script = scripted ? try attachScript(fixture) : nil
            if let script {
                XCTAssertGreaterThan(script.engine.bindings.count, 200)
            }
            var cpu: UInt64 = 0
            for _ in 1 ... 120 {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let submission = try fixture.renderer.encodeFrame(elapsed: 1.0 / 60)
                cpu += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
                guard case let .committed(commandBuffer) = submission else { return XCTFail("frame was skipped") }
                await commandBuffer.completed()
                XCTAssertNil(commandBuffer.error)
            }
            means[scripted] = Double(cpu) / 120 / 1_000_000
            if let script {
                XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
            }
        }
        print("scene 3660962877: encodeFrame CPU mean \(means[true] ?? 0) ms with scripts, "
            + "\(means[false] ?? 0) ms without")
    }

    // MARK: Helpers

    private struct Fixture {
        let plan: WPEParityFramePlan
        let renderer: WPEParityFrameRenderer
    }

    private func attachScript(_ fixture: Fixture,
                              host: WPEParitySceneScript.Host = .init()) throws -> WPEParitySceneScript {
        let renderer = fixture.renderer
        let script = try WPEParitySceneScript(
            document: fixture.plan.document, state: renderer.state, assets: fixture.plan.scene.assets,
            canvasSize: renderer.pathCamera.size,
            screenResolution: SIMD2(Float(renderer.backbuffer.width), Float(renderer.backbuffer.height)), host: host
        )
        renderer.attachScript(script)
        return script
    }

    private func encode(_ renderer: WPEParityFrameRenderer,
                        input: WPEParityFrameInput = WPEParityFrameInput()) async throws {
        guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60, input: input) else {
            return XCTFail("frame was skipped")
        }
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error)
    }

    private static func edit(_ json: inout [String: Any], object id: Int, _ body: (inout [String: Any]) -> Void) {
        var objects = json["objects"] as? [[String: Any]] ?? []
        for index in objects.indices where objects[index]["id"] as? Int == id {
            body(&objects[index])
        }
        json["objects"] = objects
    }

    private static func operation(_ plan: WPEParityFramePlan, object id: String,
                                  where predicate: (WPEParitySceneDraw) -> Bool) -> Int? {
        plan.frames[0].draws.sorted { $0.key < $1.key }.first { _, draw in
            if case let .scene(scene) = draw {
                scene.objectID == id && predicate(scene)
            } else {
                false
            }
        }?.key
    }

    private static func float(_ value: WPECBufferValue?) -> Float? {
        if case let .float(number)? = value {
            number
        } else {
            nil
        }
    }

    /// A capture scene with its scene JSON edited by `edit`.
    private func makeFixture(_ sceneID: String, edit: (inout [String: Any]) -> Void = { _ in }) async throws -> Fixture {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let install = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appending(path: "scripts/jsclasses/baseclasses.js").path)
        else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (scripts/jsclasses)")
        }
        let sceneDirectory = root.appending(path: "scene-sources/\(sceneID)")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: sceneDirectory.appending(path: "scene.json"))
        ) as? [String: Any])
        edit(&json)
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: json), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoTransformScripts() }
        )
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: Self.settings,
                                          width: Self.width, height: Self.height)
        let geometryCompiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.programs.values,
                                                     geometryCompiler: geometryCompiler),
            diskCache: WPEParityShaderDiskCache(cachesURL: scratch.appending(path: "cache"))
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: XCTUnwrap(device.makeCommandQueue()),
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: "hlsl-capture-2026-10-12",
                                                bindingABIVersion: 1),
            particleSeed: 1
        )
        return Fixture(plan: plan, renderer: renderer)
    }
}

private struct NoTransformScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
