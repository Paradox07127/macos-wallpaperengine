#if !LITE_BUILD
import CoreFoundation
import Foundation

/// Resource-saving switches for the parity renderer; unset or malformed values resolve compression on, the rest off.
struct WPEParityResourceSaverFlags: Equatable, Sendable {
    static let textureCompressionDefaultsKey = "loomscreen.wallpapers.parityTextureCompression.v1"
    static let renderTargetAliasingDefaultsKey = "loomscreen.wallpapers.parityRenderTargetAliasing.v1"
    static let offscreenScaleTierDefaultsKey = "loomscreen.wallpapers.parityOffscreenScale.v1"
    static let sceneMirrorRenderingDefaultsKey = "loomscreen.wallpapers.sceneMirrorRendering.v1"

    var textureCompression: Bool
    var renderTargetAliasing: Bool
    /// 0...3; 0 = off.
    var offscreenScaleTier: Int
    var sceneMirrorRendering: Bool

    static func resolve(defaults: UserDefaults = .appScoped()) -> Self {
        Self(textureCompression: bool(textureCompressionDefaultsKey, defaults, default: true),
             renderTargetAliasing: bool(renderTargetAliasingDefaultsKey, defaults),
             offscreenScaleTier: tier(defaults),
             sceneMirrorRendering: bool(sceneMirrorRenderingDefaultsKey, defaults))
    }

    private static func bool(_ key: String, _ defaults: UserDefaults, default fallback: Bool = false) -> Bool {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
        return number.boolValue
    }

    private static func tier(_ defaults: UserDefaults) -> Int {
        // Bools also bridge as NSNumber; only an exact integral number is a tier.
        guard let number = defaults.object(forKey: offscreenScaleTierDefaultsKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let tier = Int(exactly: number.doubleValue), (0 ... 3).contains(tier) else { return 0 }
        return tier
    }
}
#endif
