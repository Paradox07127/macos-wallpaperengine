import Foundation
import LiveWallpaperCore

struct AerialThumbnailCacheKey: Hashable {
    private let path: String
    private let fileSize: Int64

    var previewKey: String {
        "aerial::\(path)::\(fileSize)"
    }

    init(asset: AerialAsset) {
        path = asset.url.standardizedFileURL.path
        fileSize = asset.fileSize ?? -1
    }
}
