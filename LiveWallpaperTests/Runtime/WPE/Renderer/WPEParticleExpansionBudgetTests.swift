import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import Testing

@MainActor
@Suite("WPE particle expansion scene budget", .serialized)
struct WPEParticleExpansionBudgetTests {
    @Test("Shared children fanning out 16 levels stop at the scene system budget with a diagnostic")
    func binaryFanOutIsCappedBySceneBudget() async throws {
        let fixture = try Self.binaryTreeScene(depth: 16)
        defer { fixture.cleanup() }
        WPESceneDebugArtifacts.shared.setEnabledForTesting(true)
        defer { WPESceneDebugArtifacts.shared.setEnabledForTesting(nil) }

        let renderer = try await Self.loadRenderer(fixture)
        defer { renderer.cleanup() }

        #expect(renderer.particleSystems.count <= 2048,
                "unbounded expansion registers 2^16-1 systems at load")
        #expect(renderer.particleSystems.count > 3)
        let log = try await Self.sceneDebugLog(for: fixture.descriptor.workshopID, containing: "particles.expand.done")
        #expect(log.contains("particle scene budget reached"))
    }

    @Test("A small shared-child tree expands completely under the scene budget")
    func smallTreeExpandsCompletely() async throws {
        let fixture = try Self.binaryTreeScene(depth: 3)
        defer { fixture.cleanup() }

        let renderer = try await Self.loadRenderer(fixture)
        defer { renderer.cleanup() }

        #expect(renderer.particleSystems.count == 7)
    }

    private static func loadRenderer(_ fixture: MetalSceneFixture) async throws -> WPEMetalSceneRenderer {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device
        )
        try await renderer.load()
        return renderer
    }

    /// `depth` particle files p0…p(depth-1); each non-leaf references the next file twice, so a full expansion is 2^depth − 1 systems.
    private static func binaryTreeScene(depth: Int) throws -> MetalSceneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEParticleExpansionBudget-\(UUID().uuidString)", isDirectory: true)
        let particles = root.appendingPathComponent("particles", isDirectory: true)
        try FileManager.default.createDirectory(at: particles, withIntermediateDirectories: true)
        for level in 0 ..< depth {
            let children = level + 1 < depth
                ? #"[{"name": "particles/p\#(level + 1).json"}, {"name": "particles/p\#(level + 1).json"}]"#
                : "[]"
            let particle = #"{ "renderer": [], "maxcount": 1, "children": \#(children) }"#
            try Data(particle.utf8).write(to: particles.appendingPathComponent("p\(level).json"))
        }
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": { "orthogonalprojection": { "width": 64, "height": 64, "auto": true } },
          "objects": [{
            "id": "solid",
            "name": "Solid",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "1 0 0",
            "alpha": 1
          }, {
            "id": "pfx",
            "name": "Fan-out Particles",
            "particle": "particles/p0.json",
            "origin": "0.5 0.5 0",
            "visible": true
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return MetalSceneFixture(
            root: root,
            descriptor: SceneDescriptor(
                workshopID: UUID().uuidString,
                cacheRelativePath: "wpe-cache/test",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            dependencyRoot: nil
        )
    }

    private static func sceneDebugLog(for workshopID: String, containing marker: String) async throws -> String {
        let root = try #require(WPESceneDebugArtifacts.rootURL)
        for _ in 0 ..< 100 {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for folder in folders where folder.lastPathComponent.contains(workshopID) {
                let logURL = folder.appendingPathComponent("scene.log")
                if let log = try? String(contentsOf: logURL, encoding: .utf8), log.contains(marker) {
                    return log
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
