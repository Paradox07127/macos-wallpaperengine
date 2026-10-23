import AppKit
import LiveWallpaperCore
import SwiftUI

/// Inspects on open; repair only acts on the reviewed report, so the sheet never removes anything the user has not seen.
@available(macOS 26.0, *)
struct SystemWallpaperRegistrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let service: WallpaperExportService
    @State private var confirmsRepair = false

    private var maintenance: SystemWallpaperMaintenanceController {
        service.maintenance
    }

    private var report: SystemWallpaperMaintenanceReport? {
        maintenance.report
    }

    private var removalCount: Int {
        report?.copies.count(where: \.willUnregister) ?? 0
    }

    private var primaryTitle: LocalizedStringKey {
        removalCount == 0 ? "Re-register and Restart" : "Remove \(removalCount) and Restart"
    }

    var body: some View {
        VStack(spacing: 0) {
            SteamSheetHeader(
                icon: "puzzlepiece.extension",
                title: "Extension Registrations",
                iconTint: .accentColor,
                subtitle: "macOS can keep registrations from older or moved copies of Loomscreen. Only one copy should provide the system wallpaper."
            )
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.top, DesignTokens.Settings.formVerticalMargin)

            Form {
                Section {
                    LabeledContent("Inspected app") {
                        Text(verbatim: report?.currentAppPath ?? Bundle.main.bundlePath)
                            .font(DesignTokens.Typography.codeCaption)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Last connected extension") {
                        if let heartbeat = service.heartbeat, let provider = heartbeat.provider {
                            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xxs) {
                                Text(verbatim: provider.bundlePath)
                                    .font(DesignTokens.Typography.codeCaption)
                                    .textSelection(.enabled)
                                Text("Build \(provider.build), \(heartbeat.timestamp, style: .relative) ago")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("None yet")
                        }
                    }
                }

                if let report, report.outcome == .inspected {
                    Section {
                        group("This app", symbol: "checkmark.circle.fill", tint: DesignTokens.Colors.Status.active,
                              copies: report.copies.filter(\.isCurrent))
                        group("Registration to remove", symbol: "minus.circle.fill", tint: DesignTokens.Colors.Status.warning,
                              copies: report.copies.filter { !$0.isCurrent && $0.willUnregister })
                        group("Preserved", symbol: "lock.circle", tint: .secondary,
                              copies: report.copies.filter { !$0.isCurrent && !$0.willUnregister })
                    } header: {
                        Text("Found \(report.copies.count), will remove \(removalCount)")
                    }
                }

                Section {
                    switch maintenance.phase {
                    case .inspecting:
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Inspecting registrations…")
                        }
                    case .idle:
                        if report?.outcome == .repaired {
                            Text("Removed \(report?.removedCount ?? 0) registrations.")
                        }
                    default:
                        if report?.outcome == .repaired {
                            Text("Removed \(report?.removedCount ?? 0) registrations.")
                        }
                        SystemWallpaperMaintenanceResult(maintenance: maintenance)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            SheetFooterBar(
                primaryTitle: primaryTitle,
                primaryAction: { confirmsRepair = true },
                primaryDisabled: maintenance.isBusy || report?.outcome != .inspected,
                cancelTitle: "Done",
                cancelAction: { dismiss() },
                leading: {
                    Button("Copy Report", action: copyReport)
                        .disabled(report == nil)
                }
            )
        }
        .frame(width: 620, height: 560)
        .background(DesignTokens.Colors.pageBackground)
        .task { await maintenance.inspect() }
        .alert(primaryTitle, isPresented: $confirmsRepair) {
            Button(primaryTitle) { Task { await maintenance.recover(service: service, repair: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The system wallpaper service restarts and every system wallpaper redraws once. App files and videos are kept.")
        }
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, symbol: String, tint: Color,
                       copies: [SystemWallpaperMaintenanceReport.Copy]) -> some View {
        if !copies.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Label {
                    Text(title).font(DesignTokens.Typography.bodyEmphasized)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                ForEach(copies) { copy in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: copy.path)
                            .font(DesignTokens.Typography.codeCaption)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        if copy.exists {
                            Button("Show in Finder") { maintenance.reveal(copy.path) }.buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(.vertical, DesignTokens.Spacing.xxs)
        }
    }

    private func copyReport() {
        guard let report else { return }
        var lines = ["Outcome: \(report.outcome.rawValue)"]
        if let path = report.currentAppPath {
            lines.append("Inspected app: \(path)")
        }
        if let provider = service.heartbeat?.provider {
            lines.append("Last connected extension: \(provider.bundlePath) (build \(provider.build))")
        }
        for copy in report.copies {
            let role = copy.isCurrent ? "current" : copy.willUnregister ? "remove" : "preserve"
            lines.append("\(role)\t\(copy.bundleID)\t\(copy.exists ? "exists" : "missing")\t\(copy.path)")
        }
        if report.removedCount > 0 {
            lines.append("Removed: \(report.removedCount)")
        }
        if let code = report.errorCode {
            lines.append("Error: \(code)")
        }
        if let stage = report.failedStage {
            lines.append("Failed stage: \(stage)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
