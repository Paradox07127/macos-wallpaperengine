import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    /// Toggle starts/stops the live capture tap and persists for next launch.
    @ViewBuilder
    var audioResponseSection: some View {
        #if !LITE_BUILD
        Section {
            SettingRow(
                icon: "waveform",
                iconColor: audioResponseEnabled ? audioStatusColor : .pink,
                title: "Audio Response",
                subtitle: "Let compatible scenes move with the music and sound playing on your Mac.",
                info: "Analyzes your Mac's audio output on-device to compute a frequency spectrum for audio-reactive scenes. Nothing is recorded, saved, or sent anywhere. macOS asks for permission the first time you turn this on."
            ) {
                HStack(spacing: 8) {
                    if audioResponseEnabled {
                        StatusChip(verbatim: audioStatusText, tint: audioStatusColor)
                            .help(Text(verbatim: audioStatusSubtitle))
                    }

                    if audioShowsRegrant {
                        Button("Re-grant Access") {
                            regrantAudioAccess()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel(Text("Re-grant audio access"))
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
            Text("Audio", comment: "Section header for the audio-response toggle in General settings.")
        }
        .onAppear { retainAudioCaptureStatusConsumer() }
        .onDisappear { releaseAudioCaptureStatusConsumer() }
        #endif
    }

    #if !LITE_BUILD
    func applyAudioResponseEnabled(_ enabled: Bool) {
        SystemAudioCaptureManager.shared.setEnabled(enabled)
        audioCaptureState = SystemAudioCaptureManager.shared.state
        if enabled {
            scheduleSystemStatusRefresh(.audioCapture)
        } else {
            audioStatusRefreshPending = false
        }
    }

    func retainAudioCaptureStatusConsumer() {
        guard !isAudioCaptureStatusConsumerRetained else { return }
        isAudioCaptureStatusConsumerRetained = true
        SystemAudioCaptureManager.shared.retain()
        audioCaptureState = SystemAudioCaptureManager.shared.state
    }

    func releaseAudioCaptureStatusConsumer() {
        guard isAudioCaptureStatusConsumerRetained else { return }
        isAudioCaptureStatusConsumerRetained = false
        SystemAudioCaptureManager.shared.release()
        audioCaptureState = SystemAudioCaptureManager.shared.state
    }

    private var audioStatusText: String {
        guard audioResponseEnabled else {
            return String(localized: "Off", comment: "Feature is off.")
        }
        if audioStatusRefreshPending {
            return String(localized: "Checking…", comment: "Inline status while waiting for audio permission state.")
        }
        switch audioCaptureState {
        case .capturing:
            return String(localized: "Granted", comment: "Permission granted.")
        case .failed:
            return String(localized: "Needs Access", comment: "Permission still required.")
        case .idle:
            return String(localized: "Not Granted", comment: "Permission not granted yet.")
        }
    }

    private var audioStatusSubtitle: String {
        guard audioResponseEnabled else {
            return String(localized: "Audio response is off", comment: "Help text when audio response toggle is off.")
        }
        if audioStatusRefreshPending {
            return String(
                localized: "Waiting for macOS to update audio permission",
                comment: "Help text while system audio permission status refreshes."
            )
        }
        switch audioCaptureState {
        case .capturing:
            return String(
                localized: "System audio capture is running",
                comment: "Help text when system audio capture is active."
            )
        case .failed(let reason):
            return LogPrivacyRedactor.scrub(reason)
        case .idle:
            return String(
                localized: "Turn on access to start system audio capture",
                comment: "Help text prompting the user to grant system audio access."
            )
        }
    }

    private var audioStatusColor: Color {
        guard audioResponseEnabled else { return .secondary }
        if audioStatusRefreshPending {
            return .secondary
        }
        switch audioCaptureState {
        case .capturing:
            return DesignTokens.Colors.Status.active
        case .failed:
            return DesignTokens.Colors.Status.danger
        case .idle:
            return DesignTokens.Colors.Status.warning
        }
    }

    private var audioShowsRegrant: Bool {
        guard audioResponseEnabled, !audioStatusRefreshPending else { return false }
        switch audioCaptureState {
        case .capturing:
            return false
        case .failed, .idle:
            return true
        }
    }

    private func regrantAudioAccess() {
        audioResponseEnabled = true
        updateGlobalSettings()
        SystemAudioCaptureManager.shared.retryAccessRequest()
        audioCaptureState = SystemAudioCaptureManager.shared.state
        scheduleSystemStatusRefresh(.audioCapture)
    }
    #endif
}
