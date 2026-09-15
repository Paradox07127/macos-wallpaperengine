#if !LITE_BUILD
import AppKit
import Foundation

/// Background pausing is owned by the coordinator's app-resign observer — this app hosts SwiftUI in AppKit windows, so SwiftUI `scenePhase` is unreliable here and is NOT gated on.
struct ThumbnailPlaybackGate: Equatable {
    enum Trigger: Equatable { case hover, auto }

    /// Zero: every `.hoverToPlay` caller already gates hover through `settledHover`,
    /// so a debounce here would stack on top of that one.
    static let hoverPreviewDelayNanoseconds: UInt64 = 0

    var isVisible: Bool
    /// False while the host panel is mounted but not shown — a collapsed inspector
    /// clips its subtree to zero width instead of unmounting, so `isVisible` stays true.
    var hostIsPresented: Bool = true
    var isHovered: Bool
    var reduceMotion: Bool
    var isBlurred: Bool
    var trigger: Trigger

    var allowsPlayback: Bool {
        isVisible && hostIsPresented && triggerAllowsPlayback && !reduceMotion && !isBlurred
    }

    private var triggerAllowsPlayback: Bool {
        switch trigger {
        case .hover: return isHovered
        case .auto: return true
        }
    }
}

/// Prepare during the current frame's display interval, then publish at its
/// deadline. Waiting before decoding adds decode time to every authored delay.
enum PreviewFrameLoader {
    static func frame<Value: Sendable>(
        after delay: TimeInterval,
        decode: @Sendable () async -> Value?
    ) async -> Value? {
        guard !Task.isCancelled else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(delay))
        let frame = await decode()
        guard !Task.isCancelled else { return nil }
        do {
            try await Task.sleep(until: deadline, clock: .continuous)
        } catch {
            return nil
        }
        return frame
    }
}

@MainActor
final class GIFPlaybackCoordinator {
    static let shared = GIFPlaybackCoordinator()

    private static let maxActiveClients = 8

    /// LRU order: front = least-recently-used, back = most-recent.
    private var lruOrder: [UUID] = []
    private var freezers: [UUID: () -> Void] = [:]

    /// The resign-active observer is intentionally never removed: `shared` lives for the whole process, and the block captures `self` weakly so a deallocated test instance simply no-ops.
    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.freezeAll() }
        }
    }

    /// Evicts the LRU client if the cap is exceeded — never the caller, which
    /// is moved to most-recent first.
    func requestPlayback(id: UUID, freeze: @escaping () -> Void) {
        freezers[id] = freeze
        touch(id: id)
        while lruOrder.count > Self.maxActiveClients {
            let evicted = lruOrder.removeFirst()
            freezers.removeValue(forKey: evicted)?()
        }
    }

    func endPlayback(id: UUID) {
        lruOrder.removeAll { $0 == id }
        freezers.removeValue(forKey: id)
    }

    func touch(id: UUID) {
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
    }

    private func freezeAll() {
        let active = freezers
        lruOrder.removeAll()
        freezers.removeAll()
        for freeze in active.values { freeze() }
    }
}
#endif
