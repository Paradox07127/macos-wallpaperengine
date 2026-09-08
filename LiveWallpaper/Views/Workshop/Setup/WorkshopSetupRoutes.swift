#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// An available action for a Workshop setup step.
struct WorkshopSetupRoute: Identifiable {
    let id: String
    let title: LocalizedStringKey
    var role: ButtonRole?
    /// Disables the action; callers must also show the reason outside the tooltip.
    var unavailableReason: String?
    let action: () -> Void

    init(
        id: String,
        title: LocalizedStringKey,
        role: ButtonRole? = nil,
        unavailableReason: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.unavailableReason = unavailableReason
        self.action = action
    }
}

/// Named setup actions with an overflow menu for secondary maintenance actions.
struct WorkshopSetupRoutes: View {
    let primary: WorkshopSetupRoute?
    /// Common alternatives stay visible as named buttons.
    var secondary: [WorkshopSetupRoute] = []
    /// Infrequent or destructive maintenance actions.
    var overflow: [WorkshopSetupRoute] = []
    /// Suppresses every route and shows a spinner: an install or a probe is
    /// in flight and none of the commands would be accepted.
    var isBusy = false
    /// Emphasize the primary action only while the setup step is incomplete.
    var emphasizesPrimary = false

    var body: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Working"))
        } else {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let primary {
                    routeButton(primary, prominent: emphasizesPrimary)
                }
                ForEach(secondary) { route in
                    routeButton(route, prominent: false)
                }
                if !overflow.isEmpty {
                    Menu {
                        ForEach(overflow) { route in
                            Button(role: route.role) {
                                route.action()
                            } label: {
                                Text(route.title)
                            }
                            .disabled(route.unavailableReason != nil)
                            .modifier(RouteReasonTooltip(reason: route.unavailableReason))
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(Text("Other options"))
                }
            }
        }
    }

    @ViewBuilder
    private func routeButton(_ route: WorkshopSetupRoute, prominent: Bool) -> some View {
        let button = Button(role: route.role) {
            route.action()
        } label: {
            Text(route.title)
        }
        .disabled(route.unavailableReason != nil)
        .fixedSize()

        Group {
            if prominent {
                button.buttonStyle(.borderedProminent)
            } else {
                button
            }
        }
        .modifier(RouteReasonTooltip(reason: route.unavailableReason))
    }
}

/// Omits the modifier when no reason exists to avoid empty tooltips.
private struct RouteReasonTooltip: ViewModifier {
    let reason: String?

    func body(content: Content) -> some View {
        if let reason {
            content
                .help(Text(verbatim: reason))
                .accessibilityHint(Text(verbatim: reason))
        } else {
            content
        }
    }
}
#endif
