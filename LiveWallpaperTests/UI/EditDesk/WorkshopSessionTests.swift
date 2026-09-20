#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Edit Desk workshop session", .serialized)
struct WorkshopSessionTests {
    /// Which preparation steps ran, in the order the session drove them.
    @MainActor
    private final class Steps {
        var order: [String] = []
    }

    /// Keyed browsing against an empty keychain slot: every request fails as `missingAPIKey`
    /// before it reaches the network, so a deep-link search cannot escape the test.
    private func offlineServices(in directory: URL) -> WorkshopServices {
        let keychain = WorkshopKeychainStore(directory: directory, slot: WorkshopKeychainSlotSpy().slot())
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let services = WorkshopServices(
            keychain: keychain, cache: cache,
            queryService: WorkshopQueryService(keychain: keychain, cache: cache, countIssuedRequest: {})
        )
        services.hasWebAPIKey = true
        return services
    }

    private func makeSession(defaults: UserDefaults, in directory: URL, steps: Steps) -> WorkshopSession {
        let manager = DeferredWallpaperApplying()
        return WorkshopSession(
            browse: BrowseViewModel(services: offlineServices(in: directory), defaults: defaults),
            deferredApply: DeferredApplyCoordinator(
                manager: manager,
                router: ApplyRouter(
                    manager: manager,
                    bookmarks: BookmarkStore(persistence: DeferredBookmarkPersistence()),
                    sceneCapable: true
                )
            ),
            confirmReadiness: { steps.order.append("readiness") },
            ingestDownloads: { steps.order.append("ingest") }
        )
    }

    private func withSession(
        _ name: String, _ body: @MainActor (WorkshopSession, Steps) async throws -> Void
    ) async throws {
        let suite = try TestScratch.defaultsSuite(name)
        defer { suite.discard() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let steps = Steps()
        try await body(makeSession(defaults: suite.defaults, in: directory, steps: steps), steps)
    }

    @Test("The browse model and the deferred-apply owner outlive a page switch")
    func longLivedCollaboratorsKeepTheirIdentity() async throws {
        try await withSession("workshop.session.identity") { session, _ in
            let browse = session.browse
            let coordinator = session.deferredApply
            let reveal = session.matureReveal
            session.matureReveal.reveal(42)
            // What a page switch may not do: hand back a fresh model, page 1 and no reveals.
            #expect(session.browse === browse)
            #expect(session.deferredApply === coordinator)
            #expect(session.matureReveal === reveal)
            #expect(session.matureReveal.isRevealed(42))
        }
    }

    @Test("Readiness is confirmed before the ingest scan reads it", .timeLimit(.minutes(1)))
    func preparationStepsRunInOrder() async throws {
        try await withSession("workshop.session.order") { session, steps in
            await session.prepareDownloads()
            #expect(steps.order == ["readiness", "ingest"])
        }
    }

    @Test("Coming back to the page runs the preparation again", .timeLimit(.minutes(1)))
    func preparationIsNotSwallowedByAFlag() async throws {
        try await withSession("workshop.session.rerun") { session, steps in
            await session.prepareDownloads()
            await session.prepareDownloads()
            #expect(steps.order == ["readiness", "ingest", "readiness", "ingest"])
        }
    }

    @Test("A pending deep link is consumed exactly once")
    func deepLinkIsOneShot() async throws {
        try await withSession("workshop.session.deeplink") { session, _ in
            #expect(session.consumePendingDeepLink() == nil, "nothing is waiting yet")
            WorkshopDeepLink.requestSearch("nebula")
            #expect(session.consumePendingDeepLink() == "nebula")
            #expect(session.consumePendingDeepLink() == nil, "a second consumer must not re-run the search")
        }
    }
}

@MainActor
@Suite("Workshop browse card equality")
struct BrowseCardEqualityTests {
    private static func item(id: UInt64 = 7) -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: id, rawTitle: "Fixture", shortDescription: "", creatorID: nil, previewImageURL: nil,
            fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil, rating: nil, tags: [],
            visibility: .public, isBanned: false,
            steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        )
    }

    private static func card(presentation: BrowsePresentation = .legacy, isRevealed: Bool = false) -> BrowseCard {
        BrowseCard(
            item: item(), cardPreferences: GalleryCardPreferences(), reduceMotion: false,
            presentation: presentation, isRevealed: isRevealed
        )
    }

    @Test("Two cards with the same inputs compare equal")
    func identicalInputsAreEqual() {
        #expect(Self.card() == Self.card())
    }

    @Test("The presentation is part of equality")
    func presentationEntersEquality() {
        #expect(Self.card(presentation: .legacy) != Self.card(presentation: .editDesk))
    }

    @Test("A reveal is part of equality, or EquatableView would swallow the refresh")
    func revealEntersEquality() {
        #expect(Self.card(isRevealed: false) != Self.card(isRevealed: true))
    }
}
#endif
