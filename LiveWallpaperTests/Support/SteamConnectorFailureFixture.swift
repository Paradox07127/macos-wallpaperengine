#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper

extension SteamConnectorFailure {
    /// Stands in for a connector call that ended without a usable reply, for closures injected in place of the XPC call.
    static func fixture(_ kind: Kind = .interrupted) -> SteamConnectorFailure {
        SteamConnectorFailure(
            date: Date(), call: "injected()", kind: kind,
            errorDomain: nil, errorCode: nil, debugDescription: nil
        )
    }
}
#endif
