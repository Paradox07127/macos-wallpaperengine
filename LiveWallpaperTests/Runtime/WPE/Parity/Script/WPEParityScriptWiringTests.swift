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

    /// thisObject.getAnimation().play() in init starts a startpaused alpha animation through the renderer's bindings.
    func testScriptPlaysAStartPausedAlphaAnimation() async throws {
        let fixture = try await makeFixture("3815666789") { json in
            Self.edit(&json, object: 17) {
                $0["alpha"] = [
                    "value": 0.2,
                    "animation": ["c0": [["frame": 0, "value": 0.2], ["frame": 10, "value": 1]],
                                  "options": ["fps": 10, "length": 10, "mode": "single", "startpaused": true]],
                    "script": "export function init(value){ thisObject.getAnimation().play(); return value; }",
                ]
            }
        }
        let script = try attachScript(fixture)
        let operation = try XCTUnwrap(Self.operation(fixture.plan, object: "17") { $0.fillsComposite })
        for _ in 1 ... 5 {
            try await encode(fixture.renderer)
        }
        let draw = try XCTUnwrap(fixture.renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
        XCTAssertEqual(try XCTUnwrap(Self.float(draw.constants[.fragment]?["g_Alpha"])), 0.2 + 0.8 * 5 / 60,
                       accuracy: 1e-3)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    /// A fully held native pause skips object/script/render updates, retaining the last published intervals.
    func testHeldPauseStopsScriptWritesAndGPUFramesUntilResume() async throws {
        let fixture: Fixture
        do {
            fixture = try await makeFixture("3815666789") { json in
                Self.edit(&json, object: 17) {
                    $0["alpha"] = ["value": 1, "script": String(format: Self.counter, "n")]
                }
            }
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(domain: "NativePause.RequiredFixture", code: 1, userInfo: [NSUnderlyingErrorKey: error]))
        }
        let script = try attachScript(fixture)
        let operation = try XCTUnwrap(Self.operation(fixture.plan, object: "17") { $0.fillsComposite })
        var held = false
        try await encode(fixture.renderer)
        for _ in 0 ..< 20 {
            switch try fixture.renderer.encodeFrame(elapsed: 0.25, paused: true) {
            case let .committed(command):
                await command.completed()
                XCTAssertNil(command.error)
            case .skipped:
                held = true
            }
            if held {
                break
            }
        }
        XCTAssertTrue(held, "the pause ramp must eventually hold")
        let alpha = try XCTUnwrap(Self.float(fixture.renderer.lastFrameDraws.first { $0.operation == operation }?.draw.constants[.fragment]?["g_Alpha"]))
        for _ in 0 ..< 3 {
            guard case .skipped = try fixture.renderer.encodeFrame(elapsed: 0.25, paused: true) else {
                return XCTFail("a held pause must not submit GPU work")
            }
        }
        try await encode(fixture.renderer)
        let resumed = try XCTUnwrap(Self.float(fixture.renderer.lastFrameDraws.first { $0.operation == operation }?.draw.constants[.fragment]?["g_Alpha"]))
        XCTAssertEqual(resumed, alpha + 1, "held frames must not execute the script counter")
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    func testScriptCameraFovShowsOneFrameLater() async throws {
        let fixture = try await makeFixture("3815666789") { json in
            // Object fov controls the perspective scene, not an ortho layer's perspectiveoverridefov.
            var general = json["general"] as? [String: Any] ?? [:]
            general["orthogonalprojection"] = NSNull()
            json["general"] = general
            var objects = json["objects"] as? [[String: Any]] ?? []
            objects.append(["id": 901, "name": "camera", "camera": "camera", "origin": "0 0 0", "angles": "0 0 0",
                            "scale": "1 1 1", "fov": ["value": 50, "script": String(format: Self.counter, "10 + n")]])
            json["objects"] = objects
        }
        let script = try attachScript(fixture)
        XCTAssertEqual(script.cameraIDs, ["901"])
        let loaded = try XCTUnwrap(fixture.renderer.pathCamera.scenePerspective).fov
        let layerOverride = fixture.renderer.pathCamera.perspectiveFOV
        var seen: [Float] = []
        for frame in 1 ... 4 {
            try await encode(fixture.renderer)
            XCTAssertEqual(fixture.renderer.state.scriptField("fov", of: "901"), .vector(SIMD4(10 + Float(frame), 0, 0, 0)))
            let camera = fixture.renderer.pathCamera
            let fov = try XCTUnwrap(camera.scenePerspective).fov
            seen.append(fov)
            XCTAssertEqual(camera.perspectiveFOV, layerOverride)
            XCTAssertEqual(camera.projection.columns.1.y, 1 / tan(fov * Float.pi / 360), accuracy: 0.00001)
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

    /// One press opens one launch shared by cursorDown/Click; a second call in that click and a call from update
    /// throw SyntaxError.
    func testOnePressLaunchesOneUserShortcutAndLaterCallsThrowSyntaxError() async throws {
        let fixture = try await makeFixture("3815666789") { json in
            Self.edit(&json, object: 17) {
                $0["solid"] = true
                $0["alpha"] = ["value": 1, "script": """
                let clickCaught = 0, updateCaught = 0;
                export function cursorDown(event) {
                  engine.openUserShortcut('shortcut1');
                }
                export function cursorClick(event) {
                  try { engine.openUserShortcut('shortcut1'); } catch (e) { clickCaught = e instanceof SyntaxError ? 1 : -1; }
                }
                export function update(value) {
                  try { engine.openUserShortcut('shortcut1'); } catch (e) { updateCaught = e instanceof SyntaxError ? 1 : -1; }
                  return clickCaught * 2 + updateCaught;
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
        let operation = try XCTUnwrap(Self.operation(fixture.plan, object: "17") { $0.fillsComposite })
        let corners = try XCTUnwrap(fixture.renderer.cursorQuad("17", camera: fixture.renderer.pathCamera))
        let centre = (corners.0 + corners.1 + corners.2 + corners.3) / 4
        for down in [false, true, false] {
            try await encode(fixture.renderer, input: WPEParityFrameInput(cursor: centre, buttonDown: down))
        }
        XCTAssertEqual(script.engine.dispatchCount(.cursorDown), 1)
        XCTAssertEqual(script.engine.dispatchCount(.cursorClick), 1)
        XCTAssertEqual(launched.withLock { $0 }, ["shortcut1@7"])
        let draw = try XCTUnwrap(fixture.renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
        XCTAssertEqual(Self.float(draw.constants[.fragment]?["g_Alpha"]), 3,
                       "the click's and update's calls must both have thrown SyntaxError")
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    /// 1401731d0.c:493-707: a usershortcut entry carries isbound, and when bound its commandtype and file.
    func testScriptsSeeUserShortcutBindingStateAndItsChanges() async throws {
        let fixture = try await makeFixture("3815666789") { json in
            Self.edit(&json, object: 17) {
                $0["alpha"] = ["value": 1, "script": """
                export function applyUserProperties(p){ if (!p.hasOwnProperty('shortcut1')) return; \
                var s = p.shortcut1; if (s.isbound === false) { thisLayer.alpha = 0.25; return; } \
                thisLayer.alpha = (s.isbound === true && s.commandtype === 'website' \
                && s.file === 'https://example.com/a') ? 1 : 0.5; }
                """]
            }
        }
        let bridge = WPEUserShortcutScriptBridge()
        bridge.setBindings(declared: ["shortcut1"], bound: [:])
        let script = try attachScript(fixture, host: .init(
            userPropertiesJSON: #"{"shortcut1":{"type":"usershortcut","value":""}}"#, userShortcuts: bridge
        ))
        let operation = try XCTUnwrap(Self.operation(fixture.plan, object: "17") { $0.fillsComposite })
        func alpha() throws -> Float? {
            try Self.float(XCTUnwrap(fixture.renderer.lastFrameDraws.first { $0.operation == operation }?.draw)
                .constants[.fragment]?["g_Alpha"])
        }

        try await encode(fixture.renderer)
        XCTAssertEqual(try alpha(), 0.25, "an unbound shortcut must reach scripts as isbound false")

        bridge.setBindings(declared: ["shortcut1"], bound: ["shortcut1": .init(
            commandType: "web", displayName: "example.com", revision: 1, target: "https://example.com/a"
        )])
        try await encode(fixture.renderer)
        XCTAssertEqual(try alpha(), 1, "a bound web shortcut must reach scripts as a website with its URL")
        XCTAssertEqual(script.engine.dispatchCount(.applyUserProperties), 2)

        bridge.setBindings(declared: ["shortcut1"], bound: [:])
        try await encode(fixture.renderer)
        XCTAssertEqual(try alpha(), 0.25, "clearing the binding must reach scripts as isbound false")
        XCTAssertEqual(script.engine.dispatchCount(.applyUserProperties), 3)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    func testMaterialPathSelectsTheLastRealPassAndUpdatesItsProductionPixels() async throws {
        let (fixture, queue) = try await materialQueryFixture()
        let script = try attachScript(fixture)
        let first = WPEParityMaterialPassKey(objectID: "1", effectID: "7", pass: 0)
        let last = WPEParityMaterialPassKey(objectID: "1", effectID: "7", pass: 1)
        var pipelines: [Int: MTLRenderPipelineState] = [:]
        // Both authored passes use the same material path. First=(.5,1,1), last=(1,.5,1); path lookup writes
        // only last=(1,1,.25) on f2, so the multiplied output changes from(.5,.5,1) to(.5,1,.25).
        for frame in 1 ... 3 {
            try await encode(fixture.renderer)
            XCTAssertTrue(fixture.renderer.skipped.isEmpty, "\(fixture.renderer.skipped)")
            XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
            XCTAssertEqual(fixture.renderer.state.constant("querycolor", of: first)?.value, SIMD4(0.5, 1, 1, 0))
            XCTAssertEqual(fixture.renderer.state.constant("querycolor", of: last)?.value,
                           frame == 1 ? SIMD4(1, 0.5, 1, 0) : SIMD4(1, 1, 0.25, 0))
            for entry in fixture.renderer.lastFrameDraws {
                if let pipeline = pipelines[entry.operation] {
                    XCTAssertTrue(entry.draw.pipeline.state === pipeline, "constant writes must retain the pipeline")
                } else {
                    pipelines[entry.operation] = entry.draw.pipeline.state
                }
            }
            let texture = fixture.renderer.backbuffer
            XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
            let bytes = try XCTUnwrap(queue.device.makeBuffer(length: 256, options: .storageModeShared))
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 8, y: 8, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: bytes, destinationOffset: 0,
                      destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            blit.endEncoding()
            command.commit()
            await command.completed()
            XCTAssertNil(command.error)
            let pixel = Array(UnsafeRawBufferPointer(start: bytes.contents(), count: 4))
            let expected = frame == 1 ? [128, 128, 255] : [128, 255, 64]
            for channel in 0 ..< 3 {
                XCTAssertLessThanOrEqual(abs(Int(pixel[channel]) - expected[channel]), 2,
                                         "frame \(frame), channel \(channel), pixel \(pixel)")
            }
        }
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
            screenResolution: SIMD2(Float(renderer.backbuffer.width), Float(renderer.backbuffer.height)),
            materialConstants: fixture.plan.materialConstants, resolvedEffectRecords: fixture.plan.scene.resolvedEffectRecords,
            host: host
        )
        try renderer.attachScript(script)
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

    private func materialQueryFixture() async throws -> (Fixture, MTLCommandQueue) {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 16, "height": 16], "clearcolor": "0 0 0"],
            "objects": [["id": 1, "image": "models/query.json", "size": "16 16", "origin": "8 8 0",
                         "alpha": ["value": 1, "script": """
                         let frame = 0;
                         export function update(value) {
                           const effect = thisLayer.getEffect('query');
                           const first = effect.getMaterial(0), last = effect.getMaterial(1);
                           const byPath = effect.getMaterial('MATERIALS/QUERY.JSON');
                           if (!first || !last || first === last || byPath !== last) throw new Error('material identity mismatch');
                           if (++frame === 2) byPath.querycolor = new Vec3(1, 1, 0.25);
                           return value;
                         }
                         """],
                         "effects": [["id": 7, "name": "query", "file": "effects/query.json", "passes": [
                             ["constantshadervalues": ["querycolor": "0.5 1 1"]],
                             ["constantshadervalues": ["querycolor": "1 0.5 1"]],
                         ]]]]],
        ]
        let resources: [String: Any] = [
            "models/query.json": ["material": "materials/base.json"],
            "materials/base.json": ["passes": [["shader": "genericimage2", "combos": ["VERSION": 2],
                                                "textures": ["white"], "blending": "normal", "cullmode": "nocull",
                                                "depthtest": "disabled", "depthwrite": "disabled"]]],
            "materials/query.json": ["passes": [["shader": "query", "blending": "normal", "cullmode": "nocull",
                                                 "depthtest": "disabled", "depthwrite": "disabled"]]],
            "effects/query.json": ["passes": [["material": "materials/query.json", "compose": true],
                                              ["material": "materials/query.json"]]],
        ]
        var files = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        files["shaders/query.vert"] = try Data(contentsOf: engine.appending(path: "shaders/passthrough.vert"))
        files["shaders/query.frag"] = Data("""
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform vec3 g_QueryColor; // {"material":"querycolor","default":"1 1 1"}
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * vec4(g_QueryColor, 1.0); }
        """.utf8)
        var white = Data("TEXV0004\0".utf8)
        for value: UInt32 in [0, 0, 1, 1, 1, 1, 1, 1, 1, 4] {
            withUnsafeBytes(of: value.littleEndian) { white.append(contentsOf: $0) }
        }
        white.append(contentsOf: [255, 255, 255, 255])
        files["materials/white.tex"] = white
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }, .directory(engine)])
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: .init(bloom: false), width: 16, height: 16)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "query-shaderc"))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "cache")))
        let renderer = try await WPEParityFrameRenderer(plan: plan, device: device, queue: queue,
                                                        shaders: .init(store: store, compilerIdentity: compiler.compilerIdentity,
                                                                       bindingABIVersion: 1))
        return (Fixture(plan: plan, renderer: renderer), queue)
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
            data: JSONSerialization.data(withJSONObject: json), userValues: [:]
        )
        let assets = WPEParityProgramAssets(sceneDirectory: sceneDirectory,
                                            assetRoots: [root.appending(path: "wpeassets"), wpeAssets])
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: Self.settings,
                                          width: Self.width, height: Self.height)
        let geometryCompiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let store = try WPEParityShaderStore(
            compiler: WPEParityFixtureShaderCompiler(directory: root, programs: plan.loadPrograms,
                                                     geometryCompiler: geometryCompiler,
                                                     uncapturedUtilityPrograms: WPEParityFixtureShaderCompiler.utilityPrograms(in: plan)),
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

#endif
