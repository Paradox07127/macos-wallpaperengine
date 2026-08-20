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
        // 14.6 is the app floor. The SystemWallpaperProvider appexes are the
        // one sanctioned exception: the com.apple.wallpaper extension point
        // does not exist before macOS 26, so their two targets (Pro + Lite,
        // Debug + Release each) pin 26.0 — exactly four occurrences. A fifth
        // means an app target drifted.
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

    @Test("Liquid Glass APIs stay inside AdaptiveGlass")
    func liquidGlassAPIsAreCentralized() throws {
        let allowed = "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/AdaptiveGlass.swift"
        let needles = [
            "GlassEffectContainer",
            ".glassEffect(",
            ".glassEffectID(",
            ".glassEffectUnion(",
            ".glassEffectTransition(",
            "DefaultGlassEffectShape",
            ".buttonStyle(.glass)",
            ".buttonStyle(.glass(",
            ".buttonStyle(.glassProminent)",
            "GlassButtonStyle",
            "GlassProminentButtonStyle",
            "Glass.regular",
            "Glass.clear",
            "Glass.identity",
            ".regular.tint(",
            ".regular.interactive(",
        ]

        let offenders = try swiftFiles()
            .filter { !$0.path.hasSuffix(allowed) }
            .flatMap { file -> [String] in
                let raw = try String(contentsOf: file, encoding: .utf8)
                let stripped = stripLineComments(raw)
                let relativePath = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                return needles
                    .filter { stripped.contains($0) }
                    .map { "\(relativePath) contains \($0)" }
            }

        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }

    /// Availability is guarded above; this guards *placement*. Apple's own words:
    /// "Limit these effects to the most important functional elements in your app",
    /// and the section on lists / tables / forms never mentions the material at all.
    /// Both families below sit on opaque backgrounds by construction, so glass
    /// there buys a highlight with nothing behind it to refract.
    @Test("Liquid Glass stays off opaque surfaces")
    func liquidGlassStaysOffOpaqueSurfaces() throws {
        let entryPoints = [".adaptiveGlassButton(", ".adaptiveGlassSurface("]

        // Settings is a grouped Form that draws its own section plate.
        let settingsPrefix = "LiveWallpaper/Views/Settings/"

        // Every caller renders these in page flow, so the choice cannot be pushed
        // to the caller — the component itself has to stay flat.
        let flatOnlyComponents: Set<String> = [
            "ContainerGroupBoxStyle.swift",
            "SheetFooterBar.swift",
            "IllustratedEmptyState.swift",
            "StatusChip.swift",
            "TypeBadge.swift",
            "FilterChip.swift",
            "LibraryFilterBar.swift",
            "DestructiveControlTint.swift",
            "CapsuleButtonStyle.swift",
        ]

        let offenders = try swiftFiles().flatMap { file -> [String] in
            let relativePath = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            guard relativePath.hasPrefix(settingsPrefix)
                    || flatOnlyComponents.contains(file.lastPathComponent) else { return [] }
            let stripped = stripLineComments(try String(contentsOf: file, encoding: .utf8))
            return entryPoints
                .filter { stripped.contains($0) }
                .map { "\(relativePath) contains \($0)" }
        }

        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }

    private func stripLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentStart = lineCommentStart(in: line) else { return line }
                return line[line.startIndex..<commentStart]
            }
            .joined(separator: "\n")
    }

    private func lineCommentStart(in line: Substring) -> Substring.Index? {
        var inString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if inString && character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString && character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex && line[next] == "/" {
                    return index
                }
            }
            index = line.index(after: index)
        }
        return nil
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

    private func swiftFiles() throws -> [URL] {
        let roots = [
            repoRoot.appendingPathComponent("LiveWallpaper"),
            repoRoot.appendingPathComponent("Packages"),
        ]
        let manager = FileManager.default
        return roots.flatMap { root -> [URL] in
            guard
                let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { return [] }
            var collected: [URL] = []
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }
                collected.append(url)
            }
            return collected
        }
    }
}
