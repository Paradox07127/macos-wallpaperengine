#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper

/// Counting units are "pass-equivalent": prepared render passes (`unclassifiedPassCount`
/// when a pass carries no program) plus `unsupported-metadata-only` inventory entries.
struct WPESceneCoverageRecord: Equatable, Sendable {
    let sceneID: String
    let passCounts: [WPEShaderExecutionClassification: Int]
    let unclassifiedPassCount: Int
    /// Custom (`official-source`) passes whose GLSL→MSL translation + library
    /// build succeeded for this scene's rendered frame.
    let customShaderCompiledCount: Int
    let customShaderFailedCount: Int
    let customShaderUntriedCount: Int
}

struct WPECorpusCoverageSummary: Equatable, Sendable {
    let sceneCount: Int
    let passCounts: [WPEShaderExecutionClassification: Int]
    let unclassifiedPassCount: Int
    let customShaderCompiledCount: Int
    let customShaderFailedCount: Int
    let customShaderUntriedCount: Int

    var totalUnits: Int {
        passCounts.values.reduce(0, +) + unclassifiedPassCount
    }

    func share(of classification: WPEShaderExecutionClassification) -> Double {
        let total = totalUnits
        guard total > 0 else { return 0 }
        return Double(passCounts[classification] ?? 0) / Double(total)
    }

    var unclassifiedShare: Double {
        let total = totalUnits
        guard total > 0 else { return 0 }
        return Double(unclassifiedPassCount) / Double(total)
    }

    var customShaderCompileSuccessRate: Double? {
        let attempts = customShaderCompiledCount + customShaderFailedCount
        guard attempts > 0 else { return nil }
        return Double(customShaderCompiledCount) / Double(attempts)
    }
}

enum WPETranspileCoverageAggregator {
    static let orderedClassifications: [WPEShaderExecutionClassification] = [
        .officialSource, .nativeApproximation, .copyFallback, .unsupportedMetadataOnly,
    ]

    static func summarize(_ records: [WPESceneCoverageRecord]) -> WPECorpusCoverageSummary {
        var counts: [WPEShaderExecutionClassification: Int] = [:]
        var unclassified = 0
        var compiled = 0
        var failed = 0
        var untried = 0
        for record in records {
            for (classification, count) in record.passCounts {
                counts[classification, default: 0] += count
            }
            unclassified += record.unclassifiedPassCount
            compiled += record.customShaderCompiledCount
            failed += record.customShaderFailedCount
            untried += record.customShaderUntriedCount
        }
        return WPECorpusCoverageSummary(
            sceneCount: records.count,
            passCounts: counts,
            unclassifiedPassCount: unclassified,
            customShaderCompiledCount: compiled,
            customShaderFailedCount: failed,
            customShaderUntriedCount: untried
        )
    }

    static func table(records: [WPESceneCoverageRecord]) -> String {
        let summary = summarize(records)
        let headers = ["scene", "official", "native", "copy", "metadata", "unclassified",
                       "shaderOK", "shaderFail", "shaderUntried"]
        var rows: [[String]] = [headers]
        for record in records {
            rows.append(row(
                label: record.sceneID,
                counts: record.passCounts,
                unclassified: record.unclassifiedPassCount,
                compiled: record.customShaderCompiledCount,
                failed: record.customShaderFailedCount,
                untried: record.customShaderUntriedCount
            ))
        }
        rows.append(row(
            label: "TOTAL(\(summary.sceneCount))",
            counts: summary.passCounts,
            unclassified: summary.unclassifiedPassCount,
            compiled: summary.customShaderCompiledCount,
            failed: summary.customShaderFailedCount,
            untried: summary.customShaderUntriedCount
        ))

        let widths = (0 ..< headers.count).map { column in
            rows.map { $0[column].count }.max() ?? 0
        }
        let lines = rows.map { cells in
            cells.enumerated()
                .map { index, cell in cell.padding(toLength: widths[index], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }

        var shares = orderedClassifications.map {
            "\($0.rawValue) \(percent(summary.share(of: $0)))"
        }
        shares.append("unclassified \(percent(summary.unclassifiedShare))")
        let rate = if let value = summary.customShaderCompileSuccessRate {
            "\(percent(value)) (\(summary.customShaderCompiledCount)/"
                + "\(summary.customShaderCompiledCount + summary.customShaderFailedCount), "
                + "untried \(summary.customShaderUntriedCount))"
        } else {
            "n/a (no custom shader compile attempted)"
        }
        return (lines + [
            "shares: " + shares.joined(separator: "  "),
            "custom-shader compile success: " + rate,
        ]).joined(separator: "\n")
    }

    private static func row(
        label: String,
        counts: [WPEShaderExecutionClassification: Int],
        unclassified: Int,
        compiled: Int,
        failed: Int,
        untried: Int
    ) -> [String] {
        [label]
            + orderedClassifications.map { String(counts[$0] ?? 0) }
            + [String(unclassified), String(compiled), String(failed), String(untried)]
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
#endif
