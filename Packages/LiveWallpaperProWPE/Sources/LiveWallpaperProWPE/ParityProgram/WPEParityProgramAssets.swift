import Foundation
import LiveWallpaperCore
import os

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

    struct ShaderDeclarations: Sendable {
        /// Per stage; geometry only when `shaders/<name>.geom` exists.
        let uniforms: [WPEHLSLStage: [String: WPEParityMaterialUniform]]
        let annotations: WPEShaderAnnotationCombos
    }

    /// Searched in order; the first source that has a file wins.
    public let sources: [Source]
    /// The load's effective user property values; material-file `{"user": K, "value": V}` constants take `[K]`.
    public var userValues: [String: WallpaperEngineProjectPropertyValue] = [:]

    /// Keyed by shader name; a wallpaper's shader files do not change while its assets live.
    private let declarations = OSAllocatedUnfairLock(initialState: [String: ShaderDeclarations]())
    /// Keyed by path; a `nil` value records a missing or unparsable file.
    private let parsedJSON = OSAllocatedUnfairLock(initialState: [String: WPESceneJSONValue?]())
    /// Keyed by texture name; a nil value records a missing file or a render-target name.
    private let textureHeaders = OSAllocatedUnfairLock(initialState: [String: WPEParityProgramTextureHeader?]())
    /// Keyed by shader name.
    private let expanded = OSAllocatedUnfairLock(
        initialState: [String: (names: WPEHLSLProgramSources, vertex: String, geometry: String?, fragment: String)]()
    )
    /// A stored failure rethrows the rewrite's own error.
    private let rewrites = OSAllocatedUnfairLock(initialState: [RewriteKey: Result<WPEHLSLProgram, any Error>]())

    private struct RewriteKey: Hashable {
        let shader: String
        let defines: [WPEShaderDefine]
    }

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
        for source in sources {
            if let data = source.data(path) {
                return data
            }
        }
        return nil
    }

    public func json(_ path: String) -> WPESceneJSONValue? {
        if let stored = parsedJSON.withLock({ $0[path] }) {
            return stored
        }
        let computed: WPESceneJSONValue? = if let data = data(path),
                                              let object = try? JSONSerialization.jsonObject(with: data) {
            WPESceneJSONValue(jsonValue: object)
        } else {
            nil
        }
        return parsedJSON.withLock { memo in
            let first = memo[path] ?? computed
            memo[path] = first
            return first
        }
    }

    func memoizedTextureHeader(_ name: String,
                               _ read: () -> WPEParityProgramTextureHeader?) -> WPEParityProgramTextureHeader? {
        if let stored = textureHeaders.withLock({ $0[name] }) {
            return stored
        }
        let computed = read()
        return textureHeaders.withLock { memo in
            let first = memo[name] ?? computed
            memo[name] = first
            return first
        }
    }

    public func shaderSource(named name: String) -> [UInt8]? {
        data(name).map(Array.init)
    }

    func shaderDeclarations(_ shader: String) -> ShaderDeclarations {
        if let stored = declarations.withLock({ $0[shader] }) {
            return stored
        }
        let sources = expandedSources(shader)
        var stages: [WPEHLSLStage: String] = [.vertex: sources.vertex, .fragment: sources.fragment]
        stages[.geometry] = sources.geometry
        let computed = ShaderDeclarations(
            uniforms: stages.mapValues(WPEParityProgramConstants.uniforms),
            annotations: WPEShaderAnnotationCombos(vertexSource: sources.vertex, fragmentSource: sources.fragment)
        )
        return declarations.withLock { memo in
            let first = memo[shader] ?? computed
            memo[shader] = first
            return first
        }
    }

    func expandedSources(_ shader: String)
        -> (names: WPEHLSLProgramSources, vertex: String, geometry: String?, fragment: String) {
        if let stored = expanded.withLock({ $0[shader] }) {
            return stored
        }
        let computed = WPEParityProgramResolver.expandedSources(shader: shader, sources: self)
        return expanded.withLock { memo in
            let first = memo[shader] ?? computed
            memo[shader] = first
            return first
        }
    }

    /// `defines` is the full define list the rewrite consumes; `rewrite` runs only for an unseen pair.
    func rewritten(_ shader: String, defines: [WPEShaderDefine],
                   _ rewrite: () throws -> WPEHLSLProgram) throws -> WPEHLSLProgram {
        let key = RewriteKey(shader: shader, defines: defines)
        if let stored = rewrites.withLock({ $0[key] }) {
            return try stored.get()
        }
        let computed = Result(catching: rewrite)
        return try rewrites.withLock { memo in
            let first = memo[key] ?? computed
            memo[key] = first
            return first
        }.get()
    }
}
