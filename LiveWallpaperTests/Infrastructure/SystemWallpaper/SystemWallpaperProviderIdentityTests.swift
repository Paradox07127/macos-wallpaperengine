import Foundation
@testable import LiveWallpaper
import Testing

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
        #expect(!beat(provider: identity(build: "41")).isFromProvider(matching: identity(build: "42")))
    }

    @Test("A beat from a second copy installed elsewhere is not ours")
    func changedPathRejected() {
        let stale = identity(path: "/private/tmp/LW-dd/Build/Products/Debug/Loomscreen.app/Contents/Extensions/P.appex")
        #expect(!beat(provider: stale).isFromProvider(matching: identity()))
    }

    @Test("An unstamped beat is rejected — it is the pre-stamp process still running")
    func unstampedRejected() {
        #expect(!beat(provider: nil).isFromProvider(matching: identity()))
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

    // MARK: - Idle retirement (zero surfaces only)

    @Test("An idle process at the path the installed app declares keeps running")
    func idleVerdictKeepsDeclaredPath() {
        let own = "/Applications/Loomscreen.app/Contents/Extensions/P.appex"
        let verdict = SystemWallpaperProviderStaleness.idleVerdict(
            .current, ownBundlePath: own, declared: identity(path: own)
        )
        #expect(verdict == .current)
        #expect(!verdict.shouldRetire)
    }

    @Test("Path comparison survives the /private and trailing-slash spellings")
    func idleVerdictNormalizesPaths() {
        let verdict = SystemWallpaperProviderStaleness.idleVerdict(
            .current,
            ownBundlePath: "/private/tmp/Build/Loomscreen.app/Contents/Extensions/P.appex/",
            declared: identity(path: "/tmp/Build/Loomscreen.app/Contents/Extensions/P.appex")
        )
        #expect(verdict == .current)
    }

    @Test("An idle process at another path than the declared one retires")
    func idleVerdictRetiresSuperseded() {
        let declared = "/Applications/Loomscreen.app/Contents/Extensions/P.appex"
        let verdict = SystemWallpaperProviderStaleness.idleVerdict(
            .current,
            ownBundlePath: "/Users/me/Downloads/Loomscreen.app/Contents/Extensions/P.appex",
            declared: identity(path: declared)
        )
        #expect(verdict == .supersededByDeclared(declaredPath: declared))
        #expect(verdict.shouldRetire)
    }

    @Test("No declaration means the bundle verdict alone decides")
    func idleVerdictWithoutDeclaration() {
        let own = "/Applications/Loomscreen.app/Contents/Extensions/P.appex"
        #expect(SystemWallpaperProviderStaleness.idleVerdict(.current, ownBundlePath: own, declared: nil) == .current)
        let stale = SystemWallpaperProviderStaleness.idleVerdict(.bundleGone, ownBundlePath: own, declared: nil)
        #expect(stale == .bundleGone)
        // A stale bundle wins over a matching declaration: the build on disk is not the one running.
        let changed = SystemWallpaperProviderStaleness.idleVerdict(
            .buildChanged(loaded: "9", onDisk: "10"), ownBundlePath: own, declared: identity(path: own)
        )
        #expect(changed == .buildChanged(loaded: "9", onDisk: "10"))
    }

    @Test("The appex runs the idle verdict when the Agent disconnects — the only moment before RunningBoard suspends it")
    func idleRetirementIsWired() throws {
        let bridge = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCBridge.swift")
        let handler = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCHandler.swift")
        let staleness = try RepositoryRoot.source("SystemWallpaperProvider/ProviderStaleness.swift")
        let invalidation = try #require(bridge.range(of: "connection.invalidationHandler = {"))
        #expect(bridge[invalidation.upperBound...].prefix(700).contains("WallpaperXPCHandler.evaluateIdleRetirement("))
        #expect(handler.contains("ProviderStaleness.exitIfIdleAndSuperseded("))
        // Never while the Agent still holds a proxy: it keeps using it until its own 5-minute disconnection and every call errors instead of relaunching.
        #expect(staleness.contains("guard surfaces == 0, !connected else {"))
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
        #expect(bridge.contains("activateObserversIfNeeded()"))
        let initBody = try #require(
            bridge.range(of: "init(store: SharedLibraryStore) {")
                .map { bridge[$0.upperBound...].prefix(400) }
        )
        #expect(!initBody.contains("LibraryChangeObserver("))
        #expect(!initBody.contains("PowerConditionObserver("))
    }
}
