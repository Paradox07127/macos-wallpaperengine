import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPEMultiRootResourceResolver")
struct WPEMultiRootResourceResolverTests {

    @Test("Dependency reference resolves only through declared mount")
    func dependencyReferenceResolvesThroughDeclaredMount() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let depMaterials = fixture.dependencyRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: depMaterials, withIntermediateDirectories: true)
        try Data("dep".utf8).write(to: depMaterials.appendingPathComponent("dep.png"))

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: fixture.dependencyRoot)]
        )

        let url = try resolver.resolveExistingFileURL(relativePath: "../123/materials/dep.png")

        #expect(url.lastPathComponent == "dep.png")
    }

    @Test("Dependency JSON format probe stays inside its declared mount")
    func dependencyTextureFormatProbeStaysInsideMount() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let dependencyModels = fixture.dependencyRoot.appendingPathComponent("models", isDirectory: true)
        let dependencyMaterials = fixture.dependencyRoot.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencyModels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependencyMaterials, withIntermediateDirectories: true)
        try Data(#"{"material":"materials/wrapped.json"}"#.utf8)
            .write(to: dependencyModels.appendingPathComponent("wrapped.json"))
        try Data(#"{"passes":[{"textures":["dep-normal"]}]}"#.utf8)
            .write(to: dependencyMaterials.appendingPathComponent("wrapped.json"))
        try Data("dependency-tex".utf8)
            .write(to: dependencyMaterials.appendingPathComponent("dep-normal.tex"))

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: fixture.dependencyRoot)]
        )
        let probe = try resolver.resolveTextureFormatProbe(
            relativePath: "../123/models/wrapped.json"
        )

        #expect(probe.relativePath == "materials/dep-normal.tex")
        #expect(probe.texPayload?.materializedData() == Data("dependency-tex".utf8))
    }

    @Test("Engine assets fallback resolves only after primary miss")
    func engineAssetsFallbackResolvesOnlyAfterPrimaryMiss() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let primaryMaterials = fixture.primaryRoot.appendingPathComponent("materials/util", isDirectory: true)
        let engineMaterials = fixture.engineRoot.appendingPathComponent("assets/materials/util", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryMaterials, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineMaterials, withIntermediateDirectories: true)
        try Data("primary".utf8).write(to: primaryMaterials.appendingPathComponent("composelayer.json"))
        try Data("engine".utf8).write(to: engineMaterials.appendingPathComponent("fallback.json"))

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )

        let primaryURL = try resolver.resolveExistingFileURL(relativePath: "materials/util/composelayer.json")
        let fallbackURL = try resolver.resolveExistingFileURL(relativePath: "materials/util/fallback.json")

        #expect(String(data: try Data(contentsOf: primaryURL), encoding: .utf8) == "primary")
        #expect(String(data: try Data(contentsOf: fallbackURL), encoding: .utf8) == "engine")
    }

    @Test("Engine assets fallback does not shadow project's own files")
    func engineAssetsFallbackDoesNotShadowProjectFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let primaryMaterials = fixture.primaryRoot.appendingPathComponent("materials", isDirectory: true)
        let engineMaterials = fixture.engineRoot.appendingPathComponent("assets/materials", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryMaterials, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineMaterials, withIntermediateDirectories: true)
        try Data("project-version".utf8).write(to: primaryMaterials.appendingPathComponent("composelayer.json"))
        try Data("engine-version".utf8).write(to: engineMaterials.appendingPathComponent("composelayer.json"))

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )

        let url = try resolver.resolveExistingFileURL(relativePath: "materials/composelayer.json")
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8) == "project-version")
    }

    @Test("Engine JSON format probe keeps its terminal TEX in the engine root")
    func engineTextureFormatProbeKeepsOrigin() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let primaryMaterials = fixture.primaryRoot.appendingPathComponent("materials", isDirectory: true)
        let engineModels = fixture.engineRoot.appendingPathComponent("assets/models", isDirectory: true)
        let engineMaterials = fixture.engineRoot.appendingPathComponent("assets/materials", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryMaterials, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineModels, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engineMaterials, withIntermediateDirectories: true)
        try Data("primary-shadow".utf8)
            .write(to: primaryMaterials.appendingPathComponent("shared.tex"))
        try Data(#"{"material":"materials/wrapped.json"}"#.utf8)
            .write(to: engineModels.appendingPathComponent("wrapped.json"))
        try Data(#"{"passes":[{"textures":["shared"]}]}"#.utf8)
            .write(to: engineMaterials.appendingPathComponent("wrapped.json"))
        try Data("engine-tex".utf8)
            .write(to: engineMaterials.appendingPathComponent("shared.tex"))

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )
        let probe = try resolver.resolveTextureFormatProbe(relativePath: "models/wrapped.json")

        #expect(probe.relativePath == "materials/shared.tex")
        #expect(probe.texPayload?.materializedData() == Data("engine-tex".utf8))
    }

    @Test("Engine assets fallback only triggers on .fileMissing")
    func engineAssetsFallbackOnlyTriggersOnFileMissing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            _ = try resolver.resolveExistingFileURL(relativePath: "../456/materials/x.png")
        }
    }

    @Test("Undeclared dependency reference is rejected")
    func undeclaredDependencyReferenceRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot
        )

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            _ = try resolver.resolveExistingFileURL(relativePath: "../123/materials/dep.png")
        }
    }

    @Test("Nested traversal inside dependency reference is rejected")
    func dependencyTraversalRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: fixture.dependencyRoot)]
        )

        #expect(throws: SceneResourceResolver.ResolveError.pathEscape) {
            _ = try resolver.resolveExistingFileURL(relativePath: "../123/../secret.png")
        }
    }

    @Test("Optional probe miss is not traced; required miss is")
    func optionalProbeMissNotTraced() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot,
            tracer: tracer
        )

        #expect(throws: SceneResourceResolver.ResolveError.fileMissing) {
            _ = try resolver.data(relativePath: "materials/particle/流星.tex-json", optional: true)
        }
        #expect(tracer.snapshot().missedRefs.isEmpty)

        #expect(throws: SceneResourceResolver.ResolveError.fileMissing) {
            _ = try resolver.data(relativePath: "materials/particle/流星.tex")
        }
        #expect(tracer.snapshot().missedRefs.map(\.ref) == ["materials/particle/流星.tex"])
    }

    @Test("Optional probe hit is still traced as resolved")
    func optionalProbeHitTraced() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let engineParticle = fixture.engineRoot
            .appendingPathComponent("assets/materials/particle", isDirectory: true)
        try FileManager.default.createDirectory(at: engineParticle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: engineParticle.appendingPathComponent("halo_3.tex-json"))

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: fixture.primaryRoot,
            dependencyMounts: [],
            engineAssetsRootURL: fixture.engineRoot,
            tracer: tracer
        )

        _ = try resolver.data(relativePath: "materials/particle/halo_3.tex-json", optional: true)
        let snapshot = tracer.snapshot()
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty)
    }

    private struct Fixture {
        let root: URL
        let primaryRoot: URL
        let dependencyRoot: URL
        let engineRoot: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMultiRootResourceResolverTests-\(UUID().uuidString)", isDirectory: true)
        let primary = root.appendingPathComponent("primary", isDirectory: true)
        let dependency = root.appendingPathComponent("dependency", isDirectory: true)
        let engine = root.appendingPathComponent("engine", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        return Fixture(root: root, primaryRoot: primary, dependencyRoot: dependency, engineRoot: engine)
    }
}
