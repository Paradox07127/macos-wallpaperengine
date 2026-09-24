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
    /// Verbatim glyphs under the preview (Workshop tags, `4K`, `HDR`); never translated.
    var tags: [String]
    /// Bottom-bar line, joined by the shell with " · ": `{来源} · {作者} · {大小} · {分辨率} · 上次 {时间} → {屏}`.
    var metaParts: [String]
    /// Scene preset capsule `◈ 预设 {名} ▾`; nil hides the capsule.
    var presetName: String?
    /// Decoded at the preview's pixel size; nil shows the placeholder. The shell derives its
    /// blurred backdrop from this image itself.
    var preview: CGImage?
    var isDraggable: Bool
    /// Present only for installed Workshop items.
    var installed: InstalledItemExtras?
    var descriptionText: String?
    var contentRating: String?
    var importedAt: Date?
    var workshopID: UInt64?
    var dependencyIDs: [String] = []
    /// False for a type this Mac cannot run: every apply control is disabled.
    var canApply = true
    /// Why the item may not play here, already localized; nil when nothing is known to be wrong.
    var notice: String?
    /// A Workshop project this Mac can't run; the right column explains why. nil for everything else.
    var unsupportedOrigin: WPEOrigin?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.itemID == rhs.itemID
            && lhs.title == rhs.title
            && lhs.kind == rhs.kind
            && lhs.tags == rhs.tags
            && lhs.metaParts == rhs.metaParts
            && lhs.presetName == rhs.presetName
            && lhs.preview === rhs.preview
            && lhs.isDraggable == rhs.isDraggable
            && lhs.installed == rhs.installed
            && lhs.descriptionText == rhs.descriptionText
            && lhs.contentRating == rhs.contentRating
            && lhs.importedAt == rhs.importedAt
            && lhs.workshopID == rhs.workshopID
            && lhs.dependencyIDs == rhs.dependencyIDs
            && lhs.canApply == rhs.canApply
            && lhs.notice == rhs.notice
            && lhs.unsupportedOrigin == rhs.unsupportedOrigin
    }
}

/// `InstalledInspector`'s own fields, so the library modal loses nothing the old page showed.
struct InstalledItemExtras: Equatable {
    enum UpdateState: Equatable {
        case unknown
        case upToDate
        case available
        case checking(progress: Double?)
        case failed(message: String)
    }

    var updateState: UpdateState
    var isWindowsOnly: Bool
    /// Display names the item is running on; empty when idle.
    var inUseOnDisplayNames: [String]
    /// True when deleting reclaims disk (a Steam item in the shared repository): the delete row then
    /// reads "删除并释放空间"; false reads "仅从库移除". One action either way, as in `InstalledLibrary`.
    var deletesFiles: Bool
    /// `project.json` description for folder imports.
    var localDescription: String?
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
    /// "＋" button menu.
    var addToPlaylist: (@MainActor (CGDirectDisplayID) -> Void)?
    /// "…" menu — the same rows as the shelf card's context menu.
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
    /// The "…" menu's rows, in order: the modal and the library's context menus all draw these.
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

/// How the float layer treats its thumbnails.
enum FloatLayerMode: Equatable {
    /// Library: a drag from the modal preview lands here; `highlighted` follows the drag.
    case dropTarget
    /// Workshop: click selects a single target; `highlighted` is the selection.
    case selectTarget
}
