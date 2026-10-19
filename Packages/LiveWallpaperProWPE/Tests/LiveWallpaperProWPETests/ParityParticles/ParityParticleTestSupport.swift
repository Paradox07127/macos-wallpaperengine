import Foundation
@testable import LiveWallpaperProWPE
import simd

enum ParityParticleTestSupport {
    static func json(_ text: String) -> WPESceneJSONValue {
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        return object.flatMap { WPESceneJSONValue(jsonValue: $0) } ?? .null
    }

    /// The product draw entry with the root's own placement, an identity world and every material ready.
    static func drawBatches(_ scene: inout WPEParityParticleScene, _ objectID: String) -> [WPEParityParticleDrawBatch] {
        let owner = scene.objects.first { $0.id == objectID }?.system.instanceTransform ?? matrix_identity_float4x4
        return scene.drawStream(objectID: objectID, ownerModel: owner, worldModel: matrix_identity_float4x4) { _ in
            false
        }.batches
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
