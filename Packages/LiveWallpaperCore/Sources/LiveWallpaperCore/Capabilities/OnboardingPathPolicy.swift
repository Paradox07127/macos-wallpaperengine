import Foundation

/// First-run entry points. `importFile` opens a single file/folder picker and
/// routes by type (video / web / — on Pro — Wallpaper Engine scene). Apple
/// Aerials remains the low-friction gallery choice in every capable SKU.
/// Workshop is intentionally deferred until the user opens that feature.
public enum OnboardingSourceAction: Sendable, Equatable {
    case importFile
    case appleAerials
}

/// Capability-derived plan for the onboarding source-picker step.
public struct OnboardingPathPolicy: Sendable, Equatable {
    public let sku: ProductSKU
    public let galleryActions: [OnboardingSourceAction]

    public init(capabilities: ProductCapabilities) {
        sku = capabilities.sku
        let canImport = capabilities.enabledFeatures.contains(.video)
            || capabilities.enabledFeatures.contains(.html)
            || capabilities.enabledFeatures.contains(.scene)
        var actions: [OnboardingSourceAction] = []
        if canImport { actions.append(.importFile) }
        if capabilities.enabledFeatures.contains(.appleAerials) {
            actions.append(.appleAerials)
        }
        galleryActions = actions
    }
}
