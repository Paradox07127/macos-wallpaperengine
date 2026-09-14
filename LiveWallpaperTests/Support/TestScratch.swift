import Foundation
@testable import LiveWallpaper

enum TestScratch {
    static func externalFixtureURL(
        pathKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard environment["LIVEWALLPAPER_EXTERNAL_FIXTURES"] == "1",
              let path = environment[pathKey],
              path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path)
    }

    enum Failure: Error {
        case defaultsSuiteUnavailable(String)
    }

    /// Call as the last statement, not from `defer` (it cannot await). Pass *every*
    /// manager built on `directory`, read-only ones included: `init` alone queues writes.
    static func discard(_ directory: URL, flushing managers: SettingsManager...) async {
        for manager in managers {
            await manager.flushPendingConfigurationWrites()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    struct DefaultsSuite {
        let name: String
        let defaults: UserDefaults

        /// The plist itself stays: cfprefsd rewrites every registered suite after the
        /// process dies, so unlinking the file from inside the test achieves nothing.
        func discard() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    /// Deliberately *not* UUID-suffixed — one file per test forever. Give every test
    /// its own `name`: parallel tests sharing a name trample each other.
    static func defaultsSuite(_ name: String) throws -> DefaultsSuite {
        guard let defaults = UserDefaults(suiteName: name) else {
            throw Failure.defaultsSuiteUnavailable(name)
        }
        defaults.removePersistentDomain(forName: name)
        return DefaultsSuite(name: name, defaults: defaults)
    }

    static func defaultsSuite(prefix: String, function: String = #function) throws -> DefaultsSuite {
        try defaultsSuite("\(prefix).\(function.prefix { $0 != "(" })")
    }
}
