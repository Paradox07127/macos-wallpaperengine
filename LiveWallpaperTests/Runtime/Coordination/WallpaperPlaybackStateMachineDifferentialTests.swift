import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WallpaperPlaybackStateMachine differential vs WallpaperPolicyEngine")
struct WallpaperPlaybackStateMachineDifferentialTests {
    /// Oracle differential over the dimensions the engine actually owns:
    /// intent stays fixed at true (the engine has no intent axis; intent
    /// folding is covered by the machine's own table tests). Every pause
    /// setting is enabled so each discretionary reason can really fire.
    ///
    /// A red here means the machine is wrong — the engine is the oracle and
    /// must not be changed to make this pass.
    @Test("Machine mirrors the engine across the full input lattice")
    func machineMirrorsEngineAcrossInputLattice() {
        let settings = GlobalSettings(
            globalPauseOnBattery: true,
            pauseOnFullScreen: true,
            pauseOnWindowOcclusion: true,
            pauseInLowPowerMode: true
        )
        let thermalStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        let bools = [false, true]
        // One machine across the whole sweep: also proves policy events never
        // disturb the stored intent.
        let machine = WallpaperPlaybackStateMachine(userIntendsToPlay: true)
        var combinations = 0

        for thermalState in thermalStates {
            for memoryLevel in SystemMemoryPressureLevel.allCases {
                for isOnBattery in bools {
                    for isHiddenByFullScreen in bools {
                        for isWindowOccluding in bools {
                            for isApplicationRuleActive in bools {
                                for isUserAbsent in bools {
                                    for isLowPowerMode in bools {
                                        for isFrontmostExcludedByRule in bools {
                                            let inputs = WallpaperPolicyInputs(
                                                powerSource: isOnBattery ? .battery(level: 0.5) : .external,
                                                isHiddenByFullScreen: isHiddenByFullScreen,
                                                isWindowOccluding: isWindowOccluding,
                                                isApplicationRuleActive: isApplicationRuleActive,
                                                thermalState: thermalState,
                                                isUserAbsent: isUserAbsent,
                                                memoryPressureLevel: memoryLevel,
                                                isLowPowerMode: isLowPowerMode,
                                                isFrontmostExcludedByRule: isFrontmostExcludedByRule
                                            )
                                            let decision = WallpaperPolicyEngine.decision(
                                                inputs: inputs,
                                                settings: settings
                                            )
                                            let outputs = machine.policyChanged(decision)
                                            combinations += 1

                                            let label = "thermal=\(thermalState) memory=\(memoryLevel) "
                                                + "battery=\(isOnBattery) fs=\(isHiddenByFullScreen) "
                                                + "occl=\(isWindowOccluding) appRule=\(isApplicationRuleActive) "
                                                + "absent=\(isUserAbsent) lpm=\(isLowPowerMode) "
                                                + "veto=\(isFrontmostExcludedByRule)"
                                            #expect(
                                                outputs.policyProfile == decision.profile,
                                                "policyProfile diverged: \(label)"
                                            )
                                            #expect(
                                                outputs.suspendReasons == decision.suspendReasons,
                                                "suspendReasons diverged: \(label)"
                                            )
                                            #expect(
                                                outputs.throttleActive == !decision.throttleReasons.isEmpty,
                                                "throttleActive diverged: \(label)"
                                            )
                                            #expect(
                                                machine.userIntendsToPlay,
                                                "policy event rewrote intent: \(label)"
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 4 thermal x 3 memory x 2^6 reason inputs x 2 neverPause veto.
        #expect(combinations == 1536)
    }
}
