import AppKit

enum ProcessAppIdentity {
    /// Daemons and CLI processes commonly have no application bundle.
    static func bundleID(forPID pid: Int32) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.bundleURL?.pathExtension.lowercased() == "app" else { return nil }
        return app.bundleIdentifier
    }
}
