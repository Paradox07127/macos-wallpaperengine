#if !MAS_BUILD
import Foundation

struct SystemWallpaperFollowState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case preparing
        case ready(itemID: String)
        case needsRecording
        case cancelled
        case failed(message: String)
    }

    struct Display: Equatable, Sendable {
        let displayID: UInt32
        let title: String
        let sourceKey: String
        let phase: Phase
    }

    var displays: [UInt32: Display] = [:]
}
#endif
