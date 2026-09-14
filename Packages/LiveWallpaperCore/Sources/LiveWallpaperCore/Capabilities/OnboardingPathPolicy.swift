import Foundation

/// `importFile` opens one file/folder picker and routes by type
/// (video / web / — on Pro — Wallpaper Engine scene).
public enum OnboardingSourceAction: Sendable, Equatable {
    case steamWorkshop
    case importFile
    case appleAerials
}

public struct OnboardingPathPolicy: Sendable, Equatable {
    public let sku: ProductSKU
    public let showsWorkshopSetup: Bool
    public let galleryActions: [OnboardingSourceAction]

    public init(capabilities: ProductCapabilities) {
        sku = capabilities.sku
        showsWorkshopSetup = capabilities.enabledFeatures.contains(.workshopOnline)
        let canImport = capabilities.enabledFeatures.contains(.video)
            || capabilities.enabledFeatures.contains(.html)
            || capabilities.enabledFeatures.contains(.scene)
        var actions: [OnboardingSourceAction] = []
        if showsWorkshopSetup { actions.append(.steamWorkshop) }
        if canImport { actions.append(.importFile) }
        if capabilities.enabledFeatures.contains(.appleAerials) {
            actions.append(.appleAerials)
        }
        galleryActions = actions
    }
}
