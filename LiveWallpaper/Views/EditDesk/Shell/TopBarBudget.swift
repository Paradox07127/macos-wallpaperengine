import Foundation
import LiveWallpaperCore

/// How much of the top bar's trailing cluster fits beside the centred `NavPill`. The pill is
/// centred in the window and sized by its own titles, so the cluster gets whatever is left of the
/// half it sits in; the onboarding capsule is what goes when that is not enough.
enum TopBarBudget {
    struct Layout: Equatable {
        /// Leading edge of the trailing cluster, in window points.
        let clusterX: CGFloat
        /// False once the cluster had to drop the onboarding capsule to clear the pill.
        let showsCapsule: Bool
        /// How far the cluster still reaches past the pill's trailing edge once the capsule is
        /// spent. 0 when it clears.
        let overflow: CGFloat
    }

    private static var gutter: CGFloat {
        DesignTokens.Spacing.lg
    }

    private static var gap: CGFloat {
        DesignTokens.EditDesk.Spacing.s12
    }

    private static func clusterWidth(_ items: [CGFloat?]) -> CGFloat {
        let present = items.compactMap(\.self)
        return present.reduce(0, +) + CGFloat(max(0, present.count - 1)) * gap
    }

    /// `capsuleWidth` is what the onboarding capsule *asks for*, never a measured frame: this may
    /// drop it, and a measured width would then read 0 and hand it straight back.
    static func layout(
        windowWidth: CGFloat, pillWidth: CGFloat,
        capsuleWidth: CGFloat, statusWidth: CGFloat
    ) -> Layout {
        let room = windowWidth / 2 - pillWidth / 2 - gutter
        let capsule: CGFloat? = capsuleWidth > 0 ? capsuleWidth : nil
        let status: CGFloat? = statusWidth > 0 ? statusWidth : nil
        var width = clusterWidth([capsule, status])
        var showsCapsule = capsule != nil
        // The capsule is a first-launch hint whose progress the onboarding card already spells out,
        // so it goes whole rather than push the permanent nav pill off centre.
        if width > room, showsCapsule {
            width = clusterWidth([status])
            showsCapsule = false
        }
        return Layout(
            clusterX: windowWidth - gutter - width,
            showsCapsule: showsCapsule,
            overflow: max(0, width - room)
        )
    }
}
