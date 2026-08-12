import Foundation

/// Per-app pause rule (bundle ID). Event-driven via NSWorkspace — no polling.
public struct ApplicationPerformanceRule: Codable, Equatable, Sendable, Identifiable {
    public enum Trigger: String, Codable, Sendable {
        case frontmost
        case running
        /// Veto auto fullscreen/occlusion/battery while frontmost; safety pauses still win.
        case neverPause
    }

    public var bundleID: String
    public var displayName: String
    public var trigger: Trigger

    public var id: String { bundleID }

    public init(bundleID: String, displayName: String, trigger: Trigger = .frontmost) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.trigger = trigger
    }
}
