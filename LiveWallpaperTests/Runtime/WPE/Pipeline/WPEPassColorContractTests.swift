#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE hardware color contract definitions")
struct WPEPassColorContractTests {
    @Test func formatFactsNeverConflateUNORMWithLinearAuthoredColor() throws {
        let encoded = WPEPixelColorContract(.rgba8Unorm)
        let srgb = WPEPixelColorContract(.rgba8Unorm_srgb)
        let mask = WPEPixelColorContract(.r8Unorm)
        let hdr = WPEPixelColorContract(.rgba16Float)
        #expect(encoded.storage == .normalized && encoded.hardwareRGBTransfer == .identity)
        #expect(srgb.storage == .normalized && srgb.hardwareRGBTransfer == .sRGB)
        #expect(mask.hardwareRGBTransfer == .identity && hdr.hardwareRGBTransfer == .identity)
        #expect(hdr.storage == .floatingPoint)
        #expect(encoded.alphaTransfer == srgb.alphaTransfer && srgb.alphaTransfer == "identity")
        #expect(try JSONDecoder().decode(WPEPixelColorContract.self, from: JSONEncoder().encode(srgb)) == srgb)
        // A typed transfer fact has no authored-encoding assertion, including on an UNORM view.
        #expect(encoded.jsonObject()["authoredRGBEncoding"] == nil)
    }

    @Test func unknownFormatsStayUnknownInsteadOfGuessingTransfer() {
        let unknown = WPEPixelColorContract(.invalid)
        #expect(unknown.storage == .unknown && unknown.hardwareRGBTransfer == .unknown)
        #expect(unknown.alphaTransfer == "unverified")
    }

    #if DEBUG
    @Test func builtinTraceDoesNotReportOutputRepresentationAsInjectedPremultiply() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let pass = WPERenderPass(id: "blur", phase: .material, shader: "effects/blur", source: .fbo("a"),
                                 target: .layerComposite(name: "b"), textures: [:], binds: [:], constants: [:], combos: [:],
                                 blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let resolved = WPEPassRenderContract.resolve(pass: pass, shader: nil, bindings: [0: .fbo("a")], alphaOverride: nil)
        try #require(resolved.shaderAlpha.premultipliedOutput)
        let state = WPECanonicalTraceRecorder.NativeRenderState.scenePass(
            blendMode: "disabled", alphaWritePolicy: .all, cullMode: "nocull",
            depthAttached: false, depthTest: "disabled", depthWrite: "disabled", reversedZ: false
        )
        let builtin = WPEPassColorContract(textureBindings: [], alpha: resolved.shaderAlpha, target: target,
                                           nativeState: state, resolved: resolved, builtin: true)
        #expect(builtin.shaderOutputAlphaOperation == "unverified")
        #expect(builtin.shaderOutputRepresentation == "premultiplied")
        let translated = WPEPassColorContract(textureBindings: [], alpha: resolved.shaderAlpha, target: target,
                                              nativeState: state, resolved: resolved)
        #expect(translated.shaderOutputAlphaOperation == "premultiply-before-attachment")
        #expect(translated.shaderOutputRepresentation == "premultiplied")
    }
    #endif
}
#endif
