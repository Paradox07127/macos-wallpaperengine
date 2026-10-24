import CoreLocation
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Weather tile pairs each place with its own weather", .serialized) @MainActor
struct WeatherReadingTests {
    private nonisolated static let clearJSON = Data(#"{"current":{"weather_code":0,"is_day":1}}"#.utf8)
    private nonisolated static let rainJSON = Data(#"{"current":{"weather_code":63,"is_day":1}}"#.utf8)

    private static func place(_ name: String, latitude: Double?) -> WeatherLocationResolution {
        WeatherLocationResolution(
            coordinate: latitude.map { CLLocationCoordinate2D(latitude: $0, longitude: 5) },
            resolvedSource: .manual,
            displayName: name,
            error: latitude == nil ? "No coordinate" : nil,
            failureKind: latitude == nil ? .unavailable : nil
        )
    }

    private nonisolated static func isFor(_ url: URL, latitude: Double) -> Bool {
        url.absoluteString.contains("latitude=\(latitude)&")
    }

    private func withManualLocation(_ body: () async throws -> Void) async rethrows {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }
        var settings = original
        settings.weatherLocation = WeatherLocationPreference(
            source: .manual, manual: .init(latitude: 10, longitude: 5, name: "Alpha")
        )
        SettingsManager.shared.saveGlobalSettings(settings)
        try await body()
    }

    /// Polls until `condition` holds; the fetch resumes on the main actor between polls.
    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 400 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func fetchAlpha(_ service: WeatherReactiveService, _ provider: SwitchableLocationProvider) async throws {
        service.refresh()
        #expect(await settle { provider.resolveCount == 1 && service.locationStatus != .fetching })
        let shown = try #require(WeatherWidgetView.shownReading(service))
        #expect(shown.locationLabel == "Alpha")
        #expect(shown.condition == .clear)
    }

    @Test("A failed fetch for a new place keeps the old weather labelled with the old place", .timeLimit(.minutes(1)))
    func failedFetchKeepsOldPlace() async throws {
        try await withManualLocation {
            let provider = SwitchableLocationProvider(Self.place("Alpha", latitude: 10))
            let service = WeatherReactiveService(locationProvider: provider) { url in
                guard Self.isFor(url, latitude: 10) else { throw URLError(.cannotConnectToHost) }
                return Self.clearJSON
            }
            defer { service.shutdown() }
            try await fetchAlpha(service, provider)

            provider.resolution = Self.place("Bravo", latitude: 20)
            service.refresh()
            #expect(await settle { provider.resolveCount == 2 && service.locationStatus != .fetching })
            #expect(service.locationStatus == .error)
            let shown = WeatherWidgetView.shownReading(service)
            #expect(shown?.locationLabel == "Alpha", "Alpha's clear sky would be captioned with Bravo's name")
            #expect(shown?.condition == .clear)
        }
    }

    @Test("A new place without a coordinate keeps the old weather labelled with the old place", .timeLimit(.minutes(1)))
    func unresolvedPlaceKeepsOldPlace() async throws {
        try await withManualLocation {
            let provider = SwitchableLocationProvider(Self.place("Alpha", latitude: 10))
            let service = WeatherReactiveService(locationProvider: provider) { _ in Self.clearJSON }
            defer { service.shutdown() }
            try await fetchAlpha(service, provider)

            provider.resolution = Self.place("Bravo", latitude: nil)
            service.refresh()
            #expect(await settle { provider.resolveCount == 2 && service.locationStatus != .fetching })
            let shown = WeatherWidgetView.shownReading(service)
            #expect(shown?.locationLabel == "Alpha", "Alpha's clear sky would be captioned with Bravo's name")
            #expect(shown?.condition == .clear)
        }
    }

    @Test("While a new place loads the tile shows the old pair, then the new pair at once", .timeLimit(.minutes(1)))
    func switchPublishesPlaceAndWeatherTogether() async throws {
        try await withManualLocation {
            let (started, startedContinuation) = AsyncStream<Void>.makeStream()
            let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
            let provider = SwitchableLocationProvider(Self.place("Alpha", latitude: 10))
            let service = WeatherReactiveService(locationProvider: provider) { url in
                if Self.isFor(url, latitude: 10) {
                    return Self.clearJSON
                }
                startedContinuation.yield()
                for await _ in gate {
                    break
                }
                return Self.rainJSON
            }
            defer { service.shutdown() }
            try await fetchAlpha(service, provider)

            provider.resolution = Self.place("Bravo", latitude: 20)
            service.refresh()
            var startedIterator = started.makeAsyncIterator()
            _ = await startedIterator.next()
            let midway = WeatherWidgetView.shownReading(service)
            #expect(midway?.locationLabel == "Alpha", "Bravo's name would sit on Alpha's sky until the fetch lands")
            #expect(midway?.condition == .clear)
            #expect(WeatherStatusBadge.shownPlace(service) == "Alpha", "The badge would caption Alpha's sky with Bravo's name")

            gateContinuation.yield()
            #expect(await settle { service.locationStatus == .available })
            let shown = WeatherWidgetView.shownReading(service)
            #expect(shown?.locationLabel == "Bravo")
            #expect(shown?.condition == .rain)
        }
    }

    @Test("A superseded fetch that fails as cancelled leaves the newer success standing", .timeLimit(.minutes(1)))
    func supersededCancelledFetchRecordsNoError() async throws {
        try await withManualLocation {
            let (started, startedContinuation) = AsyncStream<Void>.makeStream()
            let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
            let provider = SwitchableLocationProvider(Self.place("Alpha", latitude: 10))
            let service = WeatherReactiveService(locationProvider: provider) { url in
                guard Self.isFor(url, latitude: 20) else { return Self.clearJSON }
                startedContinuation.yield()
                // An unstructured task ignores the fetch's cancellation, so Bravo stays parked until the gate opens, as URLSession does.
                await Task {
                    for await _ in gate {
                        break
                    }
                }.value
                throw URLError(.cancelled)
            }
            defer { service.shutdown() }
            try await fetchAlpha(service, provider)

            provider.resolution = Self.place("Bravo", latitude: 20)
            service.refresh()
            var startedIterator = started.makeAsyncIterator()
            _ = await startedIterator.next()

            provider.resolution = Self.place("Charlie", latitude: 30)
            service.refresh()
            #expect(await settle { provider.resolveCount == 3 && service.locationStatus == .available })

            gateContinuation.yield()
            // Gives Bravo's task time to resume and return; it never flips the status once fixed, so this waits out the poll.
            _ = await settle { service.locationStatus != .available }
            #expect(service.locationStatus == .available, "Bravo's cancellation would be recorded as a fetch error")
            #expect(service.lastError == nil)
            #expect(WeatherWidgetView.shownReading(service)?.locationLabel == "Charlie")
        }
    }

    @Test("A wind reading too large for an integer still lands", .timeLimit(.minutes(1)))
    func hugeWindReadingLands() async throws {
        try await withManualLocation {
            let json = Data(#"{"current":{"weather_code":0,"wind_speed_10m":1e100,"wind_direction_10m":90}}"#.utf8)
            let provider = SwitchableLocationProvider(Self.place("Alpha", latitude: 10))
            let service = WeatherReactiveService(locationProvider: provider) { _ in json }
            defer { service.shutdown() }
            service.refresh()
            #expect(await settle { provider.resolveCount == 1 && service.locationStatus != .fetching })
            #expect(service.locationStatus == .available)
            #expect(service.currentWind?.speedKPH == 1e100)
        }
    }
}

private final class SwitchableLocationProvider: WeatherLocationProviding {
    var resolution: WeatherLocationResolution
    private(set) var resolveCount = 0

    init(_ resolution: WeatherLocationResolution) {
        self.resolution = resolution
    }

    func resolveCoordinate() async -> WeatherLocationResolution {
        resolveCount += 1
        return resolution
    }

    func requestCoreLocationAuthorizationIfNeeded() {}
}
