import CoreGraphics

enum DisplayRotation: Int32, CaseIterable, Sendable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    /// nil = CG reported an angle outside the four quadrants.
    static func current(for display: CGDirectDisplayID) -> DisplayRotation? {
        DisplayRotation(rawValue: Int32(CGDisplayRotation(display).rounded()))
    }
}

#if !MAS_BUILD
extension DisplayRotation {
    static var isSettable: Bool {
        DisplayPrivateSymbols.shared.setDisplayRotation != nil
    }

    static func set(_ rotation: DisplayRotation, for display: CGDirectDisplayID) throws {
        guard let setDisplayRotation = DisplayPrivateSymbols.shared.setDisplayRotation else {
            throw DisplayControlError.unavailable
        }
        let result = setDisplayRotation(display, rotation.rawValue)
        guard result == .success else { throw DisplayControlError.windowServer(result) }
    }
}
#endif
