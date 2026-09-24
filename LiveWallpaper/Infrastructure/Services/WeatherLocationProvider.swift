import Foundation
import CoreLocation
import LiveWallpaperCore

@MainActor
protocol WeatherLocationProviding: AnyObject {
    func resolveCoordinate() async -> WeatherLocationResolution

    func requestCoreLocationAuthorizationIfNeeded()
}

@MainActor
protocol WeatherCoreLocationRequesting: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    /// Last Core Location error, cleared by the next fix — authorization status alone cannot tell "not authorized" from "authorized but no fix".
    var lastLocationFailure: Error? { get }
    var resultHandler: ((CLLocation?) -> Void)? { get set }
    var authorizationHandler: ((CLAuthorizationStatus) -> Void)? { get set }

    func requestWhenInUseAuthorization()
    func requestLocation()
}

@MainActor
private final class WeatherCoreLocationClient: NSObject, WeatherCoreLocationRequesting, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    var resultHandler: ((CLLocation?) -> Void)?
    var authorizationHandler: ((CLAuthorizationStatus) -> Void)?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestLocation() {
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor [weak self] in
            self?.lastLocationFailure = nil
            self?.resultHandler?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the error: discarding it would report a failed fix as a permissions problem.
        Task { @MainActor [weak self] in
            self?.lastLocationFailure = error
            self?.resultHandler?(nil)
        }
    }

    private(set) var lastLocationFailure: Error?

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorizationHandler?(status)
        }
    }
}

struct WeatherLocationResolution: Equatable {
    enum FailureKind: Equatable {
        case permissionDenied
        case unavailable
    }

    /// Successful coordinate, or `nil` if every source in the chain failed.
    var coordinate: CLLocationCoordinate2D?
    var resolvedSource: WeatherLocationPreference.Source?
    var displayName: String?
    var error: String?
    var failureKind: FailureKind?

    init(
        coordinate: CLLocationCoordinate2D?,
        resolvedSource: WeatherLocationPreference.Source?,
        displayName: String?,
        error: String?,
        failureKind: FailureKind? = nil
    ) {
        self.coordinate = coordinate
        self.resolvedSource = resolvedSource
        self.displayName = displayName
        self.error = error
        self.failureKind = failureKind
    }

    static let unresolved = WeatherLocationResolution(
        coordinate: nil,
        resolvedSource: nil,
        displayName: nil,
        error: nil,
        failureKind: nil
    )

    /// Manual `==`: CLLocationCoordinate2D isn't Equatable by default.
    static func == (lhs: WeatherLocationResolution, rhs: WeatherLocationResolution) -> Bool {
        lhs.resolvedSource == rhs.resolvedSource &&
        lhs.displayName == rhs.displayName &&
        lhs.error == rhs.error &&
        lhs.failureKind == rhs.failureKind &&
        lhs.coordinate?.latitude == rhs.coordinate?.latitude &&
        lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }
}

@MainActor
final class WeatherLocationProvider: NSObject, WeatherLocationProviding {
    private enum CoreLocationAttempt {
        case resolved(CLLocation)
        case permissionDenied
        case unavailable
        case cancelled
    }

    private let coreLocationClient: any WeatherCoreLocationRequesting
    private var pendingCoreLocationContinuations: [
        UInt64: CheckedContinuation<CLLocation?, Never>
    ] = [:]
    private var nextCoreLocationWaiterID: UInt64 = 0
    private var pendingAuthorizationContinuations: [
        UInt64: CheckedContinuation<CLAuthorizationStatus?, Never>
    ] = [:]
    private var nextAuthorizationWaiterID: UInt64 = 0
    /// Auth in flight until terminal status; later callers piggyback on the prompt.
    private var authorizationRequestInFlight = false
    /// One-shot request in flight (macOS rejects a second concurrent requestLocation).
    private var coreLocationRequestInFlight = false

    override convenience init() {
        self.init(coreLocationClient: WeatherCoreLocationClient())
    }

    init(coreLocationClient: any WeatherCoreLocationRequesting) {
        self.coreLocationClient = coreLocationClient
        super.init()
        coreLocationClient.resultHandler = { [weak self] location in
            self?.fulfillCoreLocationRequest(with: location)
        }
        coreLocationClient.authorizationHandler = { [weak self] status in
            self?.fulfillAuthorizationRequest(with: status)
        }
    }

    #if DEBUG
    var pendingCoreLocationWaiterCountForTesting: Int {
        pendingCoreLocationContinuations.count
    }

    var pendingAuthorizationWaiterCountForTesting: Int {
        pendingAuthorizationContinuations.count
    }
    #endif

    // MARK: - Public API

    func resolveCoordinate() async -> WeatherLocationResolution {
        let preference = SettingsManager.shared.loadGlobalSettings().weatherLocation

        switch preference.source {
        case .off:
            return .unresolved

        case .coreLocation:
            let attempt = await tryCoreLocation()
            if case .resolved(let location) = attempt {
                return WeatherLocationResolution(
                    coordinate: location.coordinate,
                    resolvedSource: .coreLocation,
                    displayName: String(
                        localized: "System location",
                        defaultValue: "System location",
                        bundle: .appLanguage, comment: "Weather source label for macOS Core Location."
                    ),
                    error: nil,
                    failureKind: nil
                )
            }
            if let resolved = tryManual(preference) { return resolved }
            let failureKind: WeatherLocationResolution.FailureKind
            if case .permissionDenied = attempt {
                failureKind = .permissionDenied
            } else {
                failureKind = .unavailable
            }
            // `denied` here is the system-wide switch rather than this app's permission, which `authorizationStatus` cannot see.
            let deniedBySystem = (coreLocationClient.lastLocationFailure as? CLError)?.code == .denied
            let message = failureKind == .unavailable
                && coreLocationClient.lastLocationFailure != nil
                && !deniedBySystem
                ? String(
                    localized: "Couldn't get a location fix. Try again, or choose Manual in Settings › Integrations › Weather.",
                    bundle: .appLanguage, comment: "Weather error when Core Location is authorized but reported a failure rather than a coordinate."
                )
                : String(
                    localized: "Location unavailable. Allow Location Services, or choose Manual in Settings › Integrations › Weather.",
                    defaultValue: "Location unavailable. Allow Location Services, or choose Manual in Settings › Integrations › Weather.",
                    bundle: .appLanguage, comment: "Weather error shown when System location is selected but Core Location did not yield a coordinate and no manual city is set."
                )
            return WeatherLocationResolution(
                coordinate: nil,
                resolvedSource: .coreLocation,
                displayName: nil,
                error: message,
                failureKind: failureKind
            )

        case .manual:
            if let resolved = tryManual(preference) { return resolved }
            return WeatherLocationResolution(
                coordinate: nil,
                resolvedSource: .manual,
                displayName: nil,
                error: String(
                    localized: "Manual location not set. Enter a city in Settings › Integrations › Weather.",
                    defaultValue: "Manual location not set. Enter a city in Settings › Integrations › Weather.",
                    bundle: .appLanguage, comment: "Weather error shown when Manual source is selected but the user has not typed a city yet."
                ),
                failureKind: .unavailable
            )
        }
    }

    func requestCoreLocationAuthorizationIfNeeded() {
        guard SettingsManager.shared.loadGlobalSettings().weatherLocation.source == .coreLocation else {
            return
        }
        guard coreLocationClient.authorizationStatus == .notDetermined,
              !authorizationRequestInFlight else { return }
        authorizationRequestInFlight = true
        coreLocationClient.requestWhenInUseAuthorization()
    }

    // MARK: - CoreLocation

    private func tryCoreLocation() async -> CoreLocationAttempt {
        var status = coreLocationClient.authorizationStatus
        if status == .notDetermined {
            guard let resolvedStatus = await waitForAuthorization() else {
                return .cancelled
            }
            status = resolvedStatus
        }
        guard !Task.isCancelled else {
            return .cancelled
        }
        // Switch-pattern: whenInUse unavailable as == on macOS but can appear at runtime.
        switch status {
        case .authorizedAlways, .authorized, .authorizedWhenInUse:
            break
        default:
            return .permissionDenied
        }

        nextCoreLocationWaiterID &+= 1
        let waiterID = nextCoreLocationWaiterID

        let location = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }

                pendingCoreLocationContinuations[waiterID] = continuation
                guard !coreLocationRequestInFlight else { return }

                coreLocationRequestInFlight = true
                coreLocationClient.requestLocation()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCoreLocationWaiter(waiterID)
            }
        }

        guard !Task.isCancelled else { return .cancelled }
        guard let location else {
            let latestStatus = coreLocationClient.authorizationStatus
            return latestStatus == .denied || latestStatus == .restricted
                ? .permissionDenied
                : .unavailable
        }
        return .resolved(location)
    }

    private func waitForAuthorization() async -> CLAuthorizationStatus? {
        nextAuthorizationWaiterID &+= 1
        let waiterID = nextAuthorizationWaiterID

        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<CLAuthorizationStatus?, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }

                pendingAuthorizationContinuations[waiterID] = continuation
                guard !authorizationRequestInFlight else { return }

                authorizationRequestInFlight = true
                coreLocationClient.requestWhenInUseAuthorization()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAuthorizationWaiter(waiterID)
            }
        }
    }

    private func fulfillAuthorizationRequest(with status: CLAuthorizationStatus) {
        // CLLocationManager may emit an initial `.notDetermined` delegate event
        // when its delegate is attached. It is not an authorization decision.
        guard status != .notDetermined else { return }
        authorizationRequestInFlight = false
        let continuations = Array(pendingAuthorizationContinuations.values)
        pendingAuthorizationContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(returning: status)
        }
    }

    private func cancelAuthorizationWaiter(_ waiterID: UInt64) {
        let continuation = pendingAuthorizationContinuations.removeValue(forKey: waiterID)
        continuation?.resume(returning: nil)
    }

    private func fulfillCoreLocationRequest(with location: CLLocation?) {
        // One system request until callback; drain even if all waiters cancel.
        guard coreLocationRequestInFlight else { return }
        coreLocationRequestInFlight = false
        let continuations = Array(pendingCoreLocationContinuations.values)
        pendingCoreLocationContinuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(returning: location)
        }
    }

    /// Drop one waiter without cancelling the shared system request.
    private func cancelCoreLocationWaiter(_ waiterID: UInt64) {
        let continuation = pendingCoreLocationContinuations.removeValue(forKey: waiterID)
        continuation?.resume(returning: nil)
    }

    // MARK: - Manual

    private func tryManual(_ preference: WeatherLocationPreference) -> WeatherLocationResolution? {
        guard let manual = preference.manual else { return nil }
        return WeatherLocationResolution(
            coordinate: manual.coordinate,
            resolvedSource: .manual,
            displayName: String(
                localized: "Manual: \(manual.name)",
                bundle: .appLanguage, comment: "Weather source label. The placeholder is the user-selected location name."
            ),
            error: nil,
            failureKind: nil
        )
    }
}
