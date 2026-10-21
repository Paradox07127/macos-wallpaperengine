#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

struct WorkshopDiagnosticsSection: View {
    @Binding var showingExportToast: Bool

    @Environment(SteamCMDDoctorService.self) private var service
    @Environment(WorkshopSetupController.self) private var controller

    @State private var showingSignIn = false
    @State private var showingSteamCMDSetup = false

    var body: some View {
        Section {
            ForEach(DoctorProbeKind.allCases) { kind in
                WorkshopProbeRow(
                    report: service.probes[kind]
                        ?? DoctorProbeReport(id: kind, status: .notRun, lastRun: .distantPast),
                    service: service,
                    onCopied: { showingExportToast = true },
                    onConnectAccount: { showingSignIn = true },
                    onLocateSteamCMD: { controller.autoDetectBinary(onNeedsSetup: { showingSteamCMDSetup = true }) }
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
            // Attach the sheet to a row so Form retains section styling.
            .sheet(isPresented: $showingSignIn) {
                AppLanguageScope(defaults: .appScoped()) {
                    SteamSignInSheet { accountName in
                        controller.adoptSignedInAccount(accountName)
                    }
                }
            }
            .sheet(isPresented: $showingSteamCMDSetup) {
                AppLanguageScope(defaults: .appScoped()) {
                    SteamCMDSetupSheet(onConfirmManagedInstall: { controller.runManagedInstall() }, isRecovery: true)
                }
            }
        } header: {
            SettingsSearchSectionHeader("Diagnostics", anchor: .workshopDiagnostics)
        }
    }

    // MARK: - Export

    private func exportDiagnostics() {
        guard let json = service.diagnosticsJSON() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        showingExportToast = pasteboard.setString(json, forType: .string)
    }

}
#endif
