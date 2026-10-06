import AppKit
import Foundation
import LiveWallpaperCore

enum ApplicationPerformanceRuleEngine {
    /// Evaluates configured application rules without enumerating processes unless required.
    @MainActor
    static func evaluate(for settings: GlobalSettings) -> (shouldPause: Bool, frontmostExcluded: Bool) {
        let rules = settings.applicationPerformanceRules
        guard !rules.isEmpty else { return (false, false) }
        return evaluate(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            rules: rules,
            runningBundleIDs: { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        )
    }

    /// Snapshot running processes at most once, and only if no frontmost rule already pauses.
    static func evaluate(
        frontmostBundleID: String?,
        rules: [ApplicationPerformanceRule],
        runningBundleIDs: () -> Set<String>
    ) -> (shouldPause: Bool, frontmostExcluded: Bool) {
        var pause = false
        var excluded = false
        var needsRunningApps = false
        for rule in rules {
            switch rule.trigger {
            case .frontmost:
                pause = pause || rule.bundleID == frontmostBundleID
            case .neverPause:
                excluded = excluded || rule.bundleID == frontmostBundleID
            case .running:
                needsRunningApps = true
            }
        }
        if !pause, needsRunningApps {
            let running = runningBundleIDs()
            pause = rules.contains { $0.trigger == .running && running.contains($0.bundleID) }
        }
        return (pause, excluded)
    }

    static func frontmostIsExcluded(frontmostBundleID: String?, rules: [ApplicationPerformanceRule]) -> Bool {
        guard let frontmostBundleID else { return false }
        return rules.contains { $0.trigger == .neverPause && $0.bundleID == frontmostBundleID }
    }

    static func shouldPause(
        frontmostBundleID: String?,
        runningBundleIDs: Set<String>,
        rules: [ApplicationPerformanceRule]
    ) -> Bool {
        guard !rules.isEmpty else { return false }
        for rule in rules {
            switch rule.trigger {
            case .frontmost:
                if let frontmostBundleID, frontmostBundleID == rule.bundleID { return true }
            case .running:
                if runningBundleIDs.contains(rule.bundleID) { return true }
            case .neverPause:
                continue
            }
        }
        return false
    }
}
