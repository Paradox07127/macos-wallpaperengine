import Foundation

enum PackageTestAssets {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/TextAssets", isDirectory: true)
    static let fonts = root.appendingPathComponent("fonts", isDirectory: true)
}
