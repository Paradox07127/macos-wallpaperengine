import CoreGraphics
import Foundation

/// `CGSessionCopyCurrentDictionary()` omits `CGSSessionScreenIsLocked` while unlocked. Treat `.unknown` as "keep the current belief".
enum ScreenLockState: Equatable, Sendable {
    case locked
    case unlocked
    case unknown
}

protocol UserPresenceProbing: Sendable {
    func areAllDisplaysAsleep() -> Bool
    func isMainDisplayActive() -> Bool
    func screenLockState() -> ScreenLockState
}

struct SystemUserPresenceProbe: UserPresenceProbing {
    static let shared = SystemUserPresenceProbe()

    /// Every online display, not any, and ONLINE not ACTIVE: asleep displays are absent from the active list. `true` also covers "cannot tell".
    func areAllDisplaysAsleep() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return true }
        return ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
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
