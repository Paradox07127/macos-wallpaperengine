import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("WPESceneCapabilityClassifier")
struct WPESceneCapabilityClassifierTests {

    @Test("Classifier rejects scenes where the declared image reference resolves nowhere")
    func unreachableImageReferenceIsUnsupported() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try parseScene(imagePath: "materials/totally-missing.png")

        let tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot)

        #expect(tier == .unsupported)
    }

    @Test("Classifier accepts scenes whose direct image reference resolves even if the deep chain fails")
    func reachableImageReferenceWithBrokenChainIsImageOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let modelsDir = fixture.cacheRoot.appendingPathComponent("models", isDirectory: true)
        let materialsDir = fixture.cacheRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materialsDir, withIntermediateDirectories: true)
        try Data(#"{ "material": "materials/foo.json" }"#.utf8).write(to: modelsDir.appendingPathComponent("foo.json"))
        try Data(#"{ "passes": [{ "textures": ["missing"], "shader": "genericimage4" }] }"#.utf8).write(to: materialsDir.appendingPathComponent("foo.json"))
        let document = try parseScene(imagePath: "models/foo.json")

        let tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot)

        #expect(tier == .imageOnly)
    }

    @Test("A sound object alongside a renderable image does not downgrade the scene")
    func renderableImageWithSoundObjectStaysImageOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("not decoded by probe".utf8).write(to: fixture.cacheRoot.appendingPathComponent("layer.png"))
        let document = try parseScene(
            imagePath: "layer.png",
            extraObject: #"{ "name": "Loop", "sound": { "file": "sounds/loop.ogg" } }"#
        )

        let tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot)

        #expect(tier == .imageOnly)
    }

    @Test("Text-only scenes use the existing limited compatibility tier")
    func textOnlySceneIsAdmitted() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try parseObjects([["id": "text", "text": "Hello", "origin": "32 32 0"]])
        #expect(WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot) == .degraded)
    }

    @Test("Particle-only scenes require a reachable definition", arguments: [false, true])
    func particleOnlyNeedsDefinition(reachable: Bool) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        if reachable {
            try Data(#"{"material":"missing.json"}"#.utf8).write(to: fixture.cacheRoot.appendingPathComponent("particle.json"))
        }
        let document = try parseObjects([["id": "pfx", "particle": "particle.json"]])
        let tier = WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot)
        #expect(tier == (reachable ? .degraded : .unsupported))
    }

    @Test("Light-only and empty scenes remain unsupported", arguments: [false, true])
    func noRenderableProducerIsUnsupported(light: Bool) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = try parseObjects(light ? [["id": "lamp", "light": "lpoint"]] : [])
        #expect(WPESceneCapabilityClassifier().capabilityTier(for: document, cacheURL: fixture.cacheRoot) == .unsupported)
    }

    private func parseObjects(_ objects: [[String: Any]]) throws -> WPESceneDocument {
        let json: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": objects,
        ]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json))
    }

    private struct Fixture {
        let root: URL
        let cacheRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneCapabilityClassifierTests-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return Fixture(root: root, cacheRoot: cacheRoot)
    }

    private func parseScene(imagePath: String, extraObject: String? = nil) throws -> WPESceneDocument {
        let extra = extraObject.map { ",\n\($0)" } ?? ""
        let json = """
        {
            "camera": { "center": "0 0 0" },
            "general": {
                "orthogonalprojection": { "width": 1920, "height": 1080, "auto": true }
            },
            "objects": [
                {
                    "name": "Layer",
                    "image": "\(imagePath)"
                }
                \(extra)
            ]
        }
        """
        return try WPESceneDocumentParser.parse(data: Data(json.utf8))
    }
}
