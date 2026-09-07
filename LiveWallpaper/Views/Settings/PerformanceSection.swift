import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var performanceSection: some View {
        Section {
            SettingRow(icon: "macwindow.badge.plus", iconColor: .purple, title: "Pause on full-screen apps") {
                Toggle("", isOn: $pauseOnFullScreen)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseOnFullScreen) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause on full-screen apps"))
            }

            SettingRow(
                icon: "battery.25",
                iconColor: .green,
                title: "Pause in Low Power Mode"
            ) {
                Toggle("", isOn: $pauseInLowPowerMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseInLowPowerMode) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause in Low Power Mode"))
            }

            SettingRow(
                icon: "rectangle.on.rectangle",
                iconColor: .purple,
                title: "Pause when windows cover the desktop",
                info: "Pauses when windows cover about \(0.85, format: .percent) of the display; resumes when the desktop is revealed."
            ) {
                Toggle("", isOn: $pauseOnWindowOcclusion)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: pauseOnWindowOcclusion) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause when windows cover the desktop"))
                    .accessibilityHint(Text("Pause when other apps' windows cover at least 85 percent of a display"))
            }

            #if !LITE_BUILD
            SettingRow(
                icon: "gauge.with.dots.needle.33percent",
                iconColor: .teal,
                title: "Adaptive frame rate",
                info: "Uses about half the scene frame rate when windows cover half the display or the Mac is on battery."
            ) {
                Toggle("", isOn: $adaptiveFrameRateEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: adaptiveFrameRateEnabled) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Adaptive frame rate"))
                    .accessibilityHint(Text("Scene wallpapers only: reduces frame rate when covered or on battery."))
            }

            if WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler {
                SettingRow(
                    icon: "wand.and.stars",
                    iconColor: .cyan,
                    title: "MetalFX upscaling",
                    info: "Renders scenes at a lower resolution; may blur text or increase power use. Changes reload wallpapers."
                ) {
                    // Render scale is read at session creation; changes require a rebuild.
                    Picker("", selection: $metalFXRenderScale) {
                        Text("Off").tag(1.0)
                        Text("Quality (0.75×)").tag(0.75)
                        Text("Performance (0.5×)").tag(0.5)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: metalFXRenderScale) { _, _ in screenManager.reloadAllScreens() }
                    .accessibilityLabel(Text("MetalFX upscaling"))
                    .accessibilityHint(Text("Reduces scene resolution; may use more power on light scenes. Changes reload wallpapers."))
                }
            }

            SettingRow(
                icon: "cpu",
                iconColor: .indigo,
                title: "Multithreaded rendering",
                info: "Scene wallpapers only. Disable for troubleshooting; changes reload wallpapers."
            ) {
                // Thread mode is read at session creation; changes require a rebuild.
                Toggle("", isOn: $offMainRenderEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: offMainRenderEnabled) { _, _ in screenManager.reloadAllScreens() }
                    .accessibilityLabel(Text("Multithreaded rendering"))
                    .accessibilityHint(Text("Scene wallpapers only. Disable for troubleshooting; changes reload wallpapers."))
            }
            #endif

            SettingRow(icon: "bolt.circle.fill", iconColor: .yellow, title: "Pause on battery") {
                Toggle("", isOn: $globalPauseOnBattery)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: globalPauseOnBattery) { _, _ in updateGlobalSettings() }
                    .accessibilityLabel(Text("Pause on battery"))
            }

            SettingRow(
                icon: "hand.raised",
                iconColor: .blue,
                title: "Application Pause Rules",
                subtitle: appExceptionsSubtitle,
                info: "Rules apply to all displays."
            ) {
                Button("Edit") { showAppExceptions = true }
                    .fixedSize()
                    .accessibilityLabel(Text("Edit application exceptions"))
            }

            SettingRow(
                icon: "memorychip",
                iconColor: .pink,
                title: "Video preload (RAM)",
                info: "Uses memory per display to reduce disk reads. When off, videos stream from disk."
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
                        Text("Off")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        CoalescedSlider(
                            value: videoCacheBudgetMB,
                            in: 0 ... Double(GlobalSettings.maxVideoCacheBytes / (1024 * 1024)),
                            step: 32,
                            owner: "videoCacheBudgetMB",
                            sizing: .flexible(minimum: 0, maximum: .infinity),
                            accessibilityLabel: Text("Video preload (RAM)"),
                            accessibilityValue: { Text(verbatim: videoCacheValueLabel(forMB: $0)) },
                            write: { newValue in
                                videoCacheBudgetMB = (newValue / 32).rounded() * 32
                                updateGlobalSettings()
                            },
                            readout: { _ in
                                Text("1 GB")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        )
                    }
                    .frame(width: DesignTokens.Settings.sliderWidth)

                    Text(videoCacheValueLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Performance & Battery")
        }
    }

    /// Keep singular and plural in separate localization keys.
    private var appExceptionsSubtitle: LocalizedStringKey {
        if applicationRules.isEmpty {
            return "No apps added"
        }
        if applicationRules.count == 1 {
            return "Active for 1 app"
        }
        return "Active for \(applicationRules.count) apps"
    }

    /// `150 MB · 300 MB total` (per-screen · total). Off collapses to
    /// "Streaming only" to avoid a misleading "0 MB total".
    private var videoCacheValueLabel: String {
        videoCacheValueLabel(forMB: videoCacheBudgetMB)
    }

    private func videoCacheValueLabel(forMB videoCacheBudgetMB: Double) -> String {
        guard videoCacheBudgetMB > 0 else {
            return String(localized: "Streaming only", bundle: .appLanguage, comment: "Video cache budget set to off / stream from disk.")
        }

        let perScreenMB = Int(videoCacheBudgetMB)
        let screenCount = max(screenManager.screens.count, 1)
        if screenCount == 1 {
            return "\(perScreenMB) MB"
        }
        let totalMB = perScreenMB * screenCount
        return String(localized: "\(perScreenMB) MB · \(totalMB) MB total", bundle: .appLanguage, comment: "Video cache budget subtitle: per-screen budget then the multi-screen total.")
    }
}
