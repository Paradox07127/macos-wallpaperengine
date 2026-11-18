import CoreGraphics

enum DisplayControl {
    /// Scope every display-configuration transaction commits with.
    static let configurationScope: CGConfigureOption = .forAppOnly
}

enum DisplayControlError: Error, Equatable {
    /// The private symbol or class behind this capability is missing on this OS, architecture or SKU.
    case unavailable
    case wouldLeaveNoOnlineDisplay
    case modeNotFound
    case displayNotFound
    case windowServer(CGError)
    /// The transaction committed but the online display list does not show the requested state.
    case stateNotReached
}
