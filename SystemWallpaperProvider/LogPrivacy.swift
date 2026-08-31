import Foundation

/// The appex does not link `LiveWallpaperCore`, so it has no `LogPrivacyRedactor`.
/// Rather than duplicate those regex rules out of sync, it keeps user data out of
/// public lines in the first place: identities public, anything path-shaped `.private`.
enum WPXLogPrivacy {
    /// `localizedDescription` and `String(describing:)` smuggle `NSFilePathErrorKey`
    /// absolute paths into a public log line; domain and code carry the triage signal.
    static func summary(_ error: Error?) -> String {
        guard let error else { return "none" }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}
