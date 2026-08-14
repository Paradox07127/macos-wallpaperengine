#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

struct WorkshopDoctorView: View {
    /// Which shell this content is wearing.
    ///
    /// The same three setup rows are reached two ways, and the difference is
    /// entirely chrome: onboarding presents them modally because it is a step
    /// the user is in the middle of, while Settings pushes them because they are
    /// a place the user navigated to and can leave by going back. Sharing the
    /// body rather than forking it is what keeps the two from drifting.
    enum Chrome {
        /// Own title bar, own Done button, own window size.
        case sheet
        /// Pushed into the Settings detail column; the navigation stack supplies
        /// the title and the way back.
        case pane
    }

    var chrome: Chrome = .sheet

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
    @State private var showingSignIn = false
    @State private var showingBrewInstructions = false
    /// Mirrors the connector's manual binding for one purpose: deciding whether
    /// to offer "Forget". The record itself lives in the connector's own root,
    /// which this sandboxed process cannot read — so this is a display hint, not
    /// a source of truth about what will actually be executed.
    @AppStorage("loomscreen.workshop.doctor.hasManualBinding.v1", store: .appScoped())
    private var hasManualBinding = false

    var body: some View {
        shell
        .overlay(alignment: .bottom) {
            DiagnosticExportToast(isPresented: $showingToast)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .allowsHitTesting(false)
        }
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
            HomebrewSteamCMDSheet()
        }
        .task {
            await service.autoConfigureIfNeeded()
            await loadAccounts()
        }
    }

    // MARK: - Shells

    @ViewBuilder
    private var shell: some View {
        switch chrome {
        case .sheet:
            VStack(spacing: 0) {
                navigationBar
                Divider()
                content
                SheetFooterBar(
                    primaryTitle: "Done",
                    primaryAction: { dismiss() },
                    primaryHelp: "Close the Steam connection sheet"
                )
            }
            .frame(
                minWidth: SteamSheetWidth.dense,
                idealWidth: SteamSheetWidth.dense,
                minHeight: 520,
                idealHeight: 580
            )
        case .pane:
            // No size of its own: the detail column decides how wide settings
            // are, the same way every other settings page is sized.
            content
                .navigationTitle(Text("Steam connection", bundle: .main))
        }
    }

    /// The grouped Form is what every other settings surface in the app uses;
    /// this was the one hand-rolled VStack, which is why it never quite looked
    /// like the rest of the app.
    private var content: some View {
        Form {
            Section {
                statusStrip
            }

            Section {
                stepList
            } header: {
                Text("Setup", bundle: .main)
            }

            diagnosticsSection

            Section {
                WorkshopPrivacyLink()
            }
        }
        .settingsFormChrome()
    }

    // MARK: - Sections

    private var navigationBar: some View {
        HStack {
            Text("Steam connection")
                .font(DesignTokens.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.bar)
    }

    /// One sentence, not a "2 of 3" tally: the rows below already show which
    /// step is outstanding, and a fraction only asks the user to do the diff
    /// themselves. HIG has no counter idiom for a three-item checklist.
    private var statusStrip: some View {
        SteamSheetHeader(
            icon: connectionHeaderIcon,
            title: connectionHeaderTitle,
            iconTint: connectionHeaderTint,
            subtitle: connectionHeaderSubtitle
        )
    }

    /// No hand-rolled `Divider()`s: the grouped Form draws its own separators,
    /// and drawing a second set on top is how this sheet used to look denser
    /// than every other settings surface.
    @ViewBuilder
    private var stepList: some View {
        WorkshopSetupRow(
            icon: "folder",
            title: "Steam library",
            detail: service.workdirDisplayPath ?? String(localized: "Not authorized", comment: "Steam library step detail when no folder has been picked."),
            state: isLibraryReady ? .ready : .notStarted,
            info: "Pick Steam's own folder — the one containing config/config.vdf — once. Loomscreen keeps a security-scoped bookmark to it and never creates a second Workshop repository."
        ) {
            libraryControl
        }

        WorkshopSetupRow(
            icon: "terminal",
            title: "SteamCMD",
            detail: binaryDetail,
            state: binaryState,
            info: "Valve's command-line downloader. Loomscreen can install it for you or locate an existing verified Homebrew or tarball install."
        ) {
            binaryControl
        }

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Setup error: \(setupError)"))
        }
    }

    /// Same slot contract as the other two rows: not set up → one prominent
    /// verb; set up → a Menu holding the less common follow-ups.
    @ViewBuilder
    private var libraryControl: some View {
        if isLibraryReady {
            Menu {
                Button("Change…") { pickSteamLibrary() }
            } label: {
                Text("Change", bundle: .main)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            Button("Choose…") { pickSteamLibrary() }
                .adaptiveGlassButton(.prominent, size: .small)
        }
    }

    /// Three states, because the right action differs completely between them.
    /// Most Macs have no SteamCMD, so for them the managed install is the whole
    /// point of this row and belongs in a primary button, not behind a menu
    /// labelled "Set up".
    @ViewBuilder
    private var binaryControl: some View {
        if isBinaryBusy {
            ProgressView().controlSize(.small)
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
        Button("Choose SteamCMD…") { pickBinaryManually() }
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
                .adaptiveGlassButton(.prominent, size: .small)
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
                Divider()
                Button("Sign in to another account…") { showingSignIn = true }
                Button("Rescan") { Task { await loadAccounts() } }
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

    /// Collapsed by default and summarised in its own header, so the sheet
    /// costs one line when everything is fine. The batch actions live in the
    /// header rather than a footer strip — they act on this section, and Apple
    /// puts section-scoped commands next to the section title.
    @ViewBuilder
    private var diagnosticsSection: some View {
        Section(isExpanded: $showsAdvancedDiagnostics) {
            ForEach(DoctorProbeKind.allCases) { kind in
                WorkshopProbeRow(
                    report: service.probes[kind]
                        ?? DoctorProbeReport(id: kind, status: .notRun, lastRun: .distantPast),
                    service: service,
                    onCopied: { showingToast = true }
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
                .adaptiveGlassButton(.regular, size: .small)
                .disabled(service.state == .probing)

                Button(action: exportDiagnostics) {
                    Text("Export…", bundle: .main)
                }
                .buttonStyle(.link)
                .help(Text("Copy all probe reports as redacted JSON to clipboard"))

                Spacer(minLength: 0)
            }
        } header: {
            // The disclosure control is ours, not the system's: a collapsible
            // `Section` is documented from macOS 14, but whether a *grouped
            // Form* draws its own chevron and makes the header clickable is
            // not something this code can verify. An explicit button works
            // either way.
            Button {
                withAnimation { showsAdvancedDiagnostics.toggle() }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsAdvancedDiagnostics ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Diagnostics", bundle: .main)
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    if !showsAdvancedDiagnostics, let summary = diagnosticsSummary {
                        Text(summary)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.Status.warning)
                    }
                }
                .contentShape(Rectangle())
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

    // MARK: - Connection status

    private var isLibraryReady: Bool {
        guard service.workdirBookmarkData != nil else { return false }
        if case .red? = service.probes[.workingDirectory]?.status { return false }
        return true
    }

    private var isBinaryReady: Bool {
        service.hasBoundBinary && service.isGreen(.binaryIdentity)
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
        if isBinaryBusy { return .working }
        guard service.hasBoundBinary else { return .notStarted }
        switch service.probes[.binaryIdentity]?.status {
        case .green: return .ready
        case .red: return .attention
        default: return .working
        }
    }

    private var connectionHeaderTitle: LocalizedStringKey {
        isLibraryReady ? "Official Steam library connected" : "Connect your Steam library"
    }

    /// The sentence that replaced the "N of 3" tally — it names the next
    /// action rather than a fraction the user has to interpret.
    private var connectionHeaderSubtitle: LocalizedStringKey? {
        if !isLibraryReady { return "Choose Steam's folder to get started." }
        if !isBinaryReady { return "Set up SteamCMD to download from the Workshop." }
        if accountState != .ready { return "Sign in so downloads run as your account." }
        return nil
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

// MARK: - Helpers

#endif
