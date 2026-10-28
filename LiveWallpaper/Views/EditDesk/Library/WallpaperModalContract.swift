import CoreGraphics
import Foundation
import LiveWallpaperCore
import SwiftUI

// Seam between the modal shell (`WallpaperModal`), the float layer (`DisplayFloatLayer`) and the
// wiring (`ModalActions`). Values only: the wiring fills them, the views consume them. Owned by the
// integration; neither side adds members without going through it.

/// One library item as the modal shows it. Strings arrive localized; missing parts are omitted.
struct WallpaperModalContent: Equatable {
    let itemID: String
    var title: String
    var kind: LibraryItem.Kind
    /// Rows under the preview, sorted by `WallpaperFact.Kind`; a row with nothing to say is absent.
    var facts: [WallpaperFact] = []
    /// The chips under the rows; Workshop projects only.
    var tags: [WallpaperTagChip] = []
    /// Where a file or page without a Workshop page lives; empty for Workshop items.
    var fileFacts: [WallpaperFact] = []
    /// The whole picture, never upscaled, so its pixels cap how far the modal enlarges it; nil shows the placeholder.
    var preview: CGImage?
    /// Present only for installed Workshop items.
    var installed: InstalledItemExtras?
    /// nil hides the description section; empty shows its placeholder.
    var descriptionText: String?
    var workshopID: UInt64?
    var dependencyIDs: [String] = []
    /// False for a type this Mac cannot run: every apply control is disabled.
    var canApply = true
    /// Why the item may not play here, already localized; nil when nothing is known to be wrong.
    var notice: String?
    /// A Workshop project this Mac can't run; the right column explains why. nil for everything else.
    var unsupportedOrigin: WPEOrigin?
    /// Steam answered that the item's page is gone or hidden.
    var isUnavailableOnSteam = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemID == rhs.itemID
            && lhs.title == rhs.title
            && lhs.kind == rhs.kind
            && lhs.facts == rhs.facts
            && lhs.tags == rhs.tags
            && lhs.fileFacts == rhs.fileFacts
            && lhs.preview === rhs.preview
            && lhs.installed == rhs.installed
            && lhs.descriptionText == rhs.descriptionText
            && lhs.workshopID == rhs.workshopID
            && lhs.dependencyIDs == rhs.dependencyIDs
            && lhs.canApply == rhs.canApply
            && lhs.notice == rhs.notice
            && lhs.unsupportedOrigin == rhs.unsupportedOrigin
            && lhs.isUnavailableOnSteam == rhs.isUnavailableOnSteam
    }
}

/// One labelled row of the detail modal's facts, the same list for library and Workshop items.
struct WallpaperFact: Equatable, Identifiable {
    /// Declaration order is the order the rows are drawn in, whichever source supplied them.
    enum Kind: Int, CaseIterable, Comparable {
        case type, author, rating, size, resolution, duration, ageRating, stats, posted, capturedFrom, saved, updated, source, imported
        case lastUsed, location, webAddress

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .type: String(localized: "Type", bundle: .appLanguage, comment: "Workshop tag group: Scene / Video / Web.")
            case .author: String(localized: "Author", bundle: .appLanguage, comment: "Wallpaper detail row: the Workshop item's creator.")
            case .rating: String(localized: "Rating", bundle: .appLanguage, comment: "Thumbnail badge switch: the Workshop star rating.")
            case .size: String(localized: "Size", bundle: .appLanguage, comment: "Storage table column header.")
            case .resolution: String(localized: "Resolution", bundle: .appLanguage, comment: "Workshop tag group.")
            case .duration: String(localized: "Duration", bundle: .appLanguage, comment: "Wallpaper detail row: a video's running time.")
            case .ageRating: String(localized: "Age Rating", bundle: .appLanguage, comment: "Workshop tag group: Everyone / Questionable / Mature.")
            case .stats: String(localized: "Stats", bundle: .appLanguage, comment: "Wallpaper detail row: Workshop subscribers, favorites and views.")
            case .posted: String(localized: "Posted", bundle: .appLanguage, comment: "Wallpaper detail row: the date the Workshop item was first published.")
            case .capturedFrom: String(localized: "Captured From", bundle: .appLanguage, comment: "Scheme detail row: the display the scheme was saved from.")
            case .saved: String(localized: "Saved", bundle: .appLanguage, comment: "Scheme detail row: the date the scheme was first saved.")
            case .updated: String(localized: "Updated", bundle: .appLanguage, comment: "Wallpaper detail row: the date the Workshop item last changed.")
            case .source: String(localized: "Source", bundle: .appLanguage)
            case .imported: String(localized: "Imported", bundle: .appLanguage)
            case .lastUsed: String(localized: "Last Used", bundle: .appLanguage, comment: "Wallpaper detail row: how long ago the wallpaper was last applied.")
            case .location: String(localized: "Location", bundle: .appLanguage, comment: "Managed SteamCMD install consent sheet field label for the install path.")
            case .webAddress: String(localized: "Web Address", bundle: .appLanguage, comment: "Wallpaper detail row: the page a web wallpaper loads.")
            }
        }
    }

    let kind: Kind
    var value: String
    /// Tooltip, such as the relative time behind a date; nil shows none.
    var help: String?

    var id: Kind {
        kind
    }
}

/// One tag chip: `raw` is the tag as Steam matches it, `label` the localized text drawn.
struct WallpaperTagChip: Equatable, Identifiable {
    let raw: String
    let label: String

    var id: String {
        raw
    }
}

/// A title-row button of the detail modal: one "…" row that is not an apply.
struct ModalHeaderAction: Identifiable {
    enum Kind: Hashable {
        case showInFinder, copyLink, rename, removeFromLibrary, delete
        #if !MAS_BUILD
        case openInSteam
        #endif
        case bookmark(isBookmarked: Bool)
        case like(isLiked: Bool)
    }

    let kind: Kind
    let perform: @MainActor () -> Void

    var id: Kind {
        kind
    }

    var isDestructive: Bool {
        kind == .removeFromLibrary || kind == .delete
    }

    /// The title-row capsule the button sits in: marks, then places to open, then the destructive one last.
    var group: Int {
        switch kind {
        case .bookmark, .like, .rename: 0
        #if !MAS_BUILD
        case .showInFinder, .openInSteam, .copyLink: 1
        #else
        case .showInFinder, .copyLink: 1
        #endif
        case .removeFromLibrary, .delete: 2
        }
    }

    /// The title row's capsules in order, each keeping its buttons' order; a group with no button is absent.
    static func groups(_ actions: [ModalHeaderAction]) -> [[ModalHeaderAction]] {
        Dictionary(grouping: actions, by: \.group).sorted { $0.key < $1.key }.map(\.value)
    }

    var symbol: String {
        switch kind {
        case .showInFinder: "folder"
        case .copyLink: "link"
        #if !MAS_BUILD
        case .openInSteam: "arrow.up.forward.app"
        #endif
        case .rename: "pencil"
        case .removeFromLibrary, .delete: "trash"
        case let .bookmark(isBookmarked): isBookmarked ? "bookmark.fill" : "bookmark"
        case let .like(isLiked): isLiked ? "heart.fill" : "heart"
        }
    }

    /// nil draws the glyph in the button's own colour.
    var tint: Color? {
        switch kind {
        case .bookmark(isBookmarked: true): DesignTokens.Colors.rating
        case .like(isLiked: true): DesignTokens.Colors.like
        default: nil
        }
    }

    var title: String {
        switch kind {
        case .showInFinder: String(localized: "Show in Finder", bundle: .appLanguage)
        case .copyLink: String(localized: "Copy link", bundle: .appLanguage)
        #if !MAS_BUILD
        case .openInSteam: String(localized: "Open in Steam", bundle: .appLanguage)
        #endif
        case .rename:
            String(
                localized: "Rename", bundle: .appLanguage,
                comment: "Context menu item that opens a rename alert, for a display on the Edit Desk stage or for a wallpaper."
            )
        case .removeFromLibrary: String(localized: "Remove from Wallpaper Library", bundle: .appLanguage)
        case .delete: String(localized: "Delete", bundle: .appLanguage)
        case .bookmark(isBookmarked: true): String(localized: "Remove Bookmark", bundle: .appLanguage)
        case .bookmark(isBookmarked: false): String(localized: "Add Bookmark", bundle: .appLanguage)
        case .like(isLiked: true): String(localized: "Unlike", bundle: .appLanguage)
        case .like(isLiked: false): String(localized: "Like", bundle: .appLanguage)
        }
    }
}

/// `InstalledInspector`'s update state, so the library modal loses nothing the old page showed.
struct InstalledItemExtras: Equatable {
    enum UpdateState: Equatable {
        case unknown
        case upToDate
        case available
        case checking(progress: Double?)
        case failed(message: String)
    }

    var updateState: UpdateState
}

/// A display as the ⌘n buttons and the float layer present it. Ordered left→right by `frame.minX`;
/// `shortcutIndex` is that order, 1-based, and is what ⌘1…⌘9 select.
struct ModalDisplayTarget: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var shortcutIndex: Int
    /// Width / height in points; the float layer sizes thumbnails from it (16:9 → 150×84).
    var aspectRatio: CGFloat
    var thumbnail: CGImage?
    /// The display the library was opened for, drawn prominent; false for every display when there is none.
    var isPrimary: Bool
    var isApplied = false
    /// An apply to this display is still preparing.
    var isPreparing = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.shortcutIndex == rhs.shortcutIndex
            && lhs.aspectRatio == rhs.aspectRatio
            && lhs.thumbnail === rhs.thumbnail
            && lhs.isPrimary == rhs.isPrimary
            && lhs.isApplied == rhs.isApplied
            && lhs.isPreparing == rhs.isPreparing
    }
}

/// Everything the modal can trigger. A nil closure hides its control or menu row.
struct WallpaperModalActions {
    var applyTo: @MainActor (CGDirectDisplayID) -> Void
    var applyToAllDisplays: @MainActor () -> Void
    /// Opens a display's detail page from its button once the wallpaper runs there; nil applies again instead.
    var showDisplay: (@MainActor (CGDirectDisplayID) -> Void)?
    /// The context menus' rows and the modal's title-row buttons.
    var showInFinder: (@MainActor () -> Void)?
    #if !MAS_BUILD
    var openInSteam: (@MainActor () -> Void)?
    #endif
    var removeFromSaved: (@MainActor () -> Void)?
    /// Installed Workshop items with an available update only.
    var checkForUpdate: (@MainActor () -> Void)?
    var cancelUpdate: (@MainActor () -> Void)?
    var deleteInstalled: (@MainActor () -> Void)?
    /// Saved entries only; takes the new name.
    var rename: (@MainActor (String) -> Void)?
    /// Marks or unmarks the entry in the library's Bookmarks.
    var toggleBookmark: (@MainActor () -> Void)?
    /// The entry's mark when these actions were built; picks the row's title and glyph.
    var isBookmarked = false
    /// Adds a saved video to System Wallpaper or takes it out; nil where System Wallpaper can't take the entry.
    var toggleSystemWallpaper: (@MainActor () -> Void)?
    /// Whether the entry was in System Wallpaper when these actions were built; picks the row's title.
    var isInSystemWallpaper = false
}

extension WallpaperModalActions {
    /// The modal's title-row buttons: every context-menu row that is not an apply, System Wallpaper or an update, each
    /// once. The bottom row applies; the primary title-row button updates. `requestRename` and `requestDelete` open the
    /// presenter's own alert and confirmation.
    func headerActions(
        requestRename: @escaping @MainActor () -> Void, requestDelete: @escaping @MainActor () -> Void
    ) -> [ModalHeaderAction] {
        var actions: [ModalHeaderAction] = []
        if let toggleBookmark {
            actions.append(ModalHeaderAction(kind: .bookmark(isBookmarked: isBookmarked), perform: toggleBookmark))
        }
        if rename != nil {
            actions.append(ModalHeaderAction(kind: .rename, perform: requestRename))
        }
        if let showInFinder {
            actions.append(ModalHeaderAction(kind: .showInFinder, perform: showInFinder))
        }
        #if !MAS_BUILD
        if let openInSteam {
            actions.append(ModalHeaderAction(kind: .openInSteam, perform: openInSteam))
        }
        #endif
        if let removeFromSaved {
            actions.append(ModalHeaderAction(kind: .removeFromLibrary, perform: removeFromSaved))
        }
        if deleteInstalled != nil {
            actions.append(ModalHeaderAction(kind: .delete, perform: requestDelete))
        }
        return actions
    }

    /// Updates live in the title row. The status line only cancels an active transfer.
    func statusButton(for state: InstalledItemExtras.UpdateState?) -> ModalExtraButton? {
        switch state {
        case .checking:
            cancelUpdate.map { ModalExtraButton(title: String(localized: "Cancel", bundle: .appLanguage), action: $0) }
        default:
            nil
        }
    }

    func updateButton(for state: InstalledItemExtras.UpdateState?) -> ModalExtraButton? {
        switch state {
        case .available, .failed: break
        default: return nil
        }
        return checkForUpdate.map { ModalExtraButton(title: String(localized: "Update", bundle: .appLanguage), action: $0) }
    }
}

extension WallpaperModalActions {
    /// The context menus' sections, in order, empty ones left out: the grid and the shelf both draw these.
    /// `requestRename` and `requestDelete` open the presenter's own rename alert and delete confirmation.
    func menuItems(
        targets: [ModalDisplayTarget], canApply: Bool, isUpdating: Bool,
        requestRename: @escaping @MainActor () -> Void, requestDelete: @escaping @MainActor () -> Void
    ) -> [[StageMenuItem]] {
        var applyTargets = [targets.map { target in
            StageMenuItem(title: target.name, isEnabled: true) { applyTo(target.id) }
        }]
        if targets.count > 1 {
            applyTargets.append([StageMenuItem(
                title: String(localized: "All Displays", bundle: .appLanguage), isEnabled: true, action: applyToAllDisplays
            )])
        }
        let apply = [
            StageMenuItem(
                title: String(localized: "Apply to", bundle: .appLanguage), isEnabled: canApply, submenu: applyTargets
            ) {},
        ]
        var organize: [StageMenuItem] = []
        if let toggleBookmark {
            organize.append(StageMenuItem(
                title: isBookmarked
                    ? String(localized: "Remove Bookmark", bundle: .appLanguage)
                    : String(localized: "Add Bookmark", bundle: .appLanguage),
                isEnabled: true, action: toggleBookmark
            ))
        }
        if rename != nil {
            organize.append(StageMenuItem(
                title: String(
                    localized: "Rename", bundle: .appLanguage,
                    comment: "Context menu item that opens a rename alert, for a display on the Edit Desk stage or for a wallpaper."
                ),
                isEnabled: true, action: requestRename
            ))
        }
        if let toggleSystemWallpaper {
            organize.append(StageMenuItem(
                title: isInSystemWallpaper
                    ? String(localized: "Remove from System Wallpaper", bundle: .appLanguage)
                    : String(localized: "Add to System Wallpaper", bundle: .appLanguage),
                isEnabled: true, action: toggleSystemWallpaper
            ))
        }
        var reveal: [StageMenuItem] = []
        if let showInFinder {
            reveal.append(StageMenuItem(
                title: String(localized: "Show in Finder", bundle: .appLanguage), isEnabled: true, action: showInFinder
            ))
        }
        #if !MAS_BUILD
        if let openInSteam {
            reveal.append(StageMenuItem(
                title: String(localized: "Open in Steam", bundle: .appLanguage), isEnabled: true, action: openInSteam
            ))
        }
        #endif
        var download: [StageMenuItem] = []
        if isUpdating, let cancelUpdate {
            download.append(StageMenuItem(
                title: String(localized: "Cancel update", bundle: .appLanguage), isEnabled: true, action: cancelUpdate
            ))
        } else if let checkForUpdate {
            download.append(StageMenuItem(
                title: String(localized: "Update", bundle: .appLanguage),
                isEnabled: true, action: checkForUpdate
            ))
        }
        var remove: [StageMenuItem] = []
        if let removeFromSaved {
            remove.append(StageMenuItem(
                title: String(localized: "Remove from Wallpaper Library", bundle: .appLanguage), isEnabled: true,
                isDestructive: true, action: removeFromSaved
            ))
        }
        if deleteInstalled != nil {
            remove.append(StageMenuItem(
                title: String(localized: "Delete", bundle: .appLanguage), isEnabled: true, isDestructive: true,
                action: requestDelete
            ))
        }
        return [apply, organize, reveal, download, remove].filter { !$0.isEmpty }
    }
}

/// ← / → over the adjacent library items; the host owns the order.
struct ModalNavigation {
    var canGoPrevious: Bool
    var canGoNext: Bool
    var previous: @MainActor () -> Void
    var next: @MainActor () -> Void
}

/// The modal preview's drag as the host sees it. Points are in `EditDeskCoordinateSpace.name`.
enum ModalDragPhase: Equatable {
    case began(CGPoint)
    case moved(CGPoint)
    case ended(CGPoint)
    case cancelled
}

/// What a modal drag is over when it is released.
enum ModalDropTarget: Equatable {
    case display(CGDirectDisplayID)
    case allDisplays
}

/// Where a float-layer thumbnail sits, in `EditDeskCoordinateSpace.name`, reported through
/// `onGeometryChange` so the host can hit-test a modal drag without either view knowing the other.
struct FloatTargetFrame: Equatable {
    let id: CGDirectDisplayID
    var rect: CGRect
}

enum EditDeskCoordinateSpace {
    static let name = "editDesk"
}
