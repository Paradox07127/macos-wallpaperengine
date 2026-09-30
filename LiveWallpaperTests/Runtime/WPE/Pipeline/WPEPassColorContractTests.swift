#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
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
}
#endif
