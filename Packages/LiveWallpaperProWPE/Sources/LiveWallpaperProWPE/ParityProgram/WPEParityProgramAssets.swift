import Foundation

/// WPE's file lookup for one wallpaper: the wallpaper directory first, then each WPE `assets` root in order. The
/// 2.8.42 capture manifest lists every stage's own root (the wallpaper's `shaders/` for workshop effects) ahead of
/// `wpeassets/shaders`, and includes resolve through that same list.
public struct WPEParityProgramAssets: WPEShaderSourceProviding {
    public let roots: [URL]

    public init(sceneDirectory: URL, assetRoots: [URL]) {
        roots = [sceneDirectory] + assetRoots
    }

    public func data(_ path: String) -> Data? {
        for root in roots {
            var isDirectory: ObjCBool = false
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return try? Data(contentsOf: url)
            }
        }
        return nil
    }

    public func json(_ path: String) -> WPESceneJSONValue? {
        guard let data = data(path), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return WPESceneJSONValue(jsonValue: object)
    }

    public func shaderSource(named name: String) -> [UInt8]? {
        data(name).map(Array.init)
    }
}
