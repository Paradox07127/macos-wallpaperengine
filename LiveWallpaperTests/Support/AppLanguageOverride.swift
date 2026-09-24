import Foundation
import LiveWallpaperCore

/// Picks the app language for one test through the argument domain, which every lookup reads first
/// and which is never saved or seen by a running copy of the app.
enum AppLanguageOverride {
    /// The argument domain is process-wide: tests that snapshot and restore it take turns, or a late
    /// restore would put back another test's override.
    private static let lock = NSLock()

    static func with<T>(_ language: AppLanguagePreference, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments[AppLanguagePreference.storageKey] = language.rawValue
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        return try body()
    }
}
