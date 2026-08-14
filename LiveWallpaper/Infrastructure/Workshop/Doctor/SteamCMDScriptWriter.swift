#if !LITE_BUILD
import Darwin
import Foundation

/// Username validation gate for every SteamCMD/XPC entry point. Script-writing
/// used to live here; it moved into the connector along with every other Steam
/// write (see `SteamWriteOwnershipTests`), leaving only this check behind.
enum SteamCMDScriptWriter {
    /// `^[A-Za-z0-9_]{1,32}$` — Steam's documented login-name charset.
    static func validateUsername(_ username: String) -> Bool {
        guard !username.isEmpty, username.count <= 32 else { return false }
        return username.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "_")
        }
    }
}
#endif
