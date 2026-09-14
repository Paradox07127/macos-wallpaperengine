#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct WorkshopSetupRoute: Identifiable {
    let id: String
    let title: LocalizedStringKey
    var role: ButtonRole?
    /// Callers must also show the reason outside the tooltip.
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

struct WorkshopSetupRoutes: View {
    let primary: WorkshopSetupRoute?
    var secondary: [WorkshopSetupRoute] = []
    var overflow: [WorkshopSetupRoute] = []
    var isBusy = false
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
