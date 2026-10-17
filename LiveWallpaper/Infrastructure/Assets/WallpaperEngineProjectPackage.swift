#if !LITE_BUILD
import Foundation

extension WallpaperEngineProject {
    static let defaultPackageFileName = "scene.pkg"

    /// `<stem of the project file>.pkg` when that file exists in `folder`, else `scene.pkg`.
    /// Existence is the only check here; callers keep their own containment and readability checks.
    static func packageFileName(entryFile: String?, in folder: URL, fileManager: FileManager = .default) -> String {
        let name = ((entryFile ?? "").replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        guard !stem.isEmpty else { return defaultPackageFileName }
        let derived = stem + ".pkg"
        guard fileManager.fileExists(atPath: folder.appendingPathComponent(derived, isDirectory: false).path) else {
            return defaultPackageFileName
        }
        return derived
    }

    func packageFileName(in folder: URL, fileManager: FileManager = .default) -> String {
        Self.packageFileName(entryFile: entryFile, in: folder, fileManager: fileManager)
    }
}
#endif
