#if !LITE_BUILD && DEBUG
import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import QuartzCore
import XCTest

/// Original combine programs sample media in slot 1 of two real image effects.
/// Input PNG quadrants and the original black + artwork equation define the pixel oracle.
@MainActor
final class WPEParityMediaTextureProductTests: XCTestCase {
    private static let size = CGSize(width: 80, height: 32)
    private static let settings = WPEParityProgramSettings(bloom: false, hdrPostProcessing: false)
    private static let nativeSizingDiagnostic = "media.artwork-native-sizing-unverified:mac-maximum-edge=256"

    func testExplicitNonSystemProviderCannotBecomeMediaThroughItsName() async throws {
        for provider in ["usershortcut", "unverified-provider"] {
            let fixture = try makeFixture(scripted: false, mediaProvider: provider)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let driver = try WPEParitySceneDriver(device: fixture.device)
            defer { driver.cleanup() }
            try await driver.load(document: fixture.document, assets: fixture.assets, settings: Self.settings,
                                  drawableSize: Self.size, pixelFormat: .bgra8Unorm_srgb,
                                  compiler: fixture.compiler, diskCache: fixture.cache)
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertFalse(driver.hasMediaTextureDemand, "An explicit provider cannot request system artwork uploads")
            XCTAssertEqual(renderer.skipped.count, 2, "Both unsupported media-named provider draws are diagnosed")
            XCTAssertTrue(renderer.skipped.values.allSatisfy {
                $0.description.contains("media usertexture provider '\(provider)' is unsupported")
            }, "\(renderer.skipped)")
        }
    }

    func testSelectedPassInstanceMergeBindsCurrentAndPreviousArtworkInOriginalEffectsAcrossResize() async throws {
        let fixture = try makeFixture(scripted: false, mergeUserTextures: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = MediaInputSource()
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let driver = try WPEParitySceneDriver(device: fixture.device)
        defer { dispatcher.stop(); driver.cleanup() }
        let layer = makeLayer(device: fixture.device)
        try await load(driver, fixture: fixture, dispatcher: dispatcher, size: Self.size)
        XCTAssertTrue(driver.hasMediaTextureDemand)
        XCTAssertTrue(dispatcher.configureParity(generation: driver.loadGeneration, device: fixture.device,
                                                 textureDemand: driver.hasMediaTextureDemand, onChange: {}))
        source.push(artwork: fixture.a)
        let first = try await present(driver, layer: layer)
        assertPanels(first, width: 80, current: .a, previous: nil)
        source.push(artwork: fixture.b)
        let second = try await present(driver, layer: layer)
        assertPanels(second, width: 80, current: .b, previous: .a)
        let before = try pair(driver)
        try assertBoundEffects(driver)

        // The same immutable pair and merged declarations survive a real renderer replan.
        weak let retired = driver.renderer
        layer.drawableSize = CGSize(width: 160, height: 64)
        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 160, height: 64))
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        XCTAssertNil(retired)
        let resized = try await present(driver, layer: layer)
        assertPanels(resized, width: 160, current: .b, previous: .a)
        XCTAssertEqual(try pair(driver), before)
        try assertBoundEffects(driver)
    }

    func testUserShortcutIconsWakeOriginalEffectsAndRestoreFallbackAcrossReloadAndResize() async throws {
        let fixture = try makeFixture(scripted: false, shortcutIcons: true)
        let icons = WPEUserShortcutIconStore(device: fixture.device)
        let layer = makeLayer(device: fixture.device)
        let surface = MediaPacingRecorder()
        var inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: "shortcut-icon-guard", cacheRelativePath: "shortcut-icon-guard",
                                        entryFile: "scene.json", capabilityTier: .degraded),
            entryResolver: SceneResourceResolver(cacheRootURL: fixture.root), projectRoot: fixture.root,
            assets: fixture.assets, settings: Self.settings, compiler: fixture.compiler, device: fixture.device,
            presentLayer: WPEPresentLayer(layer: layer), mailbox: WPEPointerMailbox(), surfaceControl: surface,
            drawableSize: Self.size, pixelFormat: layer.pixelFormat
        )
        inputs.userShortcutIcons = icons
        let actor = WPEDisplayRenderActor(backing: .main)
        let fixtureRoot = fixture.root
        addTeardownBlock {
            await actor.teardownRenderer()
            await actor.shutdown()
            await MainActor.run { try? FileManager.default.removeItem(at: fixtureRoot) }
        }
        try await actor.adoptParity(inputs)
        try await actor.load()
        await assertStaticActor(actor)
        try await actorFrame(actor)
        try assertPanels(readBack(XCTUnwrap(layer.lastTexture)), width: 80, current: nil, previous: nil)
        XCTAssertEqual(surface.lastIsPaused, true)

        // Controlled external icon bytes exercise the native-provider consumer, not macOS icon extraction pixels.
        // Square like the rendered icon canvas, so the square authored slots bind them unpadded.
        let cyan = WPEUserShortcutIconImage(rgba: Array(repeating: [UInt8(0), 255, 255, 255], count: 16).flatMap(\.self),
                                            width: 4, height: 4)
        let magenta = WPEUserShortcutIconImage(rgba: Array(repeating: [UInt8(255), 0, 255, 255], count: 16).flatMap(\.self),
                                               width: 4, height: 4)
        XCTAssertTrue(icons.setIcon(cyan, forKey: "shortcut-current"))
        try await waitUntil("Shortcut icon did not wake the parked product actor") { surface.lastIsPaused == false }
        try await actorFrame(actor)
        var pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 80, panel: 0, artwork: nil, fallback: [0, 255, 255, 255])
        assertPanel(pixels, width: 80, panel: 1, artwork: nil, fallback: [0, 0, 128, 255])
        XCTAssertEqual(surface.lastIsPaused, true)
        let cyanTexture = try XCTUnwrap(icons.substituting(nil, slot: 0, declarations: [0: "shortcut-current"]))
        XCTAssertFalse(icons.setIcon(cyan, forKey: "shortcut-current"))
        XCTAssertTrue(icons.substituting(nil, slot: 0, declarations: [0: "shortcut-current"]) === cyanTexture)
        XCTAssertEqual(surface.lastIsPaused, true, "Identical icon bytes must not cause another wake")

        XCTAssertTrue(icons.setIcon(magenta, forKey: "shortcut-previous"))
        try await waitUntil("Second shortcut icon did not wake the parked product actor") { surface.lastIsPaused == false }
        try await actorFrame(actor)
        pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 80, panel: 0, artwork: nil, fallback: [0, 255, 255, 255])
        assertPanel(pixels, width: 80, panel: 1, artwork: nil, fallback: [255, 0, 255, 255])
        let sourceIDs = try Set([cyanTexture, XCTUnwrap(icons.substituting(nil, slot: 0,
                                                                           declarations: [0: "shortcut-previous"]))].map(ObjectIdentifier.init))
        let boundIDs = await actor.run { actor in
            Set(actor.parityDriverForTesting?.renderer?.lastFrameDraws.compactMap {
                $0.draw.textures["g_Texture1"].map(ObjectIdentifier.init)
            } ?? [])
        }
        XCTAssertEqual(boundIDs, sourceIDs, "Both real original combine effects must bind the existing store textures")

        try await actor.reload()
        try await actorFrame(actor)
        pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 80, panel: 0, artwork: nil, fallback: [0, 255, 255, 255])
        assertPanel(pixels, width: 80, panel: 1, artwork: nil, fallback: [255, 0, 255, 255])
        layer.drawableSize = CGSize(width: 160, height: 64)
        await actor.updateSurfaceGeometry(drawableSize: CGSize(width: 160, height: 64))
        let deadline = Date().addingTimeInterval(5)
        while await actor.run({ $0.parityDriverForTesting?.renderer?.backbuffer.width != 160 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let resized = await actor.run { $0.parityDriverForTesting?.renderer?.backbuffer.width }
        XCTAssertEqual(resized, 160, "A real renderer replan must complete")
        try await actorFrame(actor)
        pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 160, panel: 0, artwork: nil, fallback: [0, 255, 255, 255])
        assertPanel(pixels, width: 160, panel: 1, artwork: nil, fallback: [255, 0, 255, 255])
        XCTAssertTrue(icons.substituting(nil, slot: 0, declarations: [0: "shortcut-current"]) === cyanTexture)

        XCTAssertTrue(icons.setIcon(nil, forKey: "shortcut-current"))
        try await waitUntil("Clearing an icon did not wake the parked product actor") { surface.lastIsPaused == false }
        try await actorFrame(actor)
        pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 160, panel: 0, artwork: nil, fallback: [0, 128, 0, 255])
        assertPanel(pixels, width: 160, panel: 1, artwork: nil, fallback: [255, 0, 255, 255])
        XCTAssertEqual(surface.lastIsPaused, true)
    }

    func testSceneTextureImagesReplaceTheirSlotAndRestoreTheAuthoredFallback() async throws {
        let fixture = try makeFixture(scripted: false, sceneTextures: true)
        let images = WPEUserShortcutIconStore(device: fixture.device)
        let layer = makeLayer(device: fixture.device)
        let surface = MediaPacingRecorder()
        var inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: "scene-texture-guard", cacheRelativePath: "scene-texture-guard",
                                        entryFile: "scene.json", capabilityTier: .degraded),
            entryResolver: SceneResourceResolver(cacheRootURL: fixture.root), projectRoot: fixture.root,
            assets: fixture.assets, settings: Self.settings, compiler: fixture.compiler, device: fixture.device,
            presentLayer: WPEPresentLayer(layer: layer), mailbox: WPEPointerMailbox(), surfaceControl: surface,
            drawableSize: Self.size, pixelFormat: layer.pixelFormat
        )
        inputs.userShortcutIcons = images
        let actor = WPEDisplayRenderActor(backing: .main)
        let fixtureRoot = fixture.root
        addTeardownBlock {
            await actor.teardownRenderer()
            await actor.shutdown()
            await MainActor.run { try? FileManager.default.removeItem(at: fixtureRoot) }
        }
        try await actor.adoptParity(inputs)
        try await actor.load()
        try await actorFrame(actor)
        try assertPanels(readBack(XCTUnwrap(layer.lastTexture)), width: 80, current: nil, previous: nil)

        let cyan = WPEUserShortcutIconImage(rgba: Array(repeating: [UInt8(0), 255, 255, 255], count: 32).flatMap(\.self),
                                            width: 8, height: 4)
        XCTAssertTrue(images.setIcon(cyan, forKey: "texture-current"))
        try await waitUntil("A scene texture image did not wake the parked product actor") { surface.lastIsPaused == false }
        try await actorFrame(actor)
        var pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 80, panel: 0, artwork: nil, fallback: [0, 255, 255, 255])
        assertPanel(pixels, width: 80, panel: 1, artwork: nil, fallback: [0, 0, 128, 255])

        try await actor.reload()
        try await actorFrame(actor)
        pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 80, panel: 0, artwork: nil, fallback: [0, 255, 255, 255])
        layer.drawableSize = CGSize(width: 160, height: 64)
        await actor.updateSurfaceGeometry(drawableSize: CGSize(width: 160, height: 64))
        let deadline = Date().addingTimeInterval(5)
        while await actor.run({ $0.parityDriverForTesting?.renderer?.backbuffer.width != 160 }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let resized = await actor.run { $0.parityDriverForTesting?.renderer?.backbuffer.width }
        XCTAssertEqual(resized, 160, "A real renderer replan must complete")
        try await actorFrame(actor)
        pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 160, panel: 0, artwork: nil, fallback: [0, 255, 255, 255])
        assertPanel(pixels, width: 160, panel: 1, artwork: nil, fallback: [0, 0, 128, 255])

        XCTAssertTrue(images.setIcon(nil, forKey: "texture-current"))
        try await waitUntil("Clearing a scene texture did not wake the parked product actor") { surface.lastIsPaused == false }
        try await actorFrame(actor)
        try assertPanels(readBack(XCTUnwrap(layer.lastTexture)), width: 160, current: nil, previous: nil)
    }

    func testSceneTextureImageIsCenterCroppedToTheAuthoredSlotAspect() async throws {
        // The authored slot is 6x2, so the 12x12 image keeps only rows 4..<8: its cyan middle third.
        let fixture = try makeFixture(scripted: false, sceneTextures: true, currentSlotWidth: 6)
        let images = WPEUserShortcutIconStore(device: fixture.device)
        let layer = makeLayer(device: fixture.device)
        let surface = MediaPacingRecorder()
        var inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: "scene-texture-crop", cacheRelativePath: "scene-texture-crop",
                                        entryFile: "scene.json", capabilityTier: .degraded),
            entryResolver: SceneResourceResolver(cacheRootURL: fixture.root), projectRoot: fixture.root,
            assets: fixture.assets, settings: Self.settings, compiler: fixture.compiler, device: fixture.device,
            presentLayer: WPEPresentLayer(layer: layer), mailbox: WPEPointerMailbox(), surfaceControl: surface,
            drawableSize: Self.size, pixelFormat: layer.pixelFormat
        )
        inputs.userShortcutIcons = images
        let actor = WPEDisplayRenderActor(backing: .main)
        let fixtureRoot = fixture.root
        addTeardownBlock {
            await actor.teardownRenderer()
            await actor.shutdown()
            await MainActor.run { try? FileManager.default.removeItem(at: fixtureRoot) }
        }
        try await actor.adoptParity(inputs)
        try await actor.load()
        try await actorFrame(actor)

        let red: [UInt8] = [255, 0, 0, 255], cyan: [UInt8] = [0, 255, 255, 255]
        let banded = (0 ..< 12).flatMap { row in Array(repeating: (4 ..< 8).contains(row) ? cyan : red, count: 12).joined() }
        XCTAssertTrue(images.setIcon(WPEUserShortcutIconImage(rgba: banded, width: 12, height: 12), forKey: "texture-current"))
        try await waitUntil("A scene texture image did not wake the parked product actor") { surface.lastIsPaused == false }
        try await actorFrame(actor)
        let pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 80, panel: 0, artwork: nil, fallback: cyan)
        assertPanel(pixels, width: 80, panel: 1, artwork: nil, fallback: [0, 0, 128, 255])
        let sizes = await actor.run { actor in
            actor.parityDriverForTesting?.renderer?.lastFrameDraws.compactMap {
                $0.draw.textures["g_Texture1"].map { [$0.width, $0.height] }
            } ?? []
        }
        XCTAssertTrue(sizes.contains([12, 4]), "the bound user image must have the cropped size, got \(sizes)")
        XCTAssertFalse(sizes.contains([12, 12]), "the uncropped user image must not be bound, got \(sizes)")
    }

    func testArtworkIsCenterCroppedToTheAuthoredSlotAspect() async throws {
        // The authored slot is 2x2, so the 16x8 artwork keeps only its centred 8x8 square.
        let sizes = try await boundArtworkSizes(makeFixture(scripted: false))
        XCTAssertTrue(sizes.contains([8, 8]), "the bound artwork must have the cropped size, got \(sizes)")
        XCTAssertFalse(sizes.contains([16, 8]), "the uncropped artwork must not be bound, got \(sizes)")
    }

    func testKeepAspectArtworkIsBoundWhole() async throws {
        let sizes = try await boundArtworkSizes(makeFixture(scripted: false, keepAspect: true))
        XCTAssertTrue(sizes.contains([16, 8]), "keepaspect must bind the whole artwork, got \(sizes)")
        XCTAssertFalse(sizes.contains([8, 8]), "keepaspect must not crop the artwork, got \(sizes)")
    }

    /// The g_Texture1 sizes drawn after artwork A (16x8) is pushed; the quadrants show A either way.
    private func boundArtworkSizes(_ fixture: Fixture) async throws -> [[Int]] {
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = MediaInputSource()
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let driver = try WPEParitySceneDriver(device: fixture.device)
        defer { dispatcher.stop(); driver.cleanup() }
        let layer = makeLayer(device: fixture.device)
        try await load(driver, fixture: fixture, dispatcher: dispatcher, size: Self.size)
        XCTAssertTrue(dispatcher.configureParity(generation: driver.loadGeneration, device: fixture.device,
                                                 textureDemand: driver.hasMediaTextureDemand, onChange: {}))
        source.push(artwork: fixture.a)
        try await assertPanels(present(driver, layer: layer), width: 80, current: .a, previous: nil)
        return try XCTUnwrap(driver.renderer).lastFrameDraws.compactMap {
            $0.draw.textures["g_Texture1"].map { [$0.width, $0.height] }
        }
    }

    func testSceneTextureVideoPlaysInItsSlotAndClearingRestoresTheAuthoredFallback() async throws {
        let fixture = try makeFixture(scripted: false, sceneTextures: true)
        let clip = fixture.root.appending(path: "user-clip.mp4")
        try await Self.writeVideo(colours: [[255, 0, 0], [0, 0, 255]]).write(to: clip)
        let images = WPEUserShortcutIconStore(device: fixture.device)
        let layer = makeLayer(device: fixture.device)
        let surface = MediaPacingRecorder()
        var inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: "scene-texture-video", cacheRelativePath: "scene-texture-video",
                                        entryFile: "scene.json", capabilityTier: .degraded),
            entryResolver: SceneResourceResolver(cacheRootURL: fixture.root), projectRoot: fixture.root,
            assets: fixture.assets, settings: Self.settings, compiler: fixture.compiler, device: fixture.device,
            presentLayer: WPEPresentLayer(layer: layer), mailbox: WPEPointerMailbox(), surfaceControl: surface,
            drawableSize: Self.size, pixelFormat: layer.pixelFormat
        )
        inputs.userShortcutIcons = images
        let actor = WPEDisplayRenderActor(backing: .main)
        let fixtureRoot = fixture.root
        addTeardownBlock {
            await actor.teardownRenderer()
            await actor.shutdown()
            await MainActor.run { try? FileManager.default.removeItem(at: fixtureRoot) }
        }
        try await actor.adoptParity(inputs)
        try await actor.load()
        try await actorFrame(actor)
        try assertPanels(readBack(XCTUnwrap(layer.lastTexture)), width: 80, current: nil, previous: nil)

        XCTAssertTrue(images.setVideo(clip, forKey: "texture-current"))
        try await waitUntil("A scene texture video did not wake the parked product actor") { surface.lastIsPaused == false }
        let playing = await actor.run { $0.parityDriverForTesting?.needsContinuousFrames == true }
        XCTAssertTrue(playing, "a bound video must keep the scene producing frames")
        // Panel 0 samples the slot; the clip turns from red to blue halfway through each loop.
        var seen: [String] = []
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, seen.count < 3 {
            try await actorFrame(actor)
            let pixels = try readBack(XCTUnwrap(layer.lastTexture))
            let offset = (24 * 80 + 8) * 4
            let (blue, green, red) = (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
            let colour = red > 180 && green < 80 && blue < 80 ? "red" : blue > 180 && green < 80 && red < 80 ? "blue" : nil
            if let colour, seen.last != colour {
                seen.append(colour)
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(seen.count, 3, "the slot must sample the playing, looping clip, saw \(seen)")
        let pixels = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanel(pixels, width: 80, panel: 1, artwork: nil, fallback: [0, 0, 128, 255])

        XCTAssertTrue(images.setVideo(nil, forKey: "texture-current"))
        try await actorFrame(actor)
        try assertPanels(readBack(XCTUnwrap(layer.lastTexture)), width: 80, current: nil, previous: nil)
    }

    func testOriginalEffectsConsumeSameFrameMediaAndScriptThenPreservePairAcrossReloadAndResize() async throws {
        let fixture = try makeFixture(scripted: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = MediaInputSource()
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let driver = try WPEParitySceneDriver(device: fixture.device)
        defer { dispatcher.stop(); driver.cleanup() }
        let layer = makeLayer(device: fixture.device)
        try await load(driver, fixture: fixture, dispatcher: dispatcher, size: Self.size)
        XCTAssertTrue(driver.hasMediaTextureDemand)
        XCTAssertTrue(driver.scriptHandlesMedia)

        // No source has delivered yet: these are authored material fallbacks, not an empty-art native oracle.
        let fallback = try await present(driver, layer: layer)
        assertPanel(fallback, width: 80, panel: 0, artwork: nil, fallback: [0, 128, 0, 255])
        assertPanel(fallback, width: 80, panel: 1, artwork: nil, fallback: [0, 0, 128, 255])
        let configured = dispatcher.configureParity(generation: driver.loadGeneration, device: fixture.device,
                                                    textureDemand: driver.hasMediaTextureDemand, onChange: {})
        XCTAssertTrue(configured)
        source.push(artwork: fixture.a)
        let first = try await present(driver, layer: layer)
        assertPanels(first, width: 80, current: .a, previous: nil)
        assertSentinel(first, width: 80, deliveries: 1, currentRevision: 1, previousRevision: 0)
        let a = try pair(driver)
        XCTAssertEqual(a.dimensions, [16, 8, 0, 0])
        XCTAssertNotNil(a.currentName)
        XCTAssertNil(a.previousName)

        // The source metadata and palette are unchanged. Only the artwork bytes and geometry change.
        source.push(artwork: fixture.b)
        let second = try await present(driver, layer: layer)
        assertPanels(second, width: 80, current: .b, previous: .a)
        assertSentinel(second, width: 80, deliveries: 2, currentRevision: 2, previousRevision: 1)
        let b = try pair(driver)
        XCTAssertEqual(b.dimensions, [8, 16, 16, 8])
        XCTAssertEqual(b.previousName, a.currentName)
        XCTAssertNotEqual(b.currentName, a.currentName)
        XCTAssertEqual(b.revision, a.revision + 1)
        try assertBoundEffects(driver)

        // A normal load creates a fresh script but replays the existing B/A pair without another source event.
        let generation = driver.loadGeneration
        try await load(driver, fixture: fixture, dispatcher: dispatcher, size: Self.size)
        XCTAssertGreaterThan(driver.loadGeneration, generation)
        let replayed = dispatcher.configureParity(generation: driver.loadGeneration, device: fixture.device,
                                                  textureDemand: driver.hasMediaTextureDemand, onChange: {})
        XCTAssertTrue(replayed)
        let reloaded = try await present(driver, layer: layer)
        assertPanels(reloaded, width: 80, current: .b, previous: .a)
        assertSentinel(reloaded, width: 80, deliveries: 1, currentRevision: 2, previousRevision: 1)
        XCTAssertEqual(try pair(driver), b, "Reload must seed the existing current/previous identities")

        let resized = CGSize(width: 160, height: 64)
        layer.drawableSize = resized
        driver.updateSurfaceGeometry(drawableSize: resized)
        XCTAssertTrue(driver.needsReplan)
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        let afterResize = try await present(driver, layer: layer)
        assertPanels(afterResize, width: 160, current: .b, previous: .a)
        assertSentinel(afterResize, width: 160, deliveries: 1, currentRevision: 2, previousRevision: 1)
        XCTAssertEqual(try pair(driver), b, "Resize must preserve B/A rather than seed previous from current")
        try assertBoundEffects(driver)

        // A/B's exact palette guard exercises byte identity independently. Midtone C also detects a missing
        // or duplicate sRGB conversion, which A/B's zero/one channels cannot expose.
        source.push(artwork: fixture.c)
        let midtones = try await present(driver, layer: layer)
        assertPanels(midtones, width: 160, current: .c, previous: .b)
        assertSentinel(midtones, width: 160, deliveries: 2, currentRevision: 3, previousRevision: 2)
    }

    func testTextureDemandWithoutHandlersWakesRealRenderActorAndParksAfterPresent() async throws {
        let fixture = try makeFixture(scripted: false)
        let source = MediaInputSource()
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let layer = makeLayer(device: fixture.device)
        let surface = MediaPacingRecorder()
        var inputs = WPEParitySceneInputs(
            descriptor: SceneDescriptor(workshopID: "media-input-guard", cacheRelativePath: "media-input-guard",
                                        entryFile: "scene.json", capabilityTier: .degraded),
            entryResolver: SceneResourceResolver(cacheRootURL: fixture.root), projectRoot: fixture.root,
            assets: fixture.assets, settings: Self.settings, compiler: fixture.compiler, device: fixture.device,
            presentLayer: WPEPresentLayer(layer: layer), mailbox: WPEPointerMailbox(), surfaceControl: surface,
            drawableSize: Self.size, pixelFormat: layer.pixelFormat
        )
        inputs.media = dispatcher
        let actor = WPEDisplayRenderActor(backing: .main)
        let fixtureRoot = fixture.root
        addTeardownBlock {
            await actor.teardownRenderer()
            await actor.shutdown()
            await MainActor.run {
                dispatcher.stop()
                try? FileManager.default.removeItem(at: fixtureRoot)
            }
        }
        try await actor.adoptParity(inputs)
        try await actor.load()
        let demandWithoutHandler = await actor.run {
            $0.parityDriverForTesting?.hasMediaTextureDemand == true
                && $0.parityDriverForTesting?.scriptHandlesMedia == false
        }
        XCTAssertTrue(demandWithoutHandler)
        await assertStaticActor(actor)
        try await actorFrame(actor)
        XCTAssertEqual(surface.lastIsPaused, true, "The static scene parks after its first frame")
        let fallback = try readBack(XCTUnwrap(layer.lastTexture))
        assertPanels(fallback, width: 80, current: nil, previous: nil)

        for (data, current, previous) in [(fixture.a, Artwork.a, Artwork?.none),
                                          (fixture.b, Artwork.b, Optional(Artwork.a))] {
            source.push(artwork: data)
            // Observe the product's onChange -> actor pending-frame path before driving the display-link tick.
            try await waitUntil("Texture-only input did not unpark the render actor") { surface.lastIsPaused == false }
            try await actorFrame(actor)
            try assertPanels(readBack(XCTUnwrap(layer.lastTexture)), width: 80,
                             current: current, previous: previous)
            XCTAssertEqual(surface.lastIsPaused, true, "The accepted present consumes the pending frame")
        }
        // Exercise the Actor's real reload/configure/replay entry as well as the direct Driver contract above.
        try await actor.reload()
        await assertStaticActor(actor)
        XCTAssertEqual(surface.lastIsPaused, false)
        try await actorFrame(actor)
        try assertPanels(readBack(XCTUnwrap(layer.lastTexture)), width: 80, current: .b, previous: .a)
        XCTAssertEqual(surface.lastIsPaused, true)
        let allowedDiagnostic = Self.nativeSizingDiagnostic
        let valid = await actor.run {
            guard let driver = $0.parityDriverForTesting, let renderer = driver.renderer else { return false }
            return driver.hasPresentedFrame && driver.shaderErrorSummary.count == 0
                && renderer.skipped.isEmpty && renderer.fallbackTextures.isEmpty
                && renderer.mediaDiagnostics.allSatisfy { $0 == allowedDiagnostic }
        }
        XCTAssertTrue(valid)
    }

    func testEvictedArtworkSurvivesActualInflightGPUReadThroughCleanup() async throws {
        let fixture = try makeFixture(scripted: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = MediaInputSource()
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let driver = try WPEParitySceneDriver(device: fixture.device)
        defer { dispatcher.stop(); driver.cleanup() }
        let layer = makeLayer(device: fixture.device)
        try await load(driver, fixture: fixture, dispatcher: dispatcher, size: Self.size)
        let configured = dispatcher.configureParity(generation: driver.loadGeneration, device: fixture.device,
                                                    textureDemand: driver.hasMediaTextureDemand, onChange: {})
        XCTAssertTrue(configured)
        let queue = driver.executor.textureSourceCommandQueue
        let gate = try XCTUnwrap(fixture.device.makeSharedEvent())
        let blocker = try XCTUnwrap(queue.makeCommandBuffer())
        blocker.encodeWaitForEvent(gate, value: 1)
        blocker.commit()
        defer { gate.signaledValue = 1 } // An assertion or thrown prerequisite must never strand the queue.

        source.push(artwork: fixture.a)
        let first = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: SIMD2(0.5, 0.5)))
        let firstDrawable = try XCTUnwrap(layer.lastTexture)
        // The first frame samples A through its square crop, so that crop is the GPU-read texture to track.
        weak var oldArtwork: (any MTLTexture)?
        let oldName = try XCTUnwrap(pair(driver).currentName)
        try autoreleasepool {
            oldArtwork = try XCTUnwrap(assertBoundEffects(driver).first)
        }
        XCTAssertNotNil(oldArtwork)
        source.push(artwork: fixture.b)
        let second = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 101, pointer: SIMD2(0.5, 0.5)))
        // A third distinct artwork evicts A from both the store and the renderer's current/previous pair.
        source.push(artwork: fixture.c)
        let third = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 102, pointer: SIMD2(0.5, 0.5)))
        let latest = try pair(driver)
        XCTAssertNotEqual(latest.currentName, oldName)
        XCTAssertNotEqual(latest.previousName, oldName)
        XCTAssertNotEqual(first.status, .completed, "The GPU read must still be blocked")
        XCTAssertGreaterThan(driver.inFlightCount, 0)
        driver.cleanup()
        dispatcher.stop()
        XCTAssertNil(driver.renderer)
        XCTAssertNotNil(oldArtwork, "The evicted artwork must survive until its last GPU reader completes")

        gate.signaledValue = 1
        for command in [blocker, first, second, third] {
            try await waitUntil("Released GPU reader did not reach a terminal status") {
                command.status == .completed || command.status == .error
            }
            try requireCompleted(command)
        }
        // The old drawable proves the blocked graph actually sampled A, rather than merely retaining an unused object.
        try assertPanels(readBack(firstDrawable), width: 80, current: .a, previous: nil)
    }

    func testVideoTexMP4BytesLeaveThePlannerOnceTheDecoderOwnsThemAndTheVideoStillPlays() async throws {
        let fixture = try await makeFixture(scripted: false, video: videoTEX(Self.writeVideo()))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let dispatcher = WPESceneMediaEventDispatcher(source: MediaInputSource())
        let driver = try WPEParitySceneDriver(device: fixture.device)
        defer { dispatcher.stop(); driver.cleanup() }
        let layer = makeLayer(device: fixture.device)
        try await load(driver, fixture: fixture, dispatcher: dispatcher, size: Self.size)
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertEqual(renderer.videoTextures.count, 1)
        let planner = try XCTUnwrap(Mirror(reflecting: renderer).descendant("planner") as? WPEParityFrameDrawPlanner)
        XCTAssertEqual(planner.videos.count, 1, "The replan guard counts the planner's video streams")
        XCTAssertEqual(planner.videos.reduce(0) { $0 + $1.bytes.count }, 0, "The planner still holds MP4 bytes")

        // The witness layer samples the video; its decoded gray frames change the presented pixel.
        func witness() async throws -> [UInt8] {
            let bytes = try await present(driver, layer: layer)
            let offset = (16 * 80 + 72) * 4
            return Array(bytes[offset ..< offset + 3])
        }
        let deadline = Date().addingTimeInterval(5)
        var before = try await witness()
        while before == [0, 0, 0], Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            before = try await witness()
        }
        XCTAssertNotEqual(before, [0, 0, 0], "No decoded video frame reached the presented witness")
        var after = before
        while after == before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            after = try await witness()
        }
        XCTAssertNotEqual(after, before, "The video texture held one frame until the deadline")
    }

    private struct Fixture {
        let root: URL
        let device: any MTLDevice
        let compiler: WPEParityHelperShaderCompiler
        let cache: WPEParityShaderDiskCache
        let assets: WPEParityProgramAssets
        let document: WPESceneDocument
        let a: Data
        let b: Data
        let c: Data
    }

    private struct Pair: Equatable {
        let revision: UInt64
        let currentName: String?
        let previousName: String?
        let currentID: ObjectIdentifier?
        let previousID: ObjectIdentifier?
        let dimensions: [Int]
    }

    private enum Artwork: Equatable {
        case a, b, c

        func isHole(right: Bool, bottom: Bool) -> Bool {
            switch self {
            case .a: right && !bottom
            case .b: !right && bottom
            case .c: right && bottom
            }
        }
    }

    private func makeFixture(scripted: Bool, mediaProvider: String = "system", mergeUserTextures: Bool = false,
                             shortcutIcons: Bool = false, sceneTextures: Bool = false,
                             currentSlotWidth: UInt32 = 2, video: Data? = nil, keepAspect: Bool = false) throws -> Fixture {
        let qualifiedInput = mergeUserTextures || shortcutIcons || sceneTextures
        let root = FileManager.default.temporaryDirectory.appending(path: "parity-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        guard FileManager.default.fileExists(atPath: engine.appending(path: "shaders/combine.frag").path) else {
            try? FileManager.default.removeItem(at: root)
            if qualifiedInput {
                throw MediaFixtureError.originalShader("required original combine.frag")
            }
            throw XCTSkip("Set WPE_ASSETS_DIR to the original WPE 2.8.42 assets directory")
        }
        // Matches the sealed Windows resource manifest; no shader stub or translated-capture result is supplied.
        for (file, expected) in [
            ("combine.frag", "94fdbeb77d365f330e538db4493b0b8374b48d2d95fd460f6dc34036d6868ddf"),
            ("combine.vert", "25d48e4e45c8f2092e87d1a29eb2aeb62e5592e1581a6efc15dd06e9790f53cd"),
            ("genericimage2.frag", "1e252e2271cae57fcfdecf3bd79d1685bb726e1e8afe09ba863dca2e1b12d68e"),
            ("genericimage2.vert", "97370dbb18746d61629edf77ee2c30afe07605f5270f8a29a406b414932368bb"),
            ("common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
            ("common_pbr.h", "7a542df2279b6637d4f67434087df485b68ad24e06f85490d6ce424118c68d8d"),
            ("common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("common_blending.h", "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b"),
        ] {
            let bytes = try Data(contentsOf: engine.appending(path: "shaders/\(file)"))
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, expected, "Original WPE resource identity: \(file)")
            guard hash == expected else { throw MediaFixtureError.originalShader(file) }
            print("media product original shader=\(file) SHA256=\(hash)")
        }
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER"]
        let compiler: WPEParityHelperShaderCompiler
        if qualifiedInput {
            for key in keys + keys.map({ "TEST_RUNNER_" + $0 }) {
                _ = try XCTUnwrap(environment[key] == nil ? true : nil, "required bundled toolchain disallows \(key)")
            }
            let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath().standardizedFileURL
            let tools = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
                let url = contents.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
                _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil, "required bundled tool \(url)")
                return url
            }
            let hashes = try tools.map { try SHA256.hash(data: Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined() }
            compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1], metalIRConverter: tools[2],
                                                         workDirectory: root.appending(path: "shaderc"))
            XCTAssertEqual(compiler.compilerIdentity, "wpe-shaderc " + hashes.joined(separator: " "))
            print("media merge product toolchain origin=app-bundle compilerIdentity=\(compiler.compilerIdentity)")
        } else if keys.contains(where: { environment[$0] != nil }) {
            let urls = try keys.map { key in
                try URL(fileURLWithPath: XCTUnwrap(environment[key].flatMap { $0.isEmpty ? nil : $0 },
                                                   "Supply all three nonempty current test toolchain paths: \(keys)"))
            }
            compiler = try WPEParityHelperShaderCompiler(helper: urls[0], dxcompiler: urls[1], metalIRConverter: urls[2],
                                                         workDirectory: root.appending(path: "shaderc"))
        } else {
            switch WPEParityShaderToolchain.makeCompiler() {
            case let .success(found): compiler = found
            case let .failure(reason): throw reason
            }
        }
        print("media product compilerIdentity=\(compiler.compilerIdentity)")
        func write(_ path: String, _ data: Data) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            if qualifiedInput {
                let readBack = try Data(contentsOf: url)
                XCTAssertEqual(readBack, data, "required controlled input \(path)")
                let hash = SHA256.hash(data: readBack).map { String(format: "%02x", $0) }.joined()
                print("media merge controlled input=\(path) bytes=\(readBack.count) SHA256=\(hash)")
            }
        }
        func json(_ path: String, _ value: Any) throws {
            try write(path, JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        }
        for (name, pixel) in [("black", [UInt8(0), 0, 0, 255]), ("white", [255, 255, 255, 255]),
                              ("current", [0, 128, 0, 255]), ("previous", [0, 0, 128, 255])] {
            let wide = name == "current" && currentSlotWidth != 2
            let bytes = solidTEX(pixel, width: name == "current" ? currentSlotWidth : 2)
            if qualifiedInput {
                let expected = [
                    "black": "12bb09f8d804b7bc680b12fe8be942cd2870213357a9db7ea5b4ff2f899df86a",
                    "white": "69a03565ff1e6ec0c468d27e1faff5cff7d00f0fb6a97cd34c053cb5d49f8f3c",
                    "current": wide ? "3ca8b24e4bc5cd3ed135a7c5573c46e6aae03c2df27283e659dd10f5a6b86157"
                        : "3f42f5054e37baaba996691e03011d5c786c640212dac5cf6204031cdc1f8acd",
                    "previous": "80e49f65d3e7c3898cd20e6aa9a13f8479c19c63e3e6f873e6441de60acdd0ed",
                ]
                XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected[name])
            }
            try write("materials/input/\(name).tex", bytes)
        }
        if let video {
            try write("materials/input/video.tex", video)
        }
        // Select the original g_Color4 branch explicitly so the witness observes live thisLayer.color.
        for name in ["black", "white"] + (video == nil ? [] : ["video"]) {
            try json("models/\(name).json", ["material": "materials/\(name).json"])
            try json("materials/\(name).json", ["passes": [[
                "shader": "genericimage2", "combos": ["VERSION": 2],
                "textures": ["input/\(name)"], "blending": "normal",
                "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled",
            ]]])
        }
        for (name, system) in [("current", "$mediaThumbnail"), ("previous", "$mediaPreviousThumbnail")] {
            // combine.vert consumes clip positions directly. Its intermediate 2x2 mesh must precede a
            // layer-sized, MVP-aware draw; using it as the final effect would overwrite the entire scene.
            try json("effects/\(name).json", [
                "fbos": [["name": "media", "format": "rgba8888", "unique": true, "width": 32, "height": 32]],
                "passes": [
                    ["material": "materials/\(name)-effect.json", "target": "media"],
                    // Without a bind table slot 0 would sample the layer's input instead of media.
                    ["material": "materials/\(name)-compose.json", "bind": [["name": "media", "index": 0]]],
                ],
            ])
            let baseDeclarations: [Any] = mergeUserTextures && name == "previous" ? [NSNull()] : [
                NSNull(), ["name": shortcutIcons ? "shortcut-\(name)"
                    : mergeUserTextures ? (name == "current" ? "$mediaPreviousThumbnail" : "$mediaThumbnail") : system,
                    "type": shortcutIcons ? "usershortcut" : mediaProvider, "keepaspect": keepAspect],
            ]
            try json("materials/\(name)-effect.json", ["passes": [[
                "shader": "combine", "textures": ["previous", "input/\(name)"],
                "usertextures": sceneTextures ? [NSNull(), "texture-\(name)"] : baseDeclarations,
                "blending": "normal", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled",
            ]]])
            try json("materials/\(name)-compose.json", ["passes": [[
                "shader": "genericimage2", "combos": ["VERSION": 2], "textures": ["media"],
                "blending": "normal", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled",
            ]]])
        }
        var witness: [String: Any] = ["id": 3, "name": "ordering-witness",
                                      "image": video == nil ? "models/white.json" : "models/video.json",
                                      "size": "16 32", "origin": "72 16 0"]
        if scripted {
            witness["visible"] = ["value": true, "script": Self.orderingScript]
        }
        func effect(_ id: Int, _ name: String) -> [String: Any] {
            var effect: [String: Any] = ["id": id, "file": "effects/\(name).json"]
            if mergeUserTextures {
                let declarations: [Any] = name == "current"
                    ? [NSNull(), ["name": "$mediaThumbnail", "type": NSNull()]]
                    : [NSNull(), ["name": "$mediaPreviousThumbnail", "type": "system", "keepaspect": false], NSNull(), NSNull()]
                effect["passes"] = [["usertextures": declarations]]
            }
            return effect
        }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 80, "height": 32], "clearcolor": "0 0 0",
                        "clearenabled": true, "bloom": false, "hdr": false, "camerafade": false],
            "objects": [
                ["id": 1, "name": "current", "image": "models/black.json", "size": "32 32", "origin": "16 16 0",
                 "effects": [effect(10, "current")]],
                ["id": 2, "name": "previous", "image": "models/black.json", "size": "32 32", "origin": "48 16 0",
                 "effects": [effect(20, "previous")]],
                witness,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys])
        try write("scene.json", data)
        let a = try png(.a, width: 16, height: 8), b = try png(.b, width: 8, height: 16)
        let c = try png(.c, width: 16, height: 16)
        XCTAssertNotEqual(a, b)
        let paletteA = try XCTUnwrap(WPEMediaArtworkPalette.palette(from: a))
        let paletteB = try XCTUnwrap(WPEMediaArtworkPalette.palette(from: b))
        XCTAssertEqual(paletteA, paletteB, "Same-palette/different-bytes is a required fixture precondition")
        guard paletteA == paletteB else { throw MediaFixtureError.palette }
        return try Fixture(root: root, device: XCTUnwrap(MTLCreateSystemDefaultDevice()), compiler: compiler,
                           cache: WPEParityShaderDiskCache(cachesURL: root.appending(path: "cache")),
                           assets: WPEParityProgramAssets(sceneDirectory: root, assetRoots: [engine]),
                           document: WPESceneDocumentParser.parse(data: data, userValues: [:]), a: a, b: b, c: c)
    }

    private static let orderingScript = """
    var stage = 0;
    var deliveries = 0;
    var currentName;
    var previousName;
    export function applyUserProperties(properties) {
        if (Object.prototype.hasOwnProperty.call(properties, '$mediaThumbnail')
            || Object.prototype.hasOwnProperty.call(properties, '$mediaPreviousThumbnail')) {
            stage = -1;
            return;
        }
        if (typeof engine.userProperties['$mediaThumbnail'] === 'string') {
            currentName = engine.userProperties['$mediaThumbnail'];
            previousName = engine.userProperties['$mediaPreviousThumbnail'];
            deliveries += 1;
            stage = 1;
        }
    }
    export function mediaThumbnailChanged(event) {
        stage = stage === 1 && event.hasThumbnail ? 2 : -1;
    }
    function revision(name) {
        if (name === undefined) return 0;
        var match = /_([0-9]+)[.]system$/.exec(name);
        return match ? Number(match[1]) : -8;
    }
    export function update() {
        var currentRevision = revision(currentName);
        var previousRevision = revision(previousName);
        var same = currentRevision > 0 && previousRevision >= 0 && stage === 2 && engine.userProperties['$mediaThumbnail'] === currentName;
        if (previousName !== undefined) same = same && engine.userProperties['$mediaPreviousThumbnail'] === previousName;
        thisLayer.color = same ? new Vec3(deliveries / 8, currentRevision / 8, previousRevision / 8) : new Vec3(1, 0, 1);
        return true;
    }
    """

    private func load(_ driver: WPEParitySceneDriver, fixture: Fixture, dispatcher: WPESceneMediaEventDispatcher,
                      size: CGSize) async throws {
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: Self.settings,
                              drawableSize: size, pixelFormat: .bgra8Unorm_srgb, compiler: fixture.compiler,
                              diskCache: fixture.cache, scriptHost: .init(media: dispatcher.mailbox))
        XCTAssertTrue(driver.didLoad)
        XCTAssertEqual(driver.shaderErrorSummary.count, 0, "\(driver.shaderErrorSummary.entries)")
        let renderer = try XCTUnwrap(driver.renderer)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        XCTAssertTrue(renderer.fallbackTextures.isEmpty, "\(renderer.fallbackTextures)")
    }

    private func makeLayer(device: MTLDevice) -> MediaRecordingLayer {
        let layer = MediaRecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = Self.size
        layer.framebufferOnly = false
        layer.maximumDrawableCount = 3
        return layer
    }

    private func present(_ driver: WPEParitySceneDriver, layer: MediaRecordingLayer) async throws -> [UInt8] {
        let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: CACurrentMediaTime(),
                                                                 pointer: SIMD2(0.5, 0.5)))
        try await waitUntil("Presented GPU frame did not reach a terminal status") {
            command.status == .completed || command.status == .error
        }
        try requireCompleted(command)
        try await waitUntil("Present completion handlers did not settle") { driver.inFlightCount == 0 }
        let diagnostics = try XCTUnwrap(driver.renderer).mediaDiagnostics
        XCTAssertTrue(diagnostics.allSatisfy { $0 == Self.nativeSizingDiagnostic }, "\(diagnostics)")
        return try readBack(XCTUnwrap(layer.lastTexture))
    }

    private func pair(_ driver: WPEParitySceneDriver) throws -> Pair {
        let textures = try XCTUnwrap(driver.renderer?.mediaTextures)
        return Pair(revision: textures.revision, currentName: textures.currentSystemName,
                    previousName: textures.previousSystemName, currentID: textures.current.map(ObjectIdentifier.init),
                    previousID: textures.previous.map(ObjectIdentifier.init),
                    dimensions: [textures.current?.width ?? 0, textures.current?.height ?? 0,
                                 textures.previous?.width ?? 0, textures.previous?.height ?? 0])
    }

    /// The renderer's current/previous artwork each reach g_Texture1 as the centred crop to the 2x2 slot's square.
    @discardableResult
    private func assertBoundEffects(_ driver: WPEParitySceneDriver) throws -> [any MTLTexture] {
        let renderer = try XCTUnwrap(driver.renderer)
        let media = try XCTUnwrap(renderer.mediaTextures)
        let draws = renderer.lastFrameDraws.map(\.draw)
        let bound = draws.compactMap { $0.textures["g_Texture1"] }
        var crops: [any MTLTexture] = []
        for (label, source) in [("Current", media.current), ("Previous", media.previous)] {
            guard let source else { continue }
            let rect = WPEUserShortcutIconImage.cropRect(width: source.width, height: source.height, aspect: 1)
            let expected = bytes(of: source, in: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height))
            let crop = bound.first {
                $0.width == rect.width && $0.height == rect.height
                    && bytes(of: $0, in: MTLRegionMake2D(0, 0, rect.width, rect.height)) == expected
            }
            XCTAssertNotNil(crop, "\(label) must be bound to actual g_Texture1 as its centred square crop")
            crops += crop.map { [$0] } ?? []
        }
        let media2D = crops + [media.current, media.previous].compactMap(\.self)
        let producer = draws.filter { $0.textures["g_Texture1"] != nil }.compactMap { $0.textures["g_Texture0"] }
        XCTAssertEqual(producer.count, 2, "Both original combine effects must draw")
        XCTAssertTrue(producer.allSatisfy { slot0 in !media2D.contains { $0 === slot0 } },
                      "Slot 0 remains the effect producer; the null declaration must not shift media into it")
        return crops
    }

    private func bytes(of texture: any MTLTexture, in region: MTLRegion) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: region.size.width * region.size.height * 4)
        texture.getBytes(&bytes, bytesPerRow: region.size.width * 4, from: region, mipmapLevel: 0)
        return bytes
    }

    private func actorFrame(_ actor: WPEDisplayRenderActor) async throws {
        await actor.renderFrame()
        let deadline = Date().addingTimeInterval(5)
        var count = await actor.run { $0.parityDriverForTesting?.inFlightCount ?? 0 }
        while count > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
            count = await actor.run { $0.parityDriverForTesting?.inFlightCount ?? 0 }
        }
        XCTAssertEqual(count, 0)
        let presented = await actor.run { $0.parityDriverForTesting?.hasPresentedFrame == true }
        XCTAssertTrue(presented)
    }

    private func assertStaticActor(_ actor: WPEDisplayRenderActor) async {
        let state = await actor.run { actor in
            let driver = actor.parityDriverForTesting
            return (driver?.renderer?.isStatic == true, driver?.soundRuntime == nil,
                    driver?.needsContinuousFrames == false)
        }
        XCTAssertTrue(state.0, "This fixture must be a static renderer")
        XCTAssertTrue(state.1, "This fixture must have no continuous sound demand")
        XCTAssertTrue(state.2, "This fixture must have no continuous frame demand")
    }

    private func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate(), message)
        guard predicate() else { throw MediaFixtureError.timeout(message) }
    }

    private func requireCompleted(_ command: MTLCommandBuffer) throws {
        XCTAssertNil(command.error)
        XCTAssertEqual(command.status, .completed)
        if let error = command.error {
            throw error
        }
        guard command.status == .completed else { throw MediaFixtureError.command }
    }

    private func assertPanels(_ bytes: [UInt8], width: Int, current: Artwork?, previous: Artwork?) {
        assertPanel(bytes, width: width, panel: 0, artwork: current, fallback: [0, 128, 0, 255])
        assertPanel(bytes, width: width, panel: 1, artwork: previous, fallback: [0, 0, 128, 255])
    }

    private func assertPanel(_ bytes: [UInt8], width: Int, panel: Int, artwork: Artwork?, fallback: [UInt8]) {
        let scale = width / 80
        for bottom in [false, true] {
            for right in [false, true] {
                let expected: [UInt8] = artwork.map {
                    $0.isHole(right: right, bottom: bottom) ? [0, 0, 0, 255]
                        : $0 == .c ? [128, 64, 192, 255] : [255, 0, 0, 255]
                } ?? fallback
                assertPixel(bytes, width: width, x: (panel * 32 + (right ? 24 : 8)) * scale,
                            y: (bottom ? 24 : 8) * scale, expected: expected)
            }
        }
    }

    private func assertSentinel(_ bytes: [UInt8], width: Int, deliveries: Int,
                                currentRevision: Int, previousRevision: Int) {
        let scale = width / 80
        let rgb = [deliveries, currentRevision, previousRevision].map { UInt8((Double($0) * 255 / 8).rounded()) }
        assertPixel(bytes, width: width, x: 72 * scale, y: 16 * scale, expected: rgb + [255])
    }

    private func assertPixel(_ bytes: [UInt8], width: Int, x: Int, y: Int, expected: [UInt8]) {
        let offset = (y * width + x) * 4
        guard offset + 4 <= bytes.count else { return XCTFail("Readback missing pixel (\(x),\(y))") }
        let actual = [bytes[offset + 2], bytes[offset + 1], bytes[offset], bytes[offset + 3]]
        for channel in 0 ..< 4 {
            XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(expected[channel])), channel == 3 ? 0 : 2,
                                     "pixel (\(x),\(y)) RGBA=\(actual), expected=\(expected), channel=\(channel)")
        }
    }

    private func readBack(_ texture: MTLTexture) throws -> [UInt8] {
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm_srgb)
        let rowBytes = texture.width * 4, length = rowBytes * texture.height
        let buffer = try XCTUnwrap(texture.device.makeBuffer(length: length, options: .storageModeShared))
        let command = try XCTUnwrap(texture.device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: length)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try requireCompleted(command)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }

    private func png(_ artwork: Artwork, width: Int, height: Int) throws -> Data {
        var rgba: [UInt8] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                rgba.append(contentsOf: artwork.isHole(right: x >= width / 2, bottom: y >= height / 2)
                    ? [0, 0, 0, 0] : artwork == .c ? [128, 64, 192, 255] : [255, 0, 0, 255])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaFixtureError.png }
        return data as Data
    }

    private func solidTEX(_ pixel: [UInt8], width: UInt32 = 2) -> Data {
        tex(flags: 0, width: width, height: 2, payload: Data(Array(repeating: pixel, count: Int(width) * 2).joined()))
    }

    /// TEXI flag 0x20: the single mip holds the MP4 stream.
    private func videoTEX(_ mp4: Data) -> Data {
        tex(flags: 0x20, width: 64, height: 64, payload: mp4)
    }

    private func tex(flags: UInt32, width: UInt32, height: UInt32, payload: Data) -> Data {
        var data = Data()
        func magic(_ text: String) {
            data.append(contentsOf: text.utf8); data.append(0)
        }
        func append(_ number: UInt32) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        magic("TEXV0005"); magic("TEXI0001")
        for value in [UInt32(0), flags, width, height, width, height, 0] {
            append(value)
        }
        magic("TEXB0003")
        for value in [UInt32(1), .max, 1, width, height, 0, UInt32(payload.count), UInt32(payload.count)] {
            append(value)
        }
        data.append(payload)
        return data
    }

    /// One second of 64x64 H.264 whose 24 frames are increasingly bright gray, or `colours` (RGB) in equal runs.
    private static func writeVideo(colours: [[UInt8]] = []) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-media-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        guard writer.canAdd(input) else { throw MediaFixtureError.video }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaFixtureError.video }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(3)
        for frame in 0 ..< 24 {
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else { throw writer.error ?? MediaFixtureError.video }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
                == kCVReturnSuccess, let pixelBuffer else { throw MediaFixtureError.video }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let length = CVPixelBufferGetBytesPerRow(pixelBuffer) * 64
                if colours.isEmpty {
                    memset(base, Int32(40 + frame * 8), length)
                } else {
                    let rgb = colours[frame * colours.count / 24]
                    for offset in stride(from: 0, to: length, by: 4) {
                        for (channel, value) in [rgb[2], rgb[1], rgb[0], 255].enumerated() {
                            base.storeBytes(of: value, toByteOffset: offset + channel, as: UInt8.self)
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
                throw writer.error ?? MediaFixtureError.video
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? MediaFixtureError.video }
        return try Data(contentsOf: url)
    }
}

private enum MediaFixtureError: Error {
    case originalShader(String), palette, png, command, timeout(String), video
}

/// A controllable external source only; all upload, delivery, script, graph and presentation behavior is production code.
@MainActor
private final class MediaInputSource: WPENowPlayingEventSource {
    private var handlers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    private var ordinal: UInt64 = 0
    private var current = MonitorNowPlayingState(phase: .awaitingFirstEvent, title: "")

    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        handlers[id] = handler
        handler(ordinal, current)
    }

    func unsubscribe(id: UUID) {
        handlers[id] = nil
    }

    func push(artwork: Data) {
        ordinal += 1
        current = MonitorNowPlayingState(phase: .paused, title: "Controlled", artwork: artwork)
        for handler in handlers.values {
            handler(ordinal, current)
        }
    }
}

private final class MediaRecordingLayer: CAMetalLayer {
    private(set) var lastTexture: (any MTLTexture)?

    override func nextDrawable() -> (any CAMetalDrawable)? {
        let drawable = super.nextDrawable()
        lastTexture = drawable?.texture
        return drawable
    }
}

private final class MediaPacingRecorder: WPESurfaceControl {
    private let last = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    var lastIsPaused: Bool? {
        last.withLock { $0 }
    }

    func applyPacing(_ update: WPERenderPacingUpdate) {
        last.withLock { $0 = update.isPaused ?? $0 }
    }

    func setNeedsRedraw() {}
    func drawImmediately() {}
    func releaseDrawables() {}
    func detach() {}
    func setClickCaptureEnabled(_: Bool) {}
}
#endif
