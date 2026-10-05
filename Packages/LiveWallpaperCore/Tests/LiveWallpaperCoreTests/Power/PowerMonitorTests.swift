import Combine
@testable import LiveWallpaperCore
import Testing

@Suite("Power source changes")
@MainActor
struct PowerMonitorTests {
    @Test("Battery percentage changes publish immediately without a polling timer")
    func batteryChanges() {
        var source: PowerMonitor.PowerSource? = .battery(level: 0.42)
        let monitor = PowerMonitor(readPowerSource: { source }, registersNotifications: false)
        var received: [PowerMonitor.PowerSource] = []
        let subscription = monitor.powerSourcePublisher.sink { received.append($0) }

        source = .battery(level: 0.19)
        monitor.refreshPowerStatus()
        monitor.refreshPowerStatus()
        source = .external
        monitor.refreshPowerStatus()
        source = .battery(level: 0.18)
        monitor.refreshPowerStatus()

        #expect(received == [.battery(level: 0.42), .battery(level: 0.19), .external, .battery(level: 0.18)])
        #expect(monitor.currentPowerSource == .battery(level: 0.18))
        withExtendedLifetime(subscription) {}
    }

    @Test("An unavailable power snapshot preserves the last known source")
    func failedReadPreservesState() {
        var source: PowerMonitor.PowerSource? = .battery(level: 0.12)
        let monitor = PowerMonitor(readPowerSource: { source }, registersNotifications: false)
        var received: [PowerMonitor.PowerSource] = []
        let subscription = monitor.powerSourcePublisher.sink { received.append($0) }

        source = nil
        monitor.refreshPowerStatus()

        #expect(monitor.currentPowerSource == .battery(level: 0.12))
        #expect(received == [.battery(level: 0.12)])
        withExtendedLifetime(subscription) {}
    }
}
