import Foundation

extension UserDefaults {
    /// The app's writable preference store. Shipping processes keep the native
    /// `.standard` domain; XCTest hosts and SwiftUI previews get isolated suites
    /// so view-level `@AppStorage` and service defaults cannot touch the user's
    /// preferences.
    static func appScoped() -> UserDefaults {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return UserDefaults(suiteName: "com.loomscreen.pro.Previews") ?? .standard
        }
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        _ = reapStaleTestDefaultsOnce
        return UserDefaults(
            suiteName: TestProcessScratch.name(TestProcessScratch.defaultsPrefix)
        ) ?? .standard
    }

    /// Lazy static, so the directory scan happens once per process rather than on
    /// every `appScoped()` call.
    private static let reapStaleTestDefaultsOnce: Void = {
        TestProcessScratch.reapStale(
            prefix: TestProcessScratch.defaultsPrefix,
            in: TestProcessScratch.preferencesURL
        )
    }()

    /// The app's `com.loomscreen.pro` defaults domain. When the current process IS the app, its standard domain already maps to that bundle ID, so we return `.standard`: passing your own bundle identifier to `init(suiteName:)` is rejected by macOS with the `_NSUserDefaults_Log_Nonsensical_Suites` warning and yields no usable store.
    /// In a host process with a different bundle ID (a screensaver/agent embedding the renderer) we open the explicit suite so `defaults write com.loomscreen.pro …` knobs are still honoured.
    static var appSuite: UserDefaults {
        let appBundleID = "com.loomscreen.pro"
        if Bundle.main.bundleIdentifier == appBundleID { return .standard }
        return UserDefaults(suiteName: appBundleID) ?? .standard
    }
}
