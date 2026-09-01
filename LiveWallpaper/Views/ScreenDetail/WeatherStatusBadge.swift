import SwiftUI
import AppKit
import LiveWallpaperCore

struct WeatherStatusBadge: View {
    var weatherService: WeatherReactiveService
    var refresh: () -> Void

    /// Accessory apps (LSUIElement) cannot show the system Location permission dialog directly; we surface a one-tap shortcut to System Settings instead.
    private var needsLocationSettingsLink: Bool {
        switch weatherService.locationStatus {
        case .notDetermined, .denied, .error: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: weatherIcon)
                .font(.footnote)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                if let condition = weatherService.currentCondition {
                    Text(condition.titleKey)
                        .font(.footnote.weight(.medium))
                } else {
                    Text(weatherService.locationStatus.titleKey)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let label = weatherService.activeLocationLabel, weatherService.lastError == nil {
                    Text(verbatim: label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let error = weatherService.lastError {
                    Text(verbatim: LogPrivacyRedactor.scrub(error))
                        .font(.caption2)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .lineLimit(1)
                        .help(Text(
                            "Weather fetch error (paths and tokens scrubbed)",
                            comment: "Tooltip on the weather badge's sanitized error caption. Hovering surfaces this hint that PII has been redacted."
                        ))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Weather status: \(weatherStatusLabel)", comment: "Weather badge a11y label. The placeholder is the current condition or location status."))

            Spacer()

            if weatherService.currentParticleEffect != .none {
                Image(systemName: weatherService.currentParticleEffect.iconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if needsLocationSettingsLink {
                Button(action: openLocationSettings) {
                    Text(
                        "Open Settings",
                        comment: "Weather badge button label that jumps to System Settings → Location Services."
                    )
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(CapsuleButtonStyle(preset: .small))
                .help(Text(
                    "Open System Settings → Privacy & Security → Location Services",
                    comment: "Tooltip for the Open Settings button on the weather badge."
                ))
                .accessibilityLabel(Text(
                    "Open Location Services settings",
                    comment: "A11y label for the weather badge Open Settings button."
                ))
            }

            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help(Text(
                "Refresh weather now",
                comment: "Tooltip on the weather badge refresh icon."
            ))
            .accessibilityLabel(Text(
                "Refresh weather",
                comment: "A11y label for the weather badge refresh icon."
            ))
        }
        .padding(.vertical, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private var weatherIcon: String {
        switch weatherService.locationStatus {
        case .available: return "cloud.sun.fill"
        case .fetching: return "arrow.triangle.2.circlepath"
        case .denied: return "location.slash"
        case .notDetermined: return "location.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch weatherService.locationStatus {
        case .available: return .cyan
        case .fetching: return DesignTokens.Colors.Status.warning
        case .denied: return DesignTokens.Colors.Status.danger
        case .notDetermined: return DesignTokens.Colors.Status.warning
        case .error: return DesignTokens.Colors.Status.danger
        }
    }

    private var weatherStatusLabel: String {
        if let condition = weatherService.currentCondition {
            return condition.localizedTitle
        }
        return weatherService.locationStatus.localizedTitle
    }
}

private extension WeatherReactiveService.LocationStatus {
    var titleKey: LocalizedStringKey {
        switch self {
        case .notDetermined: return "Not Determined"
        case .denied: return "Location Denied"
        case .fetching: return "Fetching..."
        case .available: return "Available"
        case .error: return "Error"
        }
    }

    var localizedTitle: String {
        switch self {
        case .notDetermined:
            return String(localized: "Not Determined", defaultValue: "Not Determined", bundle: .appLanguage, comment: "Weather location status.")
        case .denied:
            return String(localized: "Location Denied", defaultValue: "Location Denied", bundle: .appLanguage, comment: "Weather location status.")
        case .fetching:
            return String(localized: "Fetching...", defaultValue: "Fetching...", bundle: .appLanguage, comment: "Weather location status.")
        case .available:
            return String(localized: "Available", defaultValue: "Available", bundle: .appLanguage, comment: "Weather location status.")
        case .error:
            return String(localized: "Error", defaultValue: "Error", bundle: .appLanguage, comment: "Weather location status.")
        }
    }
}

private extension WeatherReactiveService.WeatherDescription {
    var titleKey: LocalizedStringKey {
        switch self {
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly Cloudy"
        case .cloudy: return "Overcast"
        case .foggy: return "Foggy"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy Rain"
        case .snow: return "Snow"
        case .heavySnow: return "Heavy Snow"
        case .thunderstorm: return "Thunderstorm"
        case .unknown: return "Unknown"
        }
    }

    var localizedTitle: String {
        switch self {
        case .clear:
            return String(localized: "Clear", defaultValue: "Clear", bundle: .appLanguage, comment: "Weather condition.")
        case .partlyCloudy:
            return String(localized: "Partly Cloudy", defaultValue: "Partly Cloudy", bundle: .appLanguage, comment: "Weather condition.")
        case .cloudy:
            return String(localized: "Overcast", defaultValue: "Overcast", bundle: .appLanguage, comment: "Weather condition.")
        case .foggy:
            return String(localized: "Foggy", defaultValue: "Foggy", bundle: .appLanguage, comment: "Weather condition.")
        case .drizzle:
            return String(localized: "Drizzle", defaultValue: "Drizzle", bundle: .appLanguage, comment: "Weather condition.")
        case .rain:
            return String(localized: "Rain", defaultValue: "Rain", bundle: .appLanguage, comment: "Weather condition.")
        case .heavyRain:
            return String(localized: "Heavy Rain", defaultValue: "Heavy Rain", bundle: .appLanguage, comment: "Weather condition.")
        case .snow:
            return String(localized: "Snow", defaultValue: "Snow", bundle: .appLanguage, comment: "Weather condition.")
        case .heavySnow:
            return String(localized: "Heavy Snow", defaultValue: "Heavy Snow", bundle: .appLanguage, comment: "Weather condition.")
        case .thunderstorm:
            return String(localized: "Thunderstorm", defaultValue: "Thunderstorm", bundle: .appLanguage, comment: "Weather condition.")
        case .unknown:
            return String(localized: "Unknown", defaultValue: "Unknown", bundle: .appLanguage, comment: "Weather condition.")
        }
    }
}
