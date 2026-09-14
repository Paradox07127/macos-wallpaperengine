#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

@MainActor
@Observable
final class SteamCMDManagedInstallCoordinator {
    enum Status: Equatable {
        case idle
        case installing
        /// Distinct from idle: forget() suspends for the deletion, and reporting .idle across that window would let a new install() race the removal.
        case removing
        case installed(path: String)
        case failed(String)
    }

    static let shared = SteamCMDManagedInstallCoordinator()

    private(set) var status: Status = .idle

    /// Generation of the op allowed to commit. @MainActor serialises between suspension points but does not make install()/forget() atomic across them.
    private var generation: UInt64 = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let remove: () async -> SteamCMDManagedRemovalResult?
    @ObservationIgnored private let performInstall: () async -> SteamCMDManagedInstallResult?

    /// Path + the bootstrap digest that produced it, so a later run can tell a
    /// managed install apart from a directory the user happened to create.
    static let managedInstallDefaultsKey = "steamcmd.managedInstall.v1"

    init(
        defaults: UserDefaults = .standard,
        remove: @escaping () async -> SteamCMDManagedRemovalResult? = {
            await SteamConnectorClient.removeManagedSteamCMD()
        },
        performInstall: @escaping () async -> SteamCMDManagedInstallResult? = {
            await SteamConnectorClient.installManagedSteamCMD()
        }
    ) {
        self.defaults = defaults
        self.remove = remove
        self.performInstall = performInstall
        self.managedInstall = Self.recordedInstall(defaults: defaults)
    }

    struct ManagedInstallRecord: Codable, Equatable, Sendable {
        let canonicalPath: String
        /// Digest of the installed Mach-O (key name kept so earlier records keep decoding).
        let bootstrapSHA256: String
    }

    private(set) var managedInstall: ManagedInstallRecord?

    /// Deliberately doesn't stat canonicalPath — it lives outside the container, so a filesystem check here would always say no.
    static func recordedInstall(defaults: UserDefaults = .standard) -> ManagedInstallRecord? {
        guard let data = defaults.data(forKey: managedInstallDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(ManagedInstallRecord.self, from: data)
    }

    @discardableResult
    func install() async -> Status {
        // Two concurrent installs share one payload directory: the second extract would wipe the directory the first is still running +quit inside.
        switch status {
        case .installing:
            return status
        case .removing:
            // Starting now would race a deletion already in flight: separate short-lived XPC connections, whichever replies last wins.
            return status
        case .idle, .installed, .failed:
            break
        }
        let attempt = generation
        status = .installing
        let result = await performInstall()
        guard attempt == generation else { return status }

        guard let result else {
            return finish(.failed(String(
                localized: "The Steam connector did not respond.",
                bundle: .appLanguage, comment: "Managed SteamCMD install failure: the XPC service was unreachable."
            )))
        }
        guard result.outcome == .installed, let path = result.canonicalPath else {
            let detail = result.localizedFailureReason.map { " (\($0))" } ?? ""
            return finish(.failed(Self.message(for: result.outcome) + detail))
        }

        record(ManagedInstallRecord(
            canonicalPath: path,
            bootstrapSHA256: result.sha256 ?? ""
        ))
        return finish(.installed(path: path))
    }

    /// How a removal ended. A Bool would report a superseded attempt with the same value as a connector that never answered.
    enum ForgetOutcome: Equatable, Sendable {
        case removed
        /// A newer operation took over; it owns the state and the record now,
        /// and this attempt has nothing to report.
        case superseded
        case connectorUnavailable
        case refused
    }

    @discardableResult
    func forget() async -> ForgetOutcome {
        generation &+= 1
        let attempt = generation
        status = .removing
        let result = await remove()
        guard attempt == generation else { return .superseded }
        status = .idle
        guard let result else { return .connectorUnavailable }
        guard result.outcome == .removed || result.outcome == .notInstalled else {
            return .refused
        }
        defaults.removeObject(forKey: Self.managedInstallDefaultsKey)
        managedInstall = nil
        return .removed
    }

    private static func message(for outcome: SteamCMDManagedInstallResult.Outcome) -> String {
        switch outcome {
        case .installed:
            return String(
                localized: "SteamCMD was installed.",
                bundle: .appLanguage, comment: "Managed SteamCMD install outcome (not normally shown as an error)."
            )
        case .tarballRejected:
            return String(
                localized: "The downloaded SteamCMD archive didn't match its published checksum, so it was discarded.",
                bundle: .appLanguage, comment: "Managed SteamCMD install failure: the connector's own re-hash disagreed."
            )
        case .extractionFailed:
            return String(
                localized: "The SteamCMD archive couldn't be unpacked.",
                bundle: .appLanguage, comment: "Managed SteamCMD install failure: extraction failed."
            )
        case .binaryNotFound:
            return String(
                localized: "The unpacked files didn't contain the SteamCMD program.",
                bundle: .appLanguage, comment: "Managed SteamCMD install failure: no executable in the payload."
            )
        case .signatureRejected:
            return String(
                localized: "The unpacked program isn't signed by Valve, so it was not installed.",
                bundle: .appLanguage, comment: "Managed SteamCMD install failure: code signature check failed."
            )
        case .selfUpdateFailed:
            return String(
                localized: "SteamCMD was installed but its first run didn't finish.",
                bundle: .appLanguage, comment: "Managed SteamCMD install failure: the first +quit run did not complete."
            )
        case .unavailable:
            return String(
                localized: "SteamCMD can't be installed automatically right now.",
                bundle: .appLanguage, comment: "Managed SteamCMD install failure: the connector refused the request."
            )
        }
    }

    private func record(_ installRecord: ManagedInstallRecord) {
        guard let data = try? JSONEncoder().encode(installRecord) else { return }
        defaults.set(data, forKey: Self.managedInstallDefaultsKey)
        managedInstall = installRecord
    }

    private func finish(_ status: Status) -> Status {
        self.status = status
        return status
    }
}
#endif
