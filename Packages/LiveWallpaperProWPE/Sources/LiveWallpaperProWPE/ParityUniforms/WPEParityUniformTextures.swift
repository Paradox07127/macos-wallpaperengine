/// One TEXS sprite frame in pixels of its sheet image (14015e1d0.c:181-192).
public struct WPEParityUniformSpriteFrame: Sendable {
    public var x: Float, y: Float
    public var widthX: Float, widthY: Float
    public var heightX: Float, heightY: Float
    public var imageWidth: Float, imageHeight: Float

    public init(x: Float, y: Float, widthX: Float, widthY: Float, heightX: Float, heightY: Float,
                imageWidth: Float, imageHeight: Float) {
        self.x = x
        self.y = y
        self.widthX = widthX
        self.widthY = widthY
        self.heightX = heightX
        self.heightY = heightY
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public var rotation: SIMD4<Float> {
        SIMD4(widthX / imageWidth, widthY / imageHeight, heightX / imageWidth, heightY / imageHeight)
    }

    public var translation: SIMD2<Float> {
        SIMD2(x / imageWidth, y / imageHeight)
    }
}

public struct WPEParityUniformTexture: Sendable {
    public var textureWidth: UInt32, textureHeight: UInt32
    public var imageWidth: UInt32, imageHeight: UInt32
    /// The texture's int at +0xd0 (1400d8300.c cases 0x52-0x5b); its meaning is unconfirmed.
    public var mipMapInfo: Int32
    public var spriteFrame: WPEParityUniformSpriteFrame?

    public init(textureWidth: UInt32, textureHeight: UInt32, imageWidth: UInt32, imageHeight: UInt32,
                mipMapInfo: Int32, spriteFrame: WPEParityUniformSpriteFrame? = nil) {
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.mipMapInfo = mipMapInfo
        self.spriteFrame = spriteFrame
    }
}

/// g_TextureN* (1400d8300.c cases 0x2a-0x5b).
public enum WPEParityUniformTextures {
    public static let slotCount = 10
    public static let rotationNames = (0 ..< slotCount).map { "g_Texture\($0)Rotation" }
    public static let translationNames = (0 ..< slotCount).map { "g_Texture\($0)Translation" }

    /// Rotation/Translation are emitted only for a bound texture with a sprite frame.
    public static func values(slot: Int, texture: WPEParityUniformTexture?) -> [String: WPECBufferValue] {
        let prefix = "g_Texture\(slot)"
        guard let texture else {
            return [
                prefix + "Resolution": .vector([2, 2, 2, 2]),
                prefix + "Texel": .vector([0.5, 0.5, 2, 2]),
                prefix + "MipMapInfo": .float(1),
            ]
        }
        let width = Float(texture.textureWidth)
        let height = Float(texture.textureHeight)
        var values: [String: WPECBufferValue] = [
            prefix + "Resolution": .vector([width, height, Float(texture.imageWidth), Float(texture.imageHeight)]),
            prefix + "Texel": .vector([1 / width, 1 / height, width, height]),
            prefix + "MipMapInfo": .float(max(0, Float(texture.mipMapInfo))),
        ]
        if let frame = texture.spriteFrame {
            let rotation = frame.rotation
            let translation = frame.translation
            values[prefix + "Rotation"] = .vector([rotation.x, rotation.y, rotation.z, rotation.w])
            values[prefix + "Translation"] = .vector([translation.x, translation.y])
        }
        return values
    }
}
