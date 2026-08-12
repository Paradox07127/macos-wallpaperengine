#if !LITE_BUILD
import Darwin
import Foundation

/// working directory. `+args` mode silently allows interactive prompts on
/// cache miss, so every download path uniformly drives SteamCMD through a
/// script that opens with `@ShutdownOnFailedCommand 1` + `@NoPromptForPassword 1`.
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
