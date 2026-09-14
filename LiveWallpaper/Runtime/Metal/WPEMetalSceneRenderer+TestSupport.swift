#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import MetalKit
import os

#if DEBUG
extension WPEMetalSceneRenderer {
    @MainActor var nsView: NSView { debugSurface!.mtkView }

    /// Test-only strong hold on the lazily-created main-backed actor, so the weak `displayActor` back-link stays alive across the whole test (otherwise the deferred-audio / static-reload tails would silently no-op after `load()`).
    private static let debugActorsLock = OSAllocatedUnfairLock<[ObjectIdentifier: WPEDisplayRenderActor]>(initialState: [:])

    @MainActor
    private func debugAdoptedActor() async -> WPEDisplayRenderActor {
        if let actor = displayActor { return actor }
        let actor = WPEDisplayRenderActor(backing: .main)
        let key = ObjectIdentifier(self)
        Self.debugActorsLock.withLock { $0[key] = actor }
        await actor.adopt(WPERendererHandoff(renderer: self).renderer)
        return actor
    }

    @MainActor
    func load() async throws {
        try await debugAdoptedActor().load()
    }

    @MainActor
    func reload() async throws {
        try await debugAdoptedActor().reload()
    }

    func releaseDebugActorIfNeeded() {
        let key = ObjectIdentifier(self)
        Self.debugActorsLock.withLock { $0[key] = nil }
    }
}
#endif
#endif
