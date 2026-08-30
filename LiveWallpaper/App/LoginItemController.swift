import Foundation
import LiveWallpaperCore
import ServiceManagement

/// Owns "start at login" registration and the delayed re-check that catches `SMAppService`
/// reporting success while the item never activates — app not in `/Applications`, or signing
/// rejected. Touches no settings persistence; the generation counter that cancels a superseded
/// validation is state only this controller needs.
@MainActor
final class LoginItemController {
    /// Identifies the apply currently allowed to report. Bumped on every apply
    /// and every scheduled validation, so a check that was mid-sleep when the
    /// user toggled again declines to report a stale verdict.
    private var validationGeneration: UInt64 = 0

    func apply(startOnLogin: Bool) {
        let service = SMAppService.mainApp
        validationGeneration &+= 1
        let statusBefore = service.status
        Logger.debug(
            "applyStartOnLoginSetting target=\(startOnLogin) statusBefore=\(describe(statusBefore)) bundlePath=\(Bundle.main.bundlePath)",
            category: .settings
        )

        do {
            if startOnLogin {
                if statusBefore == .notRegistered || statusBefore == .notFound {
                    try service.register()
                }
            } else {
                if statusBefore == .enabled || statusBefore == .requiresApproval {
                    try service.unregister()
                }
            }
        } catch {
            Logger.error(
                "SMAppService.\(startOnLogin ? "register" : "unregister") threw: \(error.localizedDescription)",
                category: .settings
            )
            postFailure(reason: .registrationFailed(error))
            return
        }

        let statusAfter = service.status
        Logger.debug("SMAppService statusAfter=\(describe(statusAfter))", category: .settings)

        if status(statusAfter, matches: startOnLogin) {
            return
        }

        scheduleValidation(targetEnabled: startOnLogin)
    }

    private func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:    return "notRegistered"
        case .enabled:          return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown(\(status.rawValue))"
        }
    }

    private func status(_ status: SMAppService.Status, matches targetEnabled: Bool) -> Bool {
        switch (targetEnabled, status) {
        case (true, .enabled), (false, .notRegistered), (false, .notFound):
            return true
        default:
            return false
        }
    }

    private func scheduleValidation(targetEnabled: Bool) {
        validationGeneration &+= 1
        let generation = validationGeneration

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            guard let self, self.validationGeneration == generation else { return }

            let status = SMAppService.mainApp.status
            Logger.debug("SMAppService delayedStatus=\(self.describe(status))", category: .settings)
            guard !self.status(status, matches: targetEnabled) else { return }

            switch (targetEnabled, status) {
            case (true, .requiresApproval):
                Logger.warning("Login item registered but requires user approval in System Settings", category: .settings)
                self.postFailure(reason: .requiresApproval)
            case (true, .notRegistered), (true, .notFound):
                Logger.error("Login item register() returned without error but delayed status is \(self.describe(status)); app may not be in /Applications/ or signing is rejected", category: .settings)
                self.postFailure(reason: .registrationSilentlyFailed)
            case (false, _):
                Logger.warning("Login item disable target=false but delayed status=\(self.describe(status))", category: .settings)
            default:
                break
            }
        }
    }

    private func postFailure(reason: LoginItemFailure) {
        NotificationCenter.default.post(
            name: .loginItemRegistrationDidFail,
            object: nil,
            userInfo: ["reason": reason]
        )
    }
}
