import Foundation
import LiveWallpaperCore

/// How much of the top bar's trailing cluster fits beside the centred `NavPill`. The pill is
/// centred in the window and sized by its own titles, so the cluster gets whatever is left of the
/// half it sits in; the search field shrinks first, and the onboarding capsule goes after it.
enum TopBarBudget {
    struct Layout: Equatable {
        /// What `LibrarySearchField` gets; 0 on the pages that carry no search field.
        let searchWidth: CGFloat
        /// Leading edge of the trailing cluster, in window points.
        let clusterX: CGFloat
        /// False once the cluster had to drop the onboarding capsule to clear the pill.
        let showsCapsule: Bool
        /// How far the cluster still reaches past the pill's trailing edge once every move is
        /// spent. 0 when it clears.
        let overflow: CGFloat
    }

    /// SCREENS S1's search field at rest.
    static let idealSearchWidth: CGFloat = 220

    private static var gutter: CGFloat {
        DesignTokens.Spacing.lg
    }

    private static var gap: CGFloat {
        DesignTokens.EditDesk.Spacing.s12
    }

    private static var searchFloor: CGFloat {
        DesignTokens.LibraryFilterBar.searchMinWidth
    }

    private static func clusterWidth(_ items: [CGFloat?]) -> CGFloat {
        let present = items.compactMap(\.self)
        return present.reduce(0, +) + CGFloat(max(0, present.count - 1)) * gap
    }

    /// The cluster once the search field has spent whatever `room` leaves it.
    private static func spend(
        room: CGFloat, showsSearch: Bool, capsule: CGFloat?, status: CGFloat?
    ) -> (search: CGFloat?, width: CGFloat) {
        let fixed = clusterWidth([capsule, status])
        let search: CGFloat? = if showsSearch {
            max(searchFloor, min(idealSearchWidth, room - fixed - (fixed > 0 ? gap : 0)))
        } else {
            nil
        }
        return (search, clusterWidth([search, capsule, status]))
    }

    /// `capsuleWidth` is what the onboarding capsule *asks for*, never a measured frame: this may
    /// drop it, and a measured width would then read 0 and hand it straight back.
    static func layout(
        windowWidth: CGFloat, pillWidth: CGFloat, showsSearch: Bool,
        capsuleWidth: CGFloat, statusWidth: CGFloat
    ) -> Layout {
        let room = windowWidth / 2 - pillWidth / 2 - gutter
        let capsule: CGFloat? = capsuleWidth > 0 ? capsuleWidth : nil
        let status: CGFloat? = statusWidth > 0 ? statusWidth : nil
        var spent = spend(room: room, showsSearch: showsSearch, capsule: capsule, status: status)
        var showsCapsule = capsule != nil
        // Last move: the capsule is a first-launch hint whose progress the onboarding card already
        // spells out, so it goes whole rather than push the permanent nav pill off centre.
        if spent.width > room, showsCapsule {
            spent = spend(room: room, showsSearch: showsSearch, capsule: nil, status: status)
            showsCapsule = false
        }
        return Layout(
            searchWidth: spent.search ?? 0,
            clusterX: windowWidth - gutter - spent.width,
            showsCapsule: showsCapsule,
            overflow: max(0, spent.width - room)
        )
    }
}
