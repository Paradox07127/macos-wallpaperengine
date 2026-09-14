#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

enum WPESceneAssetProviderError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case fileMissing(String)
    case unreadable(String)
    case stagingUnavailable(String)
}

protocol WPESceneAssetProvider: Sendable {
    func data(atRelativePath relativePath: String) throws -> Data
    func stagedURL(atRelativePath relativePath: String) throws -> URL
    func exists(atRelativePath relativePath: String) -> Bool
    /// Package maps `scene.pkg` once and windows the entry; directory `data` is already `.mappedIfSafe`, so the default full-range wrap is correct.
    func mappedWindow(atRelativePath relativePath: String) throws -> WPEMappedByteSpan
    var entryNames: [String] { get }
}

extension WPESceneAssetProvider {
    func mappedWindow(atRelativePath relativePath: String) throws -> WPEMappedByteSpan {
        WPEMappedByteSpan(data: try data(atRelativePath: relativePath))
    }
}

final class WPESecurityScopedSceneAssetProvider: WPESceneAssetProvider, @unchecked Sendable {
    private let wrapped: any WPESceneAssetProvider
    private let scopedURL: URL
    private let didStartAccessing: Bool

    init(wrapped: any WPESceneAssetProvider, scopedURL: URL, didStartAccessing: Bool) {
        self.wrapped = wrapped
        self.scopedURL = scopedURL
        self.didStartAccessing = didStartAccessing
    }

    deinit {
        if didStartAccessing {
            scopedURL.stopAccessingSecurityScopedResource()
        }
    }

    func data(atRelativePath relativePath: String) throws -> Data {
        try wrapped.data(atRelativePath: relativePath)
    }

    func stagedURL(atRelativePath relativePath: String) throws -> URL {
        try wrapped.stagedURL(atRelativePath: relativePath)
    }

    func exists(atRelativePath relativePath: String) -> Bool {
        wrapped.exists(atRelativePath: relativePath)
    }

    func mappedWindow(atRelativePath relativePath: String) throws -> WPEMappedByteSpan {
        try wrapped.mappedWindow(atRelativePath: relativePath)
    }

    var entryNames: [String] {
        wrapped.entryNames
    }
}
#endif
