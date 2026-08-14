#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

struct WorkshopDoctorView: View {
    @Environment(SteamCMDDoctorService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var showingToast = false
    @State private var setupError: String?
    @State private var showsAdvancedDiagnostics = false
    @State private var isDetectingBinary = false
    @State private var discoveredAccounts: [SteamAccountSummary] = []
    @State private var managedInstaller = SteamCMDManagedInstallCoordinator()
    @State private var showingInstallConsent = false
    /// The window between "the connector reported installed" and "we confirmed
    /// it launches". Without it the row falls back to `binaryDisplayPath`, which
    /// is still nil, and reads "Not selected" moments after a successful install.
    @State private var isVerifyingInstall = false
    @State private var installTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    statusStrip
                    stepList
                    Divider()
                    advancedDiagnosticsSection
                    HStack {
                        WorkshopPrivacyLink()
                        Spacer()
                    }
                }
                .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                .padding(.vertical, DesignTokens.Spacing.lg)
            }
            .background(DesignTokens.Colors.pageBackground)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, idealHeight: 640)
        .overlay(alignment: .bottom) {
            DiagnosticExportToast(isPresented: $showingToast)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showingInstallConsent) {
            SteamCMDManagedInstallSheet(onConfirm: runManagedInstall)
        }
        .task {
            await service.autoConfigureIfNeeded()
            await loadAccounts()
        }
    }

    // MARK: - Sections

    private var navigationBar: some View {
        HStack {
            Text("Steam connection")
                .font(DesignTokens.Typography.sectionTitle)
            Spacer()
            Button("Done") { dismiss() }
                .adaptiveGlassButton(.regular)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.bar)
    }

    private var statusStrip: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: connectionHeaderIcon)
                .font(.system(size: 22))
                .foregroundStyle(connectionHeaderTint)
            Text(connectionHeaderTitle)
                .font(DesignTokens.Typography.sectionTitle)
            Spacer()
            Text("\(completedSetupStepCount) of 3 ready", bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkshopSetupRow(
                icon: "folder",
                title: "Steam library",
                detail: service.workdirDisplayPath ?? String(localized: "Not authorized", comment: "Steam library step detail when no folder has been picked."),
                state: isLibraryReady ? .ready : .notStarted,
                info: "Pick Steam's own folder — the one containing config/config.vdf — once. Loomscreen keeps a security-scoped bookmark to it and never creates a second Workshop repository."
            ) {
                Button(isLibraryReady ? "Change…" : "Choose…") { pickSteamLibrary() }
                    .adaptiveGlassButton(.regular, size: .small)
            }

            Divider()

            WorkshopSetupRow(
                icon: "terminal",
                title: "SteamCMD",
                detail: binaryDetail,
                state: binaryState,
                info: "Valve's command-line downloader. Loomscreen can install it for you, or find an existing Homebrew or tarball install; otherwise pick the executable or its steamcmd.sh wrapper."
            ) {
                binaryControl
            }

            Divider()

            WorkshopSetupRow(
                icon: "person.crop.circle",
                title: "Steam account",
                detail: accountDetail,
                state: accountState,
                info: "Downloads sign in as your own Steam account through SteamCMD. Loomscreen lists the accounts Steam has already signed in on this Mac; it never stores your password."
            ) {
                accountPicker
            }

            if let setupError {
                Label(setupError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .font(DesignTokens.Typography.caption)
                    .padding(.top, DesignTokens.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text("Setup error: \(setupError)"))
            }
        }
    }

    /// Three states, because the right action differs completely between them.
    /// Most Macs have no SteamCMD, so for them the managed install is the whole
    /// point of this row and belongs in a primary button, not behind a menu
    /// labelled "Set up".
    @ViewBuilder
    private var binaryControl: some View {
        if isBinaryBusy {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                if isCancellableInstall {
                    Button("Cancel") { cancelManagedInstall() }
                        .adaptiveGlassButton(.regular, size: .small)
                }
            }
        } else if isBinaryReady {
            Menu {
                binarySourceItems
            } label: {
                Text("Change", bundle: .main)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Install SteamCMD…") { showingInstallConsent = true }
                    .adaptiveGlassButton(.prominent, size: .small)

                Menu {
                    binarySourceItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Other SteamCMD options"))
            }
        }
    }

    /// The defaults record is not the only way a managed install can be the one
    /// in use: auto-detect deliberately rebinds a copy the connector rediscovers
    /// even when the record is gone (cleared defaults, a restored container).
    /// Keying the Remove action on the record alone left that copy sitting
    /// outside the container with no way to remove it — while the consent sheet
    /// had promised it could be removed from this screen.
    private var hasManagedInstall: Bool {
        if managedInstaller.managedInstall != nil { return true }
        guard let bound = service.binaryPath else { return false }
        return bound.hasPrefix(Self.managedInstallRoot + "/")
    }

    private static var managedInstallRoot: String {
        SteamCMDManagedInstaller.canonicalInstallRoot(
            home: AppleAerialsLibrary.realHomeDirectory()
        ).path(percentEncoded: false)
    }

    @ViewBuilder
    private var binarySourceItems: some View {
        if !isBinaryReady {
            Button("Install SteamCMD…") { showingInstallConsent = true }
        }
        Button("Locate automatically") { autoDetectBinary() }
        if hasManagedInstall {
            Divider()
            Button("Remove the copy Loomscreen installed", role: .destructive) {
                removeManagedInstall()
            }
        }
    }

    /// Only the download is genuinely interruptible. Once the archive is with
    /// the connector it is unpacking, verifying and running `+quit` in a
    /// process we cannot interrupt, and a Cancel button there would either lie
    /// or leave a half-written payload behind.
    private var isCancellableInstall: Bool {
        managedInstaller.status == .downloading
    }

    /// Accounts from Steam `config.vdf` via the connector (sandbox cannot read that file).
    @ViewBuilder
    private var accountPicker: some View {
        if discoveredAccounts.isEmpty {
            Button("Rescan") { Task { await loadAccounts() } }
                .adaptiveGlassButton(.regular, size: .small)
        } else {
            Menu {
                ForEach(discoveredAccounts) { account in
                    Button {
                        selectAccount(account)
                    } label: {
                        if account.accountName == service.username {
                            Label(account.accountName, systemImage: "checkmark")
                        } else {
                            Text(account.accountName)
                        }
                    }
                }
            } label: {
                Text(service.username == nil ? "Choose" : "Switch", bundle: .main)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var accountDetail: String {
        guard let username = service.username else {
            return discoveredAccounts.isEmpty
                ? String(localized: "No Steam sign-in found on this Mac", comment: "Steam account step detail when config.vdf lists no accounts.")
                : String(localized: "No account selected", comment: "Steam account step detail when no account is chosen.")
        }
        return username
    }

    /// Driven by the cached-login probe only (single source of truth).
    private var accountState: WorkshopStepState {
        guard service.username != nil else { return .notStarted }
        switch service.probes[.cachedLogin]?.status {
        case .green: return .ready
        case .running: return .working
        case .notRun, .none: return .notStarted
        default: return .attention
        }
    }

    private func selectAccount(_ account: SteamAccountSummary) {
        setupError = nil
        do {
            try service.setUsername(account.accountName)
        } catch {
            setupError = error.localizedDescription
            return
        }
        Task { await service.runProbe(.cachedLogin) }
    }

    private func loadAccounts() async {
        discoveredAccounts = await SteamConnectorClient.discoverAccounts()
        // Auto-select the only discovered account so setup finishes without a menu click.
        if service.username == nil, discoveredAccounts.count == 1 {
            selectAccount(discoveredAccounts[0])
        }
    }

    // MARK: - Setup actions

    private func pickSteamLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // Not `homeDirectoryForCurrentUser` — sandbox maps that to the container, which also has a `Steam` folder we must not bind.
        panel.directoryURL = AppleAerialsLibrary.realHomeDirectory()
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        panel.message = String(localized: "Choose Steam's main folder containing config/config.vdf.", comment: "Open-panel message when authorizing the official Steam Library.")
        panel.prompt = String(localized: "Use Steam Library", comment: "Open-panel confirm button when authorizing the official Steam Library.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setupError = nil
        Task {
            do { try await service.bindSteamLibrary(url) } catch { await MainActor.run { setupError = error.localizedDescription } }
        }
    }

    /// Nothing to fall back to when detection finds nothing: pointing us at a
    /// file by hand is no longer an option, because a path the app names is one
    /// it can also rewrite between our checks and the connector's spawn. The
    /// remaining answer is to let Loomscreen install its own copy.
    private func autoDetectBinary() {
        setupError = nil
        isDetectingBinary = true
        Task {
            let found = await service.autoDetectBinary()
            isDetectingBinary = false
            if !found {
                setupError = String(
                    localized: "No SteamCMD found in the usual places. Use Install SteamCMD… to let Loomscreen set up its own copy.",
                    comment: "Workshop setup error when auto-detection finds no SteamCMD and manual selection is not offered."
                )
            }
        }
    }

    /// Installs, then binds through the normal auto-detect path rather than the
    /// returned path: binding is what makes the rest of the Doctor consider
    /// SteamCMD set up, and auto-detect asks the connector to launch the binary
    /// instead of inferring from the install having reported success.
    private func cancelManagedInstall() {
        installTask?.cancel()
        installTask = nil
        managedInstaller.cancelInstall()
        setupError = nil
    }

    private func runManagedInstall() {
        setupError = nil
        installTask = Task {
            switch await managedInstaller.install() {
            case .installed:
                isVerifyingInstall = true
                let bound = await service.autoDetectBinary()
                isVerifyingInstall = false
                if !bound {
                    setupError = String(
                        localized: "SteamCMD was installed but could not be started.",
                        comment: "Workshop setup error after a managed SteamCMD install that will not launch."
                    )
                }
            case .failed(let reason):
                setupError = reason
            case .idle, .downloading, .installing, .removing:
                // Either a second install was already running and owns the
                // outcome, or this one was cancelled — neither is an error.
                break
            }
            installTask = nil
        }
    }

    private func removeManagedInstall() {
        setupError = nil
        let installRoot = Self.managedInstallRoot
        Task {
            let removed = await managedInstaller.forget()
            guard removed else {
                // The files are still there and still work. Unbinding here would
                // take a working SteamCMD away from the user as the visible
                // result of a delete that did not happen. `forget()` keeps the
                // install record on failure, so the Remove command stays in the
                // menu and this is retryable.
                setupError = String(
                    localized: "Couldn't remove the SteamCMD copy Loomscreen installed.",
                    comment: "Workshop setup error when removing a managed SteamCMD install fails."
                )
                return
            }
            // The bound path is the Mach-O inside the payload, not the root, so
            // compare by containment.
            if service.binaryPath?.hasPrefix(installRoot + "/") == true {
                service.unbindBinary()
                await service.autoDetectBinary()
            }
        }
    }

    private var advancedDiagnosticsSection: some View {
        DisclosureGroup(isExpanded: $showsAdvancedDiagnostics) {
            VStack(spacing: 0) {
                Divider().padding(.vertical, DesignTokens.Spacing.sm)
                ForEach(Array(DoctorProbeKind.allCases.enumerated()), id: \.element.id) { index, kind in
                    let report = service.probes[kind] ?? DoctorProbeReport(id: kind, status: .notRun, lastRun: .distantPast)
                    ProbeRow(
                        report: report,
                        service: service,
                        onCopied: { showingToast = true }
                    )
                    if index < DoctorProbeKind.allCases.count - 1 {
                        Divider().padding(.vertical, DesignTokens.Spacing.xs)
                    }
                }
                Divider().padding(.vertical, DesignTokens.Spacing.sm)
                footerBar
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Diagnostics", bundle: .main)
                    .font(DesignTokens.Typography.bodyEmphasized)
                InfoTooltipButton(
                    text: "Runs read-only checks against the selected SteamCMD binary and your authorized Steam folder. Diagnostics never request Steam credentials."
                )
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button(action: exportDiagnostics) {
                Label("Export diagnostics", systemImage: "doc.on.doc")
            }
            .adaptiveGlassButton(.regular, size: .small)
            .help(Text("Copy all probe reports as redacted JSON to clipboard"))

            Spacer()

            Button(action: { Task { await service.runAll() } }) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if service.state == .probing {
                        ProgressView().controlSize(.small)
                    }
                    Text("Run all probes")
                }
            }
            .adaptiveGlassButton(.prominent, size: .regular)
            .disabled(service.state == .probing)
            .help(Text("Run every diagnostic check against the bound SteamCMD install."))
        }
    }

    // MARK: - Connection status

    private var isLibraryReady: Bool {
        guard service.workdirBookmarkData != nil else { return false }
        if case .red? = service.probes[.workingDirectory]?.status { return false }
        return true
    }

    private var isBinaryReady: Bool {
        service.hasBoundBinary && service.isGreen(.binaryIdentity)
    }

    /// Both the download and the connector-side unpack can take a while, so the
    /// row reports which one is running rather than only spinning.
    private var binaryDetail: String {
        switch managedInstaller.status {
        case .downloading:
            return String(localized: "Downloading SteamCMD…", comment: "SteamCMD step detail while the bootstrap archive downloads.")
        case .installing:
            return String(localized: "Setting up SteamCMD…", comment: "SteamCMD step detail while the connector unpacks and verifies the install.")
        case .removing:
            return String(localized: "Removing SteamCMD…", comment: "SteamCMD step detail while the connector deletes the managed install.")
        case .idle, .installed, .failed:
            if isVerifyingInstall {
                return String(
                    localized: "Checking that SteamCMD runs…",
                    comment: "SteamCMD step detail while the connector launches the freshly installed binary to confirm it works."
                )
            }
            return service.binaryDisplayPath
                ?? String(localized: "Not selected", comment: "SteamCMD step detail when no binary is bound.")
        }
    }

    private var isBinaryBusy: Bool {
        if isDetectingBinary || isVerifyingInstall { return true }
        switch managedInstaller.status {
        // Removing counts as busy: the menu that starts an install is disabled
        // off this, and the coordinator now refuses one mid-removal anyway —
        // offering a command that will be declined is worse than greying it out.
        case .downloading, .installing, .removing: return true
        case .idle, .installed, .failed: return false
        }
    }

    private var binaryState: WorkshopStepState {
        if isBinaryBusy { return .working }
        guard service.hasBoundBinary else { return .notStarted }
        switch service.probes[.binaryIdentity]?.status {
        case .green: return .ready
        case .red: return .attention
        default: return .working
        }
    }

    private var completedSetupStepCount: Int {
        (isLibraryReady ? 1 : 0) + (isBinaryReady ? 1 : 0) + (accountState == .ready ? 1 : 0)
    }

    private var connectionHeaderTitle: LocalizedStringKey {
        isLibraryReady ? "Official Steam library connected" : "Connect your Steam library"
    }

    private var connectionHeaderIcon: String {
        isLibraryReady ? "externaldrive.badge.checkmark" : "externaldrive.badge.exclamationmark"
    }

    private var connectionHeaderTint: Color {
        isLibraryReady ? DesignTokens.Colors.Status.active : DesignTokens.Colors.Status.warning
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
            showingToast = true
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

// MARK: - Card

// MARK: - Picker rows

// MARK: - Probe row

private struct ProbeRow: View {
    let report: DoctorProbeReport
    let service: SteamCMDDoctorService
    let onCopied: () -> Void

    @State private var commandRevealed = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            statusIcon
                .frame(width: 20, height: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    Text(report.id.displayName)
                        .font(DesignTokens.Typography.bodyEmphasized)
                    Spacer()
                    if let value = inlineValue {
                        Text(value)
                            .font(DesignTokens.Typography.code)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                if let description = descriptionText {
                    Text(description)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let cmd = revealedCommand {
                    TerminalCommandPanel(command: cmd, redactedPreview: false, onCopied: onCopied)
                        .padding(.top, DesignTokens.Spacing.xs)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if hasActionRow {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        actionButtons
                        Spacer()
                        rerunButton
                    }
                    .padding(.top, DesignTokens.Spacing.xs)
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .animation(.easeInOut(duration: 0.18), value: report.status)
        .animation(.easeInOut(duration: 0.18), value: commandRevealed)
    }

    @ViewBuilder private var statusIcon: some View {
        switch report.status {
        case .green:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.Colors.Status.active)
                .accessibilityLabel(Text("Passed"))
        case .yellow:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .accessibilityLabel(Text("Warning"))
        case .red:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.Colors.Status.danger)
                .accessibilityLabel(Text("Failed"))
        case .running:
            ProgressView().controlSize(.small).accessibilityLabel(Text("Running"))
        case .notRun:
            Image(systemName: "circle.dotted")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
                .accessibilityLabel(Text("Not run"))
        }
    }

    private var inlineValue: String? {
        if report.id == .cachedLogin, case .green = report.status, let user = service.username {
            return user
        }
        switch report.status {
        case .green(let detail): return detail
        default: return nil
        }
    }

    private var descriptionText: String? {
        switch report.status {
        case .notRun:
            return String(localized: "Not run yet.", comment: "Workshop Doctor probe has not been run.")
        case .running:
            return String(localized: "Running…", comment: "Workshop Doctor probe is running.")
        case .green: return nil
        case .yellow(let msg, _): return msg
        case .red(let msg, _): return msg
        }
    }

    private var commandFromStatus: String? {
        switch report.status {
        case .yellow(_, let cmd): return cmd
        case .red(_, let cmd): return cmd
        default: return nil
        }
    }

    private var revealedCommand: String? {
        commandRevealed ? commandFromStatus : nil
    }

    private var hasActionRow: Bool {
        guard report.status != .notRun, report.status != .running else { return false }
        if report.id == .cachedLogin { return false }
        switch report.status {
        case .green: return false
        default: return true
        }
    }

    @ViewBuilder private var actionButtons: some View {
        switch (report.id, report.status) {
        case (.binaryIdentity, .red):
            // Re-detect rather than re-select: the fix for a bad identity is a
            // binary from a source we trust, not another path typed at us.
            Button("Locate automatically") {
                Task { await service.autoDetectBinary() }
            }
            .adaptiveGlassButton(.prominent, size: .small)

        case (.gatekeeperQuarantine, .yellow), (.gatekeeperQuarantine, .red):
            showCommandButton()

        case (.codeSignature, .yellow):
            if commandFromStatus != nil {
                showCommandButton(label: "Show codesign command")
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder private func showCommandButton(label: String = "Show command") -> some View {
        if commandFromStatus != nil {
            Button(commandRevealed ? "Hide command" : label) {
                commandRevealed.toggle()
            }
            .adaptiveGlassButton(.regular, size: .small)
        }
    }

    private var rerunButton: some View {
        Button(action: { Task { await service.runProbe(report.id) } }) {
            Label("Re-run", systemImage: "arrow.clockwise")
                .font(DesignTokens.Typography.caption)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(Text("Re-run this probe"))
    }

}

// MARK: - Helpers

#endif
