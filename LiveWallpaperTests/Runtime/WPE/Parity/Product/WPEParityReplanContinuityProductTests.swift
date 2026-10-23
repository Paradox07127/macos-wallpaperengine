#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// A real video, particle, text, script and sound scene keeps every logical field across a resize replan.
    func testResizeReplanKeepsClockParticlesInputsScriptVideoAndText() async throws {
        let sceneID = "3660962877"
        let (document, assets) = try sceneInputs(sceneID: sceneID)
        let compiler = try makeCompiler()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let sceneDirectory = try XCTUnwrap(TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR"))
            .appending(path: "scene-sources/\(sceneID)")
        let mailbox = WPESceneMediaEventMailbox()
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        driver.setAudioMuted(true)
        let size = CGSize(width: 640, height: 360)
        try await driver.load(document: document, assets: assets, settings: .init(), drawableSize: size,
                              pixelFormat: .bgra8Unorm_srgb, compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "continuity-cache")),
                              renderScaleOverride: 1,
                              soundResolver: WPEMultiRootResourceResolver(primaryRootURL: sceneDirectory, dependencyMounts: []),
                              scriptHost: .init(media: mailbox))
        XCTAssertNil(driver.loadDiagnostics)
        let loaded = try replanContinuitySnapshot(XCTUnwrap(driver.renderer))
        let layer = continuityLayer(device: device, size: size)
        for index in 0 ..< 6 {
            if index == 3 {
                XCTAssertTrue(mailbox.postParityInput(WPESceneParityMediaInput(
                    generation: driver.loadGeneration, textures: nil, systemProperties: [:], events: [],
                    diagnostics: ["media.artwork-palette-unavailable-native-colors-unverified"]
                )))
            }
            try await continuityFrame(driver, layer: layer, index: index)
        }
        let before = try replanContinuitySnapshot(XCTUnwrap(driver.renderer))
        XCTAssertGreaterThan(before.clockTime, 0)
        XCTAssertEqual(before.frameIndex, 6)
        XCTAssertNotNil(before.sceneRandom.object)
        XCTAssertTrue(before.particles.contains { $0.live > 0 && !$0.positions.isEmpty }, "\(before.particles)")
        XCTAssertNotEqual(before.particles, loaded.particles)
        XCTAssertNotEqual(before.pointer, loaded.pointer)
        XCTAssertNotEqual(before.parallax, loaded.parallax, "the scene's camera parallax must move")
        XCTAssertTrue(before.audio.contains { $0 != 0 })
        XCTAssertNotEqual(before.state, loaded.state)
        XCTAssertNotNil(before.script.object)
        XCTAssertNotEqual(before.seenScriptLighting, loaded.seenScriptLighting)
        XCTAssertNotEqual(before.seenSoundBoundsFields, loaded.seenSoundBoundsFields)
        XCTAssertFalse(before.mediaDiagnostics.isEmpty)
        XCTAssertNotEqual(before.renderVars, loaded.renderVars)
        XCTAssertNotNil(before.videos.object)
        XCTAssertFalse(before.videoSources.isEmpty, "the scene has no video source")
        XCTAssertNotEqual(before.texts, loaded.texts, "the scene's scripts must have relaid a text layer")

        let resized = CGSize(width: 800, height: 450)
        layer.drawableSize = resized
        driver.updateSurfaceGeometry(drawableSize: resized)
        XCTAssertTrue(driver.needsReplan)
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual([renderer.backbuffer.width, renderer.backbuffer.height], [800, 450])
        let after = try replanContinuitySnapshot(renderer)
        XCTAssertEqual(after.changedFields(from: before), [])
        XCTAssertTrue(after == before)
        try await continuityFrame(driver, layer: layer, index: 6)
    }

    /// Puppets, property and texture animations, camera paths and queues, bloom and script counters survive a fit change.
    func testFitChangeReplanKeepsAnimationsCamerasBloomAndScriptCounters() async throws {
        let original = try sceneInputs().1
        let compiler = try makeCompiler()
        let soundScene = try XCTUnwrap(TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR"))
            .appending(path: "scene-sources/3509243656")
        let (document, assets) = try continuityAnimationScene(original: original)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        driver.setAudioMuted(true)
        let size = CGSize(width: 256, height: 128)
        try await driver.load(document: document, assets: assets, settings: .init(bloom: true, hdrPostProcessing: false),
                              drawableSize: size, pixelFormat: .bgra8Unorm_srgb, compiler: compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "continuity-cache")),
                              renderScaleOverride: 1,
                              soundResolver: WPEMultiRootResourceResolver(primaryRootURL: soundScene, dependencyMounts: []))
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
        XCTAssertNotNil(driver.soundRuntime)
        let loaded = try replanContinuitySnapshot(XCTUnwrap(driver.renderer))
        let layer = continuityLayer(device: device, size: size)
        for index in 0 ..< 6 {
            try await continuityFrame(driver, layer: layer, index: index)
        }
        let script = try XCTUnwrap(driver.renderer?.instance.script)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        let before = try replanContinuitySnapshot(XCTUnwrap(driver.renderer))
        XCTAssertTrue(before.puppets.contains { $0.time > 0 }, "\(before.puppets)")
        XCTAssertTrue(before.propertyAnimations.contains { $0.time > 0 }, "\(before.propertyAnimations)")
        XCTAssertFalse(before.textureAnimations.isEmpty)
        XCTAssertFalse(before.pushedAnimationLayerFields.isEmpty)
        XCTAssertNotEqual(before.cameraPaths, loaded.cameraPaths)
        XCTAssertNotNil(before.activeCameraID)
        XCTAssertFalse(before.cameraQueues.isEmpty)
        XCTAssertNotEqual(before.bloom, loaded.bloom)
        XCTAssertNotEqual(before.seenScriptBloom, loaded.seenScriptBloom)
        XCTAssertNotEqual(before.seenScriptSound, loaded.seenScriptSound)
        XCTAssertNotEqual(before.seenScriptLighting, loaded.seenScriptLighting)
        XCTAssertNotEqual(before.textureSlots, loaded.textureSlots)
        XCTAssertNotEqual(before.parallax, loaded.parallax)

        driver.setPresentFitMode(.stretch)
        XCTAssertTrue(driver.needsReplan)
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        let after = try replanContinuitySnapshot(XCTUnwrap(driver.renderer))
        XCTAssertEqual(after.changedFields(from: before), [])
        XCTAssertTrue(after == before)
        try await continuityFrame(driver, layer: layer, index: 6)
    }

    /// The material function host call made after a replan still clears the effect's framebuffers.
    func testMaterialFunctionStillClearsAfterReplan() async throws {
        let base = try sceneInputs().1
        let compiler = try makeCompiler()
        let (document, assets) = try continuityMaterialFunctionScene(base: base)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 32, height: 32), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "continuity-cache")),
                              renderScaleOverride: 1)
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
        let layer = continuityLayer(device: device, size: CGSize(width: 32, height: 32), pixelFormat: .rgba8Unorm)
        for index in 0 ..< 2 {
            try await continuityFrame(driver, layer: layer, index: index)
        }
        weak let first = driver.renderer
        let resized = CGSize(width: 64, height: 64)
        layer.drawableSize = resized
        driver.updateSurfaceGeometry(drawableSize: resized)
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        XCTAssertNil(first, "the replaced renderer must be released before the call")
        func center(_ id: WPEResourceID) throws -> [UInt8] {
            let texture = try XCTUnwrap(driver.renderer?.renderTarget(id), "\(id)")
            let bytes = try readBack(texture, device: device)
            let offset = (texture.height / 2 * texture.width + texture.width / 2) * 4
            return Array(bytes[offset ..< offset + 4])
        }
        // The third frame's writers run at alpha 1 again, so the fourth frame's clear is the only thing changing them.
        try await continuityFrame(driver, layer: layer, index: 2)
        XCTAssertEqual(try center("first_7"), [255, 0, 0, 255])
        XCTAssertEqual(try center("second_7"), [0, 255, 0, 255])
        try await continuityFrame(driver, layer: layer, index: 3)
        let script = try XCTUnwrap(driver.renderer?.instance.script)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(try center("first_7"), [0, 0, 255, 255], "reverseTwo clears first with its declared colour")
        XCTAssertEqual(try center("second_7"), [255, 0, 0, 255], "reverseTwo clears second with its declared colour")
    }

    private func continuityLayer(device: MTLDevice, size: CGSize,
                                 pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) -> RecordingLayer {
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = pixelFormat
        layer.drawableSize = size
        layer.framebufferOnly = false
        return layer
    }

    /// The pointer drifts and the audio bins change every frame, so both inputs carry state worth continuing.
    private nonisolated(nonsending) func continuityFrame(_ driver: WPEParitySceneDriver, layer: CAMetalLayer,
                                                         index: Int) async throws {
        let bins = (0 ..< AudioSpectrumFrame.binCount).map { Float(($0 + index) % 16) / 16 }
        let command = try XCTUnwrap(driver.renderAndPresentFrame(
            layer: layer, timestamp: nextTimestamp(), pointer: SIMD2(0.25 + 0.05 * Double(index), 0.6),
            audio: AudioSpectrumFrame(left: bins, right: bins.reversed(), timestampNanos: UInt64(index))
        ), "frame \(index) was not presented")
        try await settle(driver, label: "frame \(index)")
        XCTAssertEqual(command.status, .completed, "frame \(index)")
        XCTAssertNil(command.error, "frame \(index)")
    }

    /// Puppet layer 1, sprite sheet layer 2 with a property animation, camera queue 3 shown by its parent 4 from the
    /// third frame, sound 9, root camera paths, and a scene script writing bloom, ambient light and the sound volume.
    private func continuityAnimationScene(original: WPEParityProgramAssets) throws
        -> (WPESceneDocument, WPEParityProgramAssets) {
        func key(_ value: Float, length: Int) -> [[String: Any]] {
            [["frame": 0, "value": value], ["frame": length, "value": value]]
        }
        let keyframes: [[String: Any]] = [
            ["timestamp": 0, "eye": "128 64 1", "center": "128 64 0", "up": "0 1 0"],
            ["timestamp": 4, "eye": "140 64 1", "center": "140 64 0", "up": "0 1 0"],
        ]
        let resources: [String: Any] = [
            "materials/continuity-puppet.json": ["passes": [["shader": "genericimage4", "textures": ["util/white"],
                                                             "combos": ["LIGHTING": 0, "FOG": 0, "REFLECTION": 0],
                                                             "cullmode": "nocull", "depthtest": "disabled",
                                                             "depthwrite": "disabled", "blending": "translucent"]]],
            "models/continuity-puppet.json": ["material": "materials/continuity-puppet.json",
                                              "puppet": "models/continuity-puppet.mdl"],
            "materials/continuity-sheet.json": ["passes": [["shader": "genericimage2", "textures": ["continuity-sheet"],
                                                            "blending": "normal", "cullmode": "nocull"]]],
            "models/continuity-sheet.json": ["material": "materials/continuity-sheet.json"],
            "materials/continuity-parent.json": ["passes": [["shader": "genericimage2", "textures": ["continuity-black"],
                                                             "blending": "normal", "cullmode": "nocull"]]],
            "models/continuity-parent.json": ["material": "materials/continuity-parent.json"],
            "cameras/continuity-queue.json": ["paths": [[
                "options": ["fps": 4, "length": 8, "mode": "loop"],
                "eye": ["c0": key(120, length: 8), "c1": key(64, length: 8), "c2": key(1, length: 8)],
                "center": ["c0": key(120, length: 8), "c1": key(64, length: 8), "c2": key(0, length: 8)],
                "zoom": key(1, length: 8),
            ]]],
            "cameras/continuity-path.json": ["paths": [["duration": 8, "transforms": keyframes]]],
        ]
        var files = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        files["models/continuity-puppet.mdl"] = Self.continuityPuppetMDL()
        files["materials/continuity-sheet.tex"] = Self.continuitySpriteSheet()
        files["materials/continuity-black.tex"] = cameraWitnessTexture([0, 0, 0, 255])
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + original.sources)
        let sceneScript = """
        export function update(value) {
          thisScene.ambientcolor = new Vec3(0.25, 0.25, 0.25);
          const sound = thisScene.getLayer('snd');
          if (sound) sound.volume = 0.25;
          return 3;
        }
        """
        let json: [String: Any] = [
            "camera": ["center": "128 64 0", "eye": "128 64 1", "up": "0 1 0", "paths": ["cameras/continuity-path.json"]],
            "general": ["orthogonalprojection": ["width": 256, "height": 128], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": true, "bloomstrength": ["value": 2, "script": sceneScript],
                        "camerashake": false, "cameraparallax": true, "cameraparallaxamount": 1,
                        "cameraparallaxdelay": 0.1, "cameraparallaxmouseinfluence": 1],
            "objects": [
                ["id": 1, "image": "models/continuity-puppet.json", "size": "64 64", "origin": "48 64 0",
                 "copybackground": false, "animationlayers": [["id": 10, "animation": 7, "rate": 1, "blend": 1]],
                 "alpha": ["value": 1, "script": """
                 export function update(value) {
                   const animationLayer = thisLayer.getAnimationLayer(0);
                   if (animationLayer) animationLayer.rate = 0.5;
                   return value;
                 }
                 """]],
                ["id": 2, "image": "models/continuity-sheet.json", "size": "32 32", "origin": "128 64 0",
                 "alpha": ["value": 1, "script": """
                 export function update(value) {
                   const animation = thisLayer.getTextureAnimation();
                   if (animation) animation.rate = 2;
                   return value;
                 }
                 """, "animation": ["c0": key(1, length: 8), "options": ["fps": 2, "length": 8]]]],
                ["id": 4, "image": "models/continuity-parent.json", "origin": "0 0 0", "size": "1 1",
                 "visible": ["value": false, "script": "let ticks = 0; export function update(value) { return ++ticks >= 3; }"]],
                ["id": 3, "camera": "continuity queue", "parent": 4, "path": "cameras/continuity-queue.json",
                 "queuemode": "sequential"],
                ["id": 9, "name": "snd", "sound": ["sounds/Melodysheep - Ether.flac"], "volume": 1,
                 "playbackmode": "loop", "startsilent": false],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:])
        return (document, assets)
    }

    /// Effect 7 on layer 1 writes three persistent FBOs through opacity at alpha 1 until the fourth frame, which
    /// zeroes alpha and runs `reverseTwo`; that clears the first two declared FBOs to their declared colours.
    private func continuityMaterialFunctionScene(base: WPEParityProgramAssets) throws
        -> (WPESceneDocument, WPEParityProgramAssets) {
        let root = try XCTUnwrap(base.roots.last, "WPE asset root")
        let names = ["first", "second", "third"]
        let clears = ["0 0 1 1", "1 0 0 1", "0 1 0 1"]
        var passes: [[String: Any]] = []
        for pair in [("first", "second"), ("second", "third")] {
            for _ in 0 ..< 2 {
                passes.append(["command": "swap", "source": pair.0, "target": pair.1])
            }
        }
        for name in names {
            passes.append(["material": "materials/effects/opacity.json", "target": name, "compose": true,
                           "blending": "translucent", "bind": [["index": 0, "name": "continuity-\(name)"],
                                                               ["index": 1, "name": "continuity-mask"]]])
        }
        for name in names {
            passes.append(["material": "materials/util/passthrough.json", "blending": "additive",
                           "bind": [["index": 0, "name": name]]])
        }
        let effect: [String: Any] = [
            "fbos": names.indices.map { ["name": names[$0], "width": 32, "height": 32, "unique": true,
                                         "format": "rgba8888", "clear": clears[$0]] as [String: Any] },
            "functions": ["reverseTwo": ["action": "clear", "fbos": ["third", "first"]]],
            "passes": passes,
        ]
        var files = try ["effects/continuity-material-function.json": JSONSerialization.data(withJSONObject: effect)]
        for (index, name) in (names + ["mask"]).enumerated() {
            var tex = Data("TEXV0004\0".utf8)
            for value: UInt32 in [0, 0, 1, 1, 1, 1, 1, 1, 1, 4] {
                withUnsafeBytes(of: value.littleEndian) { tex.append(contentsOf: $0) }
            }
            var rgb = [UInt8](repeating: 255, count: 4)
            if index < 3 {
                rgb = [0, 0, 0, 255]
                rgb[index] = 255
            }
            tex.append(contentsOf: rgb)
            files["materials/continuity-\(name).tex"] = tex
        }
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }] + base.sources
            + [.directory(root.appending(path: "effects/opacity"))])
        var overrides = [[String: Any]](repeating: [:], count: 10)
        for index in 4 ... 6 {
            overrides[index] = ["constantshadervalues": ["alpha": 1], "combos": ["MASK": 1]]
        }
        // passthrough tests #ifdef TRANSFORM, so only the final layer-mesh reader may carry the key.
        overrides[9] = ["combos": ["TRANSFORM": 1]]
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 32], "clearenabled": true,
                        "clearcolor": "0 0 0", "bloom": false, "hdr": false,
                        "camerashake": false, "cameraparallax": false],
            "objects": [["id": 1, "image": "models/util/solidlayer.json", "origin": "16 16 0", "size": "32 32",
                         "solid": true, "colorBlendMode": 31,
                         "alpha": ["value": 1, "script": """
                         let frames = 0;
                         export function init(value) {
                           thisLayer.solid = false;
                           return value;
                         }
                         export function update(value) {
                           frames += 1;
                           if (frames === 4) {
                             const effect = thisLayer.getEffect(0);
                             effect.setMaterialProperty('alpha', 0);
                             effect.executeMaterialFunction('reverseTwo');
                           }
                           return value;
                         }
                         """],
                         "effects": [["id": 7, "file": "effects/continuity-material-function.json", "visible": true,
                                      "passes": overrides]]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:])
        return (document, assets)
    }

    /// RGBA8888 4×4 sheet (TEXI flag 0x4) with two half-width TEXS frames of 0.25 s on its one image.
    private static func continuitySpriteSheet() -> Data {
        var data = Data()
        func magic(_ text: String) {
            data.append(contentsOf: text.utf8)
            data.append(0)
        }
        func int(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func float(_ value: Float) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        magic("TEXV0005")
        magic("TEXI0001")
        int(Int32(WPETexFormat.rgba8888.rawValue))
        int(0x4)
        for _ in 0 ..< 2 {
            int(4)
            int(4)
        }
        int(0)
        magic("TEXB0003")
        int(1)
        int(-1)
        let pixels = Data((0 ..< 16).flatMap { ($0 % 4 < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]) as [UInt8] })
        int(1)
        int(4)
        int(4)
        int(0)
        int(Int32(pixels.count))
        int(Int32(pixels.count))
        data.append(pixels)
        // TEXS3: frame count, gif size, then per frame image, time, x, y, width, widthY, heightX, height.
        magic("TEXS0003")
        int(2)
        int(4)
        int(4)
        for x: Float in [0, 2] {
            int(0)
            for value: Float in [0.25, x, 0, 2, 0, 0, 4] {
                float(value)
            }
        }
        return data
    }

    /// MDLV20 quad skinned to one bone, with MDLA3 animations 7 and 8 of two frames each.
    private static func continuityPuppetMDL() -> Data {
        var data = Data()
        func string(_ value: String) {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        func words(_ values: [UInt32]) {
            for value in values {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        func floats(_ values: [Float]) {
            words(values.map(\.bitPattern))
        }
        func end(at offset: Int) {
            withUnsafeBytes(of: UInt32(data.count).littleEndian) { data.replaceSubrange(offset ..< offset + 4, with: $0) }
        }
        string("MDLV0020")
        words([0x0180_000B, 1, 1])
        string("materials/continuity-puppet.json")
        words([4])
        floats([-32, -32, 0, 32, 32, 0])
        words([0x0180_000B, 4 * 64])
        for (x, y, u, v): (Float, Float, Float, Float) in [(-32, 32, 0, 0), (32, 32, 1, 0), (-32, -32, 0, 1), (32, -32, 1, 1)] {
            floats([x, y, 0, 0, 0, 1])
            words([0, 0, 0, 0])
            floats([1, 0, 0, 0, u, v])
        }
        words([12])
        for index: UInt16 in [0, 2, 1, 1, 2, 3] {
            withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        }
        string("MDLS0001")
        let skeletonEnd = data.count
        words([0, 1])
        string("root")
        words([0, .max, 64])
        floats([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        string("")
        end(at: skeletonEnd)
        string("MDLA0003")
        let animationEnd = data.count
        words([0, 2])
        for id: UInt32 in [7, 8] {
            words([id, 0])
            string("a\(id)")
            string("loop")
            floats([2])
            words([1, 0, 1])
            words([0, 72])
            for _ in 0 ..< 2 {
                floats([0, 0, 0, 0, 0, 0, 1, 1, 1])
            }
            words([0])
            data.append(1)
            words([0, 8])
            floats([1, 1])
            words([0])
        }
        end(at: animationEnd)
        return data
    }
}

/// Every renderer field a replan must carry over, read only through `replanContinuitySnapshot`.
private struct ReplanContinuitySnapshot: Equatable {
    /// Compares class instances by identity and retains them, so a freed instance's address cannot be reused.
    struct Identity: Equatable {
        let object: AnyObject?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.object === rhs.object
        }
    }

    struct ParticleSystem: Equatable {
        var objectID: String
        var live: Int
        /// The first four live slots.
        var positions: [SIMD3<Float>]
        var ages: [Float]
    }

    struct PuppetLayer: Equatable {
        var objectID: String
        var sceneIndex: Int
        var time: Float
        var weight: Float
        var paused: Bool
    }

    struct PropertyAnimation: Equatable {
        var objectID: String
        var animation: Identity
        var time: Float
    }

    struct TextureAnimation: Equatable {
        var objectID: String
        var frame: Int
        var time: Float
        var rate: Float
        var playing: Bool
    }

    struct Pointer: Equatable {
        var position: SIMD2<Float>
        var lastPosition: SIMD2<Float>
        var isDown: Bool
        var wasDown: Bool
    }

    struct State: Equatable {
        var ids: [String]
        var objects: [WPEParitySceneState.Object]
        var commonOrder: [String]
        var transparentOrder: [String]
        var effectVisibility: [Bool]
        var scriptFields: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue]
        /// transform, visibility, membership, effect visibility, constants, script fields, then each invalidation.
        var generations: [Int]
    }

    var clockTime: Double
    var frametime: Float
    var frameIndex: Int
    var sceneRandom: Identity
    var particles: [ParticleSystem]
    var puppets: [PuppetLayer]
    var propertyAnimations: [PropertyAnimation]
    var textureAnimations: [TextureAnimation]
    var pushedAnimationLayerFields: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue]
    var pointer: Pointer
    /// Smoothed, then target position.
    var parallax: [SIMD2<Float>]
    var audio: [Float]
    var cameraPaths: WPEParityCameraPaths
    var activeCameraID: String?
    var cameraQueues: [String: Identity]
    var bloom: WPEParityBloomSettings
    var seenScriptSound: Int
    var seenSoundBoundsFields: Int
    var seenScriptLighting: Int
    var seenScriptBloom: Int
    var mediaDiagnostics: [String]
    var state: State
    var script: Identity
    /// Values as text, since WPECBufferValue is not Equatable.
    var textureSlots: [String: String]
    var renderVars: WPEParityRenderVarState
    var videos: Identity
    var videoSources: [Identity]
    var texts: [String: WPEParityTextObject]

    /// Names of the fields whose values differ from `other`'s.
    func changedFields(from other: Self) -> [String] {
        zip(Mirror(reflecting: self).children, Mirror(reflecting: other).children).compactMap { mine, theirs in
            guard let value = mine.value as? any Equatable, value.isEqual(to: theirs.value) else { return mine.label ?? "?" }
            return nil
        }
    }
}

private extension Equatable {
    func isEqual(to other: Any) -> Bool {
        self == other as? Self
    }
}

private func replanContinuitySnapshot(_ renderer: WPEParityFrameRenderer) throws -> ReplanContinuitySnapshot {
    var particleScene = renderer.instance.particles.scene
    let particles = renderer.plan.document.particleObjects.map(\.id).sorted().compactMap { id in
        let live = particleScene.liveCount(id) ?? 0
        return particleScene.control(objectID: id) { system in
            let slots = system.lifetime.indices.filter { system.lifetime[$0] != 0 }.prefix(4)
            return ReplanContinuitySnapshot.ParticleSystem(objectID: id, live: live, positions: slots.map { system.position[$0] },
                                                           ages: slots.map { system.age[$0] })
        }
    }
    let puppets = renderer.instance.puppets.keys.sorted().flatMap { id in
        (renderer.instance.puppets[id]?.layers ?? []).map {
            ReplanContinuitySnapshot.PuppetLayer(objectID: id, sceneIndex: $0.sceneIndex, time: $0.time,
                                                 weight: $0.weight, paused: $0.paused)
        }
    }
    let propertyAnimations = ([""] + renderer.instance.state.ids).compactMap { id in
        renderer.instance.animations.animation(objectID: id, pass: nil, name: "").map {
            ReplanContinuitySnapshot.PropertyAnimation(objectID: id, animation: .init(object: $0), time: $0.time)
        }
    }
    let textureAnimations = renderer.instance.textureAnimations.sorted { $0.key < $1.key }.map { id, animation in
        ReplanContinuitySnapshot.TextureAnimation(objectID: id, frame: animation.frame, time: animation.time,
                                                  rate: animation.rate, playing: animation.playing)
    }
    let state = renderer.instance.state
    let textureSlots = renderer.instance.textureSlots
    return ReplanContinuitySnapshot(
        clockTime: renderer.instance.clock.time,
        frametime: renderer.instance.clock.frametime,
        frameIndex: renderer.instance.frameIndex,
        sceneRandom: .init(object: renderer.instance.sceneRNG),
        particles: particles,
        puppets: puppets,
        propertyAnimations: propertyAnimations,
        textureAnimations: textureAnimations,
        pushedAnimationLayerFields: renderer.instance.pushedAnimationLayerFields,
        pointer: .init(position: renderer.instance.pointer.position, lastPosition: renderer.instance.pointer.lastPosition,
                       isDown: renderer.instance.pointer.isDown, wasDown: renderer.instance.pointer.wasDown),
        parallax: [renderer.instance.parallax.smoothed, renderer.instance.parallax.position],
        audio: renderer.instance.audio.bins,
        cameraPaths: renderer.instance.cameraPaths,
        activeCameraID: renderer.instance.activeCameraID,
        cameraQueues: renderer.instance.cameraQueues.mapValues { .init(object: $0) },
        bloom: renderer.instance.bloom,
        seenScriptSound: renderer.instance.seenScriptSound,
        seenSoundBoundsFields: renderer.instance.seenSoundBoundsFields,
        seenScriptLighting: renderer.instance.seenScriptLighting,
        seenScriptBloom: renderer.instance.seenScriptBloom,
        mediaDiagnostics: renderer.instance.mediaDiagnostics,
        state: .init(ids: state.ids, objects: state.objects, commonOrder: state.commonOrder,
                     transparentOrder: state.transparentOrder, effectVisibility: state.effectVisibility,
                     scriptFields: state.scriptFields,
                     generations: [state.transformGeneration, state.visibilityGeneration, state.membershipGeneration,
                                   state.effectVisibilityGeneration, state.constantsGeneration,
                                   state.scriptFieldsGeneration]
                         + WPEParitySceneState.Invalidation.allCases.map { state.generation($0) }),
        script: .init(object: renderer.instance.script),
        textureSlots: textureSlots.mapValues { String(describing: $0) },
        renderVars: renderer.instance.renderVars,
        videos: .init(object: renderer.videos),
        videoSources: renderer.videos.authoredSourcesForTesting.map { .init(object: $0) },
        texts: renderer.texts.mapValues(\.object)
    )
}
#endif
