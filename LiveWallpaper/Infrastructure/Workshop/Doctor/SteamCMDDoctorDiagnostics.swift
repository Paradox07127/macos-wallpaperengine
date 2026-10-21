#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

extension SteamCMDDoctorService {
    static var setupRequiredMessage: String {
        String(localized: "SteamCMD was found but needs setup on this Mac. Loomscreen can download and prepare a verified copy automatically.", bundle: .appLanguage, comment: "Recovery after Locate automatically finds a SteamCMD copy that cannot be used.")
    }

    /// Unbound means no launch was accepted; discovery can still have verified
    /// signature/quarantine facts. Do not replace them with "not selected".
    func reportUnboundBinaryProbe(_ kind: DoctorProbeKind) -> Bool {
        guard !hasBoundBinary, let diagnosis = lastAutoDetectDiagnosis,
              Self.binaryProbeKinds.contains(kind) else { return false }
        let status: DoctorProbeStatus
        switch kind {
        case .binaryIdentity:
            let message = diagnosis.needsInAppSetup ? Self.setupRequiredMessage
                : (diagnosis.remedy ?? SteamCMDDoctorError.connectorUnavailable.localizedDescription)
            status = diagnosis.unavailableReason == nil
                ? .red(message: message, command: nil) : .yellow(message: message, command: nil)
        case .codeSignature:
            if let signature = diagnosis.signature {
                status = signature.isValveSigned
                    ? .green(detail: String(localized: "Verified Valve build (TeamIdentifier=MXGJJ98X76).", bundle: .appLanguage))
                    : .red(message: String(localized: "SteamCMD is not a verified Valve build.", bundle: .appLanguage), command: nil)
            } else {
                status = .notRun
            }
        case .gatekeeperQuarantine:
            if diagnosis.canonicalPath == nil {
                status = .notRun
            } else if diagnosis.isQuarantined {
                status = .red(message: String(localized: "SteamCMD has the Gatekeeper quarantine attribute. macOS may block it on launch.", bundle: .appLanguage), command: nil)
            } else {
                status = .yellow(message: String(localized: "SteamCMD has no quarantine attribute. Its launch check has not completed.", bundle: .appLanguage), command: nil)
            }
        default: return false
        }
        setProbe(kind, status: status, lastRun: lastAutoDetectDate ?? Date())
        return true
    }

    func diagnosticsJSON() -> String? {
        var reports: [String: Any] = [:]
        for kind in DoctorProbeKind.allCases {
            let report = probes[kind]
            var info: [String: Any] = [:]
            switch report?.status ?? .notRun {
            case .notRun: info["status"] = "notRun"
            case .running: info["status"] = "running"
            case .green(let detail):
                info["status"] = "green"
                info["detail"] = sanitizeForExport(detail)
            case .yellow(let message, let command), .red(let message, let command):
                if case .red? = report?.status { info["status"] = "red" } else { info["status"] = "yellow" }
                info["message"] = sanitizeForExport(message)
                info["command"] = sanitizeForExport(command)
            }
            if let lastRun = report?.lastRun, lastRun > .distantPast {
                info["lastRun"] = ISO8601DateFormatter().string(from: lastRun)
            }
            if kind == .cachedLogin {
                info["sessionStorage"] = "isolated-per-account-v1"
                info["diagnosticTail"] = sanitizeForExport(cachedLoginDiagnosticTail)
                info["exitCode"] = cachedLoginExitCode
            }
            reports[kind.rawValue] = info
        }
        var payload: [String: Any] = [
            "phase": "doctor", "ts": ISO8601DateFormatter().string(from: Date()),
            "binaryPath": binaryDisplayPath != nil ? "<bound>" : "<unbound>",
            "workdirPath": workdirDisplayPath != nil ? "<bound>" : "<unbound>",
            "hasUsername": username != nil, "state": String(describing: state), "probes": reports
        ]
        if let diagnosis = lastAutoDetectDiagnosis {
            var detection: [String: Any] = [
                "source": diagnosis.source.rawValue,
                "foundBinary": diagnosis.canonicalPath != nil,
                "isUsable": diagnosis.isUsable,
                "isQuarantined": diagnosis.isQuarantined,
                "launchAttempted": diagnosis.launch != nil,
                "needsInAppSetup": diagnosis.needsInAppSetup,
                "resolutionFailure": sanitizeForExport(diagnosis.resolutionFailure),
                "unavailableReason": sanitizeForExport(diagnosis.unavailableReason)
            ]
            if let date = lastAutoDetectDate { detection["lastRun"] = ISO8601DateFormatter().string(from: date) }
            if let signature = diagnosis.signature {
                detection["signature"] = ["isValid": signature.isValid, "teamIdentifier": signature.teamIdentifier ?? "unknown", "isValveSigned": signature.isValveSigned]
            }
            if let launch = diagnosis.launch {
                detection["launch"] = ["outcome": launch.outcome.rawValue, "exitCode": launch.exitCode,
                                       "timeout": launch.timeout, "outputTail": sanitizeForExport(launch.outputTail)]
            } else {
                detection["launch"] = NSNull()
            }
            payload["autoDetection"] = detection
        } else {
            payload["autoDetection"] = ["status": "notRun"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sanitizeForExport(_ value: String?) -> String {
        guard var output = value, !output.isEmpty else { return "" }
        let paths = [workdirDisplayPath, binaryDisplayPath, lastAutoDetectDiagnosis?.canonicalPath].compactMap { $0 }
            + (lastAutoDetectDiagnosis?.rejectedExistingPaths ?? [])
        for path in paths.sorted(by: { $0.count > $1.count }) where !path.isEmpty {
            output = output.replacingOccurrences(of: path, with: "<path>")
        }
        output = WorkshopDiagnosticRedactor.redact(output)
        if let username, !username.isEmpty { output = output.replacingOccurrences(of: username, with: "<steam_username>") }
        return output
    }
}
#endif
