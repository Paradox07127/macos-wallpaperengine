import Foundation

enum PlaylistPolicy {
    static func shouldRotate(
        now: Date,
        lastRotation: Date,
        rotationMinutes: Int
    ) -> Bool {
        guard rotationMinutes > 0 else { return false }
        return now.timeIntervalSince(lastRotation) >= Double(rotationMinutes) * 60.0
    }
}
