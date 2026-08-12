import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

struct WPEResolutionDiagnosticsTests {
    @MainActor
    @Test("Diagnostic report builder owns renderer and environment formatting")
    func diagnosticReportBuilderFormatsStableSnapshot() {
        let resolution = WPEResolutionDiagnosticsSnapshot(events: [
            WPEResolutionEvent(
                ref: "materials/fallback.tex",
                attempts: [
                    WPEResolutionAttempt(
                        origin: .builtin,
                        outcome: .resolved
                    )
                ],
                finalOutcome: .resolved
            ),
            WPEResolutionEvent(
                ref: "materials/missing.tex",
                attempts: [
                    WPEResolutionAttempt(
                        origin: .scene,
                        outcome: .fileMissing
                    )
                ],
                finalOutcome: .fileMissing
            )
        ])
        let diagnostics = SceneRendererDiagnostics(
            loadDiagnostics: nil,
            resolution: resolution,
            shaderErrors: .init(
                count: 1,
                entries: [.init(shader: "blur", reason: "compile failed")]
            ),
            gpuErrors: .init(count: 1, last: "device removed")
        )
        let descriptor = SceneDescriptor(
            workshopID: "diagnostic-fixture",
            cacheRelativePath: "wpe-cache/diagnostic-fixture",
            entryFile: "scene.json",
            capabilityTier: .degraded,
            preflightTier: .degradedPlayable,
            preflightFeatureFlags: [.imageEffect]
        )

        let report = WPERenderDiagnosticReport.make(
            descriptor: descriptor,
            diagnostics: diagnostics,
            errorCode: "WPE_FIXTURE",
            environmentLines: ["Environment", "Fixture GPU"]
        )

        #expect(report.contains("Capability: Limited Compatibility"))
        #expect(report.contains("Preflight: Approximate"))
        #expect(report.contains("Features: imageEffect"))
        #expect(report.contains("Error code: WPE_FIXTURE"))
        #expect(report.contains("materials/missing.tex: fileMissing"))
        #expect(report.contains("materials/fallback.tex <- builtin"))
        #expect(report.contains("Shader compile failures: 1"))
        #expect(report.contains("GPU errors: 1 (last: device removed)"))
        #expect(report.hasSuffix("Environment\nFixture GPU"))
    }

    @Test("Records scene miss then engine-assets hit")
    func recordsEngineAssetsHitAfterSceneMiss() throws {
        let primary = try makeTempRoot()
        let engine = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: engine)
        }
        try write("sentinel", relativePath: "assets/models/util/foo.json", under: engine)

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            engineAssetsRootURL: engine,
            tracer: tracer
        )

        let url = try resolver.resolveExistingFileURL(relativePath: "models/util/foo.json")

        #expect(url.lastPathComponent == "foo.json")
        let snapshot = tracer.snapshot()
        #expect(snapshot.events.count == 1)
        let event = try #require(snapshot.events.first)
        #expect(event.ref == "models/util/foo.json")
        #expect(event.attempts == [
            WPEResolutionAttempt(origin: .scene, outcome: .fileMissing),
            WPEResolutionAttempt(origin: .engineAssets, outcome: .resolved)
        ])
        #expect(event.finalOutcome == .resolved)
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.resolvedByOrigin[.engineAssets] == 1)
    }

    @Test("Records every root miss for unresolved ref")
    func recordsAllRootMisses() throws {
        let primary = try makeTempRoot()
        let engine = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: engine)
        }

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            engineAssetsRootURL: engine,
            tracer: tracer
        )

        #expect(throws: SceneResourceResolver.ResolveError.self) {
            _ = try resolver.resolveExistingFileURL(relativePath: "models/util/missing.json")
        }

        let snapshot = tracer.snapshot()
        #expect(snapshot.events.count == 1)
        let event = try #require(snapshot.events.first)
        #expect(event.ref == "models/util/missing.json")
        #expect(event.attempts == [
            WPEResolutionAttempt(origin: .scene, outcome: .fileMissing),
            WPEResolutionAttempt(origin: .engineAssets, outcome: .fileMissing)
        ])
        #expect(event.finalOutcome == .fileMissing)
        #expect(snapshot.missedRefs == [event])
    }

    @Test("Records dependency mount resolution")
    func recordsDependencyResolution() throws {
        let primary = try makeTempRoot()
        let dependency = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: dependency)
        }
        try write("dependency", relativePath: "X", under: dependency)

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [WPEAssetMount(workshopID: "12345", rootURL: dependency)],
            tracer: tracer
        )

        let url = try resolver.resolveExistingFileURL(relativePath: "../12345/X")

        #expect(url.lastPathComponent == "X")
        let snapshot = tracer.snapshot()
        #expect(snapshot.events.count == 1)
        let event = try #require(snapshot.events.first)
        #expect(event.ref == "../12345/X")
        #expect(event.attempts == [
            WPEResolutionAttempt(origin: .dependency("12345"), outcome: .resolved)
        ])
        #expect(event.finalOutcome == .resolved)
        #expect(snapshot.resolvedByOrigin[.dependency("12345")] == 1)
    }

    @Test("Speculative streaming decline is not a miss once the ref resolves eagerly")
    func speculativeStreamingDeclineDoesNotCountAsMiss() {
        let ref = "materials/util/clouds_256.tex"
        let tracer = WPEResolutionTracer()
        tracer.record(WPEResolutionEvent(
            ref: ref,
            attempts: [WPEResolutionAttempt(
                origin: .scene,
                outcome: .otherError("texture(unsupportedAnimation)")
            )],
            finalOutcome: .otherError("texture(unsupportedAnimation)")
        ))
        tracer.record(WPEResolutionEvent(
            ref: ref,
            attempts: [WPEResolutionAttempt(origin: .scene, outcome: .resolved)],
            finalOutcome: .resolved
        ))

        let snapshot = tracer.snapshot()
        #expect(snapshot.events.count == 2)
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty)
    }

    @Test("A ref that never resolves is still reported missing")
    func unresolvedRefStaysMissing() {
        let tracer = WPEResolutionTracer()
        tracer.record(WPEResolutionEvent(
            ref: "materials/ghost.tex",
            attempts: [WPEResolutionAttempt(origin: .scene, outcome: .fileMissing)],
            finalOutcome: .fileMissing
        ))

        let snapshot = tracer.snapshot()
        #expect(snapshot.missedRefs.map(\.ref) == ["materials/ghost.tex"])
    }

    @Test("Single-frame static .tex resolves through the real resolver without a spurious miss")
    func singleFrameStaticTexResolvesWithoutSpuriousMiss() throws {
        let primary = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
        }
        let texPath = "materials/util/black.tex"
        try writeData(
            Self.singleFrameStaticTex(width: 32, height: 32),
            relativePath: texPath,
            under: primary
        )

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer
        )

        #expect(throws: SceneResourceResolver.ResolveError.texture(.unsupportedAnimation)) {
            _ = try resolver.resolveStreamingTexturePayload(relativePath: texPath)
        }
        let payload = try resolver.resolveTexturePayload(relativePath: texPath)
        #expect(payload.largestMipmap?.width == 32)
        #expect(payload.largestMipmap?.height == 32)

        let snapshot = tracer.snapshot()
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty, "speculative streaming decline must not count as a miss")
    }

    @Test("Raster sibling resolves tex-named util image refs")
    func rasterSiblingResolvesTexNamedUtilRefs() throws {
        let primary = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
        }
        try writeData(Self.onePixelPNG, relativePath: "materials/util/white.png", under: primary)

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer
        )

        let image = try resolver.resolveImage(relativePath: "materials/util/white.tex")

        #expect(image.width == 1)
        #expect(image.height == 1)
        let snapshot = tracer.snapshot()
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty)
    }

    @Test("Workshop raw image ref stored as converted material tex resolves without miss")
    func workshopRawImageRefStoredAsConvertedMaterialTexResolvesWithoutMiss() throws {
        let primary = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
        }
        let rawRef = "workshop/2328851328/particle/雪花.jpg"
        try writeData(
            Self.singleFrameStaticTex(width: 4, height: 4),
            relativePath: "materials/\(rawRef).tex",
            under: primary
        )

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer
        )

        let image = try resolver.resolveImage(relativePath: rawRef)

        #expect(image.width == 4)
        #expect(image.height == 4)
        let snapshot = tracer.snapshot()
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty)
        #expect(snapshot.events.first?.ref == rawRef)
        #expect(snapshot.events.first?.attempts == [
            WPEResolutionAttempt(origin: .scene, outcome: .resolved)
        ])
    }

    @Test("Tracer reset clears events")
    func resetClearsEvents() throws {
        let primary = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
        }
        try write("x", relativePath: "x.json", under: primary)

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer
        )

        _ = try resolver.resolveExistingFileURL(relativePath: "x.json")
        #expect(tracer.snapshot().events.count == 1)
        tracer.reset()
        #expect(tracer.snapshot().events.isEmpty)
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-resolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ payload: String, relativePath: String, under root: URL) throws {
        try writeData(Data(payload.utf8), relativePath: relativePath, under: root)
    }

    private func writeData(_ data: Data, relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private static func singleFrameStaticTex(width: Int, height: Int) -> Data {
        var buffer = Data()
        func magic(_ value: String) {
            buffer.append(contentsOf: value.utf8)
            buffer.append(0x00)
        }
        func int32(_ value: Int32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { buffer.append(contentsOf: $0) }
        }
        func uint32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { buffer.append(contentsOf: $0) }
        }

        magic("TEXV0005")
        magic("TEXI0001")
        int32(Int32(WPETexFormat.rgba8888.rawValue))
        uint32(0)
        int32(Int32(width))
        int32(Int32(height))
        int32(Int32(width))
        int32(Int32(height))
        int32(0)

        magic("TEXB0003")
        int32(1)
        int32(-1)
        int32(1)
        int32(Int32(width))
        int32(Int32(height))
        let pixels = width * height * 4
        uint32(0)
        uint32(UInt32(pixels))
        uint32(UInt32(pixels))
        buffer.append(Data(repeating: 0x00, count: pixels))
        return buffer
    }

    private static let onePixelPNG = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=
    """)!
}
