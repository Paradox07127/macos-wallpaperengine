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
    /// Decoded at the preview's pixel size; nil shows the placeholder.
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
        case type, author, rating, size, resolution, duration, ageRating, stats, posted, updated, source, imported, lastUsed
        case location, webAddress

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
    enum Kind: Equatable {
        case showInFinder, openInSteam, rename, checkForUpdate, cancelUpdate, removeFromLibrary, delete
    }

    let kind: Kind
    let perform: @MainActor () -> Void

    var id: Kind {
        kind
    }

    var isDestructive: Bool {
        kind == .removeFromLibrary || kind == .delete
    }

    var symbol: String {
        switch kind {
        case .showInFinder: "folder"
        case .openInSteam: "arrow.up.forward.app"
        case .rename: "pencil"
        case .checkForUpdate: "arrow.triangle.2.circlepath"
        case .cancelUpdate: "xmark.circle"
        case .removeFromLibrary, .delete: "trash"
        }
    }

    var title: String {
        switch kind {
        case .showInFinder: String(localized: "Show in Finder", bundle: .appLanguage)
        case .openInSteam: String(localized: "Open in Steam", bundle: .appLanguage)
        case .rename:
            String(
                localized: "Rename", bundle: .appLanguage,
                comment: "Context menu item that opens a rename alert, for a display on the Edit Desk stage or for a wallpaper."
            )
        case .checkForUpdate: String(localized: "Check for updates", bundle: .appLanguage)
        case .cancelUpdate: String(localized: "Cancel update", bundle: .appLanguage)
        case .removeFromLibrary: String(localized: "Remove from Wallpaper Library", bundle: .appLanguage)
        case .delete: String(localized: "Delete", bundle: .appLanguage)
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
    /// Stable first display; applying content must not move another target under the pointer.
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
    /// The context menus' rows and the modal's title-row buttons.
    var showInFinder: (@MainActor () -> Void)?
    var openInSteam: (@MainActor () -> Void)?
    var removeFromSaved: (@MainActor () -> Void)?
    /// Installed Workshop items only.
    var checkForUpdate: (@MainActor () -> Void)?
    var cancelUpdate: (@MainActor () -> Void)?
    var deleteInstalled: (@MainActor () -> Void)?
    /// Saved entries only; takes the new name.
    var rename: (@MainActor (String) -> Void)?
}

extension WallpaperModalActions {
    /// The modal's title-row buttons: every context-menu row that is not an apply, each once. The bottom
    /// row applies. `requestRename` and `requestDelete` open the presenter's own alert and confirmation.
    func headerActions(
        isUpdating: Bool, requestRename: @escaping @MainActor () -> Void, requestDelete: @escaping @MainActor () -> Void
    ) -> [ModalHeaderAction] {
        var actions: [ModalHeaderAction] = []
        if let showInFinder {
            actions.append(ModalHeaderAction(kind: .showInFinder, perform: showInFinder))
        }
        if let openInSteam {
            actions.append(ModalHeaderAction(kind: .openInSteam, perform: openInSteam))
        }
        if rename != nil {
            actions.append(ModalHeaderAction(kind: .rename, perform: requestRename))
        }
        if isUpdating, let cancelUpdate {
            actions.append(ModalHeaderAction(kind: .cancelUpdate, perform: cancelUpdate))
        } else if let checkForUpdate {
            actions.append(ModalHeaderAction(kind: .checkForUpdate, perform: checkForUpdate))
        }
        if let removeFromSaved {
            actions.append(ModalHeaderAction(kind: .removeFromLibrary, perform: removeFromSaved))
        }
        if deleteInstalled != nil {
            actions.append(ModalHeaderAction(kind: .delete, perform: requestDelete))
        }
        return actions
    }
}

extension WallpaperModalActions {
    /// The context menus' rows, in order: the grid and the shelf both draw these.
    /// `requestRename` and `requestDelete` open the presenter's own rename alert and delete confirmation.
    func menuItems(
        targets: [ModalDisplayTarget], canApply: Bool, isUpdating: Bool,
        requestRename: @escaping @MainActor () -> Void, requestDelete: @escaping @MainActor () -> Void
    ) -> [StageMenuItem] {
        var items = [
            StageMenuItem(
                title: String(localized: "Apply to", bundle: .appLanguage), isEnabled: canApply,
                submenu: targets.map { target in
                    StageMenuItem(title: target.name, isEnabled: true) { applyTo(target.id) }
                }
            ) {},
            StageMenuItem(
                title: String(localized: "All Displays", bundle: .appLanguage), isEnabled: canApply,
                action: applyToAllDisplays
            ),
        ]
        if let showInFinder {
            items.append(StageMenuItem(
                title: String(localized: "Show in Finder", bundle: .appLanguage), isEnabled: true, action: showInFinder
            ))
        }
        if let openInSteam {
            items.append(StageMenuItem(
                title: String(localized: "Open in Steam", bundle: .appLanguage), isEnabled: true, action: openInSteam
            ))
        }
        if rename != nil {
            items.append(StageMenuItem(
                title: String(
                    localized: "Rename", bundle: .appLanguage,
                    comment: "Context menu item that opens a rename alert, for a display on the Edit Desk stage or for a wallpaper."
                ),
                isEnabled: true, action: requestRename
            ))
        }
        if let removeFromSaved {
            items.append(StageMenuItem(
                title: String(localized: "Remove from Wallpaper Library", bundle: .appLanguage), isEnabled: true,
                isDestructive: true, action: removeFromSaved
            ))
        }
        if isUpdating, let cancelUpdate {
            items.append(StageMenuItem(
                title: String(localized: "Cancel update", bundle: .appLanguage), isEnabled: true, action: cancelUpdate
            ))
        } else if let checkForUpdate {
            items.append(StageMenuItem(
                title: String(localized: "Check for updates", bundle: .appLanguage), isEnabled: true,
                action: checkForUpdate
            ))
        }
        if deleteInstalled != nil {
            items.append(StageMenuItem(
                title: String(localized: "Delete", bundle: .appLanguage), isEnabled: true, isDestructive: true,
                action: requestDelete
            ))
        }
        return items
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
