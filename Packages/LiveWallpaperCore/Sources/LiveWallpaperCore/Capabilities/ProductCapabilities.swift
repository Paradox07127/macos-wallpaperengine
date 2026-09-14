import Foundation
import SwiftUI

public enum ProductSKU: String, Sendable, Codable {
    /// No product has been selected. This state is intentionally featureless
    /// and is used by dependency defaults so a missed injection fails closed.
    case unconfigured
    case lite
    case pro
}

/// `WallpaperType` is *what* a wallpaper is; `ProductFeature` is *which* surfaces
/// are wired up to support it.
public enum ProductFeature: String, Sendable, Hashable, Codable, CaseIterable {
    case video
    case html
    case scene

    case monitorOverlay

    case wpeImport
    case videoEffects
    case weatherReactive

    case workshopOnline

    case scheduleAutomation
    case playlists

    case systemMonitor
    case globalShortcuts

    case lockScreenSnapshots

    case appleAerials

    case inspectorPreview
}

public struct ProductCapabilities: Sendable, Equatable {
    public let sku: ProductSKU
    public let enabledFeatures: Set<ProductFeature>

    public init(sku: ProductSKU, enabledFeatures: Set<ProductFeature>) {
        self.sku = sku
        // An unconfigured dependency must never be able to smuggle in a
        // feature through a hand-built capability set.
        self.enabledFeatures = sku == .unconfigured ? [] : enabledFeatures
    }

    /// Fail-closed catalog used until an app/test/preview explicitly chooses a shipping SKU.
    public static let unconfigured = ProductCapabilities(
        sku: .unconfigured,
        enabledFeatures: []
    )

    public static let lite = ProductCapabilities(
        sku: .lite,
        enabledFeatures: [
            .video, .html, .monitorOverlay,
            .videoEffects, .weatherReactive,
            .scheduleAutomation, .playlists,
            .systemMonitor, .globalShortcuts,
            .lockScreenSnapshots,
            .appleAerials, .inspectorPreview
        ]
    )

    public static let pro = ProductCapabilities(
        sku: .pro,
        enabledFeatures: [
            .video, .html, .scene,
            .monitorOverlay,
            .wpeImport, .videoEffects, .weatherReactive,
            .scheduleAutomation, .playlists,
            .systemMonitor, .globalShortcuts,
            .lockScreenSnapshots, .appleAerials, .inspectorPreview
        ]
    )

    /// Adds Workshop access to Pro only; the app target owns this gate because its compilation conditions do not propagate to SwiftPM dependencies.
    public func withWorkshopOnline() -> ProductCapabilities {
        guard sku == .pro else { return self }
        return ProductCapabilities(sku: sku, enabledFeatures: enabledFeatures.union([.workshopOnline]))
    }

    public func canRender(_ type: WallpaperType) -> Bool {
        switch type {
        case .video:       return enabledFeatures.contains(.video)
        case .html:        return enabledFeatures.contains(.html)
        case .scene:       return enabledFeatures.contains(.scene)
        }
    }

    /// Lite UI uses this instead of `WallpaperType.allCases`.
    public var selectableWallpaperTypes: [WallpaperType] {
        WallpaperType.allCases.filter { canRender($0) }
    }

    public var selectableWallpaperModes: [WallpaperMode] {
        guard enabledFeatures.contains(.playlists) else { return [] }
        return WallpaperMode.allCases.filter { mode in
            switch mode {
            case .playlist: return true
            case .schedule: return enabledFeatures.contains(.scheduleAutomation)
            }
        }
    }
}

public struct FeatureCatalog: Sendable, Equatable {
    public let capabilities: ProductCapabilities

    public init(capabilities: ProductCapabilities) {
        self.capabilities = capabilities
    }

    public func isEnabled(_ feature: ProductFeature) -> Bool {
        capabilities.enabledFeatures.contains(feature)
    }

    public static let unconfigured = FeatureCatalog(capabilities: .unconfigured)
}

private struct FeatureCatalogKey: EnvironmentKey {
    /// Missing SwiftUI injection is a configuration error, not permission to
    /// expose Pro functionality. Shipping roots inject Lite or Pro explicitly.
    static let defaultValue = FeatureCatalog.unconfigured
}

extension EnvironmentValues {
    public var featureCatalog: FeatureCatalog {
        get { self[FeatureCatalogKey.self] }
        set { self[FeatureCatalogKey.self] = newValue }
    }
}
