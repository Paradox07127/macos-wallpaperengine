import Foundation
import Testing

@Suite("macOS compatibility policy")
struct MacOSCompatibilityPolicyTests {
    private var repoRoot: URL { RepositoryRoot.url }

    @Test("project and package manifests target macOS 14.6")
    func deploymentTargetsAreMacOS14_6() throws {
        let project = try XcodeProjectFile()
        var targetsByDeployment: [String: Set<String>] = [:]
        for target in project.targets {
            let name = try #require(target["name"] as? String)
            for configuration in project.configurations {
                let deployment = try #require(
                    try project.setting("MACOSX_DEPLOYMENT_TARGET", target: name, configuration: configuration),
                    "\(name)/\(configuration) has no deployment target"
                )
                targetsByDeployment[deployment, default: []].insert(name)
            }
        }
        // 14.6 is the app floor; the wallpaper appexes pin 26.0 because the extension point does not exist earlier.
        #expect(
            Set(targetsByDeployment.keys) == ["14.6", "26.0"],
            Comment(rawValue: "project has unexpected deployment targets: \(targetsByDeployment.keys.sorted())")
        )
        #expect(
            targetsByDeployment["26.0"] == ["SystemWallpaperProvider", "SystemWallpaperProviderLite"],
            Comment(rawValue: "26.0 is reserved for the two wallpaper appex targets")
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
