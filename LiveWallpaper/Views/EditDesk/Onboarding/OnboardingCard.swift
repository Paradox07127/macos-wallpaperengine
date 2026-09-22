import LiveWallpaperCore
import SwiftUI

/// SCREENS S9 measurements. `stageTopInset` is the only one the stage reads.
enum OnboardingCardMetrics {
    static let gutter = DesignTokens.EditDesk.Spacing.gutter
    static let headerTop: CGFloat = 56
    static let cardTop: CGFloat = 110
    static let cardHeight: CGFloat = 170
    /// S9 drew this at 460 for a 13pt message; `stageTitle` is 15pt now, so the box carries the
    /// same ratio forward — under it en/ja/es workshop and es library spill past `lineLimit(2)`.
    static let messageMaxWidth: CGFloat = 540
    static let primaryButtonHeight: CGFloat = 30
    static let footnoteHeight: CGFloat = 16
    /// Height the card claims where it cannot fill the page — inside the library's scroll view.
    static let blockHeight = cardTop + cardHeight + gutter + footnoteHeight
    /// R-27: while the overview card is up the display arrangement gets the stage below it.
    static let stageTopInset = cardTop + cardHeight + gutter
    /// MOTION 16.
    static let enterDuration: TimeInterval = 0.3
    static let enterOffset: CGFloat = 12
}

enum OnboardingCardAction: Hashable {
    case chooseFile
    case tryAerials
    case importMore
    case connectSteam
    case importLocalLibrary
    case addClock
}

struct OnboardingCardContent {
    struct Choice {
        let title: LocalizedStringKey
        let action: OnboardingCardAction
        let isPrimary: Bool
    }

    let icon: String
    let timing: LocalizedStringKey
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let buttons: [Choice]
    let footnote: LocalizedStringKey

    static func stepText(step: Int, total: Int) -> String {
        "STEP \(step) / \(total)"
    }

    static func of(_ page: OnboardingProgress.Page) -> OnboardingCardContent {
        switch page {
        case .home:
            OnboardingCardContent(
                icon: "arrow.down",
                timing: "First launch",
                title: "Overview · Give your first display a wallpaper",
                message: "Drag a video, a web folder or a Wallpaper Engine project onto a display — or start right away with Apple Aerials",
                buttons: [
                    Choice(title: "Choose File…", action: .chooseFile, isPrimary: true),
                    Choice(title: "Try Apple Aerials", action: .tryAerials, isPrimary: false),
                ],
                footnote: "Types are detected automatically — no need to choose. You can swap a display's wallpaper any time."
            )
        case .library:
            OnboardingCardContent(
                icon: "square.grid.3x3",
                timing: "First time in the wallpaper library",
                title: "Wallpaper Library · Everything you have used is kept here",
                message: "Files you import and Workshop items you download all show up here; drag one onto a display to apply it",
                buttons: [Choice(title: "Import More", action: .importMore, isPrimary: true)],
                footnote: "Sorted by most recently used; source and type are only filters."
            )
        case .workshop:
            OnboardingCardContent(
                icon: "cube.transparent",
                timing: "First time in Workshop",
                title: "Workshop · Connect your Steam account",
                message: "Download Workshop wallpapers with your own Steam account and Wallpaper Engine licence; nothing goes through a third-party server",
                buttons: [
                    Choice(title: "Connect Steam", action: .connectSteam, isPrimary: true),
                    Choice(title: "Import a local WE library", action: .importLocalLibrary, isPrimary: false),
                ],
                footnote: "Needs SteamCMD (installed and managed for you). You can disconnect later in Settings."
            )
        case .overlay:
            OnboardingCardContent(
                icon: "sparkles",
                timing: "First time in overlays",
                title: "Overlays · Put something on your wallpaper",
                message: "Clock, weather, system stats, music, Agent sessions — press + to add one, then drag it into place",
                buttons: [Choice(title: "Try adding a clock", action: .addClock, isPrimary: true)],
                footnote: "When every step is done the Get Started capsule disappears; you can replay it from Settings."
            )
        }
    }
}

/// SCREENS S9: the dashed card each page shows until its step is completed or skipped. The host
/// decides *where* it hangs and what its buttons do; completion is recorded by `OnboardingSignals`.
struct OnboardingCard: View {
    let page: OnboardingProgress.Page
    /// Space the detail page's inspector column takes off the trailing edge; 0 on full-width pages.
    var trailingInset: CGFloat = 0
    let perform: (OnboardingCardAction) -> Void

    @Environment(OnboardingProgress.self) private var progress: OnboardingProgress?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var content: OnboardingCardContent {
        OnboardingCardContent.of(page)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let progress, !progress.handled.contains(page) {
                card(progress)
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(animation, value: progress?.handled)
    }

    private var animation: Animation {
        reduceMotion
            ? .linear(duration: 0.15)
            : .easeOut(duration: OnboardingCardMetrics.enterDuration)
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: OnboardingCardMetrics.enterOffset)),
            removal: .opacity.combined(with: .offset(y: -OnboardingCardMetrics.enterOffset))
        )
    }

    private func card(_ progress: OnboardingProgress) -> some View {
        ZStack(alignment: .topLeading) {
            header(progress)
                .padding(.top, OnboardingCardMetrics.headerTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            dashedBox
                .frame(height: OnboardingCardMetrics.cardHeight)
                .padding(.top, OnboardingCardMetrics.cardTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer(progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.leading, OnboardingCardMetrics.gutter)
        .padding(.trailing, OnboardingCardMetrics.gutter + trailingInset)
    }

    private func header(_ progress: OnboardingProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
                Text(verbatim: OnboardingCardContent.stepText(
                    step: progress.stepNumber(of: page), total: progress.visiblePages.count
                ))
                Text(verbatim: "·")
                Text(content.timing)
            }
            .font(DesignTokens.EditDesk.Typography.badgeMono)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
            Text(content.title)
                .font(DesignTokens.EditDesk.Typography.onboardingTitle)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var dashedBox: some View {
        VStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            Image(systemName: content.icon)
                .font(DesignTokens.EditDesk.Typography.onboardingIcon)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                .accessibilityHidden(true)
            Text(content.message)
                .font(DesignTokens.EditDesk.Typography.stageTitle)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: OnboardingCardMetrics.messageMaxWidth)
            HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
                ForEach(content.buttons, id: \.action) { choice in
                    OnboardingCardButton(title: choice.title, isPrimary: choice.isPrimary) {
                        perform(choice.action)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(boxShape.fill(DesignTokens.EditDesk.Colors.fillShell))
        .overlay(
            boxShape.strokeBorder(
                DesignTokens.EditDesk.Colors.strokeDashedCard,
                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
        )
    }

    private var boxShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panel, style: .continuous)
    }

    private func footer(_ progress: OnboardingProgress) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.EditDesk.Spacing.s12) {
            Text(content.footnote)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            OnboardingSkipButton { progress.dismiss(page) }
        }
        .font(DesignTokens.EditDesk.Typography.footnote)
    }
}

private struct OnboardingCardButton: View {
    let title: LocalizedStringKey
    let isPrimary: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.EditDesk.Typography.onboardingButton)
                .foregroundStyle(
                    isPrimary
                        ? DesignTokens.EditDesk.Colors.primaryButtonText
                        : DesignTokens.EditDesk.Colors.textPrimary
                )
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.EditDesk.Spacing.s14)
                .frame(height: OnboardingCardMetrics.primaryButtonHeight)
                .background(
                    shape.fill(
                        isPrimary
                            ? DesignTokens.EditDesk.Colors.primaryButtonFill
                            : DesignTokens.EditDesk.Colors.fillSecondaryButton
                    )
                )
                .overlay(
                    shape.strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1)
                        .opacity(isHovering ? 1 : 0)
                )
                .contentShape(shape)
        }
        .buttonStyle(OnboardingPressStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(title))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.button, style: .continuous)
    }
}

/// Reachable by keyboard like any other `Button`; the hover state is the only affordance it adds.
private struct OnboardingSkipButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("Skip")
                .foregroundStyle(DesignTokens.EditDesk.Colors.textCapsule)
                .underline(isHovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(OnboardingPressStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text("Skip this step"))
    }
}

private struct OnboardingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? DesignTokens.Opacity.dimmedIcon : 1)
    }
}
