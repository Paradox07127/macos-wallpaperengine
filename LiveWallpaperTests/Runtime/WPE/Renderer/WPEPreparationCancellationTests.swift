#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@MainActor
@Suite("WPE preparation cancellation")
struct WPEPreparationCancellationTests {
    @Test("Cancelled parity preparation leaves no load fault and the next load succeeds")
    func cancelledLoadDoesNotPublishFailureDiagnostics() async throws {
        let fixture = try ParityLifecycleFixture.make()
        defer { fixture.cleanup() }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        let actor = WPEDisplayRenderActor(backing: .main)
        defer { Task { await actor.teardownRenderer(); await actor.shutdown() } }
        try await actor.adoptParity(fixture.inputs(surface: surface, actor: actor))
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await actor.load() }
        }
        await worker.value
        let cancelled = try #require(await actor.rendererStateSnapshot())
        #expect(!cancelled.isLoaded)
        #expect(cancelled.parity == nil)
        #expect(cancelled.loadDiagnostics == nil)
        try await actor.load()
        let loaded = try #require(await actor.rendererStateSnapshot())
        #expect(loaded.isLoaded)
        #expect(loaded.parity != nil)
        #expect(loaded.loadDiagnostics == nil)
    }
}
#endif
