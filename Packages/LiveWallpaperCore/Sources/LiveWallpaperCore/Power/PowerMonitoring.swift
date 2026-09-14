import Combine
import CoreGraphics
import Foundation

@MainActor
public protocol PowerMonitoring: AnyObject {
    var powerSourcePublisher: AnyPublisher<PowerMonitor.PowerSource, Never> { get }
    var currentPowerSource: PowerMonitor.PowerSource { get }
    func refreshPowerStatus()
}

extension PowerMonitor: PowerMonitoring {}

@MainActor
public protocol FullScreenDetecting: AnyObject {
    var hiddenScreens: [CGDirectDisplayID: Bool] { get }
    var occludedScreens: [CGDirectDisplayID: Bool] { get }
    /// Union-coverage fraction (0...1), quantized; the continuous source behind the
    /// binary `occludedScreens` (>= 0.85).
    var occlusionFractions: [CGDirectDisplayID: CGFloat] { get }
    func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool
    func isDesktopOccluded(for screenID: CGDirectDisplayID) -> Bool
    func occlusionFraction(for screenID: CGDirectDisplayID) -> Double
    func checkNow()
    /// With this off, `hiddenScreens`/`occludedScreens` stay frozen at the last scan -
    /// a consumer that needs fresh coverage must not read them.
    var isFallbackPollingEnabled: Bool { get }
    func setFallbackPollingEnabled(_ enabled: Bool)
    /// Permanent teardown, not the adaptive polling toggle.
    func stop()
}

extension FullScreenDetector: FullScreenDetecting {}
