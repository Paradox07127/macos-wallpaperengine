import Foundation
import Testing

@Suite("Shared scheme environment contracts")
struct SchemeEnvironmentContractTests {
    private let schemes = [
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper.xcscheme",
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaperLite.xcscheme",
    ]

    @Test("Profile uses a neutral Release environment", arguments: [
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper.xcscheme",
        "LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaperLite.xcscheme",
    ])
    func profileDoesNotInheritLaunchEnvironment(relativePath: String) throws {
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
    }

    @Test("Metal HUD never reaches the Profile or Archive actions")
    func metalHUDStaysOutOfShippingActions() throws {
        for relativePath in schemes {
            let document = try XMLDocument(
                contentsOf: RepositoryRoot.url(relativePath),
                options: []
            )
            let root = try #require(document.rootElement())
            let profile = try #require(root.elements(forName: "ProfileAction").first)
            let archive = try #require(root.elements(forName: "ArchiveAction").first)

            #expect(profile.attribute(forName: "buildConfiguration")?.stringValue == "Release")
            #expect(archive.attribute(forName: "buildConfiguration")?.stringValue == "Release")

            let nonLaunchVariables = [profile, archive]
                .flatMap { $0.elements(forName: "EnvironmentVariables") }
                .flatMap { $0.elements(forName: "EnvironmentVariable") }

            #expect(nonLaunchVariables.allSatisfy {
                $0.attribute(forName: "key")?.stringValue != "MTL_HUD_ENABLED"
            })
        }
    }

    @Test("AppIntents stays out of the target graph until a product integration exists")
    func appIntentsRequiresAnExplicitIntegration() throws {
        let project = try RepositoryRoot.source("LiveWallpaper.xcodeproj/project.pbxproj")
        let reviewedFiles = ["LiveWallpaper", "LiveWallpaperTests", "Packages"]
            .flatMap { RepositoryRoot.swiftFiles(under: $0) }
        let importNeedle = ["import", "AppIntents"].joined(separator: " ")

        #expect(!reviewedFiles.isEmpty)
        #expect(!project.contains("AppIntents.framework"))
        for file in reviewedFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains(importNeedle),
                Comment(rawValue: "\(file.path) imports AppIntents without a reviewed product integration")
            )
        }
    }
}
