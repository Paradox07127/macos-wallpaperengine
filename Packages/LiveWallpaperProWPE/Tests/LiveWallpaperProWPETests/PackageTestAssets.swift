import CoreText
import Foundation

enum PackageTestAssets {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/TextAssets", isDirectory: true)
    static let fonts = root.appendingPathComponent("fonts", isDirectory: true)

    static func fontDescriptor(file: String, postScriptName: String) throws -> CTFontDescriptor {
        let url = fonts.appendingPathComponent(file)
        _ = try Data(contentsOf: url)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first(where: {
                  CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String == postScriptName
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return descriptor
    }
}
