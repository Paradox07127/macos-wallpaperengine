#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import Metal
import os
import Testing

@Suite("Scene session retirement")
@MainActor
struct SceneSessionRetirementTests {
    @Test("A teardown wedged on the render thread cannot hold off the thread's shutdown past the retirement deadline",
          .timeLimit(.minutes(1)))
    func wedgedTeardownStillShutsDownByTheDeadline() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: .renderThread)
        let window = NSWindow(contentRect: surface.mtkView.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let session = SceneWallpaperSession(window: window, renderActor: actor, surface: surface,
                                            retirementDeadline: .milliseconds(200))
        // Stands in for a native wait on the render thread that never returns, such as a stalled GPU completion.
        let release = DispatchSemaphore(value: 0)
        let wedged = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
            await actor.run { _ in
                wedged.withLock { $0 = true }
                release.wait()
            }
        }
        defer { release.signal() }
        try await Self.poll("the render thread wedged") { wedged.withLock { $0 } }

        session.cleanup()
        let retirement = try #require(session.retirement)
        let joined = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        Task {
            let result = await retirement.value
            joined.withLock { $0 = result }
        }

        try await Self.poll("the retirement ended") { joined.withLock { $0 } != nil }
        #expect(joined.withLock { $0 } == false, "a wedged render thread reported a clean join")
    }

    @Test("A teardown that runs inline after the render thread stopped never blocks the main thread",
          .timeLimit(.minutes(1)))
    func inlineTeardownAfterShutdownStaysOffTheMainThread() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: .renderThread)
        let window = NSWindow(contentRect: surface.mtkView.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let session = SceneWallpaperSession(window: window, renderActor: actor, surface: surface)
        _ = await actor.shutdown()
        // With the thread stopped this job runs inline on a cooperative thread and holds the post-shutdown lock.
        let release = DispatchSemaphore(value: 0)
        let holding = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
            await actor.run { _ in
                holding.withLock { $0 = true }
                release.wait()
            }
        }
        defer { release.signal() }
        try await Self.poll("the post-shutdown job took the lock") { holding.withLock { $0 } }

        session.cleanup()
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            release.signal()
        }
        // Spans the whole hold so the drain reaching teardown at any point inside it is observed.
        var longestStall = Duration.zero
        for _ in 0 ..< 30 {
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(50))
            longestStall = max(longestStall, ContinuousClock.now - start)
        }
        #expect(longestStall < .milliseconds(500), "the main thread waited on an inline teardown for \(longestStall)")
        _ = await session.retirement?.value
    }

    private static func poll(_ label: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for: \(label)")
    }
}
#endif
