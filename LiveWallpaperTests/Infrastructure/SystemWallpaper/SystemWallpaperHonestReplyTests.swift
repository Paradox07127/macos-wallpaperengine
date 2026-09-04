import Foundation
import Testing

@testable import LiveWallpaper

/// The appex answers the Agent over XPC and answers the app over a heartbeat
/// file. Both channels only carry "success" and "failure" — there is no third
/// value for "I replied but produced nothing", so every path that cannot do
/// what it was asked has to say so. These are source-text guards, in the style
/// of `SystemWallpaperGuardTests`: the appex sources compile into
/// `SystemWallpaperProvider` / …`Lite` only, never into this bundle.
@Suite("System wallpaper honest reply")
struct SystemWallpaperHonestReplyTests {

    private func handler() throws -> String {
        try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCHandler.swift")
    }

    /// One member's full text: from its declaration to the closing brace at
    /// member indentation. A fixed-length prefix silently shrinks whenever a
    /// comment above the code grows, which reads as a passing guard.
    private func member(_ source: String, from marker: String) throws -> String {
        let start = try #require(source.range(of: marker), "no \(marker) in source")
        let body = source[start.lowerBound...]
        guard let end = body.range(of: "\n    }\n") else { return String(body) }
        return String(body[..<end.upperBound])
    }

    // MARK: - Private layout

    /// `verifyRuntimeLayout` only proves the private classes still exist. A
    /// class that keeps its name but changes the layout we raw-write, or a
    /// Codable shape the Agent stops decoding, fails one call at a time inside
    /// the factories — which used to reply `(nil, nil)` right next to a
    /// `runtimeHealthy: true` heartbeat. The panel is then blank or unusable
    /// while the app reports the extension is fine.
    @Test("An object the private layout would not let us build is reported, not replied as success")
    func unbuildablePrivateObjectIsReportedUnhealthy() throws {
        let source = try handler()
        let report = try member(source, from: "private func reportUnbuildable")
        #expect(
            report.contains("runtimeHealthy: false"),
            "the health bit has to mean 'this call really produced the object'"
        )
        for site in ["func provideSettingsViewModels", "func acquire"] {
            let body = try member(source, from: site)
            #expect(
                body.contains("reportUnbuildable("),
                "\(site) still answers with a healthy nothing when the factory returns nil"
            )
        }
    }

    // MARK: - Removal

    /// `loadManifest()` collapses "damaged" into "empty library", so a removal
    /// against a corrupt manifest found no such id and replied success while
    /// the files stayed on disk. The app's own `remove(itemID:)` throws
    /// `manifestUnreadable` in exactly this case; the two sides must not
    /// disagree about whether the library is readable.
    @Test("A removal against an unreadable manifest fails instead of reporting the id already gone")
    func removalOnUnreadableManifestFails() throws {
        let body = try member(try handler(), from: "func removeChoiceRequest")
        #expect(
            body.contains("loadManifestIfReadable()"),
            "a damaged manifest reads as an empty library, and 'not in the library' replies success"
        )
        #expect(!body.contains("from: store.loadManifest()"))
    }

    /// The identifier is parsed out of the opaque request's description. When
    /// that format changes we delete nothing — replying success then leaves the
    /// panel and the disk disagreeing with no error anywhere.
    @Test("A removal request we could not parse replies an error")
    func unparsableRemovalRepliesError() throws {
        let body = try member(try handler(), from: "func removeChoiceRequest")
        let logged = try #require(
            body.range(of: "removeChoiceRequest without an identifier"),
            "the unparsable branch is gone — this guard no longer measures anything"
        )
        #expect(
            String(body[logged.upperBound...].prefix(200)).contains("reply(NSError("),
            "replying nil means 'nothing left to remove', which is not what happened"
        )
    }

    // MARK: - Surface keys

    /// An acquire without a WallpaperID was filed under the *request*'s
    /// `directDisplayID` while update and invalidate looked the surface up by
    /// the *id*'s — so that surface's update landed on every display and its
    /// invalidate never found anything to tear down, leaking the remote context
    /// into the Agent's composite tree.
    @Test("Acquire, update and invalidate derive the surface key the same way")
    func surfaceKeyIsDerivedOneWay() throws {
        let source = try handler()
        for site in ["func acquire", "func update", "func invalidate"] {
            let body = try member(source, from: site)
            #expect(
                body.contains("Self.surfaceUUID("),
                "\(site) derives its own key, so the three can disagree"
            )
            #expect(
                !body.contains("MirrorProbe.firstUUID("),
                "\(site) still probes the id itself instead of going through the shared ladder"
            )
        }
    }

    // MARK: - Heartbeat

    /// A wallpaper that is simply playing sends us nothing: no acquire, no
    /// settings request, and `update` only on a state change. The beat went
    /// stale after `heartbeatFreshnessInterval` and the app fell back to
    /// "Ready — pick one" under a wallpaper that was visibly running.
    @MainActor
    @Test("A wallpaper that just plays keeps its own heartbeat fresh")
    func heartbeatKeepsItselfFresh() throws {
        // Read out here: `#expect`'s autoclosure is nonisolated, so the
        // main-actor constant cannot be touched inside it.
        let window = WallpaperExportService.heartbeatFreshnessInterval
        let source = try handler()
        let sync = try member(source, from: "private static func syncHeartbeatKeepAlive")
        #expect(
            sync.contains("makeTimerSource"),
            "nothing re-publishes the beat while a surface is only playing"
        )
        let digits = try #require(
            source.range(of: "heartbeatKeepAliveInterval = ").map {
                Int(source[$0.upperBound...].prefix(while: \.isNumber))
            } ?? nil,
            "no keep-alive interval to compare against the app's window"
        )
        #expect(
            TimeInterval(digits) < window,
            "a refresh at or past the app's freshness window still reads as stale"
        )
        // Control: an arm with no disarm would keep an idle appex ticking after
        // its last surface went away.
        #expect(sync.contains("cancel()"))
    }

    // MARK: - Panel refresh

    /// `invalidateSnapshots` only re-renders the tiles the panel already holds.
    /// A publish or a delete in the app therefore did not reach an open
    /// wallpaper panel until it was closed and reopened.
    @Test("A library change pushes the new view models, not only a snapshot invalidation")
    func libraryChangePushesViewModels() throws {
        let source = try handler()
        let changed = try member(source, from: "func libraryDidChange")
        #expect(
            changed.contains("pushSettingsViewModels()"),
            "an added or removed item needs the model list, not a re-render of the old one"
        )
        let push = try member(source, from: "private func pushSettingsViewModels")
        #expect(push.contains("proxy.updateSettingsViewModels("))
    }

    // MARK: - Wire allowlist

    /// Every `id`-typed argument needs its classes declared or NSXPC drops the
    /// message before it reaches the stub — the Agent's call then never gets a
    /// reply at all, which is worse than the stub's "nothing to do".
    @Test("Every selector taking an opaque choice id is allowlisted")
    func choiceIDSelectorsAreAllowlisted() throws {
        let bridge = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCBridge.swift")
        let start = try #require(bridge.range(of: "let argumentSelectors"))
        let end = try #require(bridge.range(of: "\n        ]\n", range: start.upperBound ..< bridge.endIndex))
        let list = String(bridge[start.upperBound ..< end.lowerBound])
        for selector in ["download(choiceID:reply:)", "pauseDownload(for:reply:)",
                         "cancelDownload(for:reply:)", "resumeDownload(for:reply:)",
                         "removeDownload(for:reply:)"] {
            #expect(
                list.contains(selector),
                "\(selector) carries a private choice-ID object the interface was never told about"
            )
        }
    }
}
