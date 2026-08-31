import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// `HTMLConfig.originKind` decides whether a page renders with the network cut
/// off, and until now it was copied straight out of stored state. A
/// `.lwconfig` is a file the user can be handed, so that made an isolation
/// decision something an imported file gets to make: mark Workshop HTML
/// `.userLocal` and it loads with every remote origin allowed again.
///
/// The rule is one-way. Provenance derived from where the content actually sits
/// can raise isolation, never lower it, so an origin that legitimately records
/// `.workshopImport` for content served out of the app's own cache — a path that
/// looks nothing like `steamapps/` — keeps it.
@MainActor
@Suite("Stored provenance can be raised by the real path, never lowered")
struct OriginProvenanceTests {
    private func workshopFolder(id: String = "1234567890") -> URL {
        URL(fileURLWithPath: "/Users/someone/Library/Steam/steamapps/workshop/content/431960/\(id)")
    }

    private func localFolder() -> URL {
        URL(fileURLWithPath: "/Users/someone/Projects/my-wallpaper")
    }

    @Test("A forged .userLocal is corrected by a Workshop path")
    func forgedUserLocalIsRaised() {
        #expect(
            WPECachedContentResolver.effectiveOriginKind(
                stored: .userLocal,
                sourceFolder: workshopFolder()
            ) == .workshopImport
        )
    }

    @Test("A stored .workshopImport survives a path that does not look like Steam's")
    func storedWorkshopImportIsNotLowered() {
        // The cache root is app-managed and never matches the steamapps layout, so
        // a naive re-derive here would quietly un-isolate every cached wallpaper.
        #expect(
            WPECachedContentResolver.effectiveOriginKind(
                stored: .workshopImport,
                sourceFolder: localFolder()
            ) == .workshopImport
        )
    }

    @Test("Genuinely local content stays local")
    func localContentStaysLocal() {
        #expect(
            WPECachedContentResolver.effectiveOriginKind(
                stored: .userLocal,
                sourceFolder: localFolder()
            ) == .userLocal
        )
    }

    /// A unit test on the helper cannot see a call site that stopped using it.
    @Test("Both resolver paths route provenance through the helper")
    func resolverPathsUseTheHelper() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Infrastructure/Workshop/WPECachedContentResolver.swift"
        )
        let routed = source.components(separatedBy: "Self.effectiveOriginKind(").count - 1
        #expect(routed == 2, "expected both the source-folder and cache web paths to route through the helper")
        #expect(
            !source.contains("originKind: origin.originKind"),
            "a resolver path still copies stored provenance verbatim"
        )
    }
}
