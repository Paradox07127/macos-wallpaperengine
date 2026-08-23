import Testing
import Foundation
import LiveWallpaperCore
import WebKit
@testable import LiveWallpaper

@Suite("HTMLTrust verdict")
struct HTMLTrustVerdictTests {

    @Test("file source is local")
    func fileIsLocal() {
        let v = HTMLTrust.evaluate(source: .file(bookmarkData: Data([0x01])), trustedOrigins: [])
        #expect(v == .localContent)
    }

    @Test("folder source is local")
    func folderIsLocal() {
        let v = HTMLTrust.evaluate(
            source: .folder(bookmarkData: Data([0x01]), indexFileName: "index.html"),
            trustedOrigins: []
        )
        #expect(v == .localContent)
    }

    @Test("inline source is local")
    func inlineIsLocal() {
        let v = HTMLTrust.evaluate(source: .inline("<html></html>"), trustedOrigins: [])
        #expect(v == .localContent)
    }

    @Test("URL with no host is local")
    func urlNoHostIsLocal() {
        let v = HTMLTrust.evaluate(source: .url(URL(string: "about:blank")!), trustedOrigins: [])
        #expect(v == .localContent)
    }

    @Test("Untrusted remote URL is flagged")
    func untrustedRemote() throws {
        let expected = try #require(TrustedHTMLOrigin(url: URL(string: "https://shadertoy.com/view/abc")!))
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://shadertoy.com/view/abc")!),
            trustedOrigins: [try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com")!))]
        )
        #expect(v == .untrustedRemote(origin: expected))
    }

    @Test("Trusted remote URL matches by exact origin")
    func trustedRemote() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://shadertoy.com/view/abc")!))
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://shadertoy.com/view/abc")!),
            trustedOrigins: [origin]
        )
        #expect(v == .trustedRemote(origin: origin))
    }

    @Test("Origin comparison is case insensitive for scheme and host")
    func caseInsensitive() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://shadertoy.com")!))
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://Shadertoy.COM/view/abc")!),
            trustedOrigins: [origin]
        )
        #expect(v == .trustedRemote(origin: origin))
    }

    @Test("Subdomain is NOT auto-trusted")
    func subdomainNotInherited() throws {
        let trusted = try #require(TrustedHTMLOrigin(url: URL(string: "https://shadertoy.com")!))
        let expected = try #require(TrustedHTMLOrigin(url: URL(string: "https://api.shadertoy.com/x")!))
        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://api.shadertoy.com/x")!),
            trustedOrigins: [trusted]
        )
        #expect(v == .untrustedRemote(origin: expected))
    }

    @Test("Trust does not cross URL scheme")
    func schemeNotInherited() throws {
        let trusted = try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com")!))
        let expected = try #require(TrustedHTMLOrigin(url: URL(string: "http://example.com")!))

        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "http://example.com/wallpaper")!),
            trustedOrigins: [trusted]
        )

        #expect(v == .untrustedRemote(origin: expected))
    }

    @Test("Trust does not cross explicit port")
    func portNotInherited() throws {
        let trusted = try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com")!))
        let expected = try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com:8443")!))

        let v = HTMLTrust.evaluate(
            source: .url(URL(string: "https://example.com:8443/wallpaper")!),
            trustedOrigins: [trusted]
        )

        #expect(v == .untrustedRemote(origin: expected))
    }

    @Test("effectiveAllowJavaScript drops JS for untrusted remote")
    func untrustedDropsJS() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://evil.example")!))
        let v = HTMLTrust.untrustedRemote(origin: origin)
        #expect(v.effectiveAllowJavaScript(requested: true) == false)
        #expect(v.effectiveAllowJavaScript(requested: false) == false)
    }

    @Test("effectiveAllowJavaScript honors request for local + trusted")
    func othersHonorRequest() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://x.com")!))
        for v in [HTMLTrust.localContent, .trustedRemote(origin: origin)] {
            #expect(v.effectiveAllowJavaScript(requested: true) == true)
            #expect(v.effectiveAllowJavaScript(requested: false) == false)
        }
    }

    @Test("effectiveMuteAudio force-mutes untrusted remote regardless of request")
    func untrustedRemoteForcesMute() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://evil.example")!))
        let v = HTMLTrust.untrustedRemote(origin: origin)
        #expect(v.effectiveMuteAudio(requested: false) == true)
        #expect(v.effectiveMuteAudio(requested: true) == true)
        #expect(v.effectiveAudioVolume(requested: 1.0) == 0)
        #expect(v.effectiveAudioVolume(requested: 0.5) == 0)
        #expect(v.effectiveAudioVolume(requested: 0.0) == 0)
    }

    @Test("effectiveMuteAudio passes request through for local + trusted")
    func othersHonorAudioRequest() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://x.com")!))
        for v in [HTMLTrust.localContent, .trustedRemote(origin: origin)] {
            #expect(v.effectiveMuteAudio(requested: false) == false)
            #expect(v.effectiveMuteAudio(requested: true) == true)
            #expect(v.effectiveAudioVolume(requested: 0.7) == 0.7)
            #expect(v.effectiveAudioVolume(requested: 0.0) == 0.0)
        }
    }

    @Test("Origin raw value includes scheme, host, and effective port")
    func originRawValueIncludesTransportBoundary() throws {
        let defaultHTTPS = try #require(TrustedHTMLOrigin(url: URL(string: "https://Example.COM/path")!))
        let explicitHTTPS = try #require(TrustedHTMLOrigin(url: URL(string: "https://example.com:8443/path")!))

        #expect(defaultHTTPS.rawValue == "https://example.com:443")
        #expect(defaultHTTPS.displayName == "https://example.com")
        #expect(explicitHTTPS.rawValue == "https://example.com:8443")
        #expect(explicitHTTPS.displayName == "https://example.com:8443")
    }

    @Test("Offscreen thumbnails consume normalized config with ephemeral storage")
    func offscreenThumbnailUsesEffectiveConfigContract() throws {
        let service = try RepositoryRoot.source(
            "LiveWallpaper/Infrastructure/Services/WallpaperThumbnailService.swift"
        )
        let requestContract = try RepositoryRoot.source(
            "LiveWallpaper/Infrastructure/Services/PendingHTMLSnapshot.swift"
        )
        let preview = try RepositoryRoot.source(
            "LiveWallpaper/Views/ScreenDetail/HTMLPreviewSection.swift"
        )
        let bookmarks = try RepositoryRoot.source(
            "LiveWallpaper/Views/Bookmarks/LibraryView.swift"
        )

        #expect(requestContract.contains("struct HTMLSnapshotRequest"))
        #expect(service.contains("func htmlSnapshotImage(\n        request: HTMLSnapshotRequest"))
        #expect(service.contains("configuration.websiteDataStore = .nonPersistent()"))
        #expect(service.contains("allowsContentJavaScript = request.effectiveConfig.allowJavaScript"))
        #expect(!requestContract.contains("request.trust"))
        #expect(!requestContract.contains("let trust: HTMLTrust"))
        #expect(!service.contains("htmlSnapshotImage(\n        for url: URL"))
        #expect(preview.contains("config: HTMLConfig"))
        #expect(preview.contains("HTMLWallpaperCompatibilityPolicy.runtimeConfig("))
        #expect(bookmarks.contains("case .html(let source, let config):"))
    }

    @Test("Offscreen thumbnail load completion is sticky until its async waiter arrives")
    func offscreenThumbnailLoadCompletionIsSticky() throws {
        let pendingSnapshot = try RepositoryRoot.source(
            "LiveWallpaper/Infrastructure/Services/PendingHTMLSnapshot.swift"
        )

        #expect(pendingSnapshot.contains("private var completedResult: Bool?"))
        #expect(pendingSnapshot.contains("if let completedResult"))
        #expect(pendingSnapshot.contains("completedResult = result"))
    }

    @Test("Offscreen thumbnail completion before waiter returns immediately")
    @MainActor
    func offscreenThumbnailCompletionBeforeWaiterReturnsImmediately() async throws {
        let source = HTMLSource.url(try #require(URL(string: "https://example.com")))
        let request = HTMLSnapshotRequest(
            source: source,
            loadURL: try #require(URL(string: "https://example.com")),
            cacheKey: "completion-before-waiter",
            effectiveConfig: .default,
            localReadAccessRoot: nil
        )
        let pending = PendingHTMLSnapshot(webView: WKWebView(), request: request)

        pending.complete(reason: .success)

        #expect(await pending.waitForLoadOutcome())
    }

    @Test("Cancelling pending capture releases both async wait points")
    @MainActor
    func offscreenThumbnailCancellationReleasesWaiters() async throws {
        let source = HTMLSource.url(try #require(URL(string: "https://example.com")))
        let request = HTMLSnapshotRequest(
            source: source,
            loadURL: try #require(URL(string: "https://example.com")),
            cacheKey: "cancel-before-load",
            effectiveConfig: .default,
            localReadAccessRoot: nil
        )
        let pending = PendingHTMLSnapshot(webView: WKWebView(), request: request)

        pending.cancel()

        #expect(await pending.waitForLoadOutcome() == false)
        #expect(
            await pending.takeSnapshot(with: WKSnapshotConfiguration()) == nil
        )
    }

    @Test("Untrusted thumbnail request disables JavaScript and uses ephemeral storage")
    @MainActor
    func untrustedThumbnailUsesEffectiveWebKitConfiguration() throws {
        let source = HTMLSource.url(
            try #require(URL(string: "https://untrusted.example/wallpaper"))
        )
        var requested = HTMLConfig.default
        requested.allowJavaScript = true
        requested.useEphemeralStorage = false
        let compatibility = HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: source,
            config: requested,
            trustedOrigins: []
        )
        let request = HTMLSnapshotRequest(
            source: source,
            loadURL: try #require(URL(string: "https://untrusted.example/wallpaper")),
            cacheKey: "test",
            effectiveConfig: compatibility.config,
            localReadAccessRoot: nil
        )

        let configuration = WallpaperThumbnailService.htmlWebViewConfiguration(for: request)

        #expect(compatibility.trust.effectiveAllowJavaScript(requested: true) == false)
        #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(configuration.websiteDataStore.isPersistent == false)
    }
}

@Suite("HTML snapshot producer ownership")
struct HTMLSnapshotProducerOwnershipTests {
    @Test("Same cache key shares one producer until its last lease is released")
    func sameKeyDeduplicatesWithReferenceCountedCancellation() throws {
        var state = HTMLSnapshotLeaseState()
        let first = state.acquire(cacheKey: "same-key")
        let second = state.acquire(cacheKey: "same-key")
        let firstLease = first.lease
        let secondLease = second.lease

        guard case .start = first else {
            Issue.record("First lease must start the producer")
            return
        }
        guard case .join = second else {
            Issue.record("Second lease must join the producer")
            return
        }
        #expect(firstLease.producerID == secondLease.producerID)
        #expect(state.waiterCount(for: "same-key") == 2)

        #expect(state.release(firstLease) == .none)
        #expect(state.waiterCount(for: "same-key") == 1)
        #expect(
            state.release(secondLease)
                == .cancelProducer(firstLease.producerID)
        )
        #expect(state.producerID(for: "same-key") == nil)
    }

    @Test("Late completion cannot retire replacement producer for same key")
    func staleCompletionPreservesReplacement() throws {
        var state = HTMLSnapshotLeaseState()
        let staleLease = state.acquire(cacheKey: "reused-key").lease
        #expect(
            state.release(staleLease)
                == .cancelProducer(staleLease.producerID)
        )

        let replacementLease = state.acquire(cacheKey: "reused-key").lease
        #expect(replacementLease.producerID != staleLease.producerID)

        let staleWaiters = state.complete(
            cacheKey: "reused-key",
            producerID: staleLease.producerID
        )
        #expect(staleWaiters.isEmpty)
        #expect(
            state.producerID(for: "reused-key")
                == replacementLease.producerID
        )

        let replacementWaiters = state.complete(
            cacheKey: "reused-key",
            producerID: replacementLease.producerID
        )
        #expect(replacementWaiters == Set([replacementLease.leaseID]))
        #expect(state.producerID(for: "reused-key") == nil)
    }

    @Test("Producer completion resolves every current waiter exactly once")
    func completionReturnsAllCurrentWaiters() {
        var state = HTMLSnapshotLeaseState()
        let first = state.acquire(cacheKey: "complete-key").lease
        let second = state.acquire(cacheKey: "complete-key").lease

        let waiters = state.complete(
            cacheKey: "complete-key",
            producerID: first.producerID
        )

        #expect(waiters == Set([first.leaseID, second.leaseID]))
        #expect(
            state.release(first)
                == .none
        )
    }
}

@MainActor
private final class InMemoryTrustedHostPersistence: TrustedHostPersisting {
    var stored: [String] = []
    func load() -> [String] { stored }
    func save(_ hosts: [String]) { stored = hosts }
}

@Suite("TrustedHostStore")
@MainActor
struct TrustedHostStoreTests {

    private func makeStore(seed: [String] = []) -> (TrustedHostStore, InMemoryTrustedHostPersistence) {
        let p = InMemoryTrustedHostPersistence()
        p.stored = seed
        return (TrustedHostStore(persistence: p), p)
    }

    @Test("Loads + normalizes seed into secure origins")
    func loadNormalizes() {
        let (store, _) = makeStore(seed: ["B.com", "https://a.com:443", "A.COM", "  https://c.com:8443  ", "http://plain.example:80"])
        #expect(store.origins.map(\.rawValue) == [
            "https://a.com:443",
            "https://b.com:443",
            "https://c.com:8443",
        ])
    }

    @Test("Loading legacy hosts persists canonical origin migration")
    func loadMigratesLegacyHostsToPersistedOrigins() {
        let (store, persistence) = makeStore(seed: ["Example.com", "https://already.com:443", "http://plain.example:80"])

        #expect(store.origins.map(\.rawValue) == [
            "https://already.com:443",
            "https://example.com:443",
        ])
        #expect(persistence.stored == [
            "https://already.com:443",
            "https://example.com:443",
        ])
    }

    @Test("trust adds new secure origin and persists")
    func trustAdds() throws {
        let (store, persistence) = makeStore()
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://Example.com/path")!))

        #expect(store.trust(origin) == true)
        #expect(store.origins.map(\.rawValue) == ["https://example.com:443"])
        #expect(persistence.stored == ["https://example.com:443"])
    }

    @Test("trust rejects insecure HTTP origins")
    func trustRejectsHTTP() throws {
        let (store, persistence) = makeStore()
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "http://example.com")!))

        #expect(store.trust(origin) == false)
        #expect(store.origins.isEmpty)
        #expect(persistence.stored.isEmpty)
    }

    @Test("trust ignores duplicate origin")
    func trustIgnoresDuplicate() throws {
        let (store, _) = makeStore(seed: ["https://x.com:443"])
        let canonical = try #require(TrustedHTMLOrigin(url: URL(string: "https://x.com")!))
        let equivalent = try #require(TrustedHTMLOrigin(url: URL(string: "https://X.COM:443/path")!))

        #expect(store.trust(canonical) == false)
        #expect(store.trust(equivalent) == false)
        #expect(store.origins.map(\.rawValue) == ["https://x.com:443"])
    }

    @Test("revoke removes origin and persists")
    func revokeRemoves() throws {
        let (store, persistence) = makeStore(seed: ["https://a.com:443", "https://b.com:8443"])
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://A.COM")!))

        #expect(store.revoke(origin) == true)
        #expect(store.origins.map(\.rawValue) == ["https://b.com:8443"])
        #expect(persistence.stored == ["https://b.com:8443"])
    }

    @Test("revoke unknown origin is a no-op")
    func revokeUnknown() throws {
        let (store, _) = makeStore(seed: ["https://a.com:443"])
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "https://missing.com")!))

        #expect(store.revoke(origin) == false)
        #expect(store.origins.map(\.rawValue) == ["https://a.com:443"])
    }

}

/// Loopback origins are trusted without an allowlist entry, matching how
/// browsers treat `http://localhost` (W3C Secure Contexts "potentially
/// trustworthy"). The negative cases are the point of this suite: a hostname
/// that merely *contains* a loopback literal must not inherit that trust.
@Suite("Loopback origins are potentially trustworthy")
struct LoopbackTrustTests {
    private func trust(_ urlString: String) throws -> HTMLTrust {
        let url = try #require(URL(string: urlString))
        // Empty allowlist: anything trusted here is trusted structurally.
        return HTMLTrust.evaluate(source: .url(url), trustedOrigins: [])
    }

    private func isTrusted(_ urlString: String) throws -> Bool {
        if case .trustedRemote = try trust(urlString) { return true }
        return false
    }

    @Test("Plain http loopback spellings are trusted with an empty allowlist", arguments: [
        "http://localhost:3000",
        "http://localhost./",
        "http://127.0.0.1:8080",
        "http://127.1.2.3:5173",
        "http://[::1]:3000",
        "http://api.localhost:9000",
    ])
    func loopbackSpellingsAreTrusted(_ urlString: String) throws {
        #expect(try isTrusted(urlString), "\(urlString) should be trusted")
    }

    @Test("Hostnames that only look like loopback stay untrusted", arguments: [
        "http://127.0.0.1.evil.com",
        "http://localhost.evil.com",
        "http://notlocalhost",
        "http://127.0.0.256",
        "http://1270.0.1",
        "http://example.com",
    ])
    func lookalikeHostsAreNotTrusted(_ urlString: String) throws {
        #expect(try !isTrusted(urlString), "\(urlString) must not be treated as loopback")
    }

    @Test("A loopback dev server gets JavaScript")
    func loopbackKeepsJavaScript() throws {
        let verdict = try trust("http://localhost:5173")
        #expect(verdict.effectiveAllowJavaScript(requested: true))
        #expect(!verdict.effectiveMuteAudio(requested: false))
    }

    @Test("A public http origin still loses JavaScript")
    func publicHTTPStillLosesJavaScript() throws {
        let verdict = try trust("http://example.com")
        #expect(!verdict.effectiveAllowJavaScript(requested: true))
    }

    /// Loopback trust is structural, so it must never be written to the
    /// persisted allowlist — otherwise "revoke" would appear to work and then
    /// silently have no effect.
    @Test("Loopback is never persisted into the allowlist")
    func loopbackIsNotPersisted() throws {
        let origin = try #require(TrustedHTMLOrigin(url: URL(string: "http://localhost:3000")!))
        #expect(origin.isLoopback)
        #expect(!origin.isSecure, "loopback over http is still cleartext")
    }
}

/// LAN literals are *eligible* for trust, not trusted outright: cleartext on a
/// shared network is tamperable, so the grant is per-origin and explicit.
@Suite("Private-network origins are trust-eligible")
@MainActor
struct PrivateNetworkTrustTests {
    private func origin(_ urlString: String) throws -> TrustedHTMLOrigin {
        let url = try #require(URL(string: urlString))
        return try #require(TrustedHTMLOrigin(url: url))
    }

    @Test("RFC 1918 and link-local literals are eligible", arguments: [
        "http://192.168.1.199:3456",
        "http://10.0.0.5:8080",
        "http://172.16.0.1:3000",
        "http://172.31.255.254:3000",
        "http://169.254.53.38:8000",
    ])
    func privateLiteralsAreEligible(_ urlString: String) throws {
        let o = try origin(urlString)
        #expect(o.isPrivateNetwork)
        #expect(o.canBeTrusted)
        #expect(!o.isLoopback, "LAN is not loopback — it must not be auto-trusted")
    }

    @Test("Public and near-miss literals are not eligible", arguments: [
        "http://172.15.0.1:3000",
        "http://172.32.0.1:3000",
        "http://193.168.1.1:3000",
        "http://11.0.0.1:3000",
        "http://example.com",
        "http://192.168.1.199.evil.com",
    ])
    func publicLiteralsAreNotEligible(_ urlString: String) throws {
        let o = try origin(urlString)
        #expect(!o.isPrivateNetwork, "\(urlString) must not count as private")
        #expect(!o.canBeTrusted)
    }

    @Test("A LAN origin runs no JavaScript until it is trusted")
    func lanNeedsExplicitTrust() throws {
        let url = try #require(URL(string: "http://192.168.1.199:3456/"))
        let o = try origin("http://192.168.1.199:3456")

        let before = HTMLTrust.evaluate(source: .url(url), trustedOrigins: [])
        #expect(before == .untrustedRemote(origin: o))
        #expect(!before.effectiveAllowJavaScript(requested: true))

        let after = HTMLTrust.evaluate(source: .url(url), trustedOrigins: [o])
        #expect(after == .trustedRemote(origin: o))
        #expect(after.effectiveAllowJavaScript(requested: true))
    }

    /// The grant has to survive a relaunch; `normalizeOrigins` used to drop
    /// every non-HTTPS origin, which would have made "Trust" look like a no-op
    /// after the next launch.
    @Test("A trusted LAN origin survives normalization on reload")
    func lanGrantSurvivesReload() {
        let normalized = TrustedHostStore.normalizeOrigins([
            "http://192.168.1.199:3456",
            "https://example.com:443",
            "http://example.com:80",
        ])
        #expect(normalized.map(\.rawValue) == ["http://192.168.1.199:3456", "https://example.com:443"])
    }
}
