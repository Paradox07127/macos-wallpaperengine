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
    private static func item(id: UInt64 = 7, tags: [String] = [], rating: WorkshopRating? = nil) -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: id, rawTitle: "Fixture", shortDescription: "", creatorID: nil, previewImageURL: nil,
            fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil, rating: rating, tags: tags,
            visibility: .public, isBanned: false,
            steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        )
    }

    /// Set on one drawing display, "Studio".
    private static let studio = NowPlayingBadge(on: [1], among: [StageDisplay(
        id: 1, fingerprint: "Studio", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false,
        name: "Studio", badgeText: "", statusText: "", cover: nil, state: .ok
    )])

    private static func card(
        presentation: BrowsePresentation = .legacy, isRevealed: Bool = false, isInLibrary: Bool = false,
        hasUpdate: Bool = false, inUseBadge: NowPlayingBadge? = nil,
        preferences: GalleryCardPreferences = GalleryCardPreferences(), tags: [String] = [], rating: WorkshopRating? = nil
    ) -> BrowseCard {
        BrowseCard(
            item: item(tags: tags, rating: rating), isInLibrary: isInLibrary, hasUpdate: hasUpdate, inUseBadge: inUseBadge,
            cardPreferences: preferences, reduceMotion: false, presentation: presentation, isRevealed: isRevealed
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

    @Test("The update and in-use badges are part of equality, or EquatableView would swallow the refresh")
    func badgesEnterEquality() {
        #expect(Self.card(hasUpdate: false) != Self.card(hasUpdate: true))
        #expect(Self.card(inUseBadge: nil) != Self.card(inUseBadge: Self.studio))
    }

    @Test("An Edit Desk browse card reads out only the marks it draws")
    func editDeskCardReadsOnlyDrawnMarks() {
        let inLibrary = String(localized: "In Library", bundle: .appLanguage)
        let inUse = String(localized: "Currently in use", bundle: .appLanguage)
        let update = String(localized: "Update available", bundle: .appLanguage)

        let drawn = Self.card(presentation: .editDesk, isInLibrary: true, hasUpdate: true, inUseBadge: Self.studio)
            .accessibilityLabelText
        #expect(drawn.contains(update) && drawn.contains(inUse), "a drawn badge is not read: \(drawn)")
        #expect(!drawn.contains(inLibrary), "the check that Needs Update replaced is still read: \(drawn)")

        let checked = Self.card(presentation: .editDesk, isInLibrary: true).accessibilityLabelText
        let switchedOff = Self.card(
            presentation: .editDesk, isInLibrary: true, preferences: GalleryCardPreferences(showsInLibrary: false)
        ).accessibilityLabelText
        #expect(checked.contains(inLibrary), "the drawn check is not read: \(checked)")
        #expect(!switchedOff.contains(inLibrary), "the check is read with its switch off: \(switchedOff)")

        let blurred = Self.card(
            presentation: .editDesk, isInLibrary: true, hasUpdate: true, inUseBadge: Self.studio, tags: ["Mature"]
        ).accessibilityLabelText
        #expect(![inLibrary, inUse, update].contains { blurred.contains($0) }, "a blurred card draws no marks but reads: \(blurred)")

        let legacy = Self.card(isInLibrary: true).accessibilityLabelText
        #expect(legacy.contains(inLibrary), "the legacy card no longer reads In Library: \(legacy)")
    }

    @Test("An Edit Desk browse card reads only the metadata its info band draws, and a blurred card only its title")
    func editDeskCardReadsOnlyDrawnMetadata() throws {
        let tags = ["Scene", "3840 x 2160"]
        let rating = WorkshopRating.score(0.9, votesUp: 9, votesDown: 1)
        let stars = String(localized: "\(4.5.formatted(.number.precision(.fractionLength(1)))) stars", bundle: .appLanguage)
        let resolution = try #require(BrowseCard.resolutionShortLabel(for: tags))
        let type = WorkshopContentTypeFilter.scene.displayName
        let off = GalleryCardPreferences(showsRating: false, showsResolution: false)

        let switchedOff = Self.card(presentation: .editDesk, preferences: off, tags: tags, rating: rating).accessibilityLabelText
        #expect(!switchedOff.contains(stars), "the rating is read with its switch off: \(switchedOff)")
        #expect(!switchedOff.contains(resolution), "the resolution is read with its switch off: \(switchedOff)")
        #expect(!switchedOff.contains(type), "the Edit Desk card draws no type but reads it: \(switchedOff)")
        let blurred = Self.card(presentation: .editDesk, tags: tags + ["Mature"], rating: rating).accessibilityLabelText
        #expect(blurred == Self.item().title, "a blurred card draws no info band but reads: \(blurred)")

        // Controls: the legacy card reads as before, and switched on the Edit Desk card reads what it draws.
        let legacy = Self.card(preferences: off, tags: tags, rating: rating).accessibilityLabelText
        #expect(legacy.contains(stars) && legacy.contains(type), "the legacy card's reading changed: \(legacy)")
        let switchedOn = Self.card(presentation: .editDesk, tags: tags, rating: rating).accessibilityLabelText
        #expect(switchedOn.contains(stars) && switchedOn.contains(resolution), "a drawn rating or resolution is not read: \(switchedOn)")
    }
}
#endif
