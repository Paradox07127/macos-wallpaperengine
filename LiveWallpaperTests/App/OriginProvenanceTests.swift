import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

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
