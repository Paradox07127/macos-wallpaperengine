#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Advisory diagnostics. Download eligibility is owned by `SteamCMDDoctorService.downloadBlocker`.
struct WorkshopDiagnosticsSection: View {
    @Binding var showingExportToast: Bool

    @Environment(SteamCMDDoctorService.self) private var service
    @Environment(WorkshopSetupController.self) private var controller

    @State private var showingSignIn = false

    var body: some View {
        Section {
            ForEach(DoctorProbeKind.allCases) { kind in
                WorkshopProbeRow(
                    report: service.probes[kind]
                        ?? DoctorProbeReport(id: kind, status: .notRun, lastRun: .distantPast),
                    service: service,
                    onCopied: { showingExportToast = true },
                    onConnectAccount: { showingSignIn = true }
                )
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button(action: { Task { await service.runAll() } }) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if service.state == .probing {
                            ProgressView().controlSize(.small)
                        }
                        Text("Run all checks")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.state == .probing)

                Button(action: exportDiagnostics) {
                    Text("Copy reports")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("Copies redacted diagnostic reports as JSON."))

                Spacer(minLength: 0)
            }
            .padding(.top, DesignTokens.Spacing.xs)
            // Hung off a row rather than the Section: a modified `Section` stops
            // being a section to `Form`.
            .sheet(isPresented: $showingSignIn) {
                AppLanguageScope(defaults: .appScoped()) {
                    SteamSignInSheet { accountName in
                        controller.adoptSignedInAccount(accountName)
                    }
                }
            }
        } header: {
            SettingsSearchSectionHeader("Diagnostics", anchor: .workshopDiagnostics)
        }
    }

    // MARK: - Export

    private func exportDiagnostics() {
        var probesPayload: [String: Any] = [:]
        for kind in DoctorProbeKind.allCases {
            let report = service.probes[kind]
            var info: [String: Any] = ["status": statusKey(report?.status ?? .notRun)]
            switch report?.status {
            case .green(let detail)?:
                info["detail"] = sanitizeForExport(detail)
            case .yellow(let msg, let cmd)?:
                info["message"] = sanitizeForExport(msg)
                info["command"] = sanitizeForExport(cmd)
            case .red(let msg, let cmd)?:
                info["message"] = sanitizeForExport(msg)
                info["command"] = sanitizeForExport(cmd)
            default: break
            }
            if let lastRun = report?.lastRun, lastRun > .distantPast {
                info["lastRun"] = ISO8601DateFormatter().string(from: lastRun)
            }
            if kind == .cachedLogin {
                info["sessionStorage"] = "isolated-per-account-v1"
                info["diagnosticTail"] = sanitizeForExport(service.cachedLoginDiagnosticTail)
                info["exitCode"] = service.cachedLoginExitCode
            }
            probesPayload[kind.rawValue] = info
        }

        let payload: [String: Any] = [
            "phase": "doctor",
            "ts": ISO8601DateFormatter().string(from: Date()),
            "binaryPath": service.binaryDisplayPath != nil ? "<bound>" : "<unbound>",
            "workdirPath": service.workdirDisplayPath != nil ? "<bound>" : "<unbound>",
            "hasUsername": service.username != nil,
            "state": String(describing: service.state),
            "probes": probesPayload
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(json, forType: .string)
            showingExportToast = true
        }
    }

    private func sanitizeForExport(_ value: String?) -> String {
        guard var output = value, !output.isEmpty else { return "" }
        if let workdir = service.workdirDisplayPath, !workdir.isEmpty {
            output = output.replacingOccurrences(of: workdir, with: "<workdir>")
        }
        if let binary = service.binaryDisplayPath, !binary.isEmpty {
            output = output.replacingOccurrences(of: binary, with: "<steamcmd>")
        }
        output = WorkshopDiagnosticRedactor.redact(output)
        if let username = service.username, !username.isEmpty {
            output = output.replacingOccurrences(of: username, with: "<steam_username>")
        }
        return output
    }

    private func statusKey(_ status: DoctorProbeStatus) -> String {
        switch status {
        case .notRun: return "notRun"
        case .running: return "running"
        case .green: return "green"
        case .yellow: return "yellow"
        case .red: return "red"
        }
    }
}
#endif
