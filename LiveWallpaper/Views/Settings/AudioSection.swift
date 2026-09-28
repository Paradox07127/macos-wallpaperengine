import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var audioResponseSection: some View {
        #if !LITE_BUILD
        Section {
            SettingRow(
                icon: "waveform",
                iconColor: audioResponseEnabled ? audioStatusColor : .pink,
                title: "Audio Response",
                info: "Requires system audio access. Compatible scenes use local analysis; audio is not saved or uploaded."
            ) {
                HStack(spacing: 8) {
                    if audioResponseEnabled {
                        StatusChip(verbatim: audioStatusText, tint: audioStatusColor)
                            .help(Text(verbatim: audioStatusSubtitle))
                    }

                    if audioShowsRetry {
                        Button("Retry") {
                            retryAudioCapture()
                        }
                        .fixedSize()
                    }

                    Toggle("", isOn: $audioResponseEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: audioResponseEnabled) { _, newValue in
                            updateGlobalSettings()
                            applyAudioResponseEnabled(newValue)
                        }
                        .accessibilityLabel(Text("Audio Response"))
                        .accessibilityHint(Text("Lets compatible scenes react to the audio playing on your Mac. Off by default; requires audio-recording permission."))
                }
            }
        } header: {
            SettingsSearchSectionHeader("Audio", anchor: .integrationsAudio)
        }
        #endif
    }

    #if !LITE_BUILD
    private var audioCaptureState: SystemAudioCaptureManager.State {
        SystemAudioCaptureManager.shared.state
    }

    func applyAudioResponseEnabled(_ enabled: Bool) {
        SystemAudioCaptureManager.shared.setEnabled(enabled)
    }

    private var audioStatusText: String {
        guard audioResponseEnabled else {
            return String(localized: "Off", bundle: .appLanguage, comment: "Feature is off.")
        }
        switch audioCaptureState {
        case .capturing:
            return String(localized: "Active", bundle: .appLanguage, comment: "System audio capture is currently running.")
        case .failed:
            return String(localized: "Unavailable", bundle: .appLanguage, comment: "System audio capture could not start.")
        case .idle:
            return String(localized: "Ready", bundle: .appLanguage, comment: "Audio response is enabled and waiting for compatible content.")
        }
    }

    private var audioStatusSubtitle: String {
        guard audioResponseEnabled else {
            return String(localized: "Audio response is off", bundle: .appLanguage, comment: "Help text when audio response toggle is off.")
        }
        switch audioCaptureState {
        case .capturing:
            return String(
                localized: "System audio capture is running",
                bundle: .appLanguage, comment: "Help text when system audio capture is active."
            )
        case .failed(let reason):
            return LogPrivacyRedactor.scrub(reason)
        case .idle:
            return String(
                localized: "Waiting for compatible content to use system audio",
                bundle: .appLanguage, comment: "Audio response is enabled but no content currently needs capture."
            )
        }
    }

    private var audioStatusColor: Color {
        guard audioResponseEnabled else { return .secondary }
        switch audioCaptureState {
        case .capturing:
            return DesignTokens.Colors.Status.active
        case .failed:
            return DesignTokens.Colors.Status.danger
        case .idle:
            return .secondary
        }
    }

    private var audioShowsRetry: Bool {
        guard audioResponseEnabled else { return false }
        switch audioCaptureState {
        case .capturing, .idle:
            return false
        case .failed:
            return true
        }
    }

    private func retryAudioCapture() {
        audioResponseEnabled = true
        updateGlobalSettings()
        SystemAudioCaptureManager.shared.retryAccessRequest()
    }
    #endif
}
