import Foundation
import Testing

/// `CGContext(data:)` keeps the pointer and writes through it when the context draws — after
/// `&array` has stopped being valid. The buffer has to be pinned for as long as the context
/// exists, so the context has to be built inside `withUnsafeMutableBytes`.
@Suite("Bitmap contexts never take an inout array pointer")
struct BitmapContextBufferGuardTests {
    @Test("No shipped source hands CGContext an inout array")
    func noInoutBitmapBuffers() throws {
        var offenders: [String] = []
        for directory in ["LiveWallpaper", "Packages", "SystemWallpaperProvider", "SteamConnector"] {
            for file in RepositoryRoot.swiftFiles(under: directory) {
                let path = RepositoryRoot.relativePath(of: file)
                guard !path.contains("/Tests/") else { continue }
                let contents = try String(contentsOf: file, encoding: .utf8)
                guard contents.contains("CGContext(") else { continue }
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() where line.contains("data: &") {
                    offenders.append("\(path):\(index + 1)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            Comment(rawValue: "build the context inside withUnsafeMutableBytes: \(offenders.joined(separator: ", "))")
        )
    }
}
