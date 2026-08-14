import AppKit
import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var advancedSection: some View {
        Section {
            SettingRow(
                icon: "doc.on.doc",
                iconColor: .blue,
                title: "Copy Diagnostic Summary",
                subtitle: "Copy a sanitized system and runtime summary."
            ) {
                Button("Copy") { copyDiagnosticsSummary() }
                    .adaptiveGlassButton(.regular, size: .small)
                    .fixedSize()
                    .accessibilityLabel(Text("Copy diagnostic summary"))
            }

            SettingRow(
                icon: "square.and.arrow.up",
                iconColor: .blue,
                title: "Export Diagnostics",
                subtitle: "Save a sanitized diagnostic report as a text file."
            ) {
                Button("Export…") { beginDiagnosticsExport() }
                    .adaptiveGlassButton(.regular, size: .small)
                    .fixedSize()
                    .accessibilityLabel(Text("Export diagnostics"))
            }

            SettingRow(
                icon: "ladybug",
                iconColor: .red,
                title: "Report a Bug",
                subtitle: "Review diagnostics before opening a GitHub issue."
            ) {
                Button("Open…") { presentBugReport() }
                    .adaptiveGlassButton(.regular, size: .small)
                    .fixedSize()
                    .accessibilityLabel(Text("Report a bug"))
            }

            SettingRow(
                icon: "doc.text.magnifyingglass",
                iconColor: .orange,
                title: "Log Files",
                subtitle: "Open the folder containing the app's diagnostic logs."
            ) {
                Button("Show in Finder") { revealLogFolder() }
                    .adaptiveGlassButton(.regular, size: .small)
                    .fixedSize()
                    .accessibilityLabel(Text("Show logs in Finder"))
                    .accessibilityHint(Text("Opens the folder containing the app's log files"))
            }
        } header: {
            Text("Advanced", comment: "Section header for diagnostics and developer settings.")
        }
    }

    // MARK: - Diagnostics Actions

    func presentBugReport() {
        pendingBugReport = makeDiagnosticsReport()
    }

    private func copyDiagnosticsSummary() {
        let report = makeDiagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.diagnosticMarkdown, forType: .string)
    }

    private func beginDiagnosticsExport() {
        diagnosticsDocument = DiagnosticDocument(text: makeDiagnosticsReport().diagnosticMarkdown)
        isPresentingDiagnosticsExporter = true
    }

    private func makeDiagnosticsReport() -> BugReport {
        BugReporter.makeReport(activeWallpaperKinds: activeWallpaperKinds)
    }

    private var activeWallpaperKinds: [String] {
        screenManager.wallpaperSessionSummaries
            .compactMap { $0.wallpaperType?.rawValue }
    }

    private func revealLogFolder() {
        if let logURL = Logger.persistentLogFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
            return
        }
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/LiveWallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
