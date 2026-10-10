import Foundation
import Testing

@Suite("macOS compatibility policy")
struct MacOSCompatibilityPolicyTests {
    private var repoRoot: URL { RepositoryRoot.url }

    @Test("project and package manifests target macOS 14.6")
    func deploymentTargetsAreMacOS14_6() throws {
        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("LiveWallpaper.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let projectTargets = project
            .matches(of: /MACOSX_DEPLOYMENT_TARGET = ([^;]+);/)
            .map { String($0.output.1) }
        #expect(!projectTargets.isEmpty)
        // 14.6 is the app floor; the wallpaper appexes pin 26.0 because the extension
        // point does not exist earlier — 2 targets x 2 configs = the four occurrences.
        #expect(
            Set(projectTargets) == ["14.6", "26.0"],
            Comment(rawValue: "pbxproj has unexpected deployment targets: \(Set(projectTargets).sorted())")
        )
        #expect(
            projectTargets.filter { $0 == "26.0" }.count == 4,
            Comment(rawValue: "26.0 is reserved for the two wallpaper appex targets (×2 configs)")
        )

        // SPM has no `.v14_6` case, so the floor is spelled as a version string.
        for (name, manifest) in try allPackageManifests() {
            #expect(
                manifest.contains(#"platforms: [.macOS("14.6")]"#),
                Comment(rawValue: #"\#(name) does not declare platforms: [.macOS("14.6")]"#)
            )
        }
    }

    private func allPackageManifests() throws -> [(name: String, contents: String)] {
        let packagesRoot = repoRoot.appendingPathComponent("Packages")
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(
            at: packagesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try entries
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .compactMap { dir -> (String, String)? in
                let manifest = dir.appendingPathComponent("Package.swift")
                guard manager.fileExists(atPath: manifest.path) else { return nil }
                let contents = try String(contentsOf: manifest, encoding: .utf8)
                return (dir.lastPathComponent, contents)
            }
    }

}
