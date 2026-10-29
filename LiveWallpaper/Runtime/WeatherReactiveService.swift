import Foundation
import CoreLocation
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class WeatherReactiveService {

    static let refreshInterval: Duration = .seconds(3600)

    /// The last successful fetch, replaced whole so its place and weather never come from different fetches; nil when stale or off.
    private(set) var currentReading: WeatherReading?
    var currentCondition: WeatherDescription? {
        currentReading?.condition
    }

    var currentParticleEffect: ParticleEffect {
        currentReading?.particleEffect ?? .none
    }

    var currentEffectAdjustments: WeatherEffectAdjustments {
        currentReading?.effectAdjustments ?? .neutral
    }

    var currentIntensity: WeatherIntensity {
        currentReading?.intensity ?? .moderate
    }

    var currentWind: WeatherWind? {
        currentReading?.wind
    }

    private(set) var locationStatus: LocationStatus = .notDetermined
    private(set) var lastError: String?
    private(set) var lastSuccessfulUpdate: Date?
    /// The most recently resolved place, which may not be the one `currentReading` was fetched for. Nil until a resolve completes.
    private(set) var activeLocationLabel: String?

    // MARK: - Types

    enum LocationStatus: String {
        case notDetermined = "Not Determined"
        case denied = "Location Denied"
        case fetching = "Fetching…"
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

    /// Wind as the API reports it: speed in km/h at 10 m, direction in degrees from which it blows (meteorological convention — 270° is a westerly).
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

    /// One successful fetch: the place it was made for and everything measured there.
    struct WeatherReading: Equatable {
        var locationLabel: String?
        var condition: WeatherDescription
        /// How hard it is coming down, apart from *what*, so drizzle and downpour share one effect at two densities.
        var intensity: WeatherIntensity
        /// `is_day` as the API reports it for this location; nil when unavailable.
        var isDaylight: Bool?
        /// Nil when the API omits wind speed or direction.
        var wind: WeatherWind?
        var particleEffect: ParticleEffect
        var effectAdjustments: WeatherEffectAdjustments
        var fetchedAt: Date
    }

    @ObservationIgnored private let locationProvider: WeatherLocationProviding
    @ObservationIgnored private let fetchForecast: @Sendable (URL) async throws -> Data
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

    var hasActiveWork: Bool { updateTask != nil || fetchTask != nil }
    #if DEBUG
    var hasPreferenceObserver: Bool { preferenceObserver != nil }
    #endif

    // MARK: - Open-Meteo Response Model

    private struct OpenMeteoResponse: Decodable {
        /// Everything past weather_code is optional on purpose: a response that drops one of them must still yield a usable condition rather than failing the decode.
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

    init(
        locationProvider: WeatherLocationProviding = WeatherLocationProvider(),
        fetchForecast: @escaping @Sendable (URL) async throws -> Data = { try await URLSession.shared.data(from: $0).0 }
    ) {
        self.locationProvider = locationProvider
        self.fetchForecast = fetchForecast
        observePreferenceChanges()
    }

    deinit {
        updateTask?.cancel()
        fetchTask?.cancel()
        if let observer = preferenceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    #if DEBUG
    var isMonitoringForTesting: Bool { updateTask != nil }
    #endif

    // MARK: - Public API

    func startMonitoring() {
        guard !isShutdown else { return }
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
        if Self.isStale(lastSuccess: lastSuccessfulUpdate, now: Date()) {
            currentReading = nil
        }
        // Off means the entire weather-reactive pipeline is dormant. We still clear the cached state so a previously-rendered particle effect stops driving the wallpaper.
        let preference = SettingsManager.shared.loadGlobalSettings().weatherLocation
        if preference.source == .off {
            lastSuccessfulUpdate = nil
            currentReading = nil
            activeLocationLabel = nil
            lastError = nil
            locationStatus = .notDetermined
            return
        }

        // Apply a 5-minute cooldown to prevent API spamming unless explicitly forced.
        let now = Date()
        if !force, let last = lastFetchCompletedAt, now.timeIntervalSince(last) < 300 {
            Logger.debug("Skipping weather fetch (within 5m cooldown).", category: .screenManager)
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
        let current = [
            "weather_code", "is_day",
            "wind_speed_10m", "wind_gusts_10m", "wind_direction_10m",
            "precipitation", "cloud_cover",
        ].joined(separator: ",")
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=\(current)&timezone=auto"

        guard let url = URL(string: urlString) else {
            lastError = String(localized: "Invalid URL", defaultValue: "Invalid URL", bundle: .appLanguage, comment: "Weather fetch error.")
            locationStatus = .error
            return
        }

        do {
            let data = try await fetchForecast(url)
            try Task.checkCancellation()
            guard !isShutdown else { return }
            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            try Task.checkCancellation()
            guard !isShutdown else { return }

            let weatherCode = response.current.weather_code
            let description = Self.description(forWMOCode: weatherCode)

            let isFreezing = WeatherCodePolicy.isFreezing(wmoCode: weatherCode)
            let isDaylight = response.current.is_day.map { $0 != 0 }
            let fetchedAt = Date()
            currentReading = WeatherReading(
                locationLabel: resolution.displayName,
                condition: description,
                intensity: WeatherCodePolicy.intensity(forWMOCode: weatherCode),
                isDaylight: isDaylight,
                wind: response.current.wind_direction_10m.flatMap { direction in
                    response.current.wind_speed_10m.map { speed in
                        WeatherWind(
                            speedKPH: speed,
                            gustKPH: response.current.wind_gusts_10m,
                            fromDegrees: direction
                        )
                    }
                },
                particleEffect: mapDescriptionToParticle(description, isDaylight: isDaylight),
                effectAdjustments: mapDescriptionToEffects(description, freezing: isFreezing),
                fetchedAt: fetchedAt
            )
            locationStatus = .available
            lastError = nil
            lastSuccessfulUpdate = fetchedAt
            lastFetchCompletedAt = fetchedAt

            Logger.info("Weather updated: \(description.rawValue), code=\(weatherCode), intensity=\(currentIntensity.rawValue), particle=\(currentParticleEffect.rawValue), wind=\(currentWind.map { "\(String(format: "%.0f", $0.speedKPH))km/h@\(String(format: "%.0f", $0.fromDegrees))°" } ?? "n/a"), source=\(resolution.resolvedSource?.rawValue ?? "none")", category: .screenManager)
        } catch is CancellationError {
            return
        } catch {
            // URLSession reports a superseded request as URLError(.cancelled), not CancellationError.
            guard !Task.isCancelled, !isShutdown else { return }
            lastError = error.localizedDescription
            locationStatus = .error
            lastFetchCompletedAt = Date()
            Logger.error("Weather fetch failed: \(error.localizedDescription)", category: .screenManager)
        }
    }

    // MARK: - WMO Weather Code → Description

    nonisolated static func isStale(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= 7200
    }

    nonisolated static func description(forWMOCode code: Int) -> WeatherDescription {
        switch code {
        case 0: .clear
        case 1, 2: .partlyCloudy
        case 3: .cloudy
        case 45, 48: .foggy
        case 51, 53, 55: .drizzle
        case 56, 57: .drizzle
        case 61, 63, 80, 81: .rain
        case 65, 82: .heavyRain
        case 66, 67: .rain
        case 71, 73, 77, 85: .snow
        case 75, 86: .heavySnow
        case 95: .thunderstorm
        case 96, 99: .thunderstorm
        default: .unknown
        }
    }

    // MARK: - Weather → Particle Mapping

    /// Seasonal effects (sakura, falling leaves) stay out: the API says nothing about what's in bloom. lightning stays out — a surprise full-screen flash without consent is jarring.
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
