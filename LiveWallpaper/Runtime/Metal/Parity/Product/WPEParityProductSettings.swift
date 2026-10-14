#if !LITE_BUILD
import CoreFoundation
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// Resolves product preferences once, when a scene is loaded or reloaded.
enum WPEParityProductSettings {
    static let msaaSampleCountDefaultsKey = "loomscreen.wallpapers.parityMSAASampleCount.v1"
    /// A Mac resource policy, not Wallpaper Engine's Windows default.
    static let defaultMSAASampleCount = 1
    static let mipMappedFrameBufferDefaultsKey = "loomscreen.wallpapers.parityMipMappedFrameBufferQuality.v1"
    /// Native046f20 normalises missing/non-bool general.reflection to true;1154c0/115a90 publish bit7.
    /// The Mac preference retains that default and refreshes only snapshots requested by active shader slots.
    static let defaultMipMappedFrameBufferEnabled = true

    static func make(descriptor: SceneDescriptor, device: MTLDevice,
                     defaults: UserDefaults = .appScoped(), bloomEnabled: Bool = true) throws -> WPEParityProgramSettings {
        let correction = try WPEParityColorCorrection(presetSnapshot: descriptor.presetSnapshot)
        let samples = resolveMSAASampleCount(requested: requestedMSAASampleCount(defaults: defaults),
                                             supports: { device.supportsTextureSampleCount($0) })
        return WPEParityProgramSettings(bloom: bloomEnabled, hdrPostProcessing: true,
                                        msaaSampleCount: samples,
                                        mipMappedFrameBufferEnabled: requestedMipMappedFrameBuffer(defaults: defaults),
                                        colorCorrection: correction)
    }

    /// The picker offers only 1/2/4/8. Never increase a request to match a device capability.
    static func resolveMSAASampleCount(requested: Int, supports: (Int) -> Bool) -> Int {
        guard [1, 2, 4, 8].contains(requested) else { return defaultMSAASampleCount }
        return [8, 4, 2].first { $0 <= requested && supports($0) } ?? defaultMSAASampleCount
    }

    private static func requestedMSAASampleCount(defaults: UserDefaults) -> Int {
        // UserDefaults bridges picker integers through NSNumber. Accept an exact integral numeric
        // representation here only; bools, numeric strings and fractional values are not picker input.
        // This does not relax the wallpaper preset parser's separate, throwing input contract.
        guard let number = defaults.object(forKey: msaaSampleCountDefaultsKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = Int(exactly: number.doubleValue) else { return defaultMSAASampleCount }
        return count
    }

    private static func requestedMipMappedFrameBuffer(defaults: UserDefaults) -> Bool {
        guard let number = defaults.object(forKey: mipMappedFrameBufferDefaultsKey) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return defaultMipMappedFrameBufferEnabled }
        return number.boolValue
    }
}
#endif
