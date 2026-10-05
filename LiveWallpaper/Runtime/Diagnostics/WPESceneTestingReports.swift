#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Keeps the latest diagnostics for each load attempt across switches, for this app run only.
@MainActor
final class WPESceneTestingReports {
    static let shared = WPESceneTestingReports()

    struct Attempt: Hashable {
        let session: UUID
        let generation: Int
    }

    private struct Entry {
        let attempt: Attempt
        let number: Int
        let started: Date
        var report: String
    }

    private let capacity: Int
    private var entries: [Entry] = []
    private var nextNumber = 1
    private var omittedCount = 0
    var isEmpty: Bool {
        entries.isEmpty
    }

    init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    func record(attempt: Attempt, descriptor: SceneDescriptor, status: String, diagnostics: SceneRendererDiagnostics?) {
        var report = "Status: \(status)\n" + WPERenderDiagnosticReport.make(
            descriptor: descriptor, diagnostics: diagnostics, errorCode: nil, environmentLines: []
        )
        for identifier in [descriptor.workshopID] + descriptor.dependencyWorkshopIDs where !identifier.isEmpty {
            report = report.replacingOccurrences(of: identifier, with: "<scene-id>")
        }
        // Keep asset-relative references for analysis, but remove absolute paths and credentials.
        report = report.replacingOccurrences(
            of: #"(?:~|/(?:Users|Volumes|private|tmp|Applications|Library))/[^\n\"']+"#,
            with: "<path>", options: .regularExpression
        )
        report = LogPrivacyRedactor.scrub(report)
        if report.count > 12000 {
            report = String(report.prefix(12000)) + "\n[Scene report truncated]"
        }
        if let index = entries.firstIndex(where: { $0.attempt == attempt }) {
            entries[index].report = report
            return
        }
        entries.append(Entry(attempt: attempt, number: nextNumber, started: Date(), report: report))
        nextNumber += 1
        if entries.count > capacity {
            entries.removeFirst()
            omittedCount += 1
        }
    }

    func make(environmentLines: [String] = WPERenderDiagnosticEnvironment.lines()) -> String {
        var sections = [
            "Loomscreen scene testing report v1",
            "Current app run; anonymous labels identify load attempts, including reloads.\nA presented frame does not verify animation, cursor reveal, or visual fidelity.\nAdd observations by label, e.g. Scene 2: cursor reveal does nothing.",
            environmentLines.joined(separator: "\n"),
        ]
        if omittedCount > 0 {
            sections.append("Older attempts omitted: \(omittedCount)")
        }
        if entries.isEmpty {
            sections.append("No scene attempts recorded yet.")
        }
        for entry in entries {
            sections.append("Scene \(entry.number) · \(entry.started.ISO8601Format())\n\(entry.report)")
        }
        return LogPrivacyRedactor.scrub(sections.joined(separator: "\n\n"))
    }
}
#endif
