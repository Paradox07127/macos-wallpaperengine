import Foundation
@testable import LiveWallpaperProWPE

enum ParityParticleTestSupport {
    static func json(_ text: String) -> WPESceneJSONValue {
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        return object.flatMap { WPESceneJSONValue(jsonValue: $0) } ?? .null
    }

    static func liveSlots(_ system: WPEParityParticleSystem) -> [Int] {
        system.lifetime.indices.filter { system.lifetime[$0] != 0 }
    }

    static func float(_ bytes: [UInt8], at offset: Int) -> Float {
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }

    static func floats(_ bytes: [UInt8], at offset: Int, count: Int) -> [Float] {
        (0 ..< count).map { float(bytes, at: offset + $0 * 4) }
    }
}
