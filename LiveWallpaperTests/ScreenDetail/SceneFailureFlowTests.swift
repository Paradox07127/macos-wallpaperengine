import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import SwiftUI
import Testing

@Suite("Scene failure flow")
struct SceneFailureFlowTests {
    @Test("Unsafe schema paths are failures, not scenes without options")
    func unsafeSchemaPath() async {
        let result = await WPESceneProjectSchemaLoader.load(
            descriptor: SceneDescriptor(workshopID: "B", cacheRelativePath: "../outside", entryFile: "scene.json", capabilityTier: .imageOnly),
            wpeOrigin: nil
        )
        #expect(result.schema == nil)
        #expect(!result.isExpectedAbsence)
    }

    @MainActor
    @Test("A long author title cannot displace the actual cause from the issue URL")
    func reportKeepsCauseUnderBudget() {
        let failure = WallpaperFailureSnapshot(id: UUID(), title: String(repeating: "场景", count: 6000), workshopID: "1234", displayName: "Display", stage: "loading", cause: WallpaperFailureCause(code: "texture.metal_unavailable", reason: "Missing BC7 support"), previousWallpaper: "A", timestamp: Date(), diagnostics: String(repeating: "log", count: 8000))
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

    @MainActor
    @Test("Failure page lays out in native light and dark appearances")
    func previewLayout() throws {
        let snapshot = WallpaperFailureSnapshot(id: UUID(), title: "Night Sky · Failed Scene B", workshopID: "1234", displayName: "Built-in Display", stage: "loading", cause: WallpaperFailureCause(code: "scene.file_missing", reason: "A file required by the Stars layer is missing: materials/stars.tex."), previousWallpaper: "Mountain Lake · Scene A", timestamp: Date(), diagnostics: "Missing source texture", wallpaperType: .scene)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let host = NSHostingView(rootView: AppLanguageScope(defaults: .appScoped()) { WallpaperFailureView(failure: snapshot, onRetry: {}, onViewDesktop: {}).frame(width: 660, height: 520) })
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(x: 0, y: 0, width: 660, height: 520)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("SceneFailurePreview-\(name).png")
            try png.write(to: destination)
            print("Scene failure UI snapshot: \(destination.path)")
            #expect(host.fittingSize.width <= 660)
        }
    }
}
