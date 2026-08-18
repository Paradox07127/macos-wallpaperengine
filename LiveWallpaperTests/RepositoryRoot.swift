import Foundation
import Testing

enum RepositoryRoot {
    static let projectFileName = "LiveWallpaper.xcodeproj"

    /// Symlink-resolved. `FileManager`'s enumerator resolves symlinks while
    /// `#filePath` does not, so under a `/tmp` checkout an unresolved root strips
    /// no prefix and every path-keyed allowlist misses at once.
    static let url: URL = {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resolved = ascendToProject(from: sourceDirectory)
            ?? ascendToProject(from: workingDirectory)
            ?? sourceDirectory.deletingLastPathComponent()
        return resolved.resolvingSymlinksInPath()
    }()

    static func url(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    static func componentSource(under directory: String, namePrefix: String) throws -> String {
        let files = swiftFiles(under: directory)
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(namePrefix) }
        guard !files.isEmpty else { throw SweepError.noSourcesMatch(directory: directory, prefix: namePrefix) }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    enum SweepError: Error, CustomStringConvertible {
        case noSourcesMatch(directory: String, prefix: String)

        var description: String {
            switch self {
            case let .noSourcesMatch(directory, prefix):
                return "No .swift file under \(directory) starts with \(prefix) — the scan is misconfigured, not passing."
            }
        }
    }

    /// Keys a swept file against `root`. Both sides are symlink-resolved because
    /// `FileManager`'s enumerator resolves while a root written as `/tmp/...` does
    /// not — mismatched spaces strip nothing and miss every allowlist entry at once.
    static func relativePath(of file: URL, under root: URL = RepositoryRoot.url) -> String {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return file.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "")
    }

    static func swiftFiles(under relativePath: String) -> [URL] {
        swiftFiles(underURL: url(relativePath))
    }

    static func swiftFiles(underURL root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var collected: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular { collected.append(url) }
        }
        return collected.sorted { $0.path < $1.path }
    }

    private static func ascendToProject(from directory: URL) -> URL? {
        var candidate = directory
        while true {
            let project = candidate.appendingPathComponent(projectFileName)
            if FileManager.default.fileExists(atPath: project.path) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }
}

@Suite("Repository root anchor")
struct RepositoryRootTests {
    @Test("Resolves to the directory holding the Xcode project")
    func resolvesToProjectDirectory() {
        let manager = FileManager.default
        #expect(
            manager.fileExists(atPath: RepositoryRoot.url(RepositoryRoot.projectFileName).path),
            Comment(rawValue: "Repo root resolved to \(RepositoryRoot.url.path), which holds no \(RepositoryRoot.projectFileName)")
        )
        #expect(manager.fileExists(atPath: RepositoryRoot.url("LiveWallpaper").path))
        #expect(manager.fileExists(atPath: RepositoryRoot.url("Packages").path))
    }

    @Test("Swift sweeps under a real directory are non-empty and recursive")
    func swiftSweepIsRecursive() {
        let files = RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views")
        #expect(!files.isEmpty)
        #expect(files.contains { $0.path.contains("/Views/ScreenDetail/") }, "Sweep is not descending into subdirectories")
    }

    @Test("Sweeps reached through a symlinked path still key against their root")
    func relativePathSurvivesSymlinkedRoot() throws {
        let manager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RepositoryRootSymlink-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try manager.createDirectory(at: real.appendingPathComponent("Sub/Nested"), withIntermediateDirectories: true)
        try "// probe\n".write(to: real.appendingPathComponent("Sub/Nested/Probe.swift"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: real)

        // The root itself is a real directory; only the path used to reach it runs
        // through a symlink — the same shape as a checkout under `/tmp`.
        let root = base.appendingPathComponent("link/Sub")
        let swept = RepositoryRoot.swiftFiles(underURL: root)
        #expect(swept.count == 1)
        let keyed = RepositoryRoot.relativePath(of: try #require(swept.first), under: root)
        #expect(
            keyed == "Nested/Probe.swift",
            Comment(rawValue: "Swept path is keyed in a different symlink space than its root: \(keyed)")
        )
    }

    @Test("A missing directory sweeps to empty rather than resolving somewhere else")
    func missingDirectorySweepsEmpty() {
        #expect(RepositoryRoot.swiftFiles(under: "LiveWallpaper/DirectoryThatDoesNotExist").isEmpty)
    }

    @Test("A component sweep spans the files its type was split into")
    func componentSourceSpansSplitParts() throws {
        let executor = try RepositoryRoot.componentSource(under: "LiveWallpaper/Runtime", namePrefix: "WPEMetalRenderExecutor")
        #expect(executor.contains("final class WPEMetalRenderExecutor"))
        #expect(executor.contains("func present("))
    }

    @Test("A component sweep matching nothing throws instead of returning empty")
    func componentSourceRejectsEmptySweep() {
        #expect(throws: RepositoryRoot.SweepError.self) {
            try RepositoryRoot.componentSource(under: "LiveWallpaper/Runtime", namePrefix: "NoSuchTypeName")
        }
    }
}
