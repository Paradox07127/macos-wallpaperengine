import Testing
import Foundation
import CoreLocation
import LiveWallpaperCore
@testable import LiveWallpaper

// MARK: - Task 5.2 (Dock toggle) + 5.3 (Weather location) + 5.1 (Shortcuts)

@Suite("GlobalSettings: Week 5 fields") @MainActor
struct GlobalSettingsWeek5Tests {

    @Test("Dock visibility round-trips through encode/decode")
    func dockVisibilityRoundTrips() throws {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.showInDock = true
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        #expect(reloaded.showInDock == true)

        settings.showInDock = false
        SettingsManager.shared.saveGlobalSettings(settings)
        #expect(SettingsManager.shared.loadGlobalSettings().showInDock == false)
    }

    @Test("Legacy settings without showInDock decode safely")
    func legacySettingsWithoutShowInDockDecodeSafely() throws {
        let legacyJSON: String = """
        {
          "globalPauseOnBattery": false,
          "preservePlaybackOnLock": false,
          "startOnLogin": false,
          "pauseOnFullScreen": true,
          "recentWPEImports": []
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
        #expect(decoded.showInDock == false)
        #expect(decoded.weatherLocation == .default)
        #expect(decoded.globalShortcuts.isEmpty)
    }

    @Test("Weather location preference round-trips through encode/decode")
    func weatherLocationPreferenceRoundTrips() throws {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(
            source: .manual,
            manual: .init(latitude: 35.6762, longitude: 139.6503, name: "Tokyo, Japan")
        )
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        #expect(reloaded.weatherLocation.source == .manual)
        #expect(reloaded.weatherLocation.manual?.name == "Tokyo, Japan")
        #expect(abs((reloaded.weatherLocation.manual?.latitude ?? 0) - 35.6762) < 0.0001)
    }

    @Test("Shortcut bindings round-trip through encode/decode")
    func shortcutBindingsRoundTrip() throws {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.globalShortcuts = [
            GlobalShortcutAction.togglePlayback.rawAction:
                GlobalShortcutBinding(keyCode: 49, modifiers: [.command, .shift]),
            GlobalShortcutAction.nextWallpaper.rawAction: nil,
            GlobalShortcutAction.toggleMute.rawAction:
                GlobalShortcutBinding(keyCode: 46, modifiers: [.option])
        ]
        SettingsManager.shared.saveGlobalSettings(settings)

        let reloaded = SettingsManager.shared.loadGlobalSettings()
        let toggle = reloaded.globalShortcuts[GlobalShortcutAction.togglePlayback.rawAction]
        #expect(toggle??.keyCode == 49)
        #expect(toggle??.modifiers == [.command, .shift])

        let next = reloaded.globalShortcuts[GlobalShortcutAction.nextWallpaper.rawAction]
        #expect(next == .some(nil))

        let mute = reloaded.globalShortcuts[GlobalShortcutAction.toggleMute.rawAction]
        #expect(mute??.modifiers == [.option])
    }
}

@Suite("GlobalShortcutBinding: rendering & defaults")
struct GlobalShortcutBindingTests {

    @Test("Default bindings cover every action")
    func defaultBindingsCoverEveryAction() {
        for action in GlobalShortcutAction.allCases {
            let binding = GlobalShortcutAction.defaultBinding(for: action)
            #expect(binding != nil, "Action \(action.rawValue) ships without a default binding")
            #expect(binding?.modifiers.contains(.shift) == true || binding?.modifiers.contains(.control) == true,
                "Default binding for \(action.rawValue) should include a modifier to avoid stealing a plain key")
        }
    }

    @Test("Display string includes modifier symbols and key name")
    func displayStringFormatsCorrectly() {
        let binding = GlobalShortcutBinding(keyCode: 49, modifiers: [.control, .shift])
        let rendered = binding.displayString
        #expect(rendered.contains("⌃"))
        #expect(rendered.contains("⇧"))
        #expect(rendered.contains("Space"))
    }

    @Test("Arrow key codes resolve to arrow glyphs")
    func arrowKeyCodesResolveToArrowGlyphs() {
        #expect(GlobalShortcutBinding.keyName(for: 124) == "→")
        #expect(GlobalShortcutBinding.keyName(for: 123) == "←")
        #expect(GlobalShortcutBinding.keyName(for: 125) == "↓")
        #expect(GlobalShortcutBinding.keyName(for: 126) == "↑")
    }

    @Test("Letter key codes resolve to uppercase letter")
    func letterKeyCodesResolveToUppercaseLetter() {
        #expect(GlobalShortcutBinding.keyName(for: 46) == "M")
        #expect(GlobalShortcutBinding.keyName(for: 0) == "A")
        #expect(GlobalShortcutBinding.keyName(for: 31) == "O")
    }
}

@Suite("WeatherLocationProvider: fallback chain", .serialized) @MainActor
struct WeatherLocationProviderFallbackTests {

    @Test("Manual source returns the persisted coordinate")
    func manualSourceReturnsPersistedCoordinate() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(
            source: .manual,
            manual: .init(latitude: 51.5074, longitude: -0.1278, name: "London, UK")
        )
        SettingsManager.shared.saveGlobalSettings(settings)

        let provider = WeatherLocationProvider()
        let resolution = await provider.resolveCoordinate()

        #expect(resolution.resolvedSource == .manual)
        #expect(resolution.coordinate?.latitude == 51.5074)
        #expect(resolution.displayName?.contains("London") == true)
    }

    @Test("Manual without saved coord reports an actionable error and no coordinate")
    func manualWithoutSavedCoordReportsError() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .manual, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let provider = WeatherLocationProvider()
        let resolution = await provider.resolveCoordinate()

        #expect(resolution.resolvedSource == .manual)
        #expect(resolution.coordinate == nil)
        #expect(resolution.error != nil)
        #expect(resolution.failureKind == .unavailable)
    }

    @Test("Off source short-circuits to unresolved without touching any backend")
    func offSourceReturnsUnresolved() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .off, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let provider = WeatherLocationProvider()
        let resolution = await provider.resolveCoordinate()

        #expect(resolution == .unresolved)
    }

    @Test("Concurrent system location resolves share one request and one result")
    func concurrentCoreLocationResolvesPiggyback() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let client = FakeWeatherCoreLocationClient(authorizationStatus: .authorizedAlways)
        let provider = WeatherLocationProvider(coreLocationClient: client)

        async let first = provider.resolveCoordinate()
        let firstStarted = await eventually { client.requestLocationCount == 1 }
        #expect(firstStarted)

        async let second = provider.resolveCoordinate()
        // Both resolves must be parked on the in-flight request before it is
        // completed. Yielding once does not guarantee the second one has
        // registered, and a late waiter would start a second request that this
        // fake never answers.
        let bothParked = await eventually {
            provider.pendingCoreLocationWaiterCountForTesting == 2
        }
        #expect(bothParked)
        #expect(client.requestLocationCount == 1)

        let location = CLLocation(latitude: 37.7749, longitude: -122.4194)
        client.complete(with: location)
        let (firstResolution, secondResolution) = await (first, second)

        #expect(firstResolution.coordinate?.latitude == location.coordinate.latitude)
        #expect(secondResolution.coordinate?.latitude == location.coordinate.latitude)
        #expect(firstResolution == secondResolution)
    }

    @Test("First authorization resumes every waiter into one location request")
    func firstAuthorizationResumesCoalescedLocationRequest() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let client = FakeWeatherCoreLocationClient(authorizationStatus: .notDetermined)
        let provider = WeatherLocationProvider(coreLocationClient: client)
        // Mirrors WeatherReactiveService.startMonitoring(): the explicit prompt
        // and the immediately-started resolve must share one authorization flow.
        provider.requestCoreLocationAuthorizationIfNeeded()
        var firstDidResolve = false
        let first = Task {
            let resolution = await provider.resolveCoordinate()
            firstDidResolve = true
            return resolution
        }
        async let second = provider.resolveCoordinate()

        let promptStarted = await eventually { client.requestAuthorizationCount == 1 }
        #expect(promptStarted)
        #expect(client.requestLocationCount == 0)
        #expect(!firstDidResolve)

        client.completeAuthorization(with: .notDetermined)
        await Task.yield()
        #expect(client.requestAuthorizationCount == 1)
        #expect(client.requestLocationCount == 0)
        #expect(!firstDidResolve)

        client.completeAuthorization(with: .authorizedAlways)
        let locationStarted = await eventually { client.requestLocationCount == 1 }
        #expect(locationStarted)
        #expect(client.requestAuthorizationCount == 1)
        // Resuming the authorization waiters does not synchronously park both
        // resolves on the location request; wait for that before completing it.
        let bothParked = await eventually {
            provider.pendingCoreLocationWaiterCountForTesting == 2
        }
        #expect(bothParked)

        let location = CLLocation(latitude: 40.7128, longitude: -74.0060)
        client.complete(with: location)
        let firstResolution = await first.value
        let secondResolution = await second

        #expect(firstResolution.coordinate?.latitude == location.coordinate.latitude)
        #expect(secondResolution == firstResolution)
        #expect(client.requestLocationCount == 1)
    }

    @Test("Denied and restricted authorization never request location")
    func rejectedAuthorizationDoesNotRequestLocation() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        for status in [CLAuthorizationStatus.denied, .restricted] {
            let client = FakeWeatherCoreLocationClient(authorizationStatus: .notDetermined)
            let provider = WeatherLocationProvider(coreLocationClient: client)
            let resolutionTask = Task { await provider.resolveCoordinate() }

            let promptStarted = await eventually { client.requestAuthorizationCount == 1 }
            #expect(promptStarted)
            client.completeAuthorization(with: status)
            let resolution = await resolutionTask.value

            #expect(resolution.coordinate == nil)
            #expect(resolution.resolvedSource == .coreLocation)
            #expect(resolution.error != nil)
            #expect(resolution.failureKind == .permissionDenied)
            #expect(client.requestLocationCount == 0)
        }
    }

    @Test("When-in-use authorization requests a location instead of permission denied")
    func whenInUseAuthorizationRequestsLocation() async throws {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        // `.authorizedWhenInUse` is unavailable in expression position on macOS
        // (usable only in switch patterns); raw value 4 is the shared
        // CLAuthorizationStatus encoding for it across Apple platforms.
        let whenInUse = try #require(CLAuthorizationStatus(rawValue: 4))
        let client = FakeWeatherCoreLocationClient(authorizationStatus: whenInUse)
        let provider = WeatherLocationProvider(coreLocationClient: client)
        let resolutionTask = Task { await provider.resolveCoordinate() }

        let locationStarted = await eventually { client.requestLocationCount == 1 }
        #expect(locationStarted)
        let location = CLLocation(latitude: 48.8566, longitude: 2.3522)
        client.complete(with: location)
        let resolution = await resolutionTask.value

        #expect(resolution.failureKind != .permissionDenied)
        #expect(resolution.coordinate?.latitude == location.coordinate.latitude)
        #expect(resolution.resolvedSource == .coreLocation)
    }

    @Test("Authorized location failure is unavailable rather than permission denied")
    func authorizedLocationFailureIsUnavailable() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let client = FakeWeatherCoreLocationClient(authorizationStatus: .authorizedAlways)
        let provider = WeatherLocationProvider(coreLocationClient: client)
        let resolutionTask = Task { await provider.resolveCoordinate() }

        let locationStarted = await eventually { client.requestLocationCount == 1 }
        #expect(locationStarted)
        client.complete(with: nil)
        let resolution = await resolutionTask.value

        #expect(resolution.coordinate == nil)
        #expect(resolution.failureKind == .unavailable)
        #expect(client.requestAuthorizationCount == 0)
        #expect(client.requestLocationCount == 1)
    }

    @Test("Authorization revoked during a location request publishes permission denied")
    func authorizationRevokedDuringLocationRequestIsDenied() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let client = FakeWeatherCoreLocationClient(authorizationStatus: .authorizedAlways)
        let provider = WeatherLocationProvider(coreLocationClient: client)
        let resolutionTask = Task { await provider.resolveCoordinate() }

        let locationStarted = await eventually { client.requestLocationCount == 1 }
        #expect(locationStarted)
        client.completeAuthorization(with: .denied)
        client.complete(with: nil)
        let resolution = await resolutionTask.value

        #expect(resolution.coordinate == nil)
        #expect(resolution.failureKind == .permissionDenied)
        #expect(client.requestLocationCount == 1)
    }

    @Test("Weather service publishes denied only for permission failures")
    func weatherServiceDistinguishesDeniedFromUnavailable() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let cases: [
            (WeatherLocationResolution.FailureKind, WeatherReactiveService.LocationStatus)
        ] = [
            (.permissionDenied, .denied),
            (.unavailable, .error)
        ]

        for (failureKind, expectedStatus) in cases {
            let provider = StaticWeatherLocationProvider(
                resolution: WeatherLocationResolution(
                    coordinate: nil,
                    resolvedSource: .coreLocation,
                    displayName: nil,
                    error: "Location failure",
                    failureKind: failureKind
                )
            )
            let service = WeatherReactiveService(locationProvider: provider)
            service.refresh()

            let published = await eventually {
                provider.resolveCount == 1 && service.locationStatus == expectedStatus
            }
            #expect(published)
            service.shutdown()
        }
    }

    @Test("Cancelling an authorization waiter cannot create an overlapping generation")
    func cancelledAuthorizationWaiterDoesNotCreateOverlappingGeneration() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let client = FakeWeatherCoreLocationClient(authorizationStatus: .notDetermined)
        let provider = WeatherLocationProvider(coreLocationClient: client)
        let cancelled = Task { await provider.resolveCoordinate() }
        let promptStarted = await eventually { client.requestAuthorizationCount == 1 }
        #expect(promptStarted)
        cancelled.cancel()
        let cancelledResolution = await cancelled.value

        async let replacement = provider.resolveCoordinate()
        let replacementParked = await eventually {
            provider.pendingAuthorizationWaiterCountForTesting == 1
        }
        #expect(replacementParked)
        #expect(client.requestAuthorizationCount == 1)

        client.completeAuthorization(with: .authorizedAlways)
        let locationStarted = await eventually { client.requestLocationCount == 1 }
        #expect(locationStarted)
        let location = CLLocation(latitude: 51.5074, longitude: -0.1278)
        client.complete(with: location)

        let replacementResolution = await replacement
        #expect(cancelledResolution.coordinate == nil)
        #expect(replacementResolution.coordinate?.longitude == location.coordinate.longitude)
        #expect(client.requestAuthorizationCount == 1)
        #expect(client.requestLocationCount == 1)
    }

    @Test("Cancelling one waiter cannot let an old callback complete a newer request")
    func cancelledWaiterDoesNotCreateOverlappingGeneration() async {
        let original = SettingsManager.shared.loadGlobalSettings()
        defer { SettingsManager.shared.saveGlobalSettings(original) }

        var settings = original
        settings.weatherLocation = WeatherLocationPreference(source: .coreLocation, manual: nil)
        SettingsManager.shared.saveGlobalSettings(settings)

        let client = FakeWeatherCoreLocationClient(authorizationStatus: .authorizedAlways)
        let provider = WeatherLocationProvider(coreLocationClient: client)

        let cancelled = Task { await provider.resolveCoordinate() }
        let firstStarted = await eventually { client.requestLocationCount == 1 }
        #expect(firstStarted)
        cancelled.cancel()
        let cancelledResolution = await cancelled.value

        async let replacement = provider.resolveCoordinate()
        let replacementParked = await eventually {
            provider.pendingCoreLocationWaiterCountForTesting == 1
        }
        #expect(replacementParked)
        #expect(client.requestLocationCount == 1)

        let location = CLLocation(latitude: 35.6762, longitude: 139.6503)
        client.complete(with: location)
        let resolution = await replacement

        #expect(cancelledResolution.coordinate == nil)
        #expect(resolution.coordinate?.longitude == location.coordinate.longitude)
        #expect(client.requestLocationCount == 1)
    }

    @Test("Legacy ipGeolocation rawValue migrates to coreLocation on decode")
    func legacyIPGeolocationMigratesToCoreLocation() throws {
        let legacyJSON = #"{"source":"ipGeolocation"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WeatherLocationPreference.self, from: legacyJSON)
        #expect(decoded.source == .coreLocation)
    }

    @Test("Resolution equality compares coordinates with epsilon")
    func resolutionEqualityComparesCoordinatesWithEpsilon() {
        let a = WeatherLocationResolution(
            coordinate: CLLocationCoordinate2D(latitude: 1.0, longitude: 2.0),
            resolvedSource: .manual,
            displayName: "X",
            error: nil
        )
        let b = WeatherLocationResolution(
            coordinate: CLLocationCoordinate2D(latitude: 1.0, longitude: 2.0),
            resolvedSource: .manual,
            displayName: "X",
            error: nil
        )
        #expect(a == b)

        let c = WeatherLocationResolution(
            coordinate: CLLocationCoordinate2D(latitude: 1.1, longitude: 2.0),
            resolvedSource: .manual,
            displayName: "X",
            error: nil
        )
        #expect(a != c)
    }
}

@MainActor
private final class FakeWeatherCoreLocationClient: WeatherCoreLocationRequesting {
    var authorizationStatus: CLAuthorizationStatus
    var resultHandler: ((CLLocation?) -> Void)?
    var authorizationHandler: ((CLAuthorizationStatus) -> Void)?
    private(set) var requestAuthorizationCount = 0
    private(set) var requestLocationCount = 0

    init(authorizationStatus: CLAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }

    func requestWhenInUseAuthorization() {
        requestAuthorizationCount += 1
    }

    func requestLocation() {
        requestLocationCount += 1
    }

    func complete(with location: CLLocation?) {
        resultHandler?(location)
    }

    func completeAuthorization(with status: CLAuthorizationStatus) {
        authorizationStatus = status
        authorizationHandler?(status)
    }
}

@MainActor
private final class StaticWeatherLocationProvider: WeatherLocationProviding {
    let resolution: WeatherLocationResolution
    private(set) var resolveCount = 0

    init(resolution: WeatherLocationResolution) {
        self.resolution = resolution
    }

    func resolveCoordinate() async -> WeatherLocationResolution {
        resolveCount += 1
        return resolution
    }

    func requestCoreLocationAuthorizationIfNeeded() {}
}

@MainActor
private func eventually(
    attempts: Int = 100,
    _ condition: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}
