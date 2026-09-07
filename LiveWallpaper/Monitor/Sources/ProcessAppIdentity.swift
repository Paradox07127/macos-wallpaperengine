import AppKit

enum ProcessAppIdentity {
    /// Match the sampled aggregate's actual PID, never a guessed process name.
    /// Daemons and CLI processes commonly have no application bundle.
    static func bundleID(forPID pid: Int32) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.bundleURL?.pathExtension.lowercased() == "app" else { return nil }
        return app.bundleIdentifier
    }
}
