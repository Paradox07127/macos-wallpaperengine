import AppKit
import CoreLocation
import LiveWallpaperCore
import SwiftUI

extension GeneralSettingsView {
    @ViewBuilder
    var weatherSection: some View {
        Section {
            SettingRow(
                icon: "cloud.sun",
                iconColor: weatherShowsInlineStatus ? weatherPermissionColor : .cyan,
                title: "Weather Location",
                subtitle: "Where weather-reactive effects read conditions"
            ) {
                HStack(spacing: 8) {
                    if weatherShowsInlineStatus {
                        StatusChip(verbatim: weatherPermissionText, tint: weatherPermissionColor)
                            .help(Text(verbatim: weatherPermissionSubtitle))
                    }

                    if weatherShowsGrantButton {
                        Button(weatherGrantButtonTitle) {
                            handleWeatherGrantAction()
                        }
                        .adaptiveGlassButton(.regular, size: .small)
                        .fixedSize()
                    }

                    Picker("Source", selection: weatherSourceBinding) {
                        Text("Off").tag(WeatherLocationPreference.Source.off)
                        Text("System").tag(WeatherLocationPreference.Source.coreLocation)
                        Text("Manual").tag(WeatherLocationPreference.Source.manual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(Text("Weather location source"))
                }
            }

            if weatherLocation.source == .manual {
                ManualLocationPicker(
                    currentSelection: weatherLocation.manual,
                    onCommit: { manual in
                        weatherLocation.manual = manual
                        persistWeatherLocation()
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        } header: {
            Text("Weather")
        } footer: {
            Text("System uses Location Services; Manual lets you pick a city. Powers rain, snow, and fog effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var weatherSourceBinding: Binding<WeatherLocationPreference.Source> {
        Binding(
            get: { weatherLocation.source },
            set: { newValue in
                guard weatherLocation.source != newValue else { return }
                weatherLocation.source = newValue
                persistWeatherLocation()
                if newValue == .coreLocation {
                    scheduleSystemStatusRefresh(.weatherLocation)
                } else {
                    weatherStatusRefreshPending = false
                    refreshLocationAuthorizationStatus()
                }
            }
        )
    }

    /// `updateGlobalSettings()` persists `weatherLocation` and posts
    /// `.weatherLocationPreferenceDidChange` when it actually changed.
    private func persistWeatherLocation() {
        updateGlobalSettings()
        refreshLocationAuthorizationStatus()
    }

    // MARK: - Weather Inline Status

    private var weatherPermissionText: String {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return String(localized: "Checking…", comment: "Weather permission status while refreshing.")
        }
        switch weatherLocation.source {
        case .off:
            return String(localized: "Off", comment: "Feature is off.")
        case .manual:
            return weatherLocation.manual == nil
                ? String(localized: "Manual Needed", comment: "Weather location needs a manual place.")
                : String(localized: "Manual", comment: "Weather uses a manual location.")
        case .coreLocation:
            return locationAuthorizationStatus.displayTitle
        }
    }

    private var weatherPermissionSubtitle: String {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return String(
                localized: "Waiting for macOS to update Location Services status",
                comment: "Weather permission help while Location Services status refreshes."
            )
        }
        switch weatherLocation.source {
        case .off:
            return String(localized: "Weather effects are disabled", comment: "Weather source is off.")
        case .manual:
            return weatherLocation.manual == nil
                ? String(localized: "Choose a manual location", comment: "Prompt to pick a manual weather place.")
                : String(localized: "Using manual location", comment: "Weather is using a manual place.")
        case .coreLocation:
            return locationAuthorizationStatus.displaySubtitle
        }
    }

    private var weatherPermissionColor: Color {
        if weatherStatusRefreshPending, weatherLocation.source == .coreLocation {
            return .secondary
        }
        switch weatherLocation.source {
        case .off, .manual:
            return .secondary
        case .coreLocation:
            return locationAuthorizationStatus.displayColor
        }
    }

    private var weatherShowsGrantButton: Bool {
        guard weatherLocation.source == .coreLocation, !weatherStatusRefreshPending else { return false }
        switch locationAuthorizationStatus {
        case .notDetermined, .denied, .restricted:
            return true
        default:
            return false
        }
    }

    private var weatherGrantButtonTitle: String {
        switch locationAuthorizationStatus {
        case .notDetermined:
            return String(localized: "Re-grant Access", comment: "Button to request Location Services again.")
        default:
            return String(localized: "Open", comment: "Open System Settings.")
        }
    }

    private var weatherShowsInlineStatus: Bool {
        switch weatherLocation.source {
        case .off:
            false
        case .manual:
            weatherLocation.manual == nil
        case .coreLocation:
            true
        }
    }

    private func handleWeatherGrantAction() {
        switch locationAuthorizationStatus {
        case .notDetermined:
            screenManager.weatherService.requestLocationAuthorizationIfNeeded()
            screenManager.weatherService.refresh()
            scheduleSystemStatusRefresh(.weatherLocation)
        default:
            openLocationServicesSettings()
            scheduleSystemStatusRefresh(.weatherLocation)
        }
    }

    private func openLocationServicesSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension CLAuthorizationStatus {
    var displayTitle: String {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return String(localized: "Granted", comment: "Permission granted.")
        case .denied:
            return String(localized: "Denied", comment: "Permission denied.")
        case .restricted:
            return String(localized: "Restricted", comment: "Permission restricted by system policy.")
        case .notDetermined:
            return String(localized: "Not Determined", comment: "Permission not requested yet.")
        @unknown default:
            return String(localized: "Unknown", comment: "Unknown status value.")
        }
    }

    var displaySubtitle: String {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return String(
                localized: "Location Services access is granted",
                comment: "Weather help when Location Services is authorized."
            )
        case .denied:
            return String(
                localized: "Allow access in Location Services",
                comment: "Weather help when Location Services was denied."
            )
        case .restricted:
            return String(
                localized: "Location Services is restricted on this Mac",
                comment: "Weather help when Location Services is restricted."
            )
        case .notDetermined:
            return String(
                localized: "macOS has not asked for Location Services yet",
                comment: "Weather help when Location Services was never prompted."
            )
        @unknown default:
            return String(
                localized: "macOS returned an unknown location status",
                comment: "Weather help for an unexpected Location Services status."
            )
        }
    }

    var displayColor: Color {
        switch self {
        case .authorizedAlways, .authorizedWhenInUse:
            return DesignTokens.Colors.Status.active
        case .denied, .restricted:
            return DesignTokens.Colors.Status.danger
        case .notDetermined:
            return DesignTokens.Colors.Status.warning
        @unknown default:
            return .secondary
        }
    }
}
