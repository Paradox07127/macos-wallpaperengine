#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import os

@MainActor
final class SystemAudioCaptureManager {
    static let shared = SystemAudioCaptureManager()

    enum State: Equatable {
        case idle
        case capturing
        case failed(String)
    }

    private(set) var state: State = .idle

    nonisolated static let broker = AudioSpectrumBroker()

    nonisolated private static let captureActive = OSAllocatedUnfairLock(initialState: false)
    nonisolated static var isCapturing: Bool { captureActive.withLock { $0 } }

    private var isEnabled = false
    private var consumerCount = 0
    /// Process-lifetime shutdown latch — rejects later producer callbacks during terminate.
    private(set) var isTerminated = false
    private var serviceBox: SystemAudioCaptureService?

    init() {}

    func setEnabled(_ enabled: Bool) {
        guard !isTerminated else { return }
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        Logger.notice("[AudioCapture] manager: enabled=\(enabled)", category: .audioCapture)
        reconcile()
    }

    func retryAccessRequest() {
        guard !isTerminated else { return }
        if !isEnabled {
            isEnabled = true
        }
        stopIfNeeded()
        reconcile()
    }

    func retain() {
        guard !isTerminated else { return }
        consumerCount += 1
        reconcile()
    }

    func release() {
        guard !isTerminated else { return }
        consumerCount = max(0, consumerCount - 1)
        reconcile()
    }

    func shutdown() {
        guard !isTerminated else { return }
        isTerminated = true
        isEnabled = false
        consumerCount = 0
        stopIfNeeded()
    }

    // MARK: - Reconciliation

    static func shouldRun(isEnabled: Bool, consumerCount: Int) -> Bool {
        isEnabled && consumerCount > 0
    }

    private var shouldRun: Bool {
        Self.shouldRun(isEnabled: isEnabled, consumerCount: consumerCount)
    }

    #if DEBUG
    var consumerCountForTesting: Int { consumerCount }

    nonisolated static func setCapturingForTesting(_ active: Bool) {
        captureActive.withLock { $0 = active }
    }
    #endif

    private func reconcile() {
        if shouldRun {
            startIfNeeded()
        } else {
            stopIfNeeded()
        }
    }

    private func startIfNeeded() {
        guard serviceBox == nil else { return }
        let service = SystemAudioCaptureService(broker: Self.broker)
        do {
            try service.start()
            serviceBox = service
            Self.captureActive.withLock { $0 = true }
            state = .capturing
        } catch {
            serviceBox = nil
            Self.captureActive.withLock { $0 = false }
            state = .failed("\(error)")
            Logger.warning("[AudioCapture] manager: capture start failed: \(error)", category: .audioCapture)
        }
    }

    private func stopIfNeeded() {
        serviceBox?.stop()
        serviceBox = nil
        Self.captureActive.withLock { $0 = false }
        Self.broker.resetToSilence()
        state = .idle
    }
}
#endif
