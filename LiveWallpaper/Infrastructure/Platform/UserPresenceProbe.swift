import CoreGraphics
import Foundation

/// Whether the screen is locked, as far as we can actually tell.
///
/// `unknown` is not a formality: `CGSessionCopyCurrentDictionary()` omits
/// `CGSSessionScreenIsLocked` entirely while unlocked (2026-08-18 probe, both
/// sandboxed and not), so a missing key cannot be told apart from a dictionary
/// we failed to read. Callers must treat `unknown` as "keep the current belief".
enum ScreenLockState: Equatable, Sendable {
    case locked
    case unlocked
    case unknown
}

/// Second opinion on whether the user is present.
///
/// Absence is otherwise driven purely by OS notifications (lock/unlock, display
/// sleep/wake, system sleep/wake) with no redundancy — a single dropped wake or
/// unlock pins every wallpaper in a suspended state that nothing can lift.
protocol UserPresenceProbing: Sendable {
    func isAnyDisplayAsleep() -> Bool
    func isMainDisplayActive() -> Bool
    func screenLockState() -> ScreenLockState
}

struct SystemUserPresenceProbe: UserPresenceProbing {
    static let shared = SystemUserPresenceProbe()

    /// `true` also covers "cannot tell": the only caller uses this to decide
    /// whether to clear a display-sleep absence, so an unreadable list has to
    /// behave like a sleeping display rather than report everything awake.
    ///
    /// Must enumerate ONLINE, not ACTIVE. An active display is by definition
    /// "connected, awake, and available for drawing", so asleep displays are
    /// absent from that list and searching it for a sleeping display can never
    /// match. Verified on this Mac while its screen was actually asleep:
    /// active count 0, online count 2, `CGDisplayIsAsleep(CGMainDisplayID())` 1.
    func isAnyDisplayAsleep() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return true }
        return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) != 0 }
    }

    func isMainDisplayActive() -> Bool {
        CGDisplayIsActive(CGMainDisplayID()) != 0
    }

    func screenLockState() -> ScreenLockState {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .unknown }
        guard let locked = session["CGSSessionScreenIsLocked"] else { return .unlocked }
        if let flag = locked as? Bool { return flag ? .locked : .unlocked }
        if let number = locked as? NSNumber { return number.boolValue ? .locked : .unlocked }
        return .unknown
    }
}
