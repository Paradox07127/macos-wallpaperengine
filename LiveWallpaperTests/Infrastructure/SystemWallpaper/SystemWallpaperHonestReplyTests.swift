import Foundation
import Testing

@testable import LiveWallpaper

@Suite("System wallpaper honest reply")
struct SystemWallpaperHonestReplyTests {

    private func handler() throws -> String {
        try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCHandler.swift")
    }

    /// One member's full text, sliced to the closing brace at member indentation:
    /// a fixed-length prefix would shrink as the comment above the code grows.
    private func member(_ source: String, from marker: String) throws -> String {
        let start = try #require(source.range(of: marker), "no \(marker) in source")
        let body = source[start.lowerBound...]
        guard let end = body.range(of: "\n    }\n") else { return String(body) }
        return String(body[..<end.upperBound])
    }

    // MARK: - Private layout

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

    @Test("A removal against an unreadable manifest fails instead of reporting the id already gone")
    func removalOnUnreadableManifestFails() throws {
        let body = try member(try handler(), from: "func removeChoiceRequest")
        #expect(
            body.contains("loadManifestIfReadable()"),
            "a damaged manifest reads as an empty library, and 'not in the library' replies success"
        )
        #expect(!body.contains("from: store.loadManifest()"))
    }

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
