#if !LITE_BUILD
import Testing
@testable import LiveWallpaper

/// Two facets may point at the same scroll anchor (SteamCMD and Steam sign-in
/// both live in the connection section), but a ForEach with duplicate ids is
/// undefined behavior — identity must not be the anchor.
@Suite("Workshop setup facet identity")
struct WorkshopSetupFacetIdentityTests {
    @Test("Facets sharing a scroll anchor keep distinct ids")
    func sharedAnchorDistinctIds() {
        let steamCMD = WorkshopSetupFacet(
            key: "steamcmd",
            anchor: .workshopConnection,
            title: "SteamCMD",
            state: .ready
        )
        let signIn = WorkshopSetupFacet(
            key: "steamSignIn",
            anchor: .workshopConnection,
            title: "Steam sign-in",
            state: .ready
        )

        #expect(steamCMD.id != signIn.id)
    }
}
#endif
