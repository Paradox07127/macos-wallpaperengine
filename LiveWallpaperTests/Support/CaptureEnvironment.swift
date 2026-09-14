import CoreGraphics
import Foundation
import XCTest

/// A locked screen returns an all-black capture rather than failing, so ask the
/// window server instead of tuning thresholds around a red suite.
enum CaptureEnvironment {
    static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Int == 1
    }

    static func requireUnlockedScreen() throws {
        if screenIsLocked {
            throw XCTSkip("the screen is locked; a capture would be black whatever was drawn")
        }
    }
}
