#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// The three Steam connection steps plus their diagnostics, as form sections.
///
/// Two surfaces show them: the onboarding sheet (`WorkshopDoctorView`) and the
/// Workshop settings page, which used to push them as a second-level page.
/// Both drop these sections straight into their own `Form`, so neither can
/// drift from the other.
struct WorkshopConnectionSetup<Header: View>: View {
    /// Raised when the diagnostics JSON lands on the pasteboard. The host owns
    /// the toast because the toast is an overlay on a window, not a form row.
    @Binding var showingExportToast: Bool
    @ViewBuilder let header: () -> Header

    @Environment(SteamCMDDoctorService.self) private var service

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
    @State private var showingSignIn = false
    @State private var showingBrewInstructions = false
    /// Mirrors the connector's manual binding for one purpose: deciding whether
    /// to offer "Forget". The record itself lives in the connector's own root,
    /// which this sandboxed process cannot read — so this is a display hint, not
    /// a source of truth about what will actually be executed.
    @AppStorage("loomscreen.workshop.doctor.hasManualBinding.v1", store: .appScoped())
    private var hasManualBinding = false

    var body: some View {
        Section {
            stepList
            diagnosticsDisclosure
        } header: {
            header()
        }
    }

    // MARK: - Steps

    /// `SettingRow`, not the taller onboarding step row: on a settings page
    /// these sit among ordinary setting rows, and a row that is 5pt taller with
    /// a differently-drawn icon is exactly what makes a page look assembled
    /// from parts. Onboarding keeps `WorkshopSetupRow`, where the extra height
    /// is the point.
    @ViewBuilder
    private var stepList: some View {
        SettingRow(
            icon: "folder",
            iconColor: .teal,
            title: "Steam library",
            valueSubtitle: service.workdirDisplayPath ?? String(localized: "Not authorized", comment: "Steam library step detail when no folder has been picked."),
            titleBadge: attentionBadge(for: service.libraryStepState),
            info: "Pick Steam's own folder — the one containing config/config.vdf — once. Loomscreen keeps a security-scoped bookmark to it and never creates a second Workshop repository."
        ) {
            libraryControl
                .fixedSize()
        }
        // The three sheets and the initial probe hang off the first row rather
        // than the section: a modified `Section` stops being a section to
        // `Form`, and a presenter only has to be somewhere in the hierarchy.
        .sheet(isPresented: $showingInstallConsent) {
            SteamCMDManagedInstallSheet(onConfirm: runManagedInstall)
        }
        .sheet(isPresented: $showingSignIn) {
            SteamSignInSheet { accountName in
                service.username = accountName
                Task {
                    await loadAccounts()
                    await service.runProbe(.cachedLogin)
                }
            }
        }
        .sheet(isPresented: $showingBrewInstructions) {
            SteamCMDSheet()
        }
        .task {
            await service.autoConfigureIfNeeded()
            await loadAccounts()
        }

        SettingRow(
            icon: "terminal",
            iconColor: .purple,
            title: "SteamCMD",
            valueSubtitle: binaryDetail,
            titleBadge: attentionBadge(for: binaryState),
            info: "Valve's command-line downloader. Loomscreen can install it for you or locate an existing verified Homebrew or tarball install."
        ) {
            binaryControl
                .fixedSize()
        }

        SettingRow(
            icon: "person.crop.circle",
            iconColor: .blue,
            title: "Steam account",
            valueSubtitle: accountDetail,
            titleBadge: attentionBadge(for: service.accountStepState),
            info: "Downloads sign in as your own Steam account through SteamCMD. Loomscreen lists the accounts Steam has already signed in on this Mac; it never stores your password."
        ) {
            accountPicker
                .fixedSize()
        }

        if let setupError {
            Label(setupError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.danger)
                .font(DesignTokens.Typography.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Setup error: \(setupError)"))
        }
    }

    /// One action, so a button — the menu it used to be held a single item and
    /// spent a disclosure arrow saying so.
    @ViewBuilder
    private var libraryControl: some View {
        if service.isLibraryReady {
            Button("Change…") { pickSteamLibrary() }
        } else {
            Button("Choose…") { pickSteamLibrary() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Three states, because the right action differs completely between them.
    /// Most Macs have no SteamCMD, so for them the managed install is the whole
    /// point of this row and belongs in a primary button, not behind a menu
    /// labelled "Set up". Set up or not, the shape is the same: a button for
    /// the one thing most people want, and `⋯` for the rest.
    @ViewBuilder
    private var binaryControl: some View {
        if isBinaryBusy {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if service.isBinaryPresumedReady {
                    Button("Change…") { pickBinaryManually() }
                } else {
                    Button("Install SteamCMD…") { showingInstallConsent = true }
                        .buttonStyle(.borderedProminent)
                }

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
        // The button beside this menu already carries the common verb for the
        // current state; the menu carries the other one, never both.
        if service.isBinaryPresumedReady {
            Button("Install SteamCMD…") { showingInstallConsent = true }
        } else {
            Button("Choose SteamCMD…") { pickBinaryManually() }
        }
        Button("Locate automatically") { autoDetectBinary() }
        Button("Install with Homebrew…") { showingBrewInstructions = true }
        if hasManualBinding {
            Button("Forget the SteamCMD I chose") { forgetManualBinary() }
        }
        if hasManagedInstall {
            Divider()
            Button("Remove the copy Loomscreen installed", role: .destructive) {
                removeManagedInstall()
            }
        }
    }

    /// Accounts from Steam `config.vdf` via the connector (sandbox cannot read that file).
    @ViewBuilder
    private var accountPicker: some View {
        if discoveredAccounts.isEmpty {
            // One verb, not two side by side. Rescan is the rarer of the pair
            // and moves into the menu once there is a menu to hold it.
            Button("Sign In…") { showingSignIn = true }
                .buttonStyle(.borderedProminent)
        } else {
            Menu {
                steamAccountMenuItems(
                    accounts: discoveredAccounts,
                    current: service.username,
                    onSelect: selectAccount,
                    onSignIn: { showingSignIn = true },
                    onRescan: { Task { await loadAccounts() } }
                )
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

    private func selectAccount(_ account: SteamAccountSummary) {
        setupError = nil
        do {
            try service.adoptAccount(account)
        } catch {
            setupError = error.localizedDescription
        }
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

    private func autoDetectBinary() {
        setupError = nil
        isDetectingBinary = true
        Task {
            let found = await service.autoDetectBinary()
            isDetectingBinary = false
            if !found {
                setupError = String(
                    localized: "No SteamCMD found in the usual places. Use Install SteamCMD… for Loomscreen's own copy, or Choose SteamCMD… to point at one yourself.",
                    comment: "Workshop setup error when auto-detection finds no SteamCMD."
                )
            }
        }
    }

    /// The recourse when SteamCMD is installed somewhere auto-detection has
    /// never heard of.
    ///
    /// The path only travels as far as the connector, which resolves it, gates
    /// it, and records it on its own side; the app never gets to say what runs
    /// on any subsequent download. See `SteamCMDManualBinding`.
    private func pickBinaryManually() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        // Homebrew's cask lives under a dot-directory on newer versions.
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true)
        panel.message = String(localized: "Choose the steamcmd binary, or the steamcmd.sh that launches it.", comment: "Open-panel message when pointing Loomscreen at an existing SteamCMD.")
        panel.prompt = String(localized: "Use SteamCMD", comment: "Open-panel confirm button when pointing Loomscreen at an existing SteamCMD.")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        setupError = nil
        isDetectingBinary = true
        Task {
            let result = await SteamConnectorClient.bindManualSteamCMDBinary(
                path: url.path(percentEncoded: false)
            )
            defer { isDetectingBinary = false }
            guard let result, result.isBound, let canonical = result.canonicalPath else {
                setupError = result?.failureReason ?? String(
                    localized: "Loomscreen couldn't use that file as SteamCMD.",
                    comment: "Workshop setup error when a manually chosen SteamCMD is refused."
                )
                return
            }
            // Bind through the service so the identity probe re-runs against the
            // new binary rather than leaving the previous one's verdict on screen.
            do {
                try await service.bindResolvedBinary(canonical)
                hasManualBinding = true
            } catch {
                setupError = error.localizedDescription
            }
        }
    }

    private func forgetManualBinary() {
        setupError = nil
        isDetectingBinary = true
        Task {
            await SteamConnectorClient.clearManualSteamCMDBinary()
            hasManualBinding = false
            let found = await service.autoDetectBinary()
            isDetectingBinary = false
            if !found { service.unbindBinary() }
        }
    }

    /// Installs, then binds through the normal auto-detect path rather than the
    /// returned path: binding is what makes the rest of the Doctor consider
    /// SteamCMD set up, and auto-detect asks the connector to launch the binary
    /// instead of inferring from the install having reported success.
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
            case .idle, .installing, .removing:
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

    // MARK: - Diagnostics

    /// The last row of the connection section rather than a section of its
    /// own: the probes only ever describe the three steps above them, and as a
    /// separate section they read as a fourth thing to set up. Collapsed it
    /// costs one row, and the row states its own verdict.
    private var diagnosticsDisclosure: some View {
        DisclosureGroup(isExpanded: $showsAdvancedDiagnostics) {
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
                        Text("Run all checks")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.state == .probing)

                // A button, not a link: this copies a payload to the
                // pasteboard. Link styling is for things that open a web page.
                Button(action: exportDiagnostics) {
                    Text("Export…", bundle: .main)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("Copy all probe reports as redacted JSON to clipboard"))

                Spacer(minLength: 0)
            }
            .padding(.top, DesignTokens.Spacing.xs)
        } label: {
            // The whole row toggles, not just the chevron: a 12pt triangle is
            // the only hit target `DisclosureGroup` gives its label by default,
            // and every other expandable row in Settings takes a click anywhere.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsAdvancedDiagnostics.toggle()
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Diagnostics", bundle: .main)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    if !showsAdvancedDiagnostics, let summary = diagnosticsSummary {
                        Text(summary)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.Status.warning)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                showsAdvancedDiagnostics ? Text("Hide details") : Text("Show details")
            )
        }
    }

    /// What the collapsed header says. Silent when everything passes: a row of
    /// "all good" on a section nobody opened is noise.
    private var diagnosticsSummary: String? {
        let failing = DoctorProbeKind.allCases.filter { kind in
            switch service.probes[kind]?.status {
            case .yellow, .red: return true
            default: return false
            }
        }
        guard !failing.isEmpty else { return nil }
        return String(
            localized: "\(failing.count) need attention",
            comment: "Collapsed diagnostics header summary; %lld is how many probes are failing."
        )
    }

    // MARK: - Derived row state

    /// Only failures get a title badge. The page-top status bar carries the
    /// "everything is fine" reading now, and a green seal on every row was the
    /// noise it replaced — but a step whose probe came back red has to say so
    /// where the step is.
    private func attentionBadge(for state: WorkshopStepState) -> SettingRowTitleBadge? {
        guard state == .attention else { return nil }
        return SettingRowTitleBadge(
            systemImage: "exclamationmark.triangle.fill",
            tint: DesignTokens.Colors.Status.warning,
            accessibilityLabel: Text(state.statusText, bundle: .main)
        )
    }

    private var binaryDetail: String {
        switch managedInstaller.status {
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
        case .installing, .removing: return true
        case .idle, .installed, .failed: return false
        }
    }

    private var binaryState: WorkshopStepState {
        isBinaryBusy ? .working : service.binaryStepState
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

// MARK: - Shared step readiness

/// One reading of each step, so the sheet header, the settings status bar and
/// the rows themselves can't disagree about what is set up.
extension SteamCMDDoctorService {
    var isLibraryReady: Bool {
        guard workdirBookmarkData != nil else { return false }
        if case .red? = probes[.workingDirectory]?.status { return false }
        return true
    }

    var isBinaryReady: Bool {
        hasBoundBinary && isGreen(.binaryIdentity)
    }

    /// What the UI should offer as the next action, which is looser than
    /// `isBinaryReady` on purpose.
    ///
    /// Probe results are not persisted, so every relaunch starts at `.notRun`
    /// and a perfectly good binding reads as unverified. Gating the prominent
    /// button on the strict flag put "Install SteamCMD…" in front of users who
    /// already had one bound — clicking it reinstalls what is on disk. Matches
    /// `binaryStepState`, which already treats bound-but-unprobed as working.
    var isBinaryPresumedReady: Bool {
        guard hasBoundBinary else { return false }
        if case .red? = probes[.binaryIdentity]?.status { return false }
        return true
    }

    var libraryStepState: WorkshopStepState {
        guard workdirBookmarkData != nil else { return .notStarted }
        if case .red? = probes[.workingDirectory]?.status { return .attention }
        return .ready
    }

    /// `.working` covers "bound, not yet checked" as well as "checking right
    /// now": a binary we have never probed is unverified, not broken.
    var binaryStepState: WorkshopStepState {
        guard hasBoundBinary else { return .notStarted }
        switch probes[.binaryIdentity]?.status {
        case .green: return .ready
        case .red: return .attention
        default: return .working
        }
    }

    /// Driven by the cached-login probe only (single source of truth).
    var accountStepState: WorkshopStepState {
        guard username != nil else { return .notStarted }
        switch probes[.cachedLogin]?.status {
        case .green: return .ready
        case .running: return .working
        case .notRun, .none: return .notStarted
        default: return .attention
        }
    }

    /// The three steps as one reading, for the Workshop page's status bar.
    ///
    /// Amber means a probe came back failing — never "we haven't checked yet".
    /// Treating unchecked as failing is what used to leave the bar amber after
    /// a successful Locate: `cachedLogin` had simply never run, and only Run
    /// all checks cleared it.
    var connectionStepState: WorkshopStepState {
        let steps = [libraryStepState, binaryStepState, accountStepState]
        if steps.contains(.attention) { return .attention }
        if steps.allSatisfy({ $0 == .ready }) { return .ready }
        if steps.contains(.working) { return .working }
        return .notStarted
    }
}
#endif
