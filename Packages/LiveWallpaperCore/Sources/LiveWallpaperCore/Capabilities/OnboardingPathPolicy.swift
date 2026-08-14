import Foundation

/// First-run entry points. `importFile` opens a single file/folder picker and
/// routes by type (video / web / — on Pro — Wallpaper Engine scene). Direct Pro
/// builds put Workshop first because it is a primary acquisition path, while
/// Apple Aerials remains a low-friction gallery choice in every capable SKU.
public enum OnboardingSourceAction: Sendable, Equatable {
    case steamWorkshop
    case importFile
    case appleAerials
}

/// Capability-derived plan for the onboarding source-picker step.
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
