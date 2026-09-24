import AppKit
import LiveWallpaperCore
import SwiftUI

enum OnboardingCapsuleModel {
    static func dots(visible: [OnboardingProgress.Page], handled: Set<OnboardingProgress.Page>) -> [Bool] {
        visible.map(handled.contains)
    }
}

/// The library page carries the search field too, so below the design width its trailing cluster
/// has no room for this capsule's label and it spends its dots only. Pages without a search field
/// keep the label at any width. `TopBarBudget` may still drop the whole capsule from either.
enum OnboardingCapsuleFit {
    static let labelMinimumWidth = StageGeometry.designWindow.width
    static let horizontalPadding: CGFloat = 10
    static let dotSize: CGFloat = 5

    static func showsLabel(windowWidth: CGFloat, showsSearch: Bool) -> Bool {
        guard showsSearch else { return true }
        return windowWidth >= labelMinimumWidth
    }

    /// What the capsule asks `TopBarBudget` for, and 0 once onboarding has nothing left to show.
    /// Derived rather than measured: the budget may drop the capsule, and a measured frame would
    /// then report 0 and put it straight back.
    @MainActor
    static func width(progress: OnboardingProgress?, windowWidth: CGFloat, showsSearch: Bool) -> CGFloat {
        guard let progress, !progress.isFinished else { return 0 }
        let label = showsLabel(windowWidth: windowWidth, showsSearch: showsSearch)
            ? String(localized: "Get Started", bundle: .appLanguage)
            : nil
        return width(pages: progress.visiblePages.count, label: label)
    }

    /// The capsule's own box: `horizontalPadding` each side, the mono label plus its 8pt gap when
    /// it is shown, then one dot per visible page with 4pt between them.
    static func width(pages: Int, label: String?) -> CGFloat {
        let dots = CGFloat(pages) * dotSize + CGFloat(pages - 1) * DesignTokens.Spacing.xs
        guard let label else { return 2 * horizontalPadding + dots }
        // Mirrors `Typography.badgeMono`: 11pt monospaced.
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        return 2 * horizontalPadding + text + DesignTokens.EditDesk.Spacing.s8 + dots
    }
}

/// SCREENS S9's "Get Started ● ● ○ ○" pill. Lives in `TopBar`'s trailing cluster and vanishes for
/// good once every visible page is completed or skipped.
struct OnboardingCapsule: View {
    let windowWidth: CGFloat
    let showsSearch: Bool

    @Environment(OnboardingProgress.self) private var progress: OnboardingProgress?
    @Environment(EditDeskRouter.self) private var router: EditDeskRouter?
    @State private var isHovering = false
    @State private var menuPresented = false

    private static let height: CGFloat = 22

    var body: some View {
        if let progress, !progress.isFinished {
            let dots = OnboardingCapsuleModel.dots(visible: progress.visiblePages, handled: progress.handled)
            Button { menuPresented.toggle() } label: { capsule(dots) }
                .buttonStyle(OnboardingPressStyle())
                .onHover { isHovering = $0 }
                .help(Text("Welcome Tour"))
                .accessibilityLabel(Text("Get Started"))
                .accessibilityValue(Text("Step \(dots.filter(\.self).count) of \(dots.count)"))
                .appLanguagePopover(isPresented: $menuPresented, arrowEdge: .bottom) { menu(progress) }
        }
    }

    private func capsule(_ dots: [Bool]) -> some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            if OnboardingCapsuleFit.showsLabel(windowWidth: windowWidth, showsSearch: showsSearch) {
                Text("Get Started")
                    .font(DesignTokens.EditDesk.Typography.badgeMono)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(dots.enumerated()), id: \.offset) { _, isHandled in
                    Circle()
                        .fill(
                            isHandled
                                ? DesignTokens.EditDesk.Colors.textPrimary
                                : DesignTokens.EditDesk.Colors.fillSelectedChip
                        )
                        .frame(width: OnboardingCapsuleFit.dotSize, height: OnboardingCapsuleFit.dotSize)
                }
            }
        }
        .padding(.horizontal, OnboardingCapsuleFit.horizontalPadding)
        .frame(height: Self.height)
        .background(Capsule().fill(DesignTokens.EditDesk.Colors.panel))
        .overlay(Capsule().strokeBorder(
            isHovering ? DesignTokens.EditDesk.Colors.strokeRegular : DesignTokens.EditDesk.Colors.strokePanel,
            lineWidth: 1
        ))
        .accessibilityElement(children: .ignore)
    }

    private func menu(_ progress: OnboardingProgress) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if let step = progress.currentPage {
                Button {
                    menuPresented = false
                    router?.showOnboardingStep(step, displayID: CGMainDisplayID())
                } label: {
                    Text(
                        "Next Step: \(Text(Self.pageTitle(step)))",
                        comment: "Get Started capsule menu item that opens the page of the next welcome tour step. Placeholder is that page's name."
                    )
                }
            }
            Divider()
            Button {
                menuPresented = false
                progress.dismissRemaining()
            } label: {
                Text(
                    "Skip Welcome Tour",
                    comment: "Get Started capsule menu item that marks every remaining welcome tour step as skipped."
                )
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPopoverChrome(width: 240)
    }

    private static func pageTitle(_ page: OnboardingProgress.Page) -> LocalizedStringKey {
        switch page {
        case .home: "Overview"
        case .library: "Wallpaper Library"
        case .workshop: "Workshop"
        case .overlay: "Overlays"
        }
    }
}
