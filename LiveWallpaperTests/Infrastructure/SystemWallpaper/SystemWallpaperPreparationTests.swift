#if !LITE_BUILD
import AppKit
import AVFoundation
import CoreVideo
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import QuartzCore
import Testing
import WebKit

@MainActor
@Suite("System wallpaper preparation", .serialized, .timeLimit(.minutes(3)))
struct SystemWallpaperPreparationTests {
    @Test("Clock detection follows visibility controls and text scripts without hiding timed artwork")
    func clockLayerDetection() {
        let scene = #"""
        {"objects":[
          {"id":1,"name":"Artwork","color":{"script":"new Date().getHours()"}},
          {"id":2,"name":"D a y"},
          {"id":3,"name":"Widget","visible":{"user":"custom","value":true}},
          {"id":4,"name":"Digits","text":{"script":"export function update() { return new Date().getMinutes(); }"}},
          {"id":5,"name":"Child","parent":3},
          {"id":6,"name":"Clockwork forest"},
          {"id":7,"name":"Animation","visible":{"user":"timeformat","value":true}},
          {"id":8,"name":"Update"},
          {"id":9,"name":"Date palm forest"}
        ]}
        """#
        let project = #"{"general":{"properties":{"custom":{"type":"bool","text":"📆 Date & Time 📆"},"timeformat":{"type":"bool","text":"24-hour format"}}}}"#
        #expect(SystemWallpaperClockPolicy.hiddenObjectIDs(sceneData: Data(scene.utf8), projectData: Data(project.utf8)) == ["2", "3", "4", "5"])
        let controls = #"{"general":{"properties":{"showclock":{"type":"bool","value":true},"hidecalendar":{"type":"bool","value":false},"clockformat":{"type":"bool","value":true}}}}"#
        #expect(SystemWallpaperClockPolicy.visibilityOverrides(projectData: Data(controls.utf8)) == ["showclock": false, "hidecalendar": true])
        #expect(!SystemWallpaperClockPolicy.isWidgetName("datetimeisdraggable"))
        #expect(!SystemWallpaperClockPolicy.isWidgetName("datetimescale"))
        #expect(!SystemWallpaperClockPolicy.isWidgetName("Clock Tower"))
    }

    @Test("GPU clock exclusion beats scripts and restores the original desktop without mutating assets")
    func clockHidingRoundTrip() async throws {
        guard #available(macOS 26.0, *) else { return }
        let fixture = try filledScene()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["name"] = "Clock"
        objects[0]["visible"] = ["value": true, "script": "export function update(value) { return true; }"]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: file)
        let original = try Data(contentsOf: file)
        try Data(#"{"general":{"properties":{"showclock":{"type":"bool","value":true}}}}"#.utf8)
            .write(to: fixture.root.appendingPathComponent("project.json"))
        let source = SystemWallpaperSceneSource(descriptor: fixture.descriptor,
                                                provider: WPEDirectorySceneAssetProvider(rootURL: fixture.root), projectRoot: fixture.root,
                                                mounts: [], engineRoot: nil)
        let ids = source.clockCalendarObjectIDs()
        #expect(ids.count == 1)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        let size = CGSize(width: 64, height: 64)
        layer.drawableSize = size
        let actor = try await SystemWallpaperSceneRuntime.makeActor(source: source, layer: layer, size: size)
        do {
            let pool = try SystemWallpaperFramePool(size: size, device: device)
            let desktop = try await settledPixel(actor: actor, pool: pool)
            try await actor.setSystemWallpaperState(descriptor: source.descriptorForSystemWallpaper(hidingClockCalendar: true), excludedObjectIDs: ids)
            let locked = try await settledPixel(actor: actor, pool: pool)
            #expect(desktop[2] > 200)
            #expect(locked != desktop, "a script or cached pass rendered the excluded clock")
            #expect(await actor.hibernate())
            try await actor.setSystemWallpaperState(descriptor: source.descriptor, excludedObjectIDs: [])
            #expect(await actor.rendererStateSnapshot()?.isLoaded == false, "changing lock state must not wake an asleep renderer")
            try await actor.reload()
            #expect(try await settledPixel(actor: actor, pool: pool) == desktop)
            #expect(try Data(contentsOf: file) == original)
            await actor.teardownRenderer()
            actor.requestStop()
        } catch {
            await actor.teardownRenderer()
            actor.requestStop()
            throw error
        }
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("clock-free.mov")
        try await SystemWallpaperScenePreparation.record(source: source, url: movie, size: size, duration: 1, framesPerSecond: 15, progress: { _ in })
        #expect(try await decodedFrames(movie).allSatisfy { $0.pixel[2] < 30 }, "the exported movie contains the clock")
    }

    @Test("Web export hides dynamic DOM clocks and dates while leaving artwork intact")
    func webClockHiding() async throws {
        let view = HTMLWallpaperView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), initialEphemeral: true)
        defer { view.cleanup() }
        view.webView.loadHTMLString("""
        <html><head></head><body>
        <div id="clock" style="visibility:visible!important">12:34</div><div id="calendar">Calendar</div>
        <div id="player-duration">12:34</div>
        <div id="artwork">Clockwork forest</div><canvas id="background"></canvas>
        <script>window.wallpaperPropertyListener = {applyUserProperties: p => window.received = p};</script>
        </body></html>
        """, baseURL: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await (try? view.webView.evaluateJavaScript("!!document.getElementById('clock')")) as? Bool != true {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await view.hideClockCalendarForSystemWallpaperRecording()
        func visibility(_ id: String) async throws -> String {
            try #require(try await view.webView.evaluateJavaScript("getComputedStyle(document.getElementById('\(id)')).visibility") as? String)
        }
        #expect(try await visibility("clock") == "hidden")
        #expect(try await visibility("calendar") == "hidden")
        #expect(try await visibility("artwork") == "visible")
        #expect(try await visibility("background") == "visible")
        #expect(try await visibility("player-duration") == "visible")
        _ = try await view.webView.evaluateJavaScript("document.getElementById('clock').style.setProperty('visibility', 'visible', 'important')")
        #expect(try await visibility("clock") == "hidden")
        _ = try await view.webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<div id=late>2026-10-16</div>')")
        #expect(try await visibility("late") == "hidden")
        _ = try await view.webView.evaluateJavaScript("document.getElementById('late').textContent = '01:45:12 PM'")
        #expect(try await visibility("late") == "hidden")
        // The operation never modifies shared config or writes a stylesheet into the source.
        #expect(view.lastAppliedConfig == nil)
    }

    @Test("Desktop-picture refresh respects native ownership on each display")
    func nativeDisplayOwnership() {
        let now = Date()
        var heartbeat = SystemWallpaperHeartbeat(timestamp: now, activeChoiceID: "scene", activeDisplayIDs: [42])
        #expect(heartbeat.ownsDisplay(42, now: now))
        #expect(!heartbeat.ownsDisplay(43, now: now))
        #expect(!heartbeat.ownsDisplay(42, now: now.addingTimeInterval(301)))
        heartbeat.activeDisplayIDs = nil
        #expect(heartbeat.ownsDisplay(43, now: now), "older providers conservatively own all displays")
        heartbeat.runtimeHealthy = false
        #expect(!heartbeat.ownsDisplay(42, now: now))
    }

    @Test("Publication options survive updates and older manifests still decode")
    func preparationMetadata() throws {
        var options = SystemWallpaperPreparationOptions()
        options.sceneMode = .videoCopy
        options.duration = 30
        options.framesPerSecond = 60
        options.size = CGSize(width: 2560, height: 1440)
        let item = SystemWallpaperManifest.Item(id: "scene", title: "Scene", fileName: "scene.mov",
                                                addedAt: Date(), preparationOptions: options)
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(SystemWallpaperManifest.Item.self, from: data).preparationOptions == options)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "preparationOptions")
        let decoded = try JSONDecoder().decode(SystemWallpaperManifest.Item.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.preparationOptions == nil)
        options.size.width = .infinity
        #expect(!options.isValid)
        options.size = CGSize(width: 65, height: 64)
        #expect(!options.isValid)
    }

    @Test("Abandoned scene bundles are reclaimed without removing other directories")
    func sceneBundleOrphans() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let staging = directory.appendingPathComponent(SystemWallpaperLibrary.stagingFileName(itemID: "fixture", ext: "scene", now: now.addingTimeInterval(-90000)))
        let unrelated = directory.appendingPathComponent("unrelated")
        for url in [staging, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90000)], ofItemAtPath: url.path)
        }
        SystemWallpaperLibrary.sweepOrphans(manifest: .empty, videosDirectory: directory, now: now)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("GPU movie buffers encode distinct frames with monotonic timestamps")
    func movieRoundTrip() async throws {
        guard #available(macOS 26.0, *) else { return }
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("colors.mov")
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let writer = try SystemWallpaperMovieWriter(url: url, size: CGSize(width: 64, height: 64), framesPerSecond: 15, device: device)
        for frame in 0 ..< 15 {
            try await writer.append(at: CMTime(value: Int64(frame), timescale: 15)) { texture in
                let descriptor = MTLRenderPassDescriptor()
                descriptor.colorAttachments[0].texture = texture
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].storeAction = .store
                descriptor.colorAttachments[0].clearColor = frame < 7
                    ? MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
                    : MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)
                let command = try #require(queue.makeCommandBuffer())
                let encoder = try #require(command.makeRenderCommandEncoder(descriptor: descriptor))
                encoder.endEncoding()
                let completed = await withCheckedContinuation { continuation in
                    command.addCompletedHandler { continuation.resume(returning: $0.status == .completed) }
                    command.commit()
                }
                #expect(completed)
            }
        }
        try await writer.finish(at: CMTime(value: 1, timescale: 1))
        let frames = try await decodedFrames(url)
        #expect(frames.count == 15)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { pair in pair.0.time < pair.1.time })
        #expect(frames.first?.pixel != frames.last?.pixel)
        #expect(frames.first?.pixel[2] ?? 0 > 200)
        #expect(frames.last?.pixel[0] ?? 0 > 200)

        // Exercise the actual video decoder and PNG encoder while replacing only the OS installer.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let decoded = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
        let screen = try #require(NSScreen.screens.first)
        let screenID = CGDirectDisplayID.random(in: 0xF000_0000 ... 0xFFFF_FFFE)
        var picture: URL?
        defer {
            if let picture {
                try? FileManager.default.removeItem(at: picture)
            }
        }
        let outcome = await DesktopPictureFrameExtractor.applyFrame(
            { decoded }, screenID: screenID, nsScreen: screen,
            install: { url, _ in picture = url }
        )
        #expect(outcome == .captured)
        let png = try #require(picture)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: png)))
        let color = try #require(bitmap.colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
        #expect(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64)
        #expect(color.blueComponent > 0.8 && color.redComponent < 0.2)
    }

    @Test("Live publication, conversion and cancelled updates keep the library consistent")
    func publicationLifecycle() async throws {
        guard #available(macOS 26.0, *) else { return }
        let fixture = try filledScene()
        defer { fixture.cleanup() }
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let liveDependencies = WallpaperExportService.Dependencies.live()
        let dependencies = WallpaperExportService.Dependencies(sharedRoot: directory, resolver: liveDependencies.resolver,
                                                               now: liveDependencies.now, makeThumbnailJPEG: liveDependencies.makeThumbnailJPEG,
                                                               expectedProvider: nil)
        let service = WallpaperExportService(dependencies: dependencies)
        let descriptor = SceneDescriptor(workshopID: fixture.descriptor.workshopID, cacheRelativePath: fixture.descriptor.cacheRelativePath,
                                         entryFile: "scene.json", capabilityTier: .imageOnly, assetStorage: .sourceDirectory)
        let origin = try WPEOrigin(workshopID: descriptor.workshopID, title: "Fixture", originalType: .scene,
                                   sourceFolderBookmark: fixture.root.bookmarkData(options: .withSecurityScope),
                                   cacheRelativePath: nil, previewFileName: nil)
        var options = SystemWallpaperPreparationOptions()
        options.size = CGSize(width: 64, height: 64)
        options.duration = 1
        options.framesPerSecond = 15
        try await service.prepareAndPublish(content: .scene(descriptor), title: "Fixture", id: "fixture", options: options, origin: origin)
        let live = try #require(service.items.first)
        #expect(live.fileName == "fixture.scene")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Videos/fixture.scene/Assets/scene.json").path))
        options.sceneMode = .videoCopy
        try await service.prepareAndPublish(content: .scene(descriptor), title: "Updated", id: "fixture", options: options, origin: origin)
        let updated = try #require(service.items.first)
        #expect(service.items.count == 1)
        #expect(updated.fileName == "fixture.mov")
        #expect(updated.preparationOptions == options)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Videos/fixture.scene").path))
        let video = directory.appendingPathComponent("Videos/fixture.mov")
        let previous = try Data(contentsOf: video)
        options.duration = 30
        let task = Task { @MainActor in
            try await service.prepareAndPublish(content: .scene(descriptor), title: "Cancelled", id: "fixture", options: options, origin: origin)
        }
        try await Task.sleep(for: .milliseconds(100))
        service.cancelPreparation()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(service.items.first == updated)
        #expect(try Data(contentsOf: video) == previous)
        #expect(service.preparationProgress == nil)

        let removed = Task { @MainActor in
            try await service.prepareAndPublish(content: .scene(descriptor), title: "Removed", id: "fixture", options: options, origin: origin)
        }
        try await Task.sleep(for: .milliseconds(100))
        try service.remove(itemID: "fixture")
        await #expect(throws: CancellationError.self) { try await removed.value }
        #expect(service.items.isEmpty, "preparation resurrected the removed wallpaper")
        #expect(!FileManager.default.fileExists(atPath: video.path))
    }

    @Test("Scene recording survives publication without its original asset directory")
    func sceneBundleAndMovie() async throws {
        guard #available(macOS 26.0, *) else { return }
        let fixture = try filledScene()
        defer { fixture.cleanup() }
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("scene.scene")
        let source = SystemWallpaperSceneSource(
            descriptor: fixture.descriptor.withPropertyOverrides(["test": .number(3)]),
            provider: WPEDirectorySceneAssetProvider(rootURL: fixture.root), projectRoot: fixture.root,
            mounts: [], engineRoot: nil
        )
        try SystemWallpaperSceneBundle.stage(source: source, at: bundle)
        let staged = try SystemWallpaperSceneSource.published(at: bundle)
        #expect(staged.descriptor == source.descriptor)
        fixture.cleanup()
        let movie = directory.appendingPathComponent("scene.mov")
        try await SystemWallpaperScenePreparation.record(
            source: staged, url: movie, size: CGSize(width: 64, height: 64), duration: 1, framesPerSecond: 15,
            progress: { _ in }
        )
        let frames = try await decodedFrames(movie)
        #expect(!frames.isEmpty)
        #expect(frames.first?.pixel[2] ?? 0 > 200)
        let duration = try await AVURLAsset(url: movie).load(.duration)
        #expect(abs(duration.seconds - 1) < 0.1)
    }

    @Test("Live time advances even when background animation is suspended", arguments: [false, true])
    func liveWallClockChanges(suspended: Bool) async throws {
        guard #available(macOS 26.0, *) else { return }
        let fixture = try filledScene()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["color"] = ["value": "1 0 0", "script": "export function update(value) { value.x = new Date().getSeconds() / 60; return value; }"]
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: file)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        let size = CGSize(width: 64, height: 64)
        layer.drawableSize = size
        let source = SystemWallpaperSceneSource(descriptor: fixture.descriptor,
                                                provider: WPEDirectorySceneAssetProvider(rootURL: fixture.root), projectRoot: fixture.root,
                                                mounts: [], engineRoot: nil)
        let actor = try await SystemWallpaperSceneRuntime.makeActor(source: source, layer: layer, size: size)
        do {
            let pool = try SystemWallpaperFramePool(size: size, device: device)
            let first = try await settledPixel(actor: actor, pool: pool)
            if suspended {
                await actor.applyPerformanceProfile(.suspended)
            }
            try await Task.sleep(for: .milliseconds(1200))
            let second = try await settledPixel(actor: actor, pool: pool)
            #expect(first != second, "the clock-dependent scene was frozen")
            await actor.teardownRenderer()
            actor.requestStop()
        } catch {
            await actor.teardownRenderer()
            actor.requestStop()
            throw error
        }
    }

    @Test("Cancelling scene preparation drains its render task")
    func cancelRecording() async throws {
        guard #available(macOS 26.0, *) else { return }
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = SystemWallpaperSceneSource(descriptor: fixture.descriptor,
                                                provider: WPEDirectorySceneAssetProvider(rootURL: fixture.root), projectRoot: fixture.root,
                                                mounts: [], engineRoot: nil)
        let task = Task { @MainActor in
            try await SystemWallpaperScenePreparation.record(source: source,
                                                             url: directory.appendingPathComponent("cancelled.mov"), size: CGSize(width: 64, height: 64),
                                                             duration: 30, framesPerSecond: 15, progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SystemWallpaperPreparationTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func filledScene() throws -> MetalSceneFixture {
        let fixture = try MetalSceneFixture.solidColorScene()
        let file = fixture.root.appendingPathComponent("scene.json")
        var scene = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        objects[0]["origin"] = "32 32 0"
        objects[0]["size"] = "64 64"
        scene["objects"] = objects
        try JSONSerialization.data(withJSONObject: scene).write(to: file)
        return fixture
    }

    private func settledPixel(actor: WPEDisplayRenderActor, pool: SystemWallpaperFramePool) async throws -> [UInt8] {
        var pixel: [UInt8] = []
        for _ in 0 ..< 4 {
            let frame = try pool.makeFrame()
            try await actor.renderMovieFrame(into: .init(texture: frame.texture))
            pixel = centerPixel(frame.buffer)
            try await Task.sleep(for: .milliseconds(30))
        }
        return pixel
    }

    private func centerPixel(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let offset = CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer)
            + CVPixelBufferGetWidth(buffer) / 2 * 4
        return Array(UnsafeBufferPointer(start: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: 4))
    }

    private func decodedFrames(_ url: URL) async throws -> [(time: CMTime, pixel: [UInt8])] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var frames: [(CMTime, [UInt8])] = []
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                frames.append((CMSampleBufferGetPresentationTimeStamp(sample), centerPixel(buffer)))
            }
        }
        #expect(reader.status == .completed)
        return frames
    }
}
#endif
