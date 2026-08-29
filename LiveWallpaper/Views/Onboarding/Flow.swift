import LiveWallpaperCore
import SwiftUI

/// The picker is the last step on purpose: it *is* the finish line. A separate
/// "You're All Set" page claimed a wallpaper was on screen even when the reader
/// had chosen Workshop or Aerials, which configure nothing — the browsing they
/// asked for happens in the app. Each card now closes onboarding straight into
/// the place it names.
private enum OnboardingStep: Hashable {
    case welcome
    case workshopSetup
    case pick
}

enum OnboardingCompletionDestination: Equatable {
    case display(CGDirectDisplayID?)
    case appleAerials
    case steamWorkshop
}

struct Flow: View {
    @AppStorage("Onboarding.Completed") private var hasCompletedOnboarding: Bool = false
    @State private var index = 0
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
        result.append(.pick)
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

    /// Every step after the first can go back. A gallery card finishes
    /// onboarding, so back exists for the steps that precede it.
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
        finish(.display(screenID))
    }

    private func skip() {
        completeAndClose(opening: nil)
    }

    private func chooseAppleAerials() {
        finish(.appleAerials)
    }

    private func chooseSteamWorkshop() {
        finish(.steamWorkshop)
    }

    private func finish(_ destination: OnboardingCompletionDestination) {
        hasCompletedOnboarding = true
        onClose()
        switch destination {
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
