import Foundation
import Testing

@Suite("Shared scheme environment contracts")
struct SchemeEnvironmentContractTests {
    private static let diagnosticsScheme =
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper-Diagnostics.xcscheme"

    /// If this scheme stops enabling the checkers it is worse than not existing,
    /// because its name says otherwise.
    @Test("The diagnostics scheme actually enables the checkers it exists for")
    func diagnosticsSchemeEnablesCheckers() throws {
        let document = try XMLDocument(contentsOf: RepositoryRoot.url(Self.diagnosticsScheme), options: [])
        let root = try #require(document.rootElement())
        let launch = try #require(root.elements(forName: "LaunchAction").first)

        #expect(launch.attribute(forName: "disableMainThreadChecker")?.stringValue == "NO")
        #expect(launch.attribute(forName: "disablePerformanceAntipatternChecker")?.stringValue == "NO")

        // Not a Metal scheme: the HUD belongs to the render-path investigation,
        // and leaving it on here would put an overlay on every diagnostics run.
        let launchVariables = launch
            .elements(forName: "EnvironmentVariables")
            .flatMap { $0.elements(forName: "EnvironmentVariable") }
        #expect(launchVariables.allSatisfy {
            $0.attribute(forName: "key")?.stringValue != "MTL_HUD_ENABLED"
        })
    }

    @Test("Profile and Archive use Release without launch diagnostics", arguments: [
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper.xcscheme",
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaperLite.xcscheme",
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper-Diagnostics.xcscheme",
    ])
    func shippingActionsDoNotInheritLaunchEnvironment(relativePath: String) throws {
        let document = try XMLDocument(
            contentsOf: RepositoryRoot.url(relativePath),
            options: []
        )
        let root = try #require(document.rootElement())
        let profile = try #require(root.elements(forName: "ProfileAction").first)

        #expect(profile.attribute(forName: "buildConfiguration")?.stringValue == "Release")
        #expect(profile.attribute(forName: "shouldUseLaunchSchemeArgsEnv")?.stringValue == "NO")
        #expect(profile.elements(forName: "EnvironmentVariables").isEmpty)
        #expect(profile.elements(forName: "CommandLineArguments").isEmpty)
        let archive = try #require(root.elements(forName: "ArchiveAction").first)
        #expect(archive.attribute(forName: "buildConfiguration")?.stringValue == "Release")
        let nonLaunchVariables = [profile, archive]
            .flatMap { $0.elements(forName: "EnvironmentVariables") }
            .flatMap { $0.elements(forName: "EnvironmentVariable") }
        #expect(nonLaunchVariables.allSatisfy {
            $0.attribute(forName: "key")?.stringValue != "MTL_HUD_ENABLED"
        })
    }

}
