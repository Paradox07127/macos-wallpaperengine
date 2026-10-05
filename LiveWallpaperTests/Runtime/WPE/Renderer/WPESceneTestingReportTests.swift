#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Scene testing reports")
struct WPESceneTestingReportTests {
    private let descriptor = SceneDescriptor(
        workshopID: "1234567890", cacheRelativePath: "test", entryFile: "scene.json", capabilityTier: .degraded,
        dependencyWorkshopIDs: ["9876543210"]
    )

    @Test("A clean snapshot explicitly reports zero shader and GPU failures")
    func cleanSnapshotHasExplicitCounts() {
        let diagnostics = SceneRendererDiagnostics(
            loadDiagnostics: nil,
            resolution: WPEResolutionDiagnosticsSnapshot(events: []),
            shaderErrors: .init(count: 0, entries: []),
            gpuErrors: .init(count: 0, last: nil)
        )
        let report = WPERenderDiagnosticReport.make(
            descriptor: SceneDescriptor(workshopID: "test", cacheRelativePath: "test", entryFile: "scene.json", capabilityTier: .degraded),
            diagnostics: diagnostics, errorCode: nil, environmentLines: []
        )
        #expect(report.contains("Shader compile failures: 0"))
        #expect(report.contains("GPU errors: 0"))
    }

    @Test("Polling updates an attempt, while switching and reloading retain separate reports")
    func attemptsSurviveSwitching() {
        let reports = WPESceneTestingReports()
        let session = UUID()
        reports.record(attempt: .init(session: session, generation: 1), descriptor: descriptor, status: "loading", diagnostics: nil)
        reports.record(attempt: .init(session: session, generation: 1), descriptor: descriptor, status: "frame presented", diagnostics: nil)
        reports.record(attempt: .init(session: session, generation: 2), descriptor: descriptor, status: "load failed", diagnostics: nil)
        reports.record(attempt: .init(session: UUID(), generation: 1), descriptor: descriptor, status: "next scene", diagnostics: nil)
        let report = reports.make(environmentLines: [])
        #expect(!report.contains("Status: loading"))
        #expect(report.contains("Status: frame presented"))
        #expect(report.contains("Status: load failed"))
        #expect(report.contains("Scene 3 ·"))
        #expect(!report.contains("Scene 4 ·"))
    }

    @Test("Export removes source identifiers, absolute paths and credentials")
    func exportRedactsIdentifiers() {
        let reports = WPESceneTestingReports()
        reports.record(
            attempt: .init(session: UUID(), generation: 1), descriptor: descriptor,
            status: "1234567890 dependency 9876543210 token=secret123 at /Users/someone/private-scene/scene.pkg",
            diagnostics: nil
        )
        let report = reports.make(environmentLines: [])
        #expect(!report.contains("1234567890"))
        #expect(!report.contains("9876543210"))
        #expect(!report.contains("private-scene"))
        #expect(!report.contains("secret123"))
    }

    @Test("The bounded batch keeps recent attempts and states when older reports were dropped")
    func capacityEvictsOldAttempts() {
        let reports = WPESceneTestingReports(capacity: 2)
        for generation in 1 ... 3 {
            reports.record(attempt: .init(session: UUID(), generation: generation), descriptor: descriptor, status: "attempt \(generation)", diagnostics: nil)
        }
        let report = reports.make(environmentLines: [])
        #expect(report.contains("Older attempts omitted: 1"))
        #expect(!report.contains("Scene 1 ·"))
        #expect(report.contains("Scene 2 ·"))
        #expect(report.contains("Scene 3 ·"))
    }
}
#endif
