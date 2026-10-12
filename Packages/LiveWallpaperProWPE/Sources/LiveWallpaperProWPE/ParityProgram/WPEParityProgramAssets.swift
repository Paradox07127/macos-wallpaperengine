import Foundation

/// WPE's file lookup for one wallpaper: the wallpaper first, then each WPE `assets` root in order. The 2.8.42
/// capture manifest lists every stage's own root (the wallpaper's `shaders/` for workshop effects) ahead of
/// `wpeassets/shaders`, and includes resolve through that same list.
public struct WPEParityProgramAssets: WPEShaderSourceProviding {
    public enum Source: Sendable {
        case directory(URL)
        /// Files the caller reads by relative path, such as entries of a `scene.pkg`; the URL is the directory
        /// the lookup stands for (the folder holding the package).
        case lookup(URL, @Sendable (String) -> Data?)

        var root: URL {
            switch self {
            case let .directory(url), let .lookup(url, _): url
            }
        }

        func data(_ path: String) -> Data? {
            switch self {
            case let .directory(root):
                let url = root.appendingPathComponent(path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { return nil }
                return try? Data(contentsOf: url, options: .mappedIfSafe)
            case let .lookup(_, read):
                return read(path)
            }
        }
    }

    /// Searched in order; the first source that has a file wins.
    public let sources: [Source]

    public var roots: [URL] {
        sources.map(\.root)
    }

    public init(sources: [Source]) {
        self.sources = sources
    }

    public init(sceneDirectory: URL, assetRoots: [URL]) {
        self.init(sources: ([sceneDirectory] + assetRoots).map(Source.directory))
    }

    public func data(_ path: String) -> Data? {
        sources.lazy.compactMap { $0.data(path) }.first
    }

    public func json(_ path: String) -> WPESceneJSONValue? {
        guard let data = data(path), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return WPESceneJSONValue(jsonValue: object)
    }

    public func shaderSource(named name: String) -> [UInt8]? {
        data(name).map(Array.init)
    }
}
