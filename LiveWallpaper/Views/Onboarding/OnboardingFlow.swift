import LiveWallpaperCore
import SwiftUI

private enum OnboardingStep: Hashable {
    case welcome
    case pick
    case done
}

struct OnboardingFlow: View {
    @AppStorage("Onboarding.Completed") private var hasCompletedOnboarding: Bool = false
    @State private var index = 0
    @State private var configuredScreenID: CGDirectDisplayID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog

    let onClose: () -> Void
    /// Opens the usable app surface after onboarding completes or is skipped.
    var onFinish: (CGDirectDisplayID?) -> Void = { _ in }
    /// Opens Apple Aerials library; no-op default for previews/tests.
    var onShowAppleAerials: () -> Void = {}

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                progressIndicator
                    .padding(.bottom, DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)
            }
        }
        .frame(width: 520, height: 540)
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.4, dampingFraction: 0.85)), value: index)
    }

    private var policy: OnboardingPathPolicy {
        OnboardingPathPolicy(capabilities: featureCatalog.capabilities)
    }

    private var steps: [OnboardingStep] {
        [.welcome, .pick, .done]
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
                OnboardingStepWelcome(nextStep: nextStep, skip: skip)
            case .pick:
                OnboardingPickerView(
                    galleryActions: policy.galleryActions,
                    didConfigure: didConfigure,
                    skip: skip,
                    openAppleAerials: showAppleAerials
                )
            case .done:
                OnboardingStepDone(screenID: configuredScreenID, finish: finish)
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

    private func nextStep() {
        guard index < steps.count - 1 else { return }
        withAnimation { index += 1 }
    }

    private func didConfigure(screenID: CGDirectDisplayID?) {
        configuredScreenID = screenID
        nextStep()
    }

    private func skip() {
        completeAndClose(opening: nil)
    }

    private func showAppleAerials() {
        hasCompletedOnboarding = true
        onShowAppleAerials()
        onClose()
    }

    private func finish(screenID: CGDirectDisplayID?) {
        completeAndClose(opening: screenID)
    }

    private func completeAndClose(opening screenID: CGDirectDisplayID?) {
        hasCompletedOnboarding = true
        onClose()
        onFinish(screenID)
    }
}
