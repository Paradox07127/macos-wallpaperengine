import Foundation
import XCTest

/// The wpe-shaderc, DXC and Metal Shader Converter the test host app bundles, unless all three
/// `WPE_SHADERC`/`WPE_DXCOMPILER`/`WPE_METALIRCONVERTER` override them; skips when one is missing.
func parityShaderToolchainURLs() throws -> (helper: URL, dxcompiler: URL, metalIRConverter: URL) {
    let environment = ProcessInfo.processInfo.environment
    let overrides = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER"]
        .compactMap { environment[$0].map { URL(fileURLWithPath: $0) } }
    let urls: [URL]
    if overrides.isEmpty {
        let contents = Bundle.main.bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        urls = ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"]
            .map { contents.appending(path: $0) }
    } else {
        guard overrides.count == 3 else { throw XCTSkip("Set all of WPE_SHADERC, WPE_DXCOMPILER and WPE_METALIRCONVERTER") }
        urls = overrides
    }
    for url in urls where !FileManager.default.fileExists(atPath: url.path) {
        throw XCTSkip("Missing \(url.path)")
    }
    return (urls[0], urls[1], urls[2])
}
