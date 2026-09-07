import CoreGraphics
import Foundation
import XCTest

/// Preconditions the screen-reading suites share.
///
/// A locked screen does not make `CGWindowListCreateImage` fail — it returns a
/// fully black image, so every "is anything drawn here" measurement reads zero
/// and the suite goes red for a reason no product code can be wrong about.
/// Ask the window server directly instead of tuning thresholds around it.
enum CaptureEnvironment {
    static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Int == 1
    }

    /// Skips the calling test when the capture would be black regardless of
    /// what the renderer did.
    static func requireUnlockedScreen() throws {
        if screenIsLocked {
            throw XCTSkip("the screen is locked; a capture would be black whatever was drawn")
        }
    }
}
