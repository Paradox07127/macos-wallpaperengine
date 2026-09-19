import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Edit Desk stage springs")
struct StageSpringTests {
    @Test("Snap, hover and fly settle within four seconds at 120 Hz")
    func convergence() {
        for parameters in [StageSpring.snap, StageSpring.hover, StageSpring.fly] {
            var spring = StageSpring(value: 0, target: 1, parameters: parameters)
            for _ in 0 ..< 480 {
                spring.step(dt: 1 / 120)
            }
            #expect(spring.isSettled)
            #expect(spring.value == 1)
            #expect(spring.velocity == 0)
        }
    }

    @Test("Snap overshoot stays under three percent in both directions")
    func overshoot() {
        for target in [-1.0, 1.0] {
            var spring = StageSpring(value: 0, target: target, parameters: StageSpring.snap)
            for _ in 0 ..< 480 {
                spring.step(dt: 1 / 120)
                #expect(spring.value * target <= 1.03)
            }
        }
    }

    @Test("A spring at its target is already settled")
    func alreadySettled() {
        let spring = StageSpring(value: 1, target: 1, parameters: StageSpring.snap)
        #expect(spring.isSettled)
    }
}
