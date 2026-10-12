#if !LITE_BUILD
import Foundation

/// Locates `wpe-shaderc` and the two libraries it loads: the app bundle first, then (DEBUG only) local builds.
enum WPEParityShaderToolchain {
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    private struct Location {
        let helper: URL
        let dxcompiler: URL
        let metalIRConverter: URL
    }

    static func makeCompiler() -> Result<WPEParityHelperShaderCompiler, Unavailable> {
        let contents = Bundle.main.bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        var locations = [Location(helper: contents.appending(path: "MacOS/wpe-shaderc"),
                                  dxcompiler: contents.appending(path: "Frameworks/libdxcompiler.dylib"),
                                  metalIRConverter: contents.appending(path: "Frameworks/libmetalirconverter.dylib"))]
        #if DEBUG
        locations.append(Location(
            helper: URL(fileURLWithPath: "/Users/example/Developer/wpe-shaderc-build/wpe-shaderc"),
            dxcompiler: URL(fileURLWithPath: "/Users/example/Developer/DirectXShaderCompiler/build-14.6/lib/libdxcompiler.dylib"),
            metalIRConverter: URL(fileURLWithPath: "/usr/local/lib/libmetalirconverter.dylib")
        ))
        #endif
        var missing: [String] = []
        for location in locations {
            let absent = [location.helper, location.dxcompiler, location.metalIRConverter]
                .filter { !FileManager.default.fileExists(atPath: $0.path) }
            guard absent.isEmpty else {
                missing += absent.map(\.path)
                continue
            }
            do {
                return try .success(WPEParityHelperShaderCompiler(
                    helper: location.helper, dxcompiler: location.dxcompiler,
                    metalIRConverter: location.metalIRConverter,
                    workDirectory: FileManager.default.temporaryDirectory.appending(path: "wpe-shaderc",
                                                                                    directoryHint: .isDirectory)
                ))
            } catch {
                return .failure(Unavailable(description: "wpe-shaderc at \(location.helper.path) unusable: \(error)"))
            }
        }
        return .failure(Unavailable(description: "wpe-shaderc toolchain missing: \(missing.joined(separator: ", "))"))
    }
}
#endif
