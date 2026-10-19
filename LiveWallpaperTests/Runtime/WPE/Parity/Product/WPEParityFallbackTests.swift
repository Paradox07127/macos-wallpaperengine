#if !LITE_BUILD && DEBUG
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

/// A failed parity candidate publishes its error and leaves the installed wallpaper in place.
@MainActor
final class WPEParityFailureTests: XCTestCase {
    override func tearDown() {
        WPEParitySceneDriver.remainingForcedLoadFailuresForTesting = 0
        super.tearDown()
    }

    func testParityLoadFailureKeepsTheInstalledWallpaperAndCapturesDiagnostics() async throws {
        let screen = try Screen(nsScreen: XCTUnwrap(NSScreen.screens.first))
        let active = InstalledWallpaper()
        screen.installRuntimeSession(active)
        defer { screen.resetRuntimeSession() }
        let fixture = try ParityLifecycleFixture.make()
        defer { fixture.cleanup() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: .main)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let candidate = SceneWallpaperSession(window: window, renderActor: actor, surface: surface)
        WPEParitySceneDriver.remainingForcedLoadFailuresForTesting = 1
        candidate.startAdoptingParityScene(fixture.inputs(surface: surface, actor: actor))
        var capturedFailure = false
        let result = await WallpaperSessionTransaction.prepareAndCommit(
            candidate, to: screen, replacing: active, timeout: .seconds(5), isStillCurrent: { true },
            beforeDiscard: { result in
                XCTAssertEqual(result, .failed)
                XCTAssertNotNil(candidate.loadError)
                XCTAssertNotNil(candidate.runtimeError)
                XCTAssertNotNil(candidate.loadFailureCause)
                XCTAssertNotNil(candidate.wallpaperWindow, "Diagnostics must be captured before cleanup")
                XCTAssertTrue(screen.runtimeSession === active)
                capturedFailure = true
            }
        )
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(capturedFailure)
        XCTAssertTrue(screen.runtimeSession === active)
        XCTAssertEqual(active.cleanupCallCount, 0)
        XCTAssertNil(candidate.wallpaperWindow)
    }

    func testParityReadFailureRemainsExplicitAndRetryCanHealTheSameScene() async throws {
        let fixture = try ParityLifecycleFixture.make()
        defer { fixture.cleanup() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: .main)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let session = SceneWallpaperSession(window: window, renderActor: actor, surface: surface)
        defer { session.cleanup() }
        let entry = fixture.root.appending(path: "scene.json")
        let parked = fixture.root.appending(path: "scene.parked")
        try FileManager.default.moveItem(at: entry, to: parked)
        session.startAdoptingParityScene(fixture.inputs(surface: surface, actor: actor))
        let result = await session.prepareForDisplay(timeout: .seconds(5))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(session.adoptedScene?.renderer, "parity")
        XCTAssertNotNil(session.loadError)
        try FileManager.default.moveItem(at: parked, to: entry)
        await session.retry()
        XCTAssertNil(session.loadError)
        let snapshot = await actor.rendererStateSnapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot).isLoaded)
        XCTAssertNotNil(snapshot?.parity)
    }
}

@MainActor
private final class InstalledWallpaper: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .video
    let summary = WallpaperSessionSummary.notConfigured
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil
    private(set) var cleanupCallCount = 0

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func cleanup() {
        cleanupCallCount += 1
    }
}
#endif
