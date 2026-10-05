import Foundation
import IOKit.ps
import Combine

@MainActor
public final class PowerMonitor {
    // MARK: - Singleton & Notifications

    public static let shared = PowerMonitor()
    public nonisolated static let powerSourceDidChangeNotification = Notification.Name("com.livewallpaper.powerSourceDidChange")

    // MARK: - Power Source Types

    public enum PowerSource: Equatable, Sendable {
        case battery(level: Double)
        case external

        public var isOnBattery: Bool {
            if case .battery = self { return true }
            return false
        }
    }

    // MARK: - Properties

    private let powerSourceSubject = CurrentValueSubject<PowerSource, Never>(.external)
    /// `nonisolated(unsafe)`: set once in init on the main actor; `deinit` is the only other access.
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private let readPowerSource: () -> PowerSource?

    public var powerSourcePublisher: AnyPublisher<PowerSource, Never> {
        powerSourceSubject.eraseToAnyPublisher()
    }

    public var currentPowerSource: PowerSource {
        powerSourceSubject.value
    }

    // MARK: - Initialization

    private convenience init() {
        self.init(readPowerSource: Self.readSystemPowerSource, registersNotifications: true)
    }

    /// The reader seam lets policy tests model power changes without changing the Mac's power state.
    init(readPowerSource: @escaping () -> PowerSource?, registersNotifications: Bool) {
        self.readPowerSource = readPowerSource
        if registersNotifications {
            setupPowerNotification()
        }
        refreshPowerStatus()
    }

    deinit {
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    // MARK: - Power Monitoring Setup

    private func setupPowerNotification() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.refreshPowerStatus()
            }
        }

        // Unlike the limited notification, this also delivers battery percentage changes.
        guard let source = IOPSNotificationCreateRunLoopSource(
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() else { return }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    // MARK: - Power State Management

    public func refreshPowerStatus() {
        guard let newSource = readPowerSource() else { return }
        let oldSource = powerSourceSubject.value

        guard newSource != oldSource else { return }

        Logger.debug("Power source changing from \(oldSource) to \(newSource)", category: .powerMonitor)
        powerSourceSubject.send(newSource)
        postPowerChangeNotification(oldSource: oldSource, newSource: newSource)

        // Battery percentage changes also land here; only a source switch is notice-worthy.
        guard newSource.isOnBattery != oldSource.isOnBattery else { return }
        if case .battery(let level) = newSource {
            Logger.powerSourceChanged(isOnBattery: true, level: level)
        } else {
            Logger.powerSourceChanged(isOnBattery: false, level: nil)
        }
    }

    private func postPowerChangeNotification(oldSource: PowerSource, newSource: PowerSource) {
        NotificationCenter.default.post(
            name: Self.powerSourceDidChangeNotification,
            object: nil,
            userInfo: [
                "isOnBattery": newSource.isOnBattery,
                "previousSource": oldSource,
                "newSource": newSource
            ]
        )
    }

    // MARK: - Battery Level Monitoring

    private nonisolated static func readSystemPowerSource() -> PowerSource? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let identifier = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as? String else {
            return nil
        }
        return identifier == kIOPMBatteryPowerKey ? .battery(level: getCurrentBatteryLevel(snapshot: snapshot)) : .external
    }

    private nonisolated static func getCurrentBatteryLevel(snapshot: CFTypeRef?) -> Double {
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]

        guard let source = sources?.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
              let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
              maxCapacity > 0
        else { return 1.0 }

        return Double(currentCapacity) / Double(maxCapacity)
    }

}
