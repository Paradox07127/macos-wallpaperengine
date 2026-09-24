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
                info: "Copy a sanitized system and runtime summary."
            ) {
                CopyDiagnosticSummaryButton(copy: copyDiagnosticsSummary)
            }

            SettingRow(
                icon: "square.and.arrow.up",
                iconColor: .blue,
                title: "Export Diagnostics",
                info: "Save a sanitized diagnostic report as a text file."
            ) {
                Button("Export") { beginDiagnosticsExport() }
                    .fixedSize()
                    .accessibilityLabel(Text("Export diagnostics"))
            }

            SettingRow(
                icon: "ladybug",
                iconColor: .red,
                title: "Report a Bug"
            ) {
                Button("Open") { presentBugReport() }
                    .fixedSize()
                    .accessibilityLabel(Text("Report a bug"))
            }

            SettingRow(
                icon: "doc.text.magnifyingglass",
                iconColor: .orange,
                title: "Log Files"
            ) {
                Button("Show in Finder") { revealLogFolder() }
                    .fixedSize()
                    .accessibilityLabel(Text("Show logs in Finder"))
            }

            SettingRow(
                icon: "arrow.counterclockwise",
                iconColor: .red,
                title: "Reset All Settings",
                subtitle: "Restore global preferences, per-display setup, bookmarks, and schemes to their defaults."
            ) {
                Button("Reset") { confirmResetAllSettings() }
                    .fixedSize()
                    .accessibilityLabel(Text("Reset all settings"))
            }
        } header: {
            Text("Advanced", comment: "Section header for diagnostics and developer settings.")
        }
    }

    // MARK: - Reset

    private func confirmResetAllSettings() {
        pendingDestructive = PendingDestructive(
            .resetAllSettings(sceneCapable: screenManager.featureCatalog.isEnabled(.scene)),
            alternative: { beginExportFromAlert() },
            perform: { performResetAllSettings() }
        )
    }

    private func performResetAllSettings() {
        SettingsManager.shared.cleanAllSettings()

        postSettingsNotificationAsync(.dockVisibilityDidChange)
        postSettingsNotificationAsync(.globalShortcutsDidChange)
        postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)
        postSettingsNotificationAsync(.workshopPresetVisibilityDidChange)
        screenManager.handleGlobalSettingsChanged()
        screenManager.resetAllWallpaperSessions()
        undo?.removeAll()
        screenManager.refreshScreens(preserveRuntimeSessions: false)

        let settings = SettingsManager.shared.loadGlobalSettings()
        globalPauseOnBattery = settings.globalPauseOnBattery
        startOnLogin = settings.startOnLogin
        preservePlaybackOnLock = settings.preservePlaybackOnLock
        pauseOnFullScreen = settings.pauseOnFullScreen
        pauseOnWindowOcclusion = settings.pauseOnWindowOcclusion
        pauseInLowPowerMode = settings.pauseInLowPowerMode
        applicationRules = settings.applicationPerformanceRules
        showInDock = settings.showInDock
        wallpaperVisibleInScreenCapture = settings.wallpaperVisibleInScreenCapture
        videoCacheBudgetMB = Double(settings.videoCacheMaxBytesPerScreen) / Double(1024 * 1024)
        audioResponseEnabled = settings.audioResponseEnabled
        adaptiveFrameRateEnabled = settings.adaptiveFrameRateEnabled
        weatherLocation = settings.weatherLocation
        #if !LITE_BUILD
        applyAudioResponseEnabled(settings.audioResponseEnabled)
        #endif
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

private struct CopyDiagnosticSummaryButton: View {
    let copy: () -> Void
    @State private var didCopy = false

    var body: some View {
        Button {
            copy()
            didCopy = true
        } label: {
            if didCopy {
                Text("Copied")
            } else {
                Text("Copy")
            }
        }
        .fixedSize()
        .accessibilityLabel(Text("Copy diagnostic summary"))
        .animation(.snappy, value: didCopy)
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
}
