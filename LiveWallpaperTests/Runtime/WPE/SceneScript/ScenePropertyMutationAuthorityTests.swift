#if !LITE_BUILD
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("Scene property mutation latest-intent authority")
struct ScenePropertyMutationAuthorityTests {
    @Test("A no-op explicit selection rejects a patch queued before renderer admission")
    func noOpExplicitSelectionRejectsQueuedPatch() async {
        let authority = ScenePropertyMutationAuthority()
        let editToken = authority.advance()
        let gate = ScenePropertyMutationAdmissionGate()
        var rendererMutationCount = 0
        var persistedDescriptor = "original"

        let queuedPatch = Task { @MainActor in
            // Side-effect-free renderer preflight has returned; suspend before
            // updateSceneDescriptor's final MainActor CAS/persistence turn.
            guard authority.isCurrent(editToken) else { return false }
            await gate.suspend()
            guard authority.isCurrent(editToken) else { return false }
            persistedDescriptor = "stale-edit"
            rendererMutationCount += 1
            return true
        }

        await gate.waitUntilSuspended()
        // Models beginExplicitWallpaperSelection's synchronous advancement even
        // when the chosen wallpaper takes its unchanged/no-op fast path.
        authority.advance()
        await gate.resume()

        #expect(await queuedPatch.value == false)
        #expect(rendererMutationCount == 0)
        #expect(persistedDescriptor == "original")
    }

    @Test("An in-place configuration write rejects a patch queued before renderer admission")
    func inPlaceConfigurationWriteRejectsQueuedPatch() async {
        let authority = ScenePropertyMutationAuthority()
        let editToken = authority.advance()
        let gate = ScenePropertyMutationAdmissionGate()
        var rendererMutationCount = 0
        var persistedDescriptor = "original"

        let queuedPatch = Task { @MainActor in
            // Side-effect-free renderer preflight has returned; suspend before
            // updateSceneDescriptor's final MainActor CAS/persistence turn.
            guard authority.isCurrent(editToken) else { return false }
            await gate.suspend()
            guard authority.isCurrent(editToken) else { return false }
            persistedDescriptor = "stale-edit"
            rendererMutationCount += 1
            return true
        }

        await gate.waitUntilSuspended()
        // Models both ScreenManager.saveConfiguration and
        // PlaybackCoordinator.save advancing intent before store.save.
        authority.advance()
        await gate.resume()

        #expect(await queuedPatch.value == false)
        #expect(rendererMutationCount == 0)
        #expect(persistedDescriptor == "original")
    }
}

private actor ScenePropertyMutationAdmissionGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        suspensionWaiters.forEach { $0.resume() }
        suspensionWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        isSuspended = false
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
#endif
