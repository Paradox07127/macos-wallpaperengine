import Foundation
import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var backupSection: some View {
        Section {
            SettingRow(
                icon: "square.and.arrow.up",
                iconColor: .blue,
                title: "Export Configuration",
                subtitle: "Saves settings and bookmarks, without wallpaper files."
            ) {
                Button("Export") { beginExport() }
                    .fixedSize()
                    .accessibilityHint(Text("Save the current settings, display defaults, bookmarks, and per-display setup to a backup file"))
            }

            SettingRow(
                icon: "square.and.arrow.down",
                iconColor: .blue,
                title: "Import Configuration",
                subtitle: "Replaces current settings and merges bookmarks.",
                info: "Existing bookmarks with the same source are kept."
            ) {
                Button("Import") { beginImport() }
                    .fixedSize()
                    .accessibilityHint(Text("Restore settings, display defaults, bookmarks, and per-display setup from a backup file"))
            }
        } header: {
            Text("Backup & Restore")
        }
    }

    // MARK: - Import / Export Action Handlers

    private func beginExport() {
        do {
            exportDocument = try ConfigurationDocument.snapshot()
            isPresentingExporter = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    /// An alert is still dismissing while its button runs, so the save panel opens a turn later, as `importFeedback` does.
    func beginExportFromAlert() {
        DispatchQueue.main.async { beginExport() }
    }

    private func beginImport() {
        isPresentingImporter = true
    }

    func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let source = urls.first else { return }
            let didStartAccess = source.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    source.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let bundle = try ConfigurationPorter.decode(from: source)
                pendingImportSource = source
                pendingImportBundle = bundle
            } catch let error as ConfigurationPorter.ImportError {
                importErrorMessage = error.errorDescription
            } catch {
                importErrorMessage = error.localizedDescription
            }

        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    func applyPendingImport() {
        guard let bundle = pendingImportBundle else { return }
        let summary = ConfigurationPorter.apply(bundle)
        pendingImportBundle = nil
        pendingImportSource = nil

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
        audioResponseEnabled = settings.audioResponseEnabled
        weatherLocation = settings.weatherLocation
        #if !LITE_BUILD
        applyAudioResponseEnabled(settings.audioResponseEnabled)
        #endif

        let feedback = importFeedbackMessage(for: summary)
        DispatchQueue.main.async {
            importFeedback = feedback
        }
    }

    /// Localize each restored section separately to preserve plural rules.
    private func importFeedbackMessage(for summary: ConfigurationPorter.ApplySummary) -> String {
        guard !summary.isEmpty else {
            return String(
                localized: "Imported file contained no recognizable settings.",
                bundle: .appLanguage, comment: "Toast shown after importing an empty configuration bundle."
            )
        }

        var lines: [String] = []
        if let count = summary.displayCount {
            lines.append(String(
                localized: "Restored \(count) display configurations.",
                bundle: .appLanguage, comment: "Import success line: how many displays were restored. xcstrings provides a pluralized variant."
            ))
        }
        if summary.didRestoreGlobalSettings {
            lines.append(String(
                localized: "Restored global preferences, display defaults, schedule, and shortcuts.",
                bundle: .appLanguage, comment: "Import success line: global settings were restored."
            ))
        }
        if let count = summary.bookmarkCount {
            lines.append(String(
                localized: "Restored \(count) saved bookmarks.",
                bundle: .appLanguage, comment: "Import success line: how many bookmarks were restored. xcstrings provides a pluralized variant."
            ))
        }
        if let count = summary.schemeCount {
            lines.append(String(
                localized: "Restored \(count) saved schemes.",
                bundle: .appLanguage, comment: "Import success line: how many display schemes were restored. xcstrings provides a pluralized variant."
            ))
        }
        return lines.joined(separator: "\n")
    }

    /// Mirrors `ConfigurationPorter.apply`: display setups and global settings are replaced wholesale; bookmarks and schemes merge.
    var importConfirmationMessage: String {
        guard let bundle = pendingImportBundle else { return "" }
        var replaced: [String] = []
        if let count = bundle.screenConfigurations?.count {
            replaced.append(String(
                localized: "• Every display's complete setup, including its wallpaper, playlist, and schedule (\(count) displays in the file)",
                bundle: .appLanguage, comment: "Import confirmation bullet under Replaces: every current display setup is replaced. Placeholder is how many displays the file includes."
            ))
        }
        if bundle.globalSettings != nil {
            replaced.append(String(
                localized: "• Preferences, shortcuts, display defaults, display names, and widget, music, and clock overlays",
                bundle: .appLanguage, comment: "Import confirmation bullet under Replaces: parts of the global settings."
            ))
            #if !LITE_BUILD
            replaced.append(String(
                localized: "• Presets and the Workshop items in the wallpaper library",
                bundle: .appLanguage, comment: "Import confirmation bullet under Replaces: the preset library and the Workshop entries of the wallpaper library."
            ))
            #endif
        }
        var merged: [String] = []
        if let count = bundle.wallpaperBookmarks?.count {
            merged.append(String(
                localized: "• \(count) saved bookmarks",
                bundle: .appLanguage, comment: "Import confirmation bullet: how many bookmarks the bundle includes. xcstrings provides a pluralized variant."
            ))
        }
        if let count = bundle.screenSchemes?.count {
            merged.append(String(
                localized: "• \(count) saved schemes",
                bundle: .appLanguage, comment: "Import confirmation bullet: how many display schemes the bundle includes. xcstrings provides a pluralized variant."
            ))
        }

        var sections: [String] = []
        if !replaced.isEmpty {
            let header = String(localized: "Replaces:", bundle: .appLanguage, comment: "Import confirmation header over the parts of the current configuration the file replaces.")
            sections.append(([header] + replaced).joined(separator: "\n"))
        }
        if !merged.isEmpty {
            let header = String(localized: "Merges (items you already have are kept):", bundle: .appLanguage, comment: "Import confirmation header over the parts of the file that are added next to what exists.")
            sections.append(([header] + merged).joined(separator: "\n"))
        }
        let summary = sections.isEmpty
            ? String(
                localized: "The file contains no recognizable settings.",
                bundle: .appLanguage, comment: "Import confirmation when bundle is empty."
            )
            : sections.joined(separator: "\n\n")

        return summary + "\n\n" + localizedBookmarkPortabilityWarning
    }

    private var localizedBookmarkPortabilityWarning: String {
        String(
            localized: "Original wallpaper files must be available. Selected files and folders need access granted again on this Mac.",
            bundle: .appLanguage, comment: "Import confirmation footer warning about cross-device bookmark portability."
        )
    }
}
