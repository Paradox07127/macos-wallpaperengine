import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

extension WallpaperPolicyInputs {
    static func test(
        powerSource: PowerMonitor.PowerSource = .external,
        isHiddenByFullScreen: Bool = false,
        isWindowOccluding: Bool = false,
        isApplicationRuleActive: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        isUserAbsent: Bool = false,
        memoryPressureLevel: SystemMemoryPressureLevel = .normal,
        isLowPowerMode: Bool = false,
        isFrontmostExcludedByRule: Bool = false
    ) -> WallpaperPolicyInputs {
        WallpaperPolicyInputs(
            powerSource: powerSource,
            isHiddenByFullScreen: isHiddenByFullScreen,
            isWindowOccluding: isWindowOccluding,
            isApplicationRuleActive: isApplicationRuleActive,
            thermalState: thermalState,
            isUserAbsent: isUserAbsent,
            memoryPressureLevel: memoryPressureLevel,
            isLowPowerMode: isLowPowerMode,
            isFrontmostExcludedByRule: isFrontmostExcludedByRule
        )
    }
}

@Suite("WallpaperPolicyEngine thermal state")
struct WallpaperPolicyEngineThermalTests {

    @Test("Thermal state participates in every power and fullscreen profile decision")
    func thermalStatePowerAndFullscreenMatrix() {
        let settings = GlobalSettings(pauseOnFullScreen: true)
        let thermalExpectations: [(state: ProcessInfo.ThermalState, suspends: Bool)] = [
            (.nominal, false),
            (.fair, false),
            // `.serious` throttles instead of suspending: on a busy scene this
            // app sits near it in ordinary use, and suspending there stopped
            // wallpapers with no setting able to opt out.
            (.serious, false),
            (.critical, true),
        ]
        let powerSources: [PowerMonitor.PowerSource] = [
            .external,
            .battery(level: 0.80),
        ]
        let fullscreenStates = [false, true]

        for thermalExpectation in thermalExpectations {
            for powerSource in powerSources {
                for isHiddenByFullScreen in fullscreenStates {
                    let profile = WallpaperPolicyEngine.performanceProfile(
                        inputs: .test(
                            powerSource: powerSource,
                            isHiddenByFullScreen: isHiddenByFullScreen,
                            thermalState: thermalExpectation.state
                        ),
                        settings: settings
                    )

                    let expectedProfile: WallpaperPerformanceProfile =
                        (isHiddenByFullScreen || thermalExpectation.suspends) ? .suspended : .quality

                    #expect(
                        profile == expectedProfile,
                        "thermal=\(thermalExpectation.state) power=\(powerSource) fs=\(isHiddenByFullScreen) -> expected \(expectedProfile), got \(profile)"
                    )
                }
            }
        }
    }

    @Test("Critical memory pressure suspends regardless of other signals")
    func criticalMemoryPressureSuspends() {
        let settings = GlobalSettings(pauseOnFullScreen: false)

        let decision = WallpaperPolicyEngine.decision(
            inputs: .test(memoryPressureLevel: .critical),
            settings: settings
        )

        #expect(decision.profile == .suspended)
        #expect(decision.suspendReasons == [.memoryPressure])
    }

    @Test("Warning memory pressure throttles rather than suspending")
    func warningMemoryPressureThrottles() {
        let settings = GlobalSettings(pauseOnFullScreen: false)

        let decision = WallpaperPolicyEngine.decision(
            inputs: .test(memoryPressureLevel: .warning),
            settings: settings
        )

        #expect(decision.profile == .quality)
        #expect(decision.throttleReasons == [.memoryPressure])
        #expect(decision.suspendReasons.isEmpty)
    }

    @Test("Serious heat throttles rather than suspending; critical still stops")
    func seriousThermalThrottlesAndCriticalSuspends() {
        let settings = GlobalSettings(pauseOnFullScreen: false)

        let serious = WallpaperPolicyEngine.decision(inputs: .test(thermalState: .serious), settings: settings)
        #expect(serious.profile == .quality)
        #expect(serious.throttleReasons == [.thermal])

        let critical = WallpaperPolicyEngine.decision(inputs: .test(thermalState: .critical), settings: settings)
        #expect(critical.profile == .suspended)
        #expect(critical.suspendReasons == [.thermal])
    }

    @Test("Suspension reports every condition holding it down, not just the first")
    func suspendReasonsAreComplete() {
        let settings = GlobalSettings(globalPauseOnBattery: true, pauseOnFullScreen: true)

        let decision = WallpaperPolicyEngine.decision(
            inputs: .test(
                powerSource: .battery(level: 0.5),
                isHiddenByFullScreen: true,
                isUserAbsent: true
            ),
            settings: settings
        )

        #expect(decision.profile == .suspended)
        #expect(decision.suspendReasons == [.userAbsent, .battery, .fullScreen])
    }
}
