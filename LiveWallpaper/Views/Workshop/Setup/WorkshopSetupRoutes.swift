#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// One way to satisfy a setup step.
/// Every Steam setup step has two: an automatic route and a manual one. Previously spelled
/// differently on every row — two side-by-side buttons, a button plus an `⋯` menu, a bare menu
/// — so the reader had to work out the shape of each row before reading it.
struct WorkshopSetupRoute: Identifiable {
    let id: String
    let title: LocalizedStringKey
    var role: ButtonRole?
    /// Non-nil disables the route and says why on hover. Disabling without a
    /// reason is the failure mode this exists to prevent.
    /// A dimmed control is skipped by the pointer and de-emphasised by VoiceOver, so the tooltip
    /// can't be the only place the reason exists: every caller also renders it as visible text (the row's detail line, or the section's status line).
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

/// The trailing control of a setup row: the common route as a button, the rest beside it — one
/// more button when there is one, an `⋯` menu when there are several.
/// The alternative, a segmented route switcher, costs 48–64pt of height per row and turns the common path into two clicks — the wrong trade inside a settings form.
struct WorkshopSetupRoutes: View {
    let primary: WorkshopSetupRoute?
    /// Named buttons, always drawn with a border. A row of two or three verbs
    /// reads at a glance; the `⋯` they used to collapse into hid "Locate
    /// automatically" and "Set up SteamCMD" behind a glyph that names neither.
    var secondary: [WorkshopSetupRoute] = []
    /// The rare and the destructive — reinstalling, forgetting, removing. These
    /// keep the overflow menu: they are not what the row is for, and a
    /// destructive verb sitting in the same row as the ordinary ones invites
    /// the click it should discourage.
    var overflow: [WorkshopSetupRoute] = []
    /// Suppresses every route and shows a spinner: an install or a probe is
    /// in flight and none of the commands would be accepted.
    var isBusy = false
    /// Draws the primary route as the prominent one. Set while the step is
    /// still outstanding — once it is set up, its remaining routes are edits,
    /// not the thing the page is asking for.
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

/// `help` only when there is something to say. An always-applied `.help(Text(""))`
/// renders an empty tooltip on hover, which reads as a rendering fault.
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
