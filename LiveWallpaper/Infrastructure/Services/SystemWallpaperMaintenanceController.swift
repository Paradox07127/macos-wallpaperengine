import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SystemWallpaperMaintenanceController {
    enum Phase: Equatable { case idle, inspecting, restarting, repairing, verifying, verified, awaitingSelection, failed }
    private(set) var phase: Phase = .idle
    private(set) var report: SystemWallpaperMaintenanceReport?
    private(set) var errorCode: String?
    var automaticRecovery: Bool {
        didSet { defaults.set(automaticRecovery, forKey: "SystemWallpaper.AutomaticRecovery") }
    }

    var isBusy: Bool {
        [.inspecting, .restarting, .repairing, .verifying].contains(phase)
    }

    var helperAvailable: Bool {
        SystemWallpaperMaintenanceClient.isAvailable
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let allowsAutomaticRecovery = !AppRuntimeOptions().isTesting
    @ObservationIgnored private var recoveryPolicy: SystemWallpaperRecoveryPolicy
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    init(defaults: UserDefaults = .appScoped()) {
        self.defaults = defaults
        recoveryPolicy = .init(now: Date(), lastAttempt: defaults.object(forKey: "SystemWallpaper.LastAutomaticRecovery") as? Date ?? .distantPast)
        automaticRecovery = defaults.bool(forKey: "SystemWallpaper.AutomaticRecovery")
    }

    func inspect() async {
        guard !isBusy else { return }
        phase = .inspecting
        errorCode = nil
        let result = await SystemWallpaperMaintenanceClient.perform(.inspect)
        report = result
        errorCode = result.errorCode
        phase = result.outcome == .inspected ? .idle : .failed
    }

    func recover(service: WallpaperExportService, repair: Bool = false) async {
        guard !isBusy else { return }
        if repair, report?.outcome != .inspected {
            return
        }
        let began = Date()
        let previousPID = service.heartbeat?.provider?.pid
        phase = repair ? .repairing : .restarting
        errorCode = nil
        let operation: SystemWallpaperMaintenanceClient.Operation = repair ? .repair(report?.revision ?? "") : .restart
        let result = await SystemWallpaperMaintenanceClient.perform(operation)
        report = result
        guard result.outcome == .restarted || result.outcome == .repaired else {
            errorCode = result.errorCode ?? (result.outcome == .changed ? "maintenance.reviewChanged" : "maintenance.operationFailed")
            phase = .failed
            return
        }
        phase = .verifying
        for _ in 0 ..< 20 {
            do { try await Task.sleep(for: .seconds(1)) } catch { phase = .idle; return }
            service.refreshProviderStatus()
            if let heartbeat = service.heartbeat,
               Self.isReconnected(heartbeat: heartbeat, began: began, previousPID: previousPID,
                                  issue: service.providerIssue, running: service.providerIsRunning) {
                phase = .verified
                return
            }
        }
        // Agent restart alone is not evidence that macOS selected or rendered this provider.
        phase = .awaitingSelection
    }

    func considerAutomaticRecovery(service: WallpaperExportService, now: Date = Date()) {
        let isFailure = allowsAutomaticRecovery && automaticRecovery && helperAvailable && !isBusy && recoveryTask == nil
            && (service.providerIssue == .stopped || service.providerIssue == .unresponsive)
        guard recoveryPolicy.shouldRecover(isFailure: isFailure, now: now) else { return }
        defaults.set(now, forKey: "SystemWallpaper.LastAutomaticRecovery")
        recoveryTask = Task { @MainActor [weak self, weak service] in
            guard let self, let service else { return }
            await recover(service: service)
            recoveryTask = nil
        }
    }

    /// A new PID alone is not a reconnection: the beat must be the new process's and healthy.
    static func isReconnected(heartbeat: SystemWallpaperHeartbeat, began: Date, previousPID: Int32?,
                              issue: WallpaperExportService.ProviderIssue?, running: Bool) -> Bool {
        heartbeat.timestamp >= began && heartbeat.provider?.pid != previousPID
            && heartbeat.runtimeHealthy && issue == nil && running
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
