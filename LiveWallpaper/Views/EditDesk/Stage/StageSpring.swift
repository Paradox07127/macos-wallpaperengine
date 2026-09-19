import Foundation

@MainActor
struct StageSpring {
    static let snap = StageGeometry.snapSpring
    static let hover = StageGeometry.SpringParameters(response: 0.38)
    static let drop = StageGeometry.SpringParameters(response: 0.45)
    static let row = StageGeometry.rowSpring
    static let ghost = StageGeometry.SpringParameters(response: 0.25)
    static let fly = StageGeometry.SpringParameters(response: 0.5)

    var value: Double
    var target: Double
    var parameters: StageGeometry.SpringParameters
    private(set) var velocity = 0.0

    var isSettled: Bool {
        abs(velocity) < 0.001 && abs(target - value) < 0.001
    }

    /// Hands the spring the speed the gesture had instead of restarting it from rest.
    mutating func launch(to target: Double, velocity: Double) {
        self.target = target
        self.velocity = velocity
    }

    mutating func jump(to value: Double) {
        self.value = value
        target = value
        velocity = 0
    }

    mutating func step(dt: TimeInterval) {
        guard dt > 0 else { return }
        if isSettled {
            jump(to: target)
            return
        }
        // Substeps keep semi-implicit Euler stable after a missed display-link callback.
        let steps = max(1, Int(ceil(min(dt, 0.1) * 240)))
        let h = min(dt, 0.1) / Double(steps)
        for _ in 0 ..< steps {
            let acceleration = (parameters.stiffness * (target - value) - parameters.damping * velocity) / parameters.mass
            velocity += acceleration * h
            value += velocity * h
        }
        if isSettled {
            jump(to: target)
        }
    }
}
