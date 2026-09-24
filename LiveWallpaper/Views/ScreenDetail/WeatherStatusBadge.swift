import SwiftUI
import AppKit
import LiveWallpaperCore

struct WeatherStatusBadge: View {
    var weatherService: WeatherReactiveService
    var refresh: () -> Void

    /// Accessory apps (LSUIElement) cannot show the system Location permission dialog directly; we surface a one-tap shortcut to System Settings instead.
    private var needsLocationSettingsLink: Bool {
        guard SettingsManager.shared.loadGlobalSettings().weatherLocation.source == .coreLocation else { return false }
        switch weatherService.locationStatus {
        case .notDetermined, .denied: return true
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

                if let updated = weatherService.lastSuccessfulUpdate {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text("Last updated")
                        Text(updated, style: .relative)
                    }
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
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
                Button(action: Self.openLocationSettings) {
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

    static func openLocationSettings() {
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

extension WeatherReactiveService.LocationStatus {
    var titleKey: LocalizedStringKey {
        switch self {
        case .notDetermined: "Not Determined"
        case .denied: "Location Denied"
        case .fetching: "Fetching…"
        case .available: "Available"
        case .error: "Error"
        }
    }

    var localizedTitle: String {
        switch self {
        case .notDetermined:
            String(localized: "Not Determined", defaultValue: "Not Determined", bundle: .appLanguage, comment: "Weather location status.")
        case .denied:
            String(localized: "Location Denied", defaultValue: "Location Denied", bundle: .appLanguage, comment: "Weather location status.")
        case .fetching:
            String(localized: "Fetching…", defaultValue: "Fetching…", bundle: .appLanguage, comment: "Weather location status.")
        case .available:
            String(localized: "Available", defaultValue: "Available", bundle: .appLanguage, comment: "Weather location status.")
        case .error:
            String(localized: "Error", defaultValue: "Error", bundle: .appLanguage, comment: "Weather location status.")
        }
    }
}

extension WeatherReactiveService.WeatherDescription {
    var titleKey: LocalizedStringKey {
        switch self {
        case .clear: "Clear Sky"
        case .partlyCloudy: "Partly Cloudy"
        case .cloudy: "Overcast"
        case .foggy: "Foggy"
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy Rain"
        case .snow: "Snow"
        case .heavySnow: "Heavy Snow"
        case .thunderstorm: "Thunderstorm"
        case .unknown: "Unknown"
        }
    }

    var localizedTitle: String {
        switch self {
        case .clear:
            String(localized: "Clear Sky", defaultValue: "Clear Sky", bundle: .appLanguage, comment: "Weather condition.")
        case .partlyCloudy:
            String(localized: "Partly Cloudy", defaultValue: "Partly Cloudy", bundle: .appLanguage, comment: "Weather condition.")
        case .cloudy:
            String(localized: "Overcast", defaultValue: "Overcast", bundle: .appLanguage, comment: "Weather condition.")
        case .foggy:
            String(localized: "Foggy", defaultValue: "Foggy", bundle: .appLanguage, comment: "Weather condition.")
        case .drizzle:
            String(localized: "Drizzle", defaultValue: "Drizzle", bundle: .appLanguage, comment: "Weather condition.")
        case .rain:
            String(localized: "Rain", defaultValue: "Rain", bundle: .appLanguage, comment: "Weather condition.")
        case .heavyRain:
            String(localized: "Heavy Rain", defaultValue: "Heavy Rain", bundle: .appLanguage, comment: "Weather condition.")
        case .snow:
            String(localized: "Snow", defaultValue: "Snow", bundle: .appLanguage, comment: "Weather condition.")
        case .heavySnow:
            String(localized: "Heavy Snow", defaultValue: "Heavy Snow", bundle: .appLanguage, comment: "Weather condition.")
        case .thunderstorm:
            String(localized: "Thunderstorm", defaultValue: "Thunderstorm", bundle: .appLanguage, comment: "Weather condition.")
        case .unknown:
            String(localized: "Unknown", defaultValue: "Unknown", bundle: .appLanguage, comment: "Weather condition.")
        }
    }
}
