import Foundation
import CoreLocation
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class WeatherReactiveService {

    static let refreshInterval: Duration = .seconds(3600)

    private(set) var currentCondition: WeatherDescription?
    private(set) var currentParticleEffect: ParticleEffect = .none
    private(set) var currentEffectAdjustments: WeatherEffectAdjustments = .neutral
    /// How hard it is coming down, kept apart from *what* is coming down so a
    /// drizzle and a downpour can share one particle effect at two densities.
    private(set) var currentIntensity: WeatherIntensity = .moderate
    /// Freezing drizzle / freezing rain. Only the colour grade reads it today.
    private(set) var currentIsFreezing = false
    /// Live wind, for particles that should lean into it. Nil until a fetch
    /// lands, and nil forever if the API stops sending it.
    private(set) var currentWind: WeatherWind?
    /// `is_day` as the API reports it for this location; nil when unavailable.
    private(set) var currentIsDaylight: Bool?
    private(set) var locationStatus: LocationStatus = .notDetermined
    private(set) var lastError: String?
    /// `nil` until at least one resolve completes. Drives the status badge.
    private(set) var activeLocationLabel: String?

    // MARK: - Types

    enum LocationStatus: String {
        case notDetermined = "Not Determined"
        case denied = "Location Denied"
        case fetching = "Fetching..."
        case available = "Available"
        case error = "Error"
    }

    enum WeatherDescription: String {
        case clear = "Clear"
        case partlyCloudy = "Partly Cloudy"
        case cloudy = "Overcast"
        case foggy = "Foggy"
        case drizzle = "Drizzle"
        case rain = "Rain"
        case heavyRain = "Heavy Rain"
        case snow = "Snow"
        case heavySnow = "Heavy Snow"
        case thunderstorm = "Thunderstorm"
        case unknown = "Unknown"
    }

    /// Wind as the API reports it: speed in km/h at 10 m, direction in degrees
    /// *from* which it blows (meteorological convention — 270° is a westerly,
    /// i.e. blowing towards the east).
    struct WeatherWind: Equatable, Sendable {
        var speedKPH: Double
        var gustKPH: Double?
        var fromDegrees: Double
    }

    struct WeatherEffectAdjustments: Equatable {
        var saturation: Double
        var brightness: Double
        var warmth: Double
        var blurRadius: Double
        var vignetteIntensity: Double

        static let neutral = WeatherEffectAdjustments(
            saturation: 1.0, brightness: 0, warmth: 6500, blurRadius: 0, vignetteIntensity: 0
        )
    }

    @ObservationIgnored private let locationProvider: WeatherLocationProviding
    @ObservationIgnored nonisolated(unsafe) private var updateTask: Task<Void, Never>?
    /// Separate from `updateTask` so an explicit `refresh()` can supersede
    /// the in-flight fetch without tearing down the hourly poll cycle.
    @ObservationIgnored nonisolated(unsafe) private var fetchTask: Task<Void, Never>?
    /// `nonisolated(unsafe)`: only mutated from MainActor code, but deinit
    /// (released on an arbitrary queue) also touches it, which Swift 6 can't prove safe.
    @ObservationIgnored nonisolated(unsafe) private var preferenceObserver: NSObjectProtocol?
    @ObservationIgnored private var lastFetchCompletedAt: Date?
    /// `stopMonitoring()` is restartable for a normal settings toggle;
    /// `shutdown()` is the process-lifetime barrier used during AppKit quit.
    @ObservationIgnored private(set) var isShutdown = false

    /// Internal lifecycle seam used by termination tests. MainActor isolation
    /// keeps the two task references coherent without exposing them publicly.
    var hasActiveWork: Bool { updateTask != nil || fetchTask != nil }
    #if DEBUG
    // Test-only introspection; no production reader.
    var hasPreferenceObserver: Bool { preferenceObserver != nil }
    #endif

    // MARK: - Open-Meteo Response Model

    private struct OpenMeteoResponse: Decodable {
        /// Everything past `weather_code` is optional on purpose: the extra
        /// fields are a bonus, and a response that drops one of them must
        /// still yield a usable condition rather than failing the decode.
        struct Current: Decodable {
            let weather_code: Int
            let is_day: Int?
            let wind_speed_10m: Double?
            let wind_gusts_10m: Double?
            let wind_direction_10m: Double?
            let precipitation: Double?
            let cloud_cover: Double?
        }
        let current: Current
    }

    // MARK: - Initialization

    init(locationProvider: WeatherLocationProviding = WeatherLocationProvider()) {
        self.locationProvider = locationProvider
        observePreferenceChanges()
    }

    deinit {
        updateTask?.cancel()
        fetchTask?.cancel()
        if let observer = preferenceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func startMonitoring() {
        guard !isShutdown else { return }
        locationProvider.requestCoreLocationAuthorizationIfNeeded()

        updateTask?.cancel()
        startFetch(force: false)
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                await MainActor.run {
                    self?.startFetch(force: false)
                }
            }
        }
    }

    func stopMonitoring() {
        updateTask?.cancel()
        updateTask = nil
        fetchTask?.cancel()
        fetchTask = nil
    }

    /// One-way termination barrier: cancel both producers, unregister the
    /// preference callback that could otherwise call `refresh()` again, and
    /// reject every later public entry point.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        stopMonitoring()
        if let observer = preferenceObserver {
            NotificationCenter.default.removeObserver(observer)
            preferenceObserver = nil
        }
    }

    func refresh() {
        guard !isShutdown else { return }
        startFetch(force: true)
    }

    func requestLocationAuthorizationIfNeeded() {
        guard !isShutdown else { return }
        locationProvider.requestCoreLocationAuthorizationIfNeeded()
    }

    /// Single-flight fetch — supersedes any in-flight fetch so refresh taps don't pile up overlapping requests.
    private func startFetch(force: Bool) {
        guard !isShutdown else { return }
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchWeatherIfPossible(force: force)
        }
    }

    // MARK: - Preference Observer

    private func observePreferenceChanges() {
        guard !isShutdown, preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .weatherLocationPreferenceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isShutdown else { return }
                self.refresh()
            }
        }
    }

    // MARK: - Weather Fetch (Open-Meteo)

    private func fetchWeatherIfPossible(force: Bool) async {
        guard !isShutdown else { return }
        // Off means the entire weather-reactive pipeline is dormant: no
        // location query, no Open-Meteo request, no observable updates.
        // We still clear the cached state so a previously-rendered
        // particle effect stops driving the wallpaper.
        let preference = SettingsManager.shared.loadGlobalSettings().weatherLocation
        if preference.source == .off {
            currentCondition = nil
            currentParticleEffect = .none
            currentEffectAdjustments = .neutral
            activeLocationLabel = nil
            lastError = nil
            locationStatus = .notDetermined
            return
        }

        // Apply a 5-minute cooldown to prevent API spamming unless explicitly forced.
        let now = Date()
        if !force, let last = lastFetchCompletedAt, now.timeIntervalSince(last) < 300 {
            Logger.info("Skipping weather fetch (within 5m cooldown).", category: .screenManager)
            return
        }

        locationStatus = .fetching

        let resolution = await locationProvider.resolveCoordinate()
        guard !Task.isCancelled, !isShutdown else { return }
        activeLocationLabel = resolution.displayName

        guard let coordinate = resolution.coordinate else {
            lastError = resolution.error
            switch resolution.failureKind {
            case .permissionDenied:
                locationStatus = .denied
            case .unavailable:
                locationStatus = .error
            case nil:
                locationStatus = resolution.error == nil ? .notDetermined : .error
            }
            return
        }

        // Round coordinates to 2 decimal places (~1.1km precision) to preserve user location privacy.
        let lat = Double(round(coordinate.latitude * 100) / 100)
        let lon = Double(round(coordinate.longitude * 100) / 100)
        // One request, same endpoint, no key: `weather_code` alone was leaving
        // wind, daylight and precipitation on the table at zero extra cost.
        let current = [
            "weather_code", "is_day",
            "wind_speed_10m", "wind_gusts_10m", "wind_direction_10m",
            "precipitation", "cloud_cover",
        ].joined(separator: ",")
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=\(current)&timezone=auto"

        guard let url = URL(string: urlString) else {
            lastError = String(localized: "Invalid URL", defaultValue: "Invalid URL", comment: "Weather fetch error.")
            locationStatus = .error
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard !isShutdown else { return }
            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            try Task.checkCancellation()
            guard !isShutdown else { return }

            let weatherCode = response.current.weather_code
            let description = mapWMOCode(weatherCode)

            currentCondition = description
            currentIntensity = WeatherCodePolicy.intensity(forWMOCode: weatherCode)
            currentIsFreezing = WeatherCodePolicy.isFreezing(wmoCode: weatherCode)
            currentIsDaylight = response.current.is_day.map { $0 != 0 }
            currentWind = response.current.wind_direction_10m.flatMap { direction in
                response.current.wind_speed_10m.map { speed in
                    WeatherWind(
                        speedKPH: speed,
                        gustKPH: response.current.wind_gusts_10m,
                        fromDegrees: direction
                    )
                }
            }
            currentParticleEffect = mapDescriptionToParticle(
                description, isDaylight: currentIsDaylight
            )
            currentEffectAdjustments = mapDescriptionToEffects(description, freezing: currentIsFreezing)
            locationStatus = .available
            lastError = nil
            lastFetchCompletedAt = Date()

            Logger.info("Weather updated: \(description.rawValue), code=\(weatherCode), intensity=\(currentIntensity.rawValue), particle=\(currentParticleEffect.rawValue), wind=\(currentWind.map { "\(Int($0.speedKPH))km/h@\(Int($0.fromDegrees))°" } ?? "n/a"), source=\(resolution.resolvedSource?.rawValue ?? "none")", category: .screenManager)
        } catch is CancellationError {
            return
        } catch {
            guard !isShutdown else { return }
            lastError = error.localizedDescription
            locationStatus = .error
            lastFetchCompletedAt = Date()
            Logger.error("Weather fetch failed: \(error.localizedDescription)", category: .screenManager)
        }
    }

    // MARK: - WMO Weather Code → Description

    private func mapWMOCode(_ code: Int) -> WeatherDescription {
        switch code {
        case 0:           return .clear
        case 1, 2:        return .partlyCloudy
        case 3:           return .cloudy
        case 45, 48:      return .foggy
        case 51, 53, 55:  return .drizzle
        case 56, 57:      return .drizzle
        case 61, 63, 80:  return .rain
        case 65, 81, 82:  return .heavyRain
        case 66, 67:      return .rain
        case 71, 73, 85:  return .snow
        case 75, 77, 86:  return .heavySnow
        case 95:          return .thunderstorm
        case 96, 99:      return .thunderstorm
        default:          return .unknown
        }
    }

    // MARK: - Weather → Particle Mapping

    /// Maps a weather description to a particle effect for auto-reactive mode.
    ///
    /// Seasonal effects (sakura, falling leaves) stay out: the API says nothing
    /// about what is in bloom. `lightning` likewise stays out — a surprise
    /// full-screen flash imposed without consent is jarring.
    ///
    /// Time of day is no longer in that list. The same free request returns
    /// `is_day`, so a clear night can have the stars the effect set has always
    /// had and never used; the old comment's "the API exposes neither
    /// timestamp nor season" was only half true, and the half that was wrong
    /// cost the two nicest effects on the list.
    private func mapDescriptionToParticle(
        _ desc: WeatherDescription, isDaylight: Bool? = nil
    ) -> ParticleEffect {
        if desc == .clear, isDaylight == false { return .stars }
        switch desc {
        case .clear:        return .none
        case .partlyCloudy: return .dust
        case .cloudy:       return .none
        case .foggy:        return .mist
        case .drizzle:      return .rain
        case .rain:         return .rain
        case .heavyRain:    return .rain
        case .snow:         return .snow
        case .heavySnow:    return .snow
        case .thunderstorm: return .rain
        case .unknown:      return .none
        }
    }

    // MARK: - Weather → CIFilter Mapping

    private func mapDescriptionToEffects(
        _ desc: WeatherDescription, freezing: Bool = false
    ) -> WeatherEffectAdjustments {
        var base = baseEffects(desc)
        if freezing {
            // Freezing rain is not the same weather as rain; the grade should
            // read colder and flatter rather than pretending it is.
            base.warmth += 900
            base.saturation = max(0.35, base.saturation - 0.1)
        }
        return base
    }

    private func baseEffects(_ desc: WeatherDescription) -> WeatherEffectAdjustments {
        switch desc {
        case .clear:
            return WeatherEffectAdjustments(
                saturation: 1.15, brightness: 0.02, warmth: 5500,
                blurRadius: 0, vignetteIntensity: 0.3
            )
        case .partlyCloudy:
            return WeatherEffectAdjustments(
                saturation: 1.0, brightness: 0, warmth: 6200,
                blurRadius: 0, vignetteIntensity: 0
            )
        case .cloudy:
            return WeatherEffectAdjustments(
                saturation: 0.75, brightness: -0.05, warmth: 7000,
                blurRadius: 0, vignetteIntensity: 0.5
            )
        case .foggy:
            return WeatherEffectAdjustments(
                saturation: 0.6, brightness: -0.03, warmth: 7500,
                blurRadius: 4, vignetteIntensity: 0.8
            )
        case .drizzle:
            return WeatherEffectAdjustments(
                saturation: 0.8, brightness: -0.05, warmth: 7000,
                blurRadius: 0.5, vignetteIntensity: 0.5
            )
        case .rain:
            return WeatherEffectAdjustments(
                saturation: 0.7, brightness: -0.08, warmth: 7500,
                blurRadius: 1, vignetteIntensity: 1.0
            )
        case .heavyRain:
            return WeatherEffectAdjustments(
                saturation: 0.6, brightness: -0.12, warmth: 8000,
                blurRadius: 2, vignetteIntensity: 1.5
            )
        case .snow:
            return WeatherEffectAdjustments(
                saturation: 0.65, brightness: 0.05, warmth: 8000,
                blurRadius: 1, vignetteIntensity: 0.3
            )
        case .heavySnow:
            return WeatherEffectAdjustments(
                saturation: 0.5, brightness: 0.08, warmth: 8500,
                blurRadius: 3, vignetteIntensity: 0.5
            )
        case .thunderstorm:
            return WeatherEffectAdjustments(
                saturation: 0.5, brightness: -0.15, warmth: 8000,
                blurRadius: 2, vignetteIntensity: 1.5
            )
        case .unknown:
            return .neutral
        }
    }
}
