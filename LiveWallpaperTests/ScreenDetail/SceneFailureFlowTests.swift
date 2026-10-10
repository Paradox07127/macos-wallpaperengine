import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import SwiftUI
import Testing

@Suite("Scene failure flow")
struct SceneFailureFlowTests {
    @MainActor
    @Test("A missing fullscreen model reaches the failed-attempt page with engine setup, even while a video is retained")
    func fullscreenFailureOffersSetupOnAttemptPage() throws {
        let path = "models/util/fullscreenlayer.json"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fullscreen-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 256, "height": 128]],
            "objects": [["id": 183, "name": "Contrast Lighting", "image": path,
                         "effects": [["id": 185, "file": "effects/localcontrast/effect.json", "visible": true]]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene))
        let error = try #require(#expect(throws: WPERenderGraphError.self) {
            _ = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        })
        #expect(error == .fileMissing(path))

        let descriptor = SceneDescriptor(workshopID: "2934020506", cacheRelativePath: "fixture", entryFile: "scene.json", capabilityTier: .imageOnly)
        let renderer = try WPEMetalSceneRenderer(
            descriptor: descriptor, cacheRootURL: root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 256, height: 128), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        let diagnostic = renderer.diagnostic(for: error)
        #expect(diagnostic == .fileMissing(layer: "scene", path: path))
        let cause = SceneWallpaperSession.failureCause(for: error, diagnostic: diagnostic)
        #expect(cause.code == "scene.file_missing")
        #expect(cause.reason.contains(path))

        let snapshot = WallpaperFailureSnapshot(
            id: UUID(), title: "Golden flowers", workshopID: "2934020506", displayName: "Built-in Display",
            stage: .loading, cause: cause, previousWallpaper: "Golden Knight · Video", timestamp: Date(),
            diagnostics: "", wallpaperType: .scene
        )
        let page = WallpaperFailureView(failure: snapshot, onRetry: {})
        #expect(page.recovery(engineAssetsAuthorized: false) == [.configureEngineAssets, .retry, .openWorkshop("2934020506")])
        #expect(page.recovery(engineAssetsAuthorized: true) == [.retry, .openWorkshop("2934020506")])
        let history = WallpaperFailureView(failure: snapshot, isCurrentAttempt: false)
        #expect(history.recovery(engineAssetsAuthorized: false) == [.openWorkshop("2934020506")])
    }

    @Test("Unsafe schema paths are failures, not scenes without options")
    func unsafeSchemaPath() async {
        let result = await WPESceneProjectSchemaLoader.load(
            descriptor: SceneDescriptor(workshopID: "B", cacheRelativePath: "../outside", entryFile: "scene.json", capabilityTier: .imageOnly),
            wpeOrigin: nil
        )
        #expect(result.schema == nil)
        #expect(!result.isExpectedAbsence)
    }

    @Test("Successful scene schemas are synchronously reused without caching failures")
    func sceneSchemaCacheReusesSuccessfulReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schema-cache-\(UUID().uuidString)", isDirectory: true)
        let descriptor = SceneDescriptor(workshopID: "42", cacheRelativePath: "wpe-cache/42", entryFile: "scene.json", capabilityTier: .imageOnly)
        let folder = root.appendingPathComponent("LiveWallpaper/wpe-cache/42")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = folder.appendingPathComponent("project.json")
        try Data("{".utf8).write(to: project)
        let failed = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root)
        #expect(failed.failure != nil)
        #expect(WPESceneProjectSchemaLoader.cachedOutcome(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root) == nil)

        try Data(#"{"general":{"properties":{"enabled":{"type":"bool","text":"Enabled","value":true}}}}"#.utf8).write(to: project)
        let loaded = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root)
        #expect(loaded.schema?.properties.map(\.key) == ["enabled"])
        try FileManager.default.removeItem(at: project)
        // The synchronous seed still paints the last known answer on the first frame…
        let cached = WPESceneProjectSchemaLoader.cachedOutcome(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root)
        #expect(cached?.schema?.properties.map(\.key) == ["enabled"])
        // …but a load re-stats the file and must not serve a memo for a project.json that is gone.
        let reused = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root)
        #expect(reused.schema == nil, "load() served the memo for a project.json that no longer exists")
        #expect(WPESceneProjectSchemaLoader.cachedOutcome(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root) == nil)

        let origin = WPEOrigin(workshopID: "42", title: "Scene", originalType: .scene, sourceFolderBookmark: Data([1]), cacheRelativePath: nil, previewFileName: nil)
        #expect(WPESceneProjectSchemaLoader.cachedOutcome(descriptor: descriptor, wpeOrigin: origin, applicationSupportRootURL: root) == nil)
        let other = SceneDescriptor(workshopID: "42", cacheRelativePath: "wpe-cache/42", entryFile: "other.json", capabilityTier: .imageOnly)
        #expect(WPESceneProjectSchemaLoader.cachedOutcome(descriptor: other, wpeOrigin: nil, applicationSupportRootURL: root) == nil)
        WPESceneProjectSchemaLoader.invalidateCache()
        #expect(WPESceneProjectSchemaLoader.cachedOutcome(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root) == nil)
    }

    @Test("An edited project.json is re-read instead of served from the memo")
    func sceneSchemaCacheNoticesAnEditedProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schema-edit-\(UUID().uuidString)", isDirectory: true)
        let descriptor = SceneDescriptor(workshopID: "77", cacheRelativePath: "wpe-cache/77", entryFile: "scene.json", capabilityTier: .imageOnly)
        let folder = root.appendingPathComponent("LiveWallpaper/wpe-cache/77")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = folder.appendingPathComponent("project.json")

        try Data(#"{"general":{"properties":{"enabled":{"type":"bool","text":"Enabled","value":true}}}}"#.utf8).write(to: project)
        let first = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root)
        #expect(first.schema?.properties.map(\.key) == ["enabled"])

        try Data(#"{"general":{"properties":{"speed":{"type":"slider","text":"Speed","value":0.5,"min":0,"max":1}}}}"#.utf8).write(to: project)
        let reloaded = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: nil, applicationSupportRootURL: root)
        #expect(
            reloaded.schema?.properties.map(\.key) == ["speed"],
            "the memo served a schema for a project.json that has since changed on disk"
        )
    }

    @MainActor
    @Test("A long author title cannot displace the actual cause from the issue URL")
    func reportKeepsCauseUnderBudget() {
        let failure = WallpaperFailureSnapshot(id: UUID(), title: String(repeating: "场景", count: 6000), workshopID: "1234", displayName: "Display", stage: .loading, cause: WallpaperFailureCause(code: "texture.metal_unavailable", reason: "Missing BC7 support"), previousWallpaper: "A", timestamp: Date(), diagnostics: String(repeating: "log", count: 8000))
        let report = BugReporter.makeReport(activeWallpapers: ["C"], failureContext: failure)
        let body = URLComponents(url: report.issueURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value ?? ""
        #expect(body.utf8.count <= 6 * 1024)
        #expect(body.contains("texture.metal_unavailable"))
        #expect(body.contains("Missing BC7 support"))
        #expect(report.diagnosticMarkdown.contains(failure.diagnostics))
    }

    @MainActor
    @Test("Late B results cannot modify C or clear it")
    func lateAttemptIsRejected() throws {
        let display = try #require(NSScreen.screens.first)
        let screen = Screen(nsScreen: display)
        let state = WallpaperLoadState()
        let b = state.begin(for: screen, title: "B")
        let c = state.begin(for: screen, title: "C")
        #expect(!state.update(b, for: screen) { $0.title = "Late B" })
        state.clear(for: screen, matching: b)
        #expect(state.attempt(for: screen)?.id == c)
        #expect(state.attempt(for: screen)?.title == "C")
    }

    @Test("Decoder and layer diagnostics keep specific causes and parameters")
    func errorMatrix() {
        let errors: [WPETexDecodeError] = [.unsupportedContainer(magic: "MAGIC"), .unsupportedBlock(magic: "BLOCK"), .missingInfoBlock, .missingBitmapBlock, .unsupportedFormat(code: 71), .unsupportedAnimation, .invalidDimensions(width: 0, height: 5), .truncatedBlock(block: "TEXB", offset: 42), .mipmapOutOfBounds(index: 9), .decompressionFailed(mipmap: 3), .decodeFailed(mipmap: 2, detail: "detail"), .metalUnavailable(format: .bc7)]
        let mapped = errors.map(SceneFailureCause.make)
        #expect(Set(mapped.map(\.code)).count == 12)
        for (error, cause) in zip(errors, mapped) {
            #expect(cause.reason == error.localizedDescription)
            #expect(cause.details.contains(String(reflecting: error)))
        }
        let cross = SceneFailureCause.make(SceneLoadDiagnostic.crossPackageReference(layer: "B", path: "other/pkg"))
        #expect(cross.code == "scene.cross_package")
        #expect(cross.reason.contains("other/pkg"))
        #expect(!cross.canRetry)
        let material = SceneFailureCause.make(SceneLoadDiagnostic.materialUnresolved(layer: "B", reason: "shader XYZ"))
        #expect(material.code == "scene.material")
        #expect(material.reason.contains("shader XYZ"))
        let unknown = SceneFailureCause.make(NSError(domain: "SceneTest", code: 47, userInfo: [NSLocalizedDescriptionKey: "the actual reason"]))
        #expect(unknown.code == "SceneTest.47")
        #expect(unknown.reason == "the actual reason")
    }

    @Test("Document, resource, graph, Metal and model failures retain their payloads")
    func remainingErrorFamilies() {
        let packages: [WPEPackageError] = [.truncatedHeader, .invalidMagic("BAD"), .invalidEntryName(index: 2), .entryOutOfBounds(name: "B"), .pathTraversal(name: "../B"), .duplicateEntry(name: "B"), .resourceLimitExceeded(.entryCount)]
        for error in packages {
            let cause = SceneFailureCause.make(error)
            #expect(cause.code == error.stableReasonCode)
            #expect(cause.details.contains(String(reflecting: error)))
            #expect(!cause.canRetry)
        }
        let providers: [WPESceneAssetProviderError] = [.invalidRelativePath("../B"), .fileMissing("B.tex"), .unreadable("B.tex"), .stagingUnavailable("B.tex")]
        #expect(Set(providers.map { SceneFailureCause.make($0).code }).count == 4)
        for error in providers {
            #expect(SceneFailureCause.make(error).reason.contains("B"))
        }
        let documents: [WPESceneDocumentError] = [.invalidUTF8, .rootNotObject, .missingCamera, .missingGeneral, .malformedField("camera.zoom")]
        let rendering: [SceneRenderingError] = [.cacheRootMissing, .parseFailed("invalid JSON"), .resourceFailed(.fileMissing(layer: "B", path: "materials/B.tex")), .metalRendererUnsupported(reason: "target format")]
        let resources: [SceneLoadDiagnostic] = [.texture(layer: "B", error: .unsupportedFormat(code: 42)), .legacyUnsupportedTexture(layer: "B"), .fileMissing(layer: "B", path: "materials/B.tex"), .crossPackageReference(layer: "B", path: "other/B.tex"), .materialUnresolved(layer: "B", reason: "custom pass"), .other(layer: "B", message: "failure details")]
        let metal: [WPEMetalTextureLoaderError] = [.unsupportedFormat(.bc7), .unsupportedCompressedFormat(.bc7), .malformedPayload("wrong length"), .textureAllocationFailed]
        let graph: [WPERenderGraphError] = [.fileMissing("B"), .invalidJSON("B"), .malformedMaterial("B"), .malformedEffect("B"), .materialUnresolved("B")]
        for error in documents {
            #expect(SceneFailureCause.make(error).reason == error.localizedDescription)
        }
        for error in rendering {
            #expect(SceneFailureCause.make(error).reason == error.localizedDescription)
        }
        for error in resources {
            #expect(SceneFailureCause.make(error).reason == error.errorDescription)
        }
        for error in metal {
            #expect(SceneFailureCause.make(error).reason == error.localizedDescription)
        }
        for error in graph {
            #expect(SceneFailureCause.make(error).reason == error.localizedDescription)
        }
        let models: [WPEMdlParserError] = [.invalidHeader, .implausibleCount(section: "bones", count: 12, limit: 8), .truncated(offset: 42, requested: 8, available: 1), .unterminatedString(offset: 3), .invalidString(offset: 8), .unsupportedSectionMarker(3), .invalidPartTable(42), .invalidVertexBuffer(byteCount: 7, stride: 8), .invalidIndexBuffer(3), .invalidSkeletonMatrix(7), .invalidElementMatrixPayload(actual: 3, expected: 16), .invalidAttachmentHeader(offset: 4), .invalidAnimationHeader(offset: 9), .invalidAnimationTail(offset: 1), .invalidAnimationChannelByteCount(animationID: 7, byteCount: 2, expected: 3), .invalidAnimationChannelDelimiter(animationID: 4, channelIndex: 3, marker: 2, byteCount: 1, expected: 0)]
        let causes = models.map(SceneFailureCause.make)
        #expect(Set(causes.map(\.code)).count == 16)
        for (error, cause) in zip(models, causes) {
            #expect(cause.details.contains(String(reflecting: error)))
            #expect(!cause.canRetry)
        }
        #expect(SceneFailureCause.make(WPEMetalTextureLoaderError.textureAllocationFailed).canRetry)
    }

    @Test("A fatal code from the load error is not replaced by the renderer's coarser diagnostic")
    func loadErrorKeepsItsFatalCode() {
        let format = WPEMetalTextureLoadContextError(
            layerName: "B", path: "materials/B.tex", underlying: WPEMetalTextureLoaderError.unsupportedFormat(.bc7)
        )
        let gap = SceneLoadDiagnostic.materialUnresolved(layer: "B", reason: "format")
        let kept = SceneWallpaperSession.failureCause(for: format, diagnostic: gap)
        #expect(kept.code == "texture.metal_format")
        #expect(kept.failureClass == .fatal)

        // Control: an error with no specific cause still takes the diagnostic's.
        let missing = WPEMetalTextureLoadContextError(
            layerName: "B", path: "materials/B.tex", underlying: SceneResourceResolver.ResolveError.fileMissing
        )
        let filled = SceneWallpaperSession.failureCause(
            for: missing, diagnostic: .fileMissing(layer: "B", path: "materials/B.tex")
        )
        #expect(filled.code == "scene.file_missing")
    }

    @MainActor
    @Test("A real malformed source preserves project identity and its parser cause")
    func malformedSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"title":"Failed B","type":"scene","file":"scene.json"}"#.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data([0xFF]).write(to: folder.appendingPathComponent("scene.json"))
        let service = WallpaperEngineImportService(makeBookmark: { _ in Data([1]) })
        let result = try await service.importProject(folder: folder)
        guard case let .sceneFailure(cause, origin, descriptor) = result else {
            Issue.record("Expected a typed scene import failure")
            return
        }
        #expect(origin.title == "Failed B")
        #expect(descriptor.entryFile == "scene.json")
        #expect(cause.code == "scene.document.invalid_utf8")
        #expect(cause.reason == WPESceneDocumentError.invalidUTF8.localizedDescription)
    }

}
