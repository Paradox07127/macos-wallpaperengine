#if !LITE_BUILD
import AppKit
import Foundation
import SwiftUI

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

/// SwiftUI subtrees can stay mounted when their AppKit host stops presenting them.
/// Observe the actual host rather than relying on `scenePhase` in AppKit-hosted UI.
struct GIFHostVisibilityProbe: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context _: Context) -> GIFHostVisibilityView {
        GIFHostVisibilityView(changed: changed)
    }

    func updateNSView(_ view: GIFHostVisibilityView, context _: Context) {
        view.changed = changed
    }
}

@MainActor
final class GIFHostVisibilityView: NSView {
    var changed: @MainActor (Bool) -> Void
    private var applicationIsActive = NSApp.isActive
    private var applicationIsHidden = NSApp.isHidden
    private var lastValue: Bool?
    private var windowIsClosing = false

    init(changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        windowIsClosing = false
        if let window {
            applicationIsActive = NSApp.isActive
            applicationIsHidden = NSApp.isHidden
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                center.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                center.addObserver(self, selector: #selector(applicationChanged(_:)), name: name, object: nil)
            }
        }
        publishVisibility()
    }

    @objc private func windowChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification {
            windowIsClosing = true
            lastValue = false
            changed(false)
        } else {
            publishVisibility()
        }
    }

    @objc private func applicationChanged(_ notification: Notification) {
        switch notification.name {
        case NSApplication.didBecomeActiveNotification: applicationIsActive = true
        case NSApplication.didResignActiveNotification: applicationIsActive = false
        case NSApplication.didHideNotification: applicationIsHidden = true
        case NSApplication.didUnhideNotification: applicationIsHidden = false
        default: break
        }
        publishVisibility()
    }

    private func publishVisibility() {
        let visible = applicationIsActive && !applicationIsHidden && !windowIsClosing && window.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } == true
        guard visible != lastValue else { return }
        lastValue = visible
        changed(visible)
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

    #if DEBUG
    var activeClientIDsForTesting: [UUID] {
        lruOrder
    }
    #endif

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
