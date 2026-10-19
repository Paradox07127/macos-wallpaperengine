#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Paths are relative to the immutable scene bundle published beside the videos.
struct SystemWallpaperSceneConfiguration: Codable, Sendable {
    struct Dependency: Codable, Sendable {
        let workshopID: String
        let directory: String
    }

    /// Every value that can change shader keys or resource allocation is captured by the exporting app.
    struct Parity: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let bloom: Bool
        let hdrPostProcessing: Bool
        let msaaSampleCount: Int
        let mipMappedFrameBufferEnabled: Bool
        let displayHDR: Bool
        let maximumPotentialEDR: Float
        let shadowQuality: Int32
        let offscreenScaleTier: Int
        let renderTargetAliasing: Bool
        let textureCompression: Bool
        let renderScale: Double
        let compilerIdentity: String
        let bindingABIVersion: Int
        let minimumMacOS: String
        let boundsCheck: Bool

        init(settings: WPEParityProgramSettings, textureCompression: Bool, renderScale: Double,
             compilerIdentity: String, bindingABIVersion: Int = WPEParityShaderCompileRequest.currentBindingABIVersion,
             shaderOptions: WPEParityShaderCompileOptions = .init()) {
            schemaVersion = 1
            bloom = settings.bloom
            hdrPostProcessing = settings.hdrPostProcessing
            msaaSampleCount = settings.msaaSampleCount
            mipMappedFrameBufferEnabled = settings.mipMappedFrameBufferEnabled
            displayHDR = settings.displayHDR
            maximumPotentialEDR = settings.maximumPotentialEDR
            shadowQuality = settings.shadowQuality
            offscreenScaleTier = settings.offscreenScaleTier
            renderTargetAliasing = settings.renderTargetAliasing
            self.textureCompression = textureCompression
            self.renderScale = renderScale
            self.compilerIdentity = compilerIdentity
            self.bindingABIVersion = bindingABIVersion
            minimumMacOS = shaderOptions.minimumMacOS
            boundsCheck = shaderOptions.boundsCheck
        }

        var shaderOptions: WPEParityShaderCompileOptions {
            WPEParityShaderCompileOptions(minimumMacOS: minimumMacOS, boundsCheck: boundsCheck)
        }

        func settings(for descriptor: SceneDescriptor) throws -> WPEParityProgramSettings {
            let version = minimumMacOS.split(separator: ".", omittingEmptySubsequences: false)
            guard schemaVersion == 1, !compilerIdentity.isEmpty,
                  bindingABIVersion == WPEParityShaderCompileRequest.currentBindingABIVersion,
                  (2 ... 3).contains(version.count), version.allSatisfy({ Int($0).map { $0 >= 0 } == true }),
                  [1, 2, 4, 8].contains(msaaSampleCount), (0 ... 4).contains(shadowQuality),
                  (0 ... 3).contains(offscreenScaleTier), maximumPotentialEDR.isFinite, maximumPotentialEDR >= 1,
                  renderScale.isFinite, (0.25 ... 1).contains(renderScale) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // The preset snapshot is stored in this same immutable configuration's descriptor.
            return try WPEParityProgramSettings(
                bloom: bloom, hdrPostProcessing: hdrPostProcessing, msaaSampleCount: msaaSampleCount,
                mipMappedFrameBufferEnabled: mipMappedFrameBufferEnabled,
                colorCorrection: WPEParityColorCorrection(presetSnapshot: descriptor.presetSnapshot),
                displayHDR: displayHDR, maximumPotentialEDR: maximumPotentialEDR, shadowQuality: shadowQuality,
                offscreenScaleTier: offscreenScaleTier, renderTargetAliasing: renderTargetAliasing
            )
        }
    }

    let descriptor: SceneDescriptor
    let dependencies: [Dependency]
    let hasEngineAssets: Bool
    var parity: Parity?
    var framesPerSecond = 30
    var renderSize = CGSize(width: 1920, height: 1080)
}
#endif
