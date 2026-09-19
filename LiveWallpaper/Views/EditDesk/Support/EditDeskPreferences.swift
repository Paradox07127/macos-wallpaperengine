import Foundation

enum EditDeskPreferences {
    static let shelfStyle = "loomscreen.editDesk.shelfStyle"
    static let background = "loomscreen.editDesk.background"
    static let shelfCapacity = "loomscreen.editDesk.shelfCapacity"
    static let hoverAutoplayPreview = "loomscreen.editDesk.hoverAutoplayPreview"
    static let statusCapsuleContent = "loomscreen.editDesk.statusCapsuleContent"
    static let homeDefaultState = "loomscreen.editDesk.homeDefaultState"

    static let shelfStyleDefault: ShelfStyle = .crate
    static let backgroundDefault: EditDeskBackground = .opaque
    static let shelfCapacityDefault = StageGeometry.shelfCapacity
    static let hoverAutoplayPreviewDefault = true
    static let statusCapsuleContentDefault: StatusCapsuleContent = .systemHealth
    static let homeDefaultStateDefault: HomeDefaultState = .hidden
}

/// Whether the Edit Desk paints its own canvas or lets the desktop blur through it.
enum EditDeskBackground: String, CaseIterable {
    case opaque
    case frosted
}

enum StatusCapsuleContent: String, CaseIterable {
    case systemHealth
    case wallpapersOnly
    case hidden
}

enum HomeDefaultState: String, CaseIterable {
    case hidden
    case halfOpen
}
