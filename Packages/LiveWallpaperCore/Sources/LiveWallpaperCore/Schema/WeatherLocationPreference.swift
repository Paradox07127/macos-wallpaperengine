import Foundation
import CoreLocation

/// Coordinate source for weather-reactive effects. No IP-geolocation path —
/// third-party silent lookup was removed as a privacy compromise; use `.off`.
public struct WeatherLocationPreference: Codable, Equatable, Sendable {
    public var source: Source
    /// Kept across source switches so the user can return to manual without re-entry.
    public var manual: ManualLocation?

    public init(source: Source, manual: ManualLocation? = nil) {
        self.source = source
        self.manual = manual
    }

    public enum Source: String, Codable, Sendable {
        case off
        case coreLocation
        case manual

        /// Shipping migration: retired `"ipGeolocation"` (and unknown values) → `.coreLocation`
        /// so a single bad enum does not fail the whole `GlobalSettings` decode.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "off":           self = .off
            case "coreLocation":  self = .coreLocation
            case "manual":        self = .manual
            case "ipGeolocation": self = .coreLocation
            default:              self = .coreLocation
            }
        }
    }

    public struct ManualLocation: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var name: String

        public init(latitude: Double, longitude: Double, name: String) {
            self.latitude = latitude
            self.longitude = longitude
            self.name = name
        }

        public var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    public static let `default` = WeatherLocationPreference(source: .coreLocation, manual: nil)
}
