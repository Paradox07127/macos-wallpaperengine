#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Keeps the latest diagnostics for each load attempt across switches, for this app run only.
@MainActor
final class WPESceneTestingReports {
    static let shared = WPESceneTestingReports()

    struct Attempt: Hashable, Sendable {
        let session: UUID
        let generation: Int
    }

    private struct Entry: Sendable {
        let attempt: Attempt
        let number: Int
        let started: Date
        var descriptor: SceneDescriptor
        var status: String
        var diagnostics: SceneRendererDiagnostics?
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
        if let index = entries.firstIndex(where: { $0.attempt == attempt }) {
            entries[index].descriptor = descriptor
            entries[index].status = status
            entries[index].diagnostics = diagnostics
            return
        }
        entries.append(Entry(
            attempt: attempt, number: nextNumber, started: Date(),
            descriptor: descriptor, status: status, diagnostics: diagnostics
        ))
        nextNumber += 1
        if entries.count > capacity {
            entries.removeFirst()
            omittedCount += 1
        }
    }

    func make(environmentLines: [String] = WPERenderDiagnosticEnvironment.lines()) -> String {
        Self.make(entries: entries, omittedCount: omittedCount, environmentLines: environmentLines)
    }

    func export(environmentLines: [String] = WPERenderDiagnosticEnvironment.lines()) async -> String {
        let snapshot = entries
        let omitted = omittedCount
        return await Task.detached(priority: .userInitiated) {
            Self.make(entries: snapshot, omittedCount: omitted, environmentLines: environmentLines)
        }.value
    }

    private nonisolated static func make(entries: [Entry], omittedCount: Int, environmentLines: [String]) -> String {
        var sections = [
            "Loomscreen scene testing report v1",
            "Current app run; anonymous labels identify load attempts, including reloads.\nA presented frame does not verify animation, cursor reveal, or visual fidelity.\nAdd observations by label, e.g. Scene 2: cursor reveal does nothing.",
            LogPrivacyRedactor.scrub(environmentLines.joined(separator: "\n")),
        ]
        if omittedCount > 0 {
            sections.append("Older attempts omitted: \(omittedCount)")
        }
        if entries.isEmpty {
            sections.append("No scene attempts recorded yet.")
        }
        for entry in entries {
            sections.append("Scene \(entry.number) · \(entry.started.ISO8601Format())\n\(report(for: entry))")
        }
        return sections.joined(separator: "\n\n")
    }

    private nonisolated static func report(for entry: Entry) -> String {
        var report = (["Status: \(entry.status)"] + WPERenderDiagnosticReport.lines(
            descriptor: entry.descriptor, diagnostics: entry.diagnostics,
            errorCode: nil, environmentLines: []
        )).joined(separator: "\n")
        for identifier in [entry.descriptor.workshopID] + entry.descriptor.dependencyWorkshopIDs where !identifier.isEmpty {
            report = report.replacingOccurrences(of: identifier, with: "<scene-id>")
        }
        report = report.replacingOccurrences(
            of: #"(?:~|/(?:Users|Volumes|private|tmp|Applications|Library))/[^\n\"']+"#,
            with: "<path>", options: .regularExpression
        )
        report = LogPrivacyRedactor.scrub(report)
        if report.count > 12000 {
            report = String(report.prefix(12000)) + "\n[Scene report truncated]"
        }
        return report
    }
}
#endif
