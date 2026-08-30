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
                    .fixedSize()
                    .accessibilityLabel(Text("Copy diagnostic summary"))
            }

            SettingRow(
                icon: "square.and.arrow.up",
                iconColor: .blue,
                title: "Export Diagnostics",
                subtitle: "Save a sanitized diagnostic report as a text file."
            ) {
                Button("Export") { beginDiagnosticsExport() }
                    .fixedSize()
                    .accessibilityLabel(Text("Export diagnostics"))
            }

            SettingRow(
                icon: "ladybug",
                iconColor: .red,
                title: "Report a Bug",
                subtitle: "Review diagnostics before opening a GitHub issue."
            ) {
                Button("Open") { presentBugReport() }
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
        BugReporter.makeReport(activeWallpapers: activeWallpapers)
    }

    /// Kind alone can't identify what broke. Carry the per-screen identity the
    /// runtime log now records, so a report and its log excerpt name the same
    /// wallpaper.
    private var activeWallpapers: [String] {
        screenManager.screens.compactMap { screen in
            guard let kind = screenManager.wallpaperSummary(for: screen).wallpaperType?.rawValue else { return nil }
            let identity = [screenManager.wallpaperDisplayName(for: screen), screenManager.wallpaperOriginTitle(for: screen)]
                .compactMap { $0 }
                .joined(separator: " — ")
            return identity.isEmpty ? "screen \(screen.id): \(kind)" : "screen \(screen.id): \(kind) — \(identity)"
        }
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
