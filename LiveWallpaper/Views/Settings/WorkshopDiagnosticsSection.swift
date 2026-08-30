#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Every Steam-side check Loomscreen can run, in one place.
///
/// It used to be a `DisclosureGroup` nested inside the connection section,
/// which scoped it to the three steps above it — so the checks that describe
/// the scene resources or the connector itself had nowhere to live. As its own
/// section it can cover all of them.
///
/// **Advisory only.** Nothing here gates anything: downloads are blocked by
/// `SteamCMDDoctorService.downloadBlocker`, which reads the bindings and the
/// binary-identity verdict and never consults the rest of these probes. A red
/// row means "here is what looks wrong", not "you may not proceed".
struct WorkshopDiagnosticsSection: View {
    @Binding var showingExportToast: Bool

    @Environment(SteamCMDDoctorService.self) private var service

    var body: some View {
        Section {
            ForEach(DoctorProbeKind.allCases) { kind in
                WorkshopProbeRow(
                    report: service.probes[kind]
                        ?? DoctorProbeReport(id: kind, status: .notRun, lastRun: .distantPast),
                    service: service,
                    onCopied: { showingExportToast = true }
                )
            }

            HStack(spacing: DesignTokens.Spacing.sm) {
                Button(action: { Task { await service.runAll() } }) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if service.state == .probing {
                            ProgressView().controlSize(.small)
                        }
                        Text("Run all checks", bundle: .main)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.state == .probing)

                // A button, not a link: this copies a payload to the
                // pasteboard. Link styling is for things that open a web page.
                Button(action: exportDiagnostics) {
                    Text("Export", bundle: .main)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("Copy all probe reports as redacted JSON to clipboard"))

                Spacer(minLength: 0)
            }
            .padding(.top, DesignTokens.Spacing.xs)
        } header: {
            SettingsSearchSectionHeader("Diagnostics", anchor: .workshopDiagnostics)
        } footer: {
            // Scoped to verdicts on purpose: running the checks does briefly
            // re-verify the Steam sign-in, and downloads wait for that — so
            // "these never stop you" would have been false for those seconds.
            Text("A failing check never takes an action away from you. It reports what it found; nothing here decides whether you can browse, download or play.", bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            pasteboard.declareTypes([.string], owner: nil)
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
