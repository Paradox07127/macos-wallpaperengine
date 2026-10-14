#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Release uses only the bundled toolchain; Debug can explicitly opt into local binaries through its environment.
enum WPEParityShaderToolchain {
    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    private struct Location {
        let origin: String
        let helper: URL
        let dxcompiler: URL
        let metalIRConverter: URL
    }

    static func makeCompiler() -> Result<WPEParityHelperShaderCompiler, Unavailable> {
        let contents = Bundle.main.bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        var locations = [Location(origin: "app-bundle", helper: contents.appending(path: "MacOS/wpe-shaderc"),
                                  dxcompiler: contents.appending(path: "Frameworks/libdxcompiler.dylib"),
                                  metalIRConverter: contents.appending(path: "Frameworks/libmetalirconverter.dylib"))]
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let helper = environment["WPE_SHADERC"], !helper.isEmpty,
           let dxcompiler = environment["WPE_DXCOMPILER"], !dxcompiler.isEmpty,
           let metalIRConverter = environment["WPE_METALIRCONVERTER"], !metalIRConverter.isEmpty {
            locations.append(Location(origin: "debug-environment", helper: URL(fileURLWithPath: helper),
                                      dxcompiler: URL(fileURLWithPath: dxcompiler),
                                      metalIRConverter: URL(fileURLWithPath: metalIRConverter)))
        }
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
                let compiler = try WPEParityHelperShaderCompiler(
                    helper: location.helper, dxcompiler: location.dxcompiler,
                    metalIRConverter: location.metalIRConverter,
                    workDirectory: FileManager.default.temporaryDirectory.appending(path: "wpe-shaderc",
                                                                                    directoryHint: .isDirectory)
                )
                Logger.notice("WPE parity toolchain appPID=\(ProcessInfo.processInfo.processIdentifier) "
                    + "origin=\(location.origin) helper=\(location.helper.lastPathComponent) "
                    + "dxcompiler=\(location.dxcompiler.lastPathComponent) msc=\(location.metalIRConverter.lastPathComponent) "
                    + "compilerIdentity=\(compiler.compilerIdentity)", category: .wpeRender)
                return .success(compiler)
            } catch {
                return .failure(Unavailable(description: "wpe-shaderc at \(location.helper.path) unusable: \(error)"))
            }
        }
        return .failure(Unavailable(description: "wpe-shaderc toolchain missing: \(missing.joined(separator: ", "))"))
    }
}
#endif
