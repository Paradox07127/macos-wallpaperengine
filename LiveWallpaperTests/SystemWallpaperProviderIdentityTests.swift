import Foundation
@testable import LiveWallpaper
import Testing

/// An appex process outlives the bundle it was launched from, so both halves of
/// the fix are covered here: the beat has to say who wrote it, and the writer
/// has to notice when it is no longer the installed build.
@Suite("System wallpaper provider identity")
struct SystemWallpaperProviderIdentityTests {
    private func identity(
        build: String = "42",
        path: String = "/Applications/Loomscreen.app/Contents/Extensions/P.appex",
        pid: Int32 = 0
    ) -> SystemWallpaperProviderIdentity {
        SystemWallpaperProviderIdentity(build: build, bundlePath: path, pid: pid)
    }

    private func beat(provider: SystemWallpaperProviderIdentity?) -> SystemWallpaperHeartbeat {
        SystemWallpaperHeartbeat(
            timestamp: Date(timeIntervalSince1970: 1_760_000_000),
            activeChoiceID: "choice",
            provider: provider
        )
    }

    // MARK: - Stamp comparison

    @Test("A beat from the installed build is ours")
    func matchingStampAccepted() {
        #expect(beat(provider: identity()).isFromProvider(matching: identity()))
    }

    @Test("A beat from a build the app no longer ships is not ours")
    func changedBuildRejected() {
        // The in-place-update case: Sparkle swapped the bundle, the old process
        // kept its 120 s keep-alive running and goes on writing fresh beats.
        #expect(!beat(provider: identity(build: "41")).isFromProvider(matching: identity(build: "42")))
    }

    @Test("A beat from a second copy installed elsewhere is not ours")
    func changedPathRejected() {
        // The observed case: two builds registered for one extension point,
        // one of them out of a throwaway build directory.
        let stale = identity(path: "/private/tmp/LW-dd/Build/Products/Debug/Loomscreen.app/Contents/Extensions/P.appex")
        #expect(!beat(provider: stale).isFromProvider(matching: identity()))
    }

    @Test("An unstamped beat passes — absent must not read as mismatched")
    func unstampedAccepted() {
        // Beats written before the field existed. Rejecting them would report a
        // live extension as dead, which is worse than the bug being fixed.
        #expect(beat(provider: nil).isFromProvider(matching: identity()))
    }

    @Test("No expectation disables the check")
    func noExpectationAccepted() {
        // `bundledProvider()` returns nil when the appex cannot be read (a test
        // host, an unbundled build); the check must not fail closed there.
        #expect(beat(provider: identity(build: "41")).isFromProvider(matching: nil))
    }

    @Test("The stamp survives a JSON round trip, and older JSON still decodes")
    func codingRoundTrip() throws {
        let original = beat(provider: identity(build: "7", pid: 1234))
        let decoded = try JSONDecoder().decode(
            SystemWallpaperHeartbeat.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded.provider == original.provider)

        // A payload predating the field: decoding must succeed with nil, not throw.
        let legacy = Data("""
        {"timestamp":0,"runtimeHealthy":true,"activeChoiceID":"choice"}
        """.utf8)
        let old = try JSONDecoder().decode(SystemWallpaperHeartbeat.self, from: legacy)
        #expect(old.provider == nil)
        #expect(old.activeChoiceID == "choice")
    }

    // MARK: - Self-retirement verdict

    @Test("A process whose build still matches disk keeps running")
    func staleVerdictCurrent() {
        #expect(SystemWallpaperProviderStaleness.verdict(loadedBuild: "9", onDiskBuild: "9") == .current)
        #expect(!SystemWallpaperProviderStaleness.verdict(loadedBuild: "9", onDiskBuild: "9").shouldRetire)
    }

    @Test("A process whose bundle is gone retires")
    func staleVerdictBundleGone() {
        // `build/w5d-dd` and `build/w5d-lite-dd` on 2026-09-01: still running,
        // no longer registered, directories deleted.
        let verdict = SystemWallpaperProviderStaleness.verdict(loadedBuild: "9", onDiskBuild: nil)
        #expect(verdict == .bundleGone)
        #expect(verdict.shouldRetire)
    }

    @Test("A process whose bundle now holds another build retires")
    func staleVerdictBuildChanged() {
        let verdict = SystemWallpaperProviderStaleness.verdict(loadedBuild: "9", onDiskBuild: "10")
        #expect(verdict == .buildChanged(loaded: "9", onDisk: "10"))
        #expect(verdict.shouldRetire)
    }

    // MARK: - Source guards (appex sources never compile into this bundle)

    @Test("The appex checks staleness at both moments it can act on the system's behalf")
    func retirementIsWired() throws {
        let bridge = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCBridge.swift")
        let handler = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCHandler.swift")
        // accept(connection:) — the system is about to put this process to work.
        #expect(bridge.contains("ProviderStaleness.exitIfStale()"))
        // The keep-alive tick — the only guaranteed wake-up of an idle process.
        #expect(handler.contains("ProviderStaleness.exitIfStale()"))
    }

    @Test("The bridge builds its observers on first connection, not on discovery")
    func observersAreDeferred() throws {
        let bridge = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCBridge.swift")
        // WallpaperAgent instantiates every registered provider on each
        // LaunchServices change; a discovery pass with no connection must not
        // leave Darwin/NotificationCenter/IOKit observers behind.
        #expect(bridge.contains("activateObserversIfNeeded()"))
        let initBody = try #require(
            bridge.range(of: "init(store: SharedLibraryStore) {")
                .map { bridge[$0.upperBound...].prefix(400) }
        )
        #expect(!initBody.contains("LibraryChangeObserver("))
        #expect(!initBody.contains("PowerConditionObserver("))
    }
}
