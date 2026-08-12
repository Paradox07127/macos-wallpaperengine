import Foundation
@testable import LiveWallpaper

/// Scratch state that actually disappears when a test ends.
///
/// Both halves close a measured leak, not a theoretical one: every call site
/// already had a `defer` that removed its scratch, yet the container had
/// accumulated 236 directories under `tmp/` and 645 plists under
/// `Library/Preferences/`.
enum TestScratch {
    enum Failure: Error {
        case defaultsSuiteUnavailable(String)
    }

    /// `SettingsManager` queues its disk write on its own persistence actor, so a
    /// bare `defer { removeItem(at:) }` races it and the queued write recreates the
    /// directory. Draining first makes the removal final. Call this as the last
    /// statement of the test — `defer` cannot await.
    ///
    /// Pass *every* manager built on `directory`, including read-only ones: `init`
    /// alone queues the migration and schema stamps.
    static func discard(_ directory: URL, flushing managers: SettingsManager...) async {
        for manager in managers {
            await manager.flushPendingConfigurationWrites()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// An empty, isolated defaults suite.
    struct DefaultsSuite {
        let name: String
        let defaults: UserDefaults

        /// Empties the domain. The plist itself stays: cfprefsd rewrites every
        /// suite the process registered *after* the process dies, so unlinking
        /// the file from inside the test achieves nothing (measured — a 7-suite
        /// run put all 9 back within seconds). Bounding the name is what keeps
        /// the directory from growing.
        func discard() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    /// One stable suite per caller — deliberately *not* UUID-suffixed.
    ///
    /// A fresh UUID per run is what turned this into 645 plists in the container's
    /// Preferences; a name fixed to the test reuses one file forever. Give every
    /// test its own `name`: Swift Testing runs tests in parallel, so two tests
    /// sharing a name would trample each other, while one test never races itself.
    /// The domain is emptied on the way in, so a previous run's contents can't
    /// leak into this one.
    static func defaultsSuite(_ name: String) throws -> DefaultsSuite {
        guard let defaults = UserDefaults(suiteName: name) else {
            throw Failure.defaultsSuiteUnavailable(name)
        }
        defaults.removePersistentDomain(forName: name)
        return DefaultsSuite(name: name, defaults: defaults)
    }
}
