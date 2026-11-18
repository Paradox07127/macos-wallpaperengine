#if !MAS_BUILD
import CoreGraphics

enum DisplayPower {
    static var isSoftPowerAvailable: Bool {
        #if arch(arm64)
        DisplayPrivateSymbols.shared.configureDisplayEnabled != nil
        #else
        false
        #endif
    }

    /// Every display the window server knows, including ones switched off with `setEnabled(false, for:)`.
    static func allDisplayIDs() throws -> [CGDirectDisplayID] {
        guard let getDisplayList = DisplayPrivateSymbols.shared.getDisplayList else {
            throw DisplayControlError.unavailable
        }
        // Fixed buffer: whether SkyLight accepts a nil list for a count-only query is unverified.
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        let result = getDisplayList(UInt32(ids.count), &ids, &count)
        guard result == .success else { throw DisplayControlError.windowServer(result) }
        return Array(ids.prefix(Int(count)))
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func requireAnotherOnlineDisplay(disabling display: CGDirectDisplayID, online: [CGDirectDisplayID]) throws {
        guard online.contains(where: { $0 != display }) else {
            throw DisplayControlError.wouldLeaveNoOnlineDisplay
        }
    }

    /// The commit can block for tens of seconds, so this always runs off the caller's executor.
    @concurrent
    static func setEnabled(_ enabled: Bool, for display: CGDirectDisplayID) async throws {
        #if arch(arm64)
        guard let configureDisplayEnabled = DisplayPrivateSymbols.shared.configureDisplayEnabled else {
            throw DisplayControlError.unavailable
        }
        let online = onlineDisplayIDs()
        // Committing a transaction whose target already holds fails with 1001, so a no-op must not reach it.
        if online.contains(display) == enabled {
            return
        }
        if !enabled {
            try requireAnotherOnlineDisplay(disabling: display, online: online)
        }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw DisplayControlError.windowServer(begin) }
        // Neither return code is trusted; the online list after the commit is the verdict.
        _ = configureDisplayEnabled(config, display, enabled)
        _ = CGCompleteDisplayConfiguration(config, DisplayControl.configurationScope)
        // The online list can trail the commit; waits up to 3 s.
        for _ in 0..<30 {
            if onlineDisplayIDs().contains(display) == enabled { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DisplayControlError.stateNotReached
        #else
        throw DisplayControlError.unavailable
        #endif
    }
}
#endif
