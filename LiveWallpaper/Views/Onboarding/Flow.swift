import LiveWallpaperCore
import SwiftUI

private enum OnboardingStep: Hashable {
    case welcome
    case workshopSetup
    case pick
    case done
}

enum OnboardingCompletionDestination: Equatable {
    case display(CGDirectDisplayID?)
    case appleAerials
    case steamWorkshop
}

struct Flow: View {
    @AppStorage("Onboarding.Completed") private var hasCompletedOnboarding: Bool = false
    @State private var index = 0
    @State private var completionDestination: OnboardingCompletionDestination = .display(nil)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog

    let onClose: () -> Void
    /// Opens the usable app surface after onboarding completes or is skipped.
    var onFinish: (CGDirectDisplayID?) -> Void = { _ in }
    /// Opens Apple Aerials library; no-op default for previews/tests.
    var onShowAppleAerials: () -> Void = {}
    /// Opens the Workshop library; no-op default for previews/tests.
    var onShowSteamWorkshop: () -> Void = {}

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                progressIndicator
                    .padding(.bottom, DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)
            }

            backButton
        }
        .frame(width: 520, height: 540)
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.4, dampingFraction: 0.85)), value: index)
    }

    private var policy: OnboardingPathPolicy {
        OnboardingPathPolicy(capabilities: featureCatalog.capabilities)
    }

    private var steps: [OnboardingStep] {
        var result: [OnboardingStep] = [.welcome]
        if policy.showsWorkshopSetup { result.append(.workshopSetup) }
        result.append(contentsOf: [.pick, .done])
        return result
    }

    private var currentStep: OnboardingStep { steps[min(index, steps.count - 1)] }

    private var background: some View {
        DesignTokens.Colors.pageBackground
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch currentStep {
            case .welcome:
                StepWelcome(nextStep: nextStep, skip: skip)
            case .workshopSetup:
                #if !LITE_BUILD
                OnboardingWorkshopSetupView(continueAction: nextStep)
                #else
                EmptyView()
                #endif
            case .pick:
                PickerView(
                    galleryActions: policy.galleryActions,
                    didConfigure: didConfigure,
                    skip: skip,
                    chooseAppleAerials: chooseAppleAerials,
                    chooseSteamWorkshop: chooseSteamWorkshop
                )
            case .done:
                StepDone(destination: completionDestination, finish: finish)
            }
        }
        .transition(stepTransition)
        .id(currentStep)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var progressIndicator: some View {
        let total = steps.count
        let stepLabel = Text("Step \(index + 1) of \(total)")
        return HStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(0..<total, id: \.self) { i in
                let isCurrent = i == index
                Capsule()
                    .fill(isCurrent ? DesignTokens.Colors.accent : DesignTokens.Colors.textTertiary.opacity(0.28))
                    .frame(width: isCurrent ? 22 : 8, height: 6)
                    .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.35, dampingFraction: 0.85)), value: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stepLabel)
    }

    /// Every step after the first can go back; the done step included, so a
    /// mis-click on a gallery card is one tap to undo rather than a restart.
    @ViewBuilder
    private var backButton: some View {
        if index > 0 {
            VStack {
                HStack {
                    Button(action: previousStep) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back"))
                    Spacer()
                }
                Spacer()
            }
            .padding(DesignTokens.Spacing.lg)
        }
    }

    private func nextStep() {
        guard index < steps.count - 1 else { return }
        withAnimation { index += 1 }
    }

    private func previousStep() {
        guard index > 0 else { return }
        withAnimation { index -= 1 }
    }

    private func didConfigure(screenID: CGDirectDisplayID?) {
        completionDestination = .display(screenID)
        nextStep()
    }

    private func skip() {
        completeAndClose(opening: nil)
    }

    private func chooseAppleAerials() {
        completionDestination = .appleAerials
        nextStep()
    }

    private func chooseSteamWorkshop() {
        completionDestination = .steamWorkshop
        nextStep()
    }

    private func finish() {
        hasCompletedOnboarding = true
        onClose()
        switch completionDestination {
        case .display(let screenID):
            onFinish(screenID)
        case .appleAerials:
            onShowAppleAerials()
        case .steamWorkshop:
            onShowSteamWorkshop()
        }
    }

    private func completeAndClose(opening screenID: CGDirectDisplayID?) {
        hasCompletedOnboarding = true
        onClose()
        onFinish(screenID)
    }
}

#if !LITE_BUILD
/// Direct-Pro first-run setup keeps Workshop configuration inside onboarding
/// instead of sending the user into Settings as soon as they choose an option.
private struct OnboardingWorkshopSetupView: View {
    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor

    let continueAction: () -> Void

    @State private var installer = SteamCMDManagedInstallCoordinator()
    @State private var showingKeyEntry = false
    @State private var showingConnection = false
    @State private var showingInstallConsent = false
    @State private var setupError: String?
    @State private var isVerifyingInstall = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            // Centred here, not the sheets' leading-aligned SteamSheetHeader:
            // this is a full onboarding page whose siblings all centre their
            // titles, and matching the page it lives on beats matching the
            // sheets it links to.
            VStack(spacing: DesignTokens.Spacing.xs) {
                Text("Set Up Steam Workshop")
                    .font(DesignTokens.Typography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Optional. You can finish this later in Settings.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                WorkshopSetupRow(
                    icon: "key",
                    title: "Steam Web API key",
                    detail: services.hasWebAPIKey
                        ? String(localized: "Ready", comment: "Workshop setup status when a Steam Web API key exists.")
                        : String(localized: "Your own free key — required to browse the Workshop online", comment: "Workshop settings subtitle for Steam Web API key."),
                    state: services.hasWebAPIKey ? .ready : .notStarted,
                    info: "The key belongs to your own Steam account, not Loomscreen. Calls go directly to Valve over HTTPS, and the key is stored only on this Mac (no iCloud sync). Get one free at steamcommunity.com/dev/apikey."
                ) {
                    Button(services.hasWebAPIKey ? "Replace" : "Set key") {
                        showingKeyEntry = true
                    }
                    .adaptiveGlassButton(services.hasWebAPIKey ? .regular : .prominent, size: .small)
                }

                Divider()

                WorkshopSetupRow(
                    icon: "terminal",
                    title: "SteamCMD",
                    detail: steamCMDDetail,
                    state: steamCMDState,
                    info: "Valve's command-line downloader. Loomscreen can install it for you or locate an existing verified Homebrew or tarball install."
                ) {
                    steamCMDControl
                }

                Divider()

                WorkshopSetupRow(
                    icon: "externaldrive",
                    title: "Steam connection",
                    detail: doctor.workdirDisplayPath
                        ?? String(localized: "Not authorized", comment: "Steam library step detail when no folder has been picked."),
                    state: doctor.isDownloadReady ? .ready : .notStarted,
                    info: "Loomscreen reads installed Workshop items directly from the official Steam library after one folder authorization. Authenticated SteamCMD downloads are a separate capability and require Loomscreen's background Steam connector."
                ) {
                    Button("Configure") { showingConnection = true }
                        .adaptiveGlassButton(.regular, size: .small)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            )

            if let setupError {
                Label(setupError, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            VStack(spacing: DesignTokens.Spacing.sm) {
                Button(action: continueAction) {
                    Text("Continue")
                        .frame(minWidth: 140)
                }
                .buttonStyle(CapsuleButtonStyle(preset: .large))
                .keyboardShortcut(.defaultAction)

                // Same action as Continue — it exists to say out loud that
                // nothing on this page is required.
                Button(action: continueAction) {
                    Text("Skip for Now", comment: "Secondary onboarding action that defers wallpaper setup.")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.lg)
        .sheet(isPresented: $showingKeyEntry) {
            SteamWebAPIKeyEntrySheet(services: services) {
                Task { await services.refreshAPIKeyStatus() }
            }
        }
        .sheet(isPresented: $showingConnection) {
            WorkshopDoctorView()
                .environment(doctor)
        }
        .sheet(isPresented: $showingInstallConsent) {
            SteamCMDManagedInstallSheet(onConfirm: runManagedInstall)
        }
        .task {
            await services.refreshAPIKeyStatus()
            await doctor.autoConfigureIfNeeded()
        }
    }

    @ViewBuilder
    private var steamCMDControl: some View {
        if isSteamCMDBusy {
            ProgressView().controlSize(.small)
        } else if isSteamCMDReady {
            Button("Configure") { showingConnection = true }
                .adaptiveGlassButton(.regular, size: .small)
        } else {
            Button("Install SteamCMD…") { showingInstallConsent = true }
                .adaptiveGlassButton(.prominent, size: .small)
        }
    }

    private var isSteamCMDReady: Bool {
        doctor.hasBoundBinary && doctor.isGreen(.binaryIdentity)
    }

    private var isSteamCMDBusy: Bool {
        if isVerifyingInstall { return true }
        switch installer.status {
        case .installing, .removing: return true
        case .idle, .installed, .failed: return false
        }
    }

    private var steamCMDState: WorkshopStepState {
        if isSteamCMDBusy { return .working }
        if isSteamCMDReady { return .ready }
        if case .failed = installer.status { return .attention }
        return .notStarted
    }

    private var steamCMDDetail: String {
        switch installer.status {
        case .installing:
            return String(localized: "Setting up SteamCMD…", comment: "SteamCMD step detail while the connector unpacks and verifies the install.")
        case .removing:
            return String(localized: "Removing SteamCMD…", comment: "SteamCMD step detail while the connector deletes the managed install.")
        case .idle, .installed, .failed:
            if isVerifyingInstall {
                return String(localized: "Checking that SteamCMD runs…", comment: "SteamCMD step detail while the connector launches the freshly installed binary to confirm it works.")
            }
            return doctor.binaryDisplayPath
                ?? String(localized: "Not selected", comment: "SteamCMD step detail when no binary is bound.")
        }
    }

    private func runManagedInstall() {
        setupError = nil
        Task {
            switch await installer.install() {
            case .installed:
                isVerifyingInstall = true
                let bound = await doctor.autoDetectBinary()
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
                break
            }
        }
    }
}
#endif
