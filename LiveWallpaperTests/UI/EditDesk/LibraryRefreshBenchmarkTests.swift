import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// Opt-in: run with `TEST_RUNNER_LW_BENCH=1` (xcodebuild strips the prefix); prints one line per aerial count.
@MainActor
@Suite("Library refresh benchmark", .enabled(if: ProcessInfo.processInfo.environment["LW_BENCH"] != nil))
struct LibraryRefreshBenchmarkTests {
    @Test("refresh() time and sidecar reads as the aerial count grows")
    func refreshCostByAerialCount() async throws {
        for count in [0, 50, 150, 300] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("library-refresh-bench-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let assets = try (0 ..< count).map { index in
                let url = root.appendingPathComponent("aerial-\(index).mov")
                try Data(count: 1024).write(to: url)
                return try AerialAsset(
                    id: "aerial-\(index)", url: url, displayName: "Aerial \(index)", category: nil, fileSize: 1024,
                    bookmarkData: url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                )
            }
            let sidecar = LibraryMetadataSidecar(directory: ConfigurationDirectory(root: root))
            var parses = 0
            var inputs = SavedLibraryModel.Inputs()
            inputs.aerials = { .init(assets: assets, isAuthorized: true, lastScanError: nil, isScanning: false) }
            inputs.metadata = {
                parses += 1
                return sidecar.cached(for: $0)
            }
            let model = SavedLibraryModel(inputs: inputs)
            // Without settled probes every timed refresh would start a probe instead of scanning every row, as an idle window does.
            await model.probeSources()
            model.refresh()
            model.refresh()
            parses = 0
            let clock = ContinuousClock()
            let samples = (0 ..< 20).map { _ in clock.measure { model.refresh() } }.sorted()
            let median = (samples[9] + samples[10]) / 2
            print(String(
                format: "LW_BENCH refresh N=%d median=%.2fms p95=%.2fms parses/refresh=%.1f",
                count, median / .milliseconds(1), samples[18] / .milliseconds(1), Double(parses) / Double(samples.count)
            ))
        }
    }
}
